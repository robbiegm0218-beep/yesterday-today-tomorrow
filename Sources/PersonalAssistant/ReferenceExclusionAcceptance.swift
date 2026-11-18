import Foundation

final class ExclusionFixtureProtocol:URLProtocol,@unchecked Sendable {
    struct Reply { var calls:[DeepSeekToolCall]=[]; var text:String?=nil }
    private static let lock=NSLock()
    private static var replies:[Reply]=[],bodies:[String]=[],delay:Double=0
    private let instanceLock=NSLock();private var stopped=false
    static func configure(_ replies:[Reply],delay:Double=0) {lock.withLock{Self.replies=replies;bodies=[];Self.delay=delay}}
    static var captured:[String] {lock.withLock{bodies}}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        var bytes=request.httpBody ?? Data()
        if bytes.isEmpty,let stream=request.httpBodyStream {stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0 {break};bytes.append(buffer,count:n)}}
        let (reply,pause)=Self.lock.withLock {Self.bodies.append(String(decoding:bytes,as:UTF8.self));return(Self.replies.isEmpty ? Reply(text:"未提供对应字段") : Self.replies.removeFirst(),Self.delay)}
        let stream=((try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any])?["stream"] as? Bool == true
        var message:[String:Any]=[:]
        if let text=reply.text {message["content"]=text}
        if !reply.calls.isEmpty {message["tool_calls"]=reply.calls.enumerated().map {i,c in ["index":i,"id":c.id,"type":"function","function":["name":c.function.name,"arguments":c.function.arguments]] as [String:Any]}}
        let payload:[String:Any]=["choices":[["index":0,stream ? "delta":"message":message,"finish_reason":reply.calls.isEmpty ? "stop":"tool_calls"]],"model":"offline-reference-question","usage":["prompt_tokens":10,"completion_tokens":2,"total_tokens":12]]
        let json=try! JSONSerialization.data(withJSONObject:payload);let data=stream ? Data(("data: "+String(decoding:json,as:UTF8.self)+"\n\ndata: [DONE]\n\n").utf8):json
        let deliver:@Sendable ()->Void = {[self] in
            guard !instanceLock.withLock({stopped}) else {return}
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":stream ? "text/event-stream":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        }
        if pause>0 {DispatchQueue.global().asyncAfter(deadline:.now()+pause,execute:deliver)} else {deliver()}
    }
    override func stopLoading() {instanceLock.withLock{stopped=true}}
}


