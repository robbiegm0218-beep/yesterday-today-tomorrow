import Foundation

final class SemanticReferenceFixtureProtocol: URLProtocol, @unchecked Sendable {
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

@MainActor enum SemanticReferenceAcceptance {
    static func operation(_ mode: String, position: Int, state: String, quote: String) -> DeepSeekToolCall {
        let data = try! JSONSerialization.data(withJSONObject:["mode":mode,"position":position,"state":state,"quote":quote])
        return .init(id:"semantic-reference",function:.init(name:SemanticReferenceContext.name,arguments:String(decoding:data,as:UTF8.self)))
    }
    static func seed(selected: Bool = false) throws -> [PersonalTodo] {
        var rows = (0..<4).map { _ in PersonalTodo(title:"语义指代评审",importance:.normal) }; rows[0].isComplete = true
        if selected { rows[3].isComplete = true }
        try LocalTodoStore.save(rows)
        var messages: [AssistantMessage] = [.init(text:"查看语义指代评审",isUser:true)]
        let recall = AssistantContextRecall.make(messages:messages,context:.init(todos:rows))
        messages.append(.init(text:recall.clarification,isUser:false,conversationFocus:recall.savedFocus(messages:messages,selected:[],hidden:[])))
        if selected {
            messages.append(.init(text:"第二个",isUser:true)); let next = AssistantContextRecall.make(messages:messages,context:.init(todos:rows))
            messages.append(.init(text:"原选择已保存，尚未修改事项",isUser:false,conversationFocus:next.savedFocus(messages:messages,selected:[],hidden:[])))
        }
        LocalConversationStore.save(messages); return rows
    }
    static func run(_ index: Int) async -> Bool {
        if index >= 127 { return await probe(index) }
        let root = LocalAssistantPaths.dataDirectory, resuming = CommandLine.arguments.contains { $0.hasPrefix("--resume-sandbox=") }
        var checks: [String:Bool] = [:], failure: String?, checkpoint = false, priorCalls = 0, memoryCalls = 0
        do {
            if !resuming {
                AssistantRuntime.preferences.set(true,forKey:"autoMemoryEnabled"); AssistantRuntime.preferences.set([String](),forKey:"dingTalkSelectedProfiles"); try LocalSkillStore.save(AssistantSkill.defaults); _ = try seed(selected:index == 125)
            }
            func model() -> AssistantModel {
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SemanticReferenceFixtureProtocol.self]
                return AssistantModel(dailyDataSource:LocalOnlyDailyDataSource(),services:.init(chatClient:DeepSeekClient(session:URLSession(configuration:config)),memoryExtractor:{ _,_ in memoryCalls += 1; return [] },apiKey:{ "offline-placeholder" }))
            }
            var app = model(); let rows = app.personalTodos
            let before = try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))
            func send(_ text: String) async throws { app.draft = text; app.sendMessage(); try await StageReferenceAcceptance.settle(app) }
            if index == 123 {
                SemanticReferenceFixtureProtocol.configure(operation("unclear_position_state",position:2,state:"open",quote:"刚才第二个没完成的"))
                if !resuming {
                    try await send("刚才第二个没完成的")
                    checks["two_orders_are_clarified"] = app.messages.last?.conversationFocus?.isChoice == true && app.messages.last?.conversationFocus?.references == [.personal(rows[1].id),.personal(rows[2].id)] && app.messages.last?.text.contains("筛选后") == true
                    checks["one_model_and_one_read_charged"] = app.assistantRuns.last?.modelRequests == 1 && app.assistantRuns.last?.readCalls == 1 && SemanticReferenceFixtureProtocol.captured.count == 1
                    try JSONEncoder().encode(checks).write(to:root.appendingPathComponent("semantic-checks.json")); AssistantRuntime.preferences.synchronize(); checkpoint = true
                } else {
                    try await send("第二个")
                    checks["restart_choice_is_exact_and_discussion_only"] = app.messages.last?.conversationFocus?.references == [.personal(rows[2].id)] && app.messages.last?.text.contains("已切换讨论对象") == true && SemanticReferenceFixtureProtocol.captured.isEmpty
                }
            } else if index == 124 {
                let text = "未完成的里面选第二个"
                SemanticReferenceFixtureProtocol.configure(operation("state_then_position",position:2,state:"open",quote:text)); try await send(text)
                checks["model_interpretation_checked_against_original_ids"] = app.messages.last?.conversationFocus?.references == [.personal(rows[2].id)] && app.messages.last?.text.contains("原列表第3项") == true && app.messages.last?.conversationFocus?.discussionOnly == true
                checks["same_request_budget_records_read"] = app.assistantRuns.last?.modelRequests == 1 && app.assistantRuns.last?.readCalls == 1
            } else if index == 125 {
                let text = "剩下那条还没做完的"
                SemanticReferenceFixtureProtocol.configure(operation("other",position:0,state:"open",quote:text)); try await send(text)
                checks["other_and_state_exclude_original_focus"] = app.messages.last?.conversationFocus?.references == [.personal(rows[2].id)]
                priorCalls = SemanticReferenceFixtureProtocol.captured.count
                try CreatedTodoAcceptance.raw(Array(rows.dropFirst())); app = model()
                let next = "原来的第二个还没完成的"
                SemanticReferenceFixtureProtocol.configure(operation("position_with_state",position:2,state:"open",quote:next)); try await send(next)
                checks["missing_original_does_not_slide_numbers"] = app.messages.last?.conversationFocus == nil && app.messages.last?.text.contains("原ID不可用") == true
                checks["missing_check_does_not_write_source"] = try JSONDecoder().decode([PersonalTodo].self,from:Data(contentsOf:root.appendingPathComponent("personal-todos.json"))) == Array(rows.dropFirst())
            } else {
                let text = "把刚才第二个没完成的待办标记完成"
                let args = try JSONSerialization.data(withJSONObject:["todo_id":rows[1].id.uuidString])
                SemanticReferenceFixtureProtocol.configure(.init(id:"unbound-write",function:.init(name:"complete_personal_todo",arguments:String(decoding:args,as:UTF8.self))))
                try await send(text)
                checks["unresolved_reference_cannot_skip_read_and_propose_write"] = app.messages.last?.text.contains("指代尚未") == true && app.messages.last?.pendingActions == nil && SemanticReferenceFixtureProtocol.captured.count == 1
                priorCalls = SemanticReferenceFixtureProtocol.captured.count
                _ = try seed(); app = model()
                let query = "刚才第二个没完成的"
                SemanticReferenceFixtureProtocol.configure(operation("unclear_position_state",position:2,state:"open",quote:query),delay:0.15)
                app.draft = query; app.sendMessage(); try await Task.sleep(for:.milliseconds(35)); app.selectedDingTalkProfileIDs = ["changed:self"]; try await StageReferenceAcceptance.settle(app)
                checks["scope_change_discards_late_focus"] = app.messages.last?.conversationFocus == nil && app.messages.last?.pendingActions == nil
            }
            if index != 125 && index != 126 { checks["source_unchanged"] = try Data(contentsOf:root.appendingPathComponent("personal-todos.json")) == before }
            checks["no_business_cards_or_memory_extraction"] = memoryCalls == 0 && !app.isUpdatingMemory && app.messages.allSatisfy { ($0.pendingActions ?? []).isEmpty }
            if resuming, let old = try? JSONDecoder().decode([String:Bool].self,from:Data(contentsOf:root.appendingPathComponent("semantic-checks.json"))) { checks.merge(old) { a,_ in a } }
        } catch { failure = AssistantTurnDiagnostic.category(for:error) }
        let passed = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report(index,status:checkpoint ? "restart_required" : passed ? "pass" : "fail",checks:checks,failure:failure,simulated:priorCalls + SemanticReferenceFixtureProtocol.captured.count)
        AgentScenarioAcceptance.didCheckpoint = checkpoint; if !checkpoint { AssistantRuntime.finishEvaluationPreferences() }; return passed && !checkpoint
    }
    static func probe(_ index: Int) async -> Bool {
        var checks: [String:Bool] = [:], failure: String?, calls = 0, tokens = 0, measured = false, text = ""
        do {
            guard let key = DeepSeekCredentialStore.load(), !key.isEmpty else { throw ProjectUpdateError.invalid("saved_credential_unavailable") }
            let rows = try seed()
            var messages = LocalConversationStore.load()
            let query = index == 127 ? "刚才第二个没完成的" : "未完成的里面，我想看排第二的那条"
            messages.append(.init(text:query,isUser:true)); var context = AssistantReadContext(todos:rows)
            context.semanticReference = SemanticReferenceContext.make(messages:messages,context:context)
            let payload = [DeepSeekChatMessage(role:"system",content:"你是个人助手。本轮只核对自然语言指代，只用合成候选。位置和完成条件组合时按工具核对；歧义先澄清，不修改事项。"),context.semanticReference!.message,.init(role:"user",content:query)]
            calls = 1
            let turn = try await DeepSeekClient().assistantTurn(to:payload,enabledSkillIDs:[],apiKey:key,readContext:context,budget:.init(maxModelRounds:1,maxReadCalls:1,maxSeconds:45,maxTotalTokens:8000))
            text = turn.text ?? ""; tokens = turn.usage?.totalTokens ?? 0; measured = turn.usage != nil
            checks["one_bounded_interpretation_and_local_read"] = turn.modelRounds == 1 && turn.readToolCallCount == 1 && turn.semanticReference != nil && turn.toolCalls.isEmpty
            checks["expected_interpretation"] = index == 127 ? turn.semanticReference?.status == "ambiguous" && turn.semanticReference?.candidates.count == 2 : turn.semanticReference?.status == "resolved" && turn.semanticReference?.candidates.first?.reference == .personal(rows[2].id)
        } catch { failure = AssistantTurnDiagnostic.category(for:error) }
        let passed = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report(index,status:passed ? "pass" : "fail",checks:checks,failure:failure,calls:calls,tokens:tokens,measured:measured,text:text); AssistantRuntime.finishEvaluationPreferences(); return passed
    }
    static func report(_ index: Int,status: String,checks: [String:Bool],failure: String?,simulated: Int = 0,calls: Int = 0,tokens: Int = 0,measured: Bool = true,text: String = "") {
        let result: [String:Any] = ["case_id":"INT-\(index)","outcome":status,"checks":checks,"failure":failure ?? "none","processID":ProcessInfo.processInfo.processIdentifier,"sandboxPath":LocalAssistantPaths.dataDirectory.path,"processRestarted":CommandLine.arguments.contains { $0.hasPrefix("--resume-sandbox=") },"modelRequests":calls,"externalModelRequests":calls,"tokens":tokens,"usageComplete":measured,"simulatedModelRequests":simulated,"automaticBusinessWrites":0,"scope":index >= 127 ? "bounded live semantic reference tool probes,synthetic choices only,no business tools" : "offline production semantic reference,fixture tool calls,original-list validation","response":String(text.prefix(3500)),"qualityScore":NSNull(),"humanReviewRequired":true]
        if let bytes = try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]) { print("AGENT_SCENARIO_RESULT: " + String(decoding:bytes,as:UTF8.self)); fflush(stdout) }
    }
}
