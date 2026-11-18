import Foundation

final class ReferenceQuestionFixtureProtocol:URLProtocol,@unchecked Sendable {
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

@MainActor enum ReferenceQuestionAcceptance {
    nonisolated static let question="未完成的里面第二个，负责人和截止日期是什么？"
    nonisolated static let ambiguous="刚才第二个没完成的，负责人是谁？"
    static func call(_ mode:String="state_then_position",request:String=question)->DeepSeekToolCall {
        let bytes=try! JSONSerialization.data(withJSONObject:["mode":mode,"position":2,"state":"open","quote":request.components(separatedBy:"，")[0]])
        return .init(id:"reference-question",function:.init(name:ReferenceQuestionContext.name,arguments:String(decoding:bytes,as:UTF8.self)))
    }
    static func seed(missing:Bool=false) throws {
        var todos=(0..<4).map {_ in PersonalTodo(title:"星河评审任务",importance:.high)}
        todos[0].isComplete=true;todos[3].isComplete=true
        todos[1].owner="林一";todos[2].owner=missing ? nil : "周二"
        todos[2].dueAt=missing ? nil : ISO8601DateFormatter().date(from:"2026-12-08T04:00:00Z")
        try LocalTodoStore.save(todos)
        var messages:[AssistantMessage]=[.init(text:"查看星河评审任务",isUser:true)]
        let recall=AssistantContextRecall.make(messages:messages,context:.init(todos:todos))
        messages.append(.init(text:recall.clarification,isUser:false,conversationFocus:recall.savedFocus(messages:messages,selected:[],hidden:[])))
        LocalConversationStore.save(messages)
    }
    static func run(_ index:Int) async->Bool {
        let live=index==143,resume=CommandLine.arguments.contains{$0.hasPrefix("--resume-sandbox=")},root=LocalAssistantPaths.dataDirectory
        var checks:[String:Bool]=[:],failure:String?,checkpoint=false,extractions=0,external=0,tokens=0,measured=true,priorCalls=0
        var liveApp:AssistantModel?
        do {
            if !resume {AssistantRuntime.preferences.set(true,forKey:"autoMemoryEnabled");AssistantRuntime.preferences.set([String](),forKey:"dingTalkSelectedProfiles");try LocalSkillStore.save(AssistantSkill.defaults);try seed(missing:index==141)}
            let key:String
            if live {guard let saved=DeepSeekCredentialStore.load(),!saved.isEmpty else {throw ProjectUpdateError.invalid("saved_credential_unavailable")};key=saved} else {key="offline-placeholder"}
            let source=CardAcceptanceDataSource()
            func model()->AssistantModel {
                let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ReferenceQuestionFixtureProtocol.self]
                return AssistantModel(dailyDataSource:source,services:.init(chatClient:live ? DeepSeekClient():DeepSeekClient(session:URLSession(configuration:config)),memoryExtractor:{_,_ in extractions+=1;return []},apiKey:{key}))
            }
            func configure(_ replies:[ReferenceQuestionFixtureProtocol.Reply],delay:Double=0) {
                priorCalls += ReferenceQuestionFixtureProtocol.captured.count
                ReferenceQuestionFixtureProtocol.configure(replies,delay:delay)
            }
            var app=model();if live {liveApp=app};let rows=app.personalTodos;let before=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))
            func send(_ text:String) async throws {app.draft=text;app.sendMessage();for _ in 0..<9500 {if !app.isSending && !app.isRefreshing {return};try await Task.sleep(for:.milliseconds(10))};app.cancelChatRequest();throw ProjectUpdateError.invalid("question_did_not_settle")}
            if index==139 || live {
                configure([.init(calls:[call()]),.init(text:"负责人为周二，截止日期为2026-12-08。")])
                try await send(question)
                checks["resolves_and_answers_in_same_request"] = app.messages.last?.conversationFocus?.references == [.personal(rows[2].id)] && app.messages.last?.text.contains("周二")==true && app.messages.last?.text.contains("2026-12-08")==true
                checks["does_not_reopen_resolved_reference"] = app.messages.last?.text.contains("无法确认") != true && app.messages.last?.text.contains("无法核对") != true
                checks["two_model_rounds_one_bound_read_no_proposals"] = app.assistantRuns.count==1 && app.assistantRuns[0].modelRequests==2 && app.assistantRuns[0].readCalls==1 && app.messages.last?.pendingActions==nil && app.messages.last?.referenceQuestionPending==nil
                if !live {
                    let bodies=ReferenceQuestionFixtureProtocol.captured
                    checks["answer_prompt_contains_only_bound_target_and_no_tools"] = bodies.count==2 && !bodies[1].contains("林一") && bodies[1].contains(rows[2].id.uuidString) && !bodies[1].contains(rows[1].id.uuidString) && !bodies[1].contains("\"tools\"")
                }
            } else if index==140 {
                if !resume {
                    configure([.init(calls:[call("unclear_position_state",request:ambiguous)])]);try await send(ambiguous)
                    checks["ambiguity_retains_full_original_question"] = app.messages.last?.referenceQuestionPending?.question==ambiguous && app.messages.last?.conversationFocus?.isChoice==true && app.assistantRuns[0].modelRequests==1
                    try JSONEncoder().encode(checks).write(to:root.appendingPathComponent("question-checks.json"));AssistantRuntime.preferences.synchronize();checkpoint=true
                } else {
                    let run=app.assistantRuns[0]
                    configure([.init(text:"负责人为周二。")]);try await send("第二个")
                    checks["restart_choice_answers_without_repeating_question"] = app.messages.last?.text.contains("周二")==true && app.messages.last?.conversationFocus?.references == [.personal(rows[2].id)] && app.messages.last?.referenceQuestionPending==nil
                    checks["clarification_reuses_original_run_and_budget"] = app.assistantRuns.count==1 && app.assistantRuns[0].id==run.id && app.assistantRuns[0].requestHash==run.requestHash && app.assistantRuns[0].modelRequests==2 && app.assistantRuns[0].readCalls==2 && ReferenceQuestionFixtureProtocol.captured.count==1
                }
            } else if index==141 {
                configure([.init(calls:[call()]),.init(text:"该事项未提供负责人和截止日期，无法核对。")]);try await send(question)
                let body=ReferenceQuestionFixtureProtocol.captured.last ?? ""
                checks["missing_fields_remain_unknown"] = app.messages.last?.text.contains("未提供")==true && body.contains("unknown") && !body.contains("林一")
                let mutation=DeepSeekToolCall(id:"unbound-create",function:.init(name:"create_personal_todo",arguments:"{\"title\":\"不能创建\",\"importance\":\"normal\"}"))
                // A mixed write sentence stays in the original focus-only path, and ALL proposals are blocked.
                checks["missing_field_source_unchanged"] = try Data(contentsOf:root.appendingPathComponent("personal-todos.json")) == before
                try seed();app=model();let mixedBefore=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"));configure([.init(calls:[mutation])])
                try await send("未完成里面第二个，负责人是谁，顺便创建待办")
                checks["mixed_write_cannot_bypass_binding_with_create"] = app.messages.last?.pendingActions==nil && app.personalTodos.count==4
                let changed=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"));checks["mixed_write_source_unchanged"] = changed == mixedBefore
            } else if index==142 {
                configure([.init(calls:[call()]),.init(text:"不应显示的迟到答案")],delay:0.15)
                app.draft=question;app.sendMessage()
                for _ in 0..<200 {if !ReferenceQuestionFixtureProtocol.captured.isEmpty {break};try await Task.sleep(for:.milliseconds(5))}
                app.selectedDingTalkProfileIDs=["changed-scope"]
                for _ in 0..<200 {if !app.isSending {break};try await Task.sleep(for:.milliseconds(10))}
                checks["scope_change_stops_before_answer_round"] = !app.isSending && ReferenceQuestionFixtureProtocol.captured.count==1 && app.messages.last?.text.contains("迟到答案") != true && app.messages.last?.pendingActions==nil
                app.selectedDingTalkProfileIDs=[];try seed();app=model()
                configure([.init(calls:[call("unclear_position_state",request:ambiguous)])]);try await send(ambiguous)
                let oldID=app.personalTodos[2].id;var replacement=app.personalTodos.filter{$0.id != oldID};replacement.append(.init(title:"星河评审任务",importance:.normal));try CreatedTodoAcceptance.raw(replacement);app=model()
                let count=ReferenceQuestionFixtureProtocol.captured.count;try await send("第二个")
                checks["missing_original_id_cannot_rebind_or_answer"] = ReferenceQuestionFixtureProtocol.captured.count==count && app.messages.last?.text.contains("周二") != true && app.messages.last?.pendingActions==nil
            }
            if index != 141 && index != 142 {checks["business_source_unchanged"] = try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))==before}
            checks["no_external_refresh"] = source.calls==0
            checks["no_memory_extraction"] = extractions==0
            if resume,let saved=try? JSONDecoder().decode([String:Bool].self,from:Data(contentsOf:root.appendingPathComponent("question-checks.json"))) {checks.merge(saved){a,_ in a}}
        } catch {failure=String(error.localizedDescription.prefix(400))}
        if live,let app=liveApp {external=app.assistantRuns.reduce(0){$0+$1.modelRequests};tokens=app.assistantRuns.reduce(0){$0+$1.tokens};measured=app.assistantRuns.allSatisfy(\.usageComplete)}
        let pass=failure==nil && !checks.isEmpty && checks.values.allSatisfy{$0}
        let report:[String:Any]=["case_id":"INT-\(index)","outcome":checkpoint ? "restart_required":pass ? "pass":"fail","checks":checks,"failure":failure ?? "none","processID":ProcessInfo.processInfo.processIdentifier,"sandboxPath":root.path,"processRestarted":resume,"modelRequests":external,"externalModelRequests":external,"tokens":tokens,"usageComplete":measured,"simulatedModelRequests":live ? 0:priorCalls+ReferenceQuestionFixtureProtocol.captured.count,"automaticBusinessWrites":0,"qualityScore":NSNull()]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {print("AGENT_SCENARIO_RESULT: "+String(decoding:data,as:UTF8.self));fflush(stdout)}
        AgentScenarioAcceptance.didCheckpoint=checkpoint;if !checkpoint {AssistantRuntime.finishEvaluationPreferences()};return pass && !checkpoint
    }
}