@MainActor enum ReferenceExclusionAcceptance {
    nonisolated static let correction="不是第二个，是第三个，负责人和截止日期是什么？"
    nonisolated static let exclusion="排除原列表第二个和第三个，剩下的负责人是谁？"
    static func seed() throws {
        try ReferenceQuestionAcceptance.seed()
        var rows=LocalTodoStore.load();rows[0].owner="陈一";rows[3].owner="何四";try LocalTodoStore.save(rows)
    }
    static func run(_ index:Int) async->Bool {
        let live=index==148,resume=CommandLine.arguments.contains{$0.hasPrefix("--resume-sandbox=")},root=LocalAssistantPaths.dataDirectory
        var checks:[String:Bool]=[:],failure:String?,checkpoint=false,extractions=0,priorCalls=0,external=0,tokens=0,measured=true
        var liveApp:AssistantModel?
        do {
            if !resume {AssistantRuntime.preferences.set(true,forKey:"autoMemoryEnabled");AssistantRuntime.preferences.set([String](),forKey:"dingTalkSelectedProfiles");try LocalSkillStore.save(AssistantSkill.defaults);try seed()}
            let key:String
            if live {guard let saved=DeepSeekCredentialStore.load(),!saved.isEmpty else {throw ProjectUpdateError.invalid("saved_credential_unavailable")};key=saved} else {key="offline-placeholder"}
            let source=CardAcceptanceDataSource()
            func model()->AssistantModel {
                let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ExclusionFixtureProtocol.self]
                return AssistantModel(dailyDataSource:source,services:.init(chatClient:live ? DeepSeekClient():DeepSeekClient(session:URLSession(configuration:config)),memoryExtractor:{_,_ in extractions+=1;return []},apiKey:{key}))
            }
            func configure(_ replies:[ExclusionFixtureProtocol.Reply],delay:Double=0) {priorCalls+=ExclusionFixtureProtocol.captured.count;ExclusionFixtureProtocol.configure(replies,delay:delay)}
            var app=model();if live {liveApp=app};let rows=app.personalTodos
            let before=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))
            func send(_ text:String) async throws {app.draft=text;app.sendMessage();for _ in 0..<9500 {if !app.isSending && !app.isRefreshing {return};try await Task.sleep(for:.milliseconds(10))};app.cancelChatRequest();throw ProjectUpdateError.invalid("exclusion_did_not_settle")}
            if index==144 || live {
                configure([.init(text:"负责人是周二，截止日期是2026-12-08。")]);try await send(correction)
                checks["correction_answers_original_id_without_interpretation_model"] = app.messages.last?.conversationFocus?.references == [.personal(rows[2].id)] && app.assistantRuns.count==1 && app.assistantRuns[0].modelRequests==1 && app.assistantRuns[0].readCalls==1
                checks["correct_fields_no_renewed_reference_doubt_or_card"] = app.messages.last?.text.contains("周二")==true && app.messages.last?.text.contains("2026-12-08")==true && app.messages.last?.text.contains("无法确认") != true && app.messages.last?.text.contains("无法核对") != true && app.messages.last?.pendingActions==nil
                if !live {checks["only_corrected_target_facts_reach_answer"] = ExclusionFixtureProtocol.captured.count==1 && ExclusionFixtureProtocol.captured[0].contains(rows[2].id.uuidString) && !ExclusionFixtureProtocol.captured[0].contains("林一")}
            } else if index==145 {
                if !resume {
                    configure([]);try await send(exclusion)
                    checks["multiple_remaining_choices_clarify_without_model"] = app.messages.last?.conversationFocus?.references == [.personal(rows[0].id),.personal(rows[3].id)] && app.messages.last?.referenceQuestionPending?.question==exclusion && app.assistantRuns[0].modelRequests==0 && ExclusionFixtureProtocol.captured.isEmpty
                    try JSONEncoder().encode(checks).write(to:root.appendingPathComponent("exclusion-checks.json"));AssistantRuntime.preferences.synchronize();checkpoint=true
                } else {
                    let run=app.assistantRuns[0];configure([.init(text:"负责人为何四。")]);try await send("第二个")
                    checks["restart_selection_keeps_full_question_and_exact_remaining_id"] = app.messages.last?.text.contains("何四")==true && app.messages.last?.conversationFocus?.references == [.personal(rows[3].id)] && app.messages.last?.referenceQuestionPending==nil
                    checks["same_original_run_and_budget_after_exclusion"] = app.assistantRuns.count==1 && app.assistantRuns[0].id==run.id && app.assistantRuns[0].requestHash==run.requestHash && app.assistantRuns[0].modelRequests==1 && app.assistantRuns[0].readCalls==2 && ExclusionFixtureProtocol.captured.count==1
                }
            } else if index==146 {
                configure([])
                for text in ["不是第二个，是第二个，负责人是谁？","排除第七个，负责人是谁？","排除第二个，剩下未完成那项负责人是谁？","不是第二个，改成第三个，再修改负责人为林一"] {
                    try seed();app=model();let current=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"));try await send(text)
                    let after=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))
                    checks["reject_"+String(checks.count)] = app.messages.last?.pendingActions==nil && app.messages.last?.referenceQuestionPending==nil && app.assistantRuns.last?.modelRequests==0 && after==current
                }
                checks["invalid_or_mixed_corrections_never_call_model"] = ExclusionFixtureProtocol.captured.isEmpty
                try seed();app=model();try await send("排除原列表第二个，是第三个")
                checks["focus_only_correction_is_local_without_business_operation"] = app.messages.last?.conversationFocus?.references == [.personal(app.personalTodos[2].id)] && app.assistantRuns.last?.modelRequests==0 && app.messages.last?.pendingActions==nil && app.messages.last?.referenceQuestionPending==nil
            } else if index==147 {
                configure([.init(text:"不该显示的迟到答案")],delay:0.15);app.draft=correction;app.sendMessage()
                for _ in 0..<200 {if !ExclusionFixtureProtocol.captured.isEmpty {break};try await Task.sleep(for:.milliseconds(5))};app.selectedDingTalkProfileIDs=["changed-scope"]
                for _ in 0..<200 {if !app.isSending {break};try await Task.sleep(for:.milliseconds(10))}
                checks["scope_change_discards_late_corrected_answer"] = !app.isSending && app.messages.last?.text.contains("迟到答案") != true && app.messages.last?.pendingActions==nil
                app.selectedDingTalkProfileIDs=[];try seed();app=model();configure([]);try await send(exclusion)
                let oldID=app.personalTodos[3].id;var remaining=app.personalTodos.filter{$0.id != oldID};remaining.append(.init(title:"星河评审任务",importance:.normal));try CreatedTodoAcceptance.raw(remaining);app=model()
                let count=ExclusionFixtureProtocol.captured.count;try await send("第二个")
                checks["missing_remaining_id_never_slides_to_same_name"] = ExclusionFixtureProtocol.captured.count==count && app.messages.last?.text.contains("何四") != true && app.messages.last?.pendingActions==nil
                try seed();var all=LocalTodoStore.load();var named=PersonalTodo(title:"独立需求评审",importance:.normal);named.owner="独立负责人";all.append(named);try LocalTodoStore.save(all)
                AssistantRuntime.preferences.set(false,forKey:"autoMemoryEnabled");app=model();configure([.init(text:"独立需求评审的负责人为独立负责人。")]);try await send("不是第二个，是第三个，独立需求评审负责人是谁？")
                checks["explicit_new_name_wins_over_old_number_correction"] = app.messages.last?.conversationFocus?.references == [.personal(named.id)] && app.messages.last?.text.contains("独立负责人")==true
            }
            if index != 146 && index != 147 {checks["business_source_unchanged"] = try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))==before}
            checks["no_remote_refresh"] = source.calls==0;checks["no_memory_extraction"] = extractions==0
            if resume,let saved=try? JSONDecoder().decode([String:Bool].self,from:Data(contentsOf:root.appendingPathComponent("exclusion-checks.json"))) {checks.merge(saved){a,_ in a}}
        } catch {failure=String(error.localizedDescription.prefix(400))}
        if live,let app=liveApp {external=app.assistantRuns.reduce(0){$0+$1.modelRequests};tokens=app.assistantRuns.reduce(0){$0+$1.tokens};measured=app.assistantRuns.allSatisfy(\.usageComplete)}
        let pass=failure==nil && !checks.isEmpty && checks.values.allSatisfy{$0}
        let report:[String:Any]=["case_id":"INT-\(index)","outcome":checkpoint ? "restart_required":pass ? "pass":"fail","checks":checks,"failure":failure ?? "none","processID":ProcessInfo.processInfo.processIdentifier,"sandboxPath":root.path,"processRestarted":resume,"modelRequests":external,"externalModelRequests":external,"tokens":tokens,"usageComplete":measured,"simulatedModelRequests":live ? 0:priorCalls+ExclusionFixtureProtocol.captured.count,"automaticBusinessWrites":0,"qualityScore":NSNull()]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {print("AGENT_SCENARIO_RESULT: "+String(decoding:data,as:UTF8.self));fflush(stdout)}
        AgentScenarioAcceptance.didCheckpoint=checkpoint;if !checkpoint {AssistantRuntime.finishEvaluationPreferences()};return pass && !checkpoint
    }
}
