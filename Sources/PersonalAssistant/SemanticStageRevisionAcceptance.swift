import Foundation

final class StageAlternativeFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var call: DeepSeekToolCall?, bodies: [String] = [], pause: Double = 0
    private let instanceLock = NSLock()
    private var stopped = false
    static var captured: [String] { lock.lock(); defer { lock.unlock() }; return bodies }
    static func configure(_ call: DeepSeekToolCall, delay: Double = 0) { lock.lock(); defer { lock.unlock() }; self.call = call; bodies = []; pause = delay }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; bytes.append(buffer,count:n) }
        }
        Self.lock.lock(); Self.bodies.append(String(decoding:bytes,as:UTF8.self)); let operation = Self.call!, delay = Self.pause; Self.lock.unlock()
        let streamed = ((try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any])?["stream"] as? Bool == true
        let tool: [String:Any] = ["index":0,"id":operation.id,"type":"function","function":["name":operation.function.name,"arguments":operation.function.arguments]]
        let payload: [String:Any] = ["choices":[["index":0,streamed ? "delta" : "message":["tool_calls":[tool]],"finish_reason":"tool_calls"]],"model":"offline-reference","usage":["prompt_tokens":10,"completion_tokens":2,"total_tokens":12]]
        let json = try! JSONSerialization.data(withJSONObject:payload)
        let data = streamed ? Data(("data: " + String(decoding:json,as:UTF8.self) + "\n\ndata: [DONE]\n\n").utf8) : json
        let deliver: @Sendable () -> Void = { [self] in
            instanceLock.lock(); let cancelled = stopped; instanceLock.unlock(); if cancelled { return }
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":streamed ? "text/event-stream" : "application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline:.now()+delay,execute:deliver) } else { deliver() }
    }
    override func stopLoading() { instanceLock.lock(); stopped = true; instanceLock.unlock() }
}



@MainActor enum SemanticStageRevisionAcceptance {
    static func operation() -> DeepSeekToolCall {
        let data = try! JSONSerialization.data(withJSONObject: ["instruction":"先列出现有原型评审资料中的已知事实与缺口，再按原完成条件逐项核对；缺少资料时明确追问，不扩大任务范围。", "reason":"先区分已知与缺口，避免在资料不足时直接总结。"])
        return .init(id:"alternative",function:.init(name:SemanticStageRevision.name,arguments:String(decoding:data,as:UTF8.self)))
    }
    static func seed(scope: String) throws {
        let ledger = AssistantRunLedger()
        let user = AssistantMessage(text:"请分阶段整理原型评审资料，先核对资料，再整理结论",isUser:true)
        let parentID = try ledger.start(message:user,scope:scope)
        let plan = AssistantGoalStagePlan(requestHash:ledger.rows[0].requestHash,stages:[
            .init(title:"核对资料",instruction:"阅读已有原型评审资料并列出要点",criterion:"明确已知事实、缺少的资料及各自依据，信息不足明确说明",reviewMode:"read_review",dependencies:[]),
            .init(title:"整理结论",instruction:"根据已核对资料整理结论",criterion:"结论可追溯到已核对资料",reviewMode:"read_review",dependencies:[0])])
        let reply = AssistantMessage(text:"核对并采用阶段方案",isUser:false,goalPlanDraft:plan)
        try ledger.finish(parentID,reply:reply,state:.awaitingConfirmation,note:"待采用")
        try ledger.installStagePlan(plan,parentID:parentID,replyID:reply.id,scope:scope)
        let childID = try ledger.start(message:.init(text:"执行原阶段",isUser:true),scope:scope,parentID:parentID,stageIndex:0)
        let question = AssistantStageQuestion(runID:childID,purpose:"missing_details",question:"请补充本阶段要核对的资料摘要",choices:[])
        let ask = AssistantMessage(text:question.displayText,isUser:false,stageQuestion:question)
        try ledger.finish(childID,reply:ask,state:.responded,note:"等待资料")
        LocalConversationStore.save([user,reply,ask])
    }
    static func run(_ index: Int) async -> Bool {
        let live = index == 138, root = LocalAssistantPaths.dataDirectory
        let resume = CommandLine.arguments.contains { $0.hasPrefix("--resume-sandbox=") }
        var checks:[String:Bool]=[:], failure:String?, checkpoint=false, extractionCalls=0, external=0,tokens=0,measured=true
        var appForUsage:AssistantModel?
        do {
            let key:String
            if live {guard let value=DeepSeekCredentialStore.load(),!value.isEmpty else {throw ProjectUpdateError.invalid("saved_credential_unavailable")};key=value} else {key="offline-placeholder"}
            let source=CardAcceptanceDataSource()
            func model() -> AssistantModel {
                let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StageAlternativeFixtureProtocol.self]
                return AssistantModel(dailyDataSource:source,services:.init(chatClient:live ? DeepSeekClient() : DeepSeekClient(session:URLSession(configuration:config)),memoryExtractor:{_,_ in extractionCalls += 1;return []},apiKey:{key}))
            }
            if !resume {
                AssistantRuntime.preferences.set(true,forKey:"autoMemoryEnabled");AssistantRuntime.preferences.set([String](),forKey:"dingTalkSelectedProfiles");try LocalSkillStore.save(AssistantSkill.defaults)
                try LocalTodoStore.save([.init(title:"原业务待办保持不变",importance:.normal)])
                let initial=model();try seed(scope:initial.runScopeHash)
            }
            var app=model(); appForUsage=app
            let before=app.assistantRuns, parentID=before[0].id, childID=before[1].id
            let originalMessages = app.messages
            let sourceBefore=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))
            StageAlternativeFixtureProtocol.configure(operation())
            func send() async throws {
                app.draft="目标不变，换一种方案，先区分已知资料和缺口"
                app.sendMessage()
                for _ in 0..<5000 {if !app.isSending {return};try await Task.sleep(for:.milliseconds(10))}
                app.cancelChatRequest();throw ProjectUpdateError.invalid("alternative_did_not_settle")
            }
            if index == 134 {
                if !resume {
                    try await send()
                    let child=app.assistantRuns.first{$0.id==childID}!
                    checks["preview_without_changing_plan_question_or_receipts"] = app.stageRevisionDraft?.semanticPreviewID != nil && app.assistantRuns[0].stagePlan == before[0].stagePlan && child.stageQuestion == before[1].stageQuestion && child.receipts == before[1].receipts
                    checks["same_child_budget_one_request_no_new_goal"] = child.modelRequests == before[1].modelRequests+1 && child.tokens == before[1].tokens+12 && app.assistantRuns.count == 2 && child.originalMessageID == before[1].originalMessageID
                    try JSONEncoder().encode(checks).write(to:root.appendingPathComponent("alternative-checks.json"));AssistantRuntime.preferences.synchronize();checkpoint=true
                } else {
                    let preview=app.messages.compactMap(\.stageRevisionPreview).last!
                    app.openStageAlternative(preview.id)
                    checks["restart_reopens_bound_preview_without_model"] = app.stageRevisionDraft?.stageID == preview.stageID && StageAlternativeFixtureProtocol.captured.isEmpty
                    let d=app.stageRevisionDraft!;let budget=app.assistantRuns.first{$0.id==childID}!.budget
                    checks["confirmation_applies_only_instruction"] = app.applyStageRevision(d) && app.assistantRuns[0].stagePlan!.stages[0].instruction == preview.instruction && app.assistantRuns[0].stagePlan!.stages[0].criterion == preview.original.criterion && app.assistantRuns[0].stagePlan!.stages[1] == before[0].stagePlan!.stages[1]
                    checks["confirmed_revision_retains_identity_budget_and_stays_paused"] = app.assistantRuns.count == 2 && app.assistantRuns[1].id == childID && app.assistantRuns[1].budget.maxModelRounds == budget.maxModelRounds && app.assistantRuns[1].state == .paused && app.assistantRuns[1].stageQuestion == nil && app.messages.compactMap(\.stageRevisionPreview).last?.status == "applied"
                    app.openStageAlternative(preview.id);checks["applied_preview_cannot_replay"] = app.stageRevisionDraft == nil
                }
            } else if index == 135 {
                try await send();let preview=app.messages.compactMap(\.stageRevisionPreview).last!, current=app.assistantRuns
                let callCount = StageAlternativeFixtureProtocol.captured.count
                app.draft = "对"; app.sendMessage()
                checks["chat_ack_opens_preview_without_applying_or_calling_model"] = app.assistantRuns == current && StageAlternativeFixtureProtocol.captured.count == callCount && app.messages.compactMap(\.stageRevisionPreview).last?.status == "pending"
                app.stageRevisionDraft=nil;app.openStageAlternative(preview.id)
                checks["close_reopen_keeps_original_until_confirmation"] = app.stageRevisionDraft != nil && app.assistantRuns == current
                app.dismissStageAlternative(preview.id);app.openStageAlternative(preview.id)
                checks["dismiss_persists_without_modifying_original_stage"] = app.stageRevisionDraft == nil && app.messages.compactMap(\.stageRevisionPreview).last?.status == "dismissed" && app.assistantRuns[0].stagePlan == before[0].stagePlan && app.assistantRuns[1].stageQuestion == before[1].stageQuestion
                app=model();app.openStageAlternative(preview.id)
                checks["restart_dismissed_preview_stays_dismissed"] = app.stageRevisionDraft == nil && StageAlternativeFixtureProtocol.captured.count == 1
            } else if index == 136 {
                try await send();let preview=app.messages.compactMap(\.stageRevisionPreview).last!,d=app.stageRevisionDraft!
                var tampered=d;tampered.criterion="跳过依据直接完成"
                checks["model_preview_cannot_change_completion_criterion"] = !app.applyStageRevision(tampered) && app.assistantRuns[0].stagePlan == before[0].stagePlan
                app.selectedDingTalkProfileIDs=["changed-scope"];app.openStageAlternative(preview.id)
                checks["scope_change_refuses_preview"] = app.stageRevisionDraft == nil
                app.selectedDingTalkProfileIDs=[]
                let ledger=AssistantRunLedger();try ledger.stageTransaction {rows in rows[1].receipts=[.init(actionID:UUID(),messageID:UUID(),key:AssistantRun.digest("result"),summary:"已执行结果",state:"unverified")]}
                app=model();let calls=StageAlternativeFixtureProtocol.captured.count
                try await send()
                checks["unknown_receipt_blocks_model_and_preserves_result"] = StageAlternativeFixtureProtocol.captured.count == calls && app.stageRevisionDraft == nil && app.assistantRuns[1].receipts.first?.state == "unverified" && app.assistantRuns[0].id == parentID
            } else if index == 137 {
                StageAlternativeFixtureProtocol.configure(operation(),delay:0.25)
                app.draft="目标不变，换一种方案";app.sendMessage()
                for _ in 0..<100 {if !StageAlternativeFixtureProtocol.captured.isEmpty {break};try await Task.sleep(for:.milliseconds(5))}
                app.cancelChatRequest();try await Task.sleep(for:.milliseconds(350))
                checks["cancel_discards_late_preview_and_retains_original_question"] = app.stageRevisionDraft == nil && app.messages.compactMap(\.stageRevisionPreview).isEmpty && app.assistantRuns[0].stagePlan == before[0].stagePlan && app.assistantRuns[1].stageQuestion == before[1].stageQuestion && app.assistantRuns[1].state == before[1].state
                let l=AssistantRunLedger();try l.stageTransaction {rows in rows[1].modelRequests=4};LocalConversationStore.save(originalMessages);app=model()
                let calls=StageAlternativeFixtureProtocol.captured.count;try await send()
                checks["original_budget_exhaustion_has_no_extra_request"] = StageAlternativeFixtureProtocol.captured.count == calls && app.assistantRuns.count == 2 && app.assistantRuns[1].modelRequests == 4 && app.runStatus?.contains("预算") == true
            } else if live {
                try await send();let child=app.assistantRuns[1]
                checks["live_model_created_actual_bound_preview"] = app.stageRevisionDraft?.semanticPreviewID != nil && app.messages.compactMap(\.stageRevisionPreview).count == 1 && child.modelRequests == 1
                checks["live_preview_keeps_original_plan_and_question"] = app.assistantRuns[0].stagePlan == before[0].stagePlan && child.stageQuestion == before[1].stageQuestion && child.receipts == before[1].receipts
            }
            checks["no_source_business_writes"] = try Data(contentsOf:root.appendingPathComponent("personal-todos.json")) == sourceBefore
            checks["no_remote_refresh_or_memory_extraction"] = source.calls == 0 && extractionCalls == 0
            if resume,let saved=try? JSONDecoder().decode([String:Bool].self,from:Data(contentsOf:root.appendingPathComponent("alternative-checks.json"))) {checks.merge(saved){a,_ in a}}
        } catch {failure=String(error.localizedDescription.prefix(500))}
        if live,let app=appForUsage {external=app.assistantRuns.reduce(0){$0+$1.modelRequests};tokens=app.assistantRuns.reduce(0){$0+$1.tokens};measured=app.assistantRuns.allSatisfy(\.usageComplete)}
        let pass=failure == nil && !checks.isEmpty && checks.values.allSatisfy{$0}
        let result:[String:Any] = ["case_id":"INT-\(index)","outcome":checkpoint ? "restart_required" : pass ? "pass" : "fail","checks":checks,"failure":failure ?? "none","processID":ProcessInfo.processInfo.processIdentifier,"sandboxPath":root.path,"processRestarted":resume,"modelRequests":external,"externalModelRequests":external,"tokens":tokens,"usageComplete":measured,"simulatedModelRequests":live ? 0 : StageAlternativeFixtureProtocol.captured.count,"automaticBusinessWrites":0,"qualityScore":NSNull()]
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]) {print("AGENT_SCENARIO_RESULT: "+String(decoding:data,as:UTF8.self));fflush(stdout)}
        AgentScenarioAcceptance.didCheckpoint=checkpoint;if !checkpoint {AssistantRuntime.finishEvaluationPreferences()};return pass && !checkpoint
    }
}
