import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct ReferenceQuestionTests {
    let scope=AssistantRun.digest("reference-question"),runID=UUID()
    func fixture(_ request:String=ReferenceQuestionAcceptance.question) -> (ReferenceQuestionContext,AssistantReadContext,[AssistantMessage]) {
        var todos=(0..<4).map{_ in PersonalTodo(title:"同名评审",importance:.high)};todos[0].isComplete=true;todos[3].isComplete=true;todos[1].owner="林一";todos[2].owner="周二"
        let user=AssistantMessage(text:"列出同名评审",isUser:true)
        let focus=AssistantConversationFocus(references:todos.map{.personal($0.id)},isChoice:true,originMessageID:user.id,selected:[],hidden:[])
        let messages=[user,AssistantMessage(text:"应用原候选",isUser:false,conversationFocus:focus),AssistantMessage(text:request,isUser:true)]
        let context=AssistantReadContext(todos:todos)
        return (ReferenceQuestionContext.make(messages:messages,context:context,scope:scope,runID:runID)!,context,messages)
    }
    func client()->DeepSeekClient {let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ReferenceQuestionFixtureProtocol.self];return .init(session:URLSession(configuration:config))}
    func turn(_ question:ReferenceQuestionContext,_ context:AssistantReadContext,budget:AssistantAgentBudget = .init()) async throws->DeepSeekAssistantTurn {
        var reads=context;reads.referenceQuestion=question
        return try await client().assistantTurn(to:[.init(role:"user",content:question.reference.request)],enabledSkillIDs:["todo-priority"],apiKey:"offline",readContext:reads,budget:budget)
    }
    @Test func originalQuestionIsPreservedVerbatimAndMalformedInterpretationCannotRetarget() {
        let (q,_,messages)=fixture()
        #expect(q.pending.question==messages.last?.text && q.pending.originalRequest==q.pending.question)
        let good=q.resolve([ReferenceQuestionAcceptance.call()])
        #expect(good?.0.status=="resolved" && good?.1.question==q.pending.question)
        let extra=DeepSeekToolCall(id:"extra",function:.init(name:ReferenceQuestionContext.name,arguments:"{\"mode\":\"original_position\",\"position\":2,\"state\":\"any\",\"quote\":\"第二个\",\"question\":\"替换原问题\"}"))
        #expect(q.resolve([extra])?.0.status=="unknown")
        #expect(q.resolve([ReferenceQuestionAcceptance.call(),ReferenceQuestionAcceptance.call()])==nil)
        #expect(q.resolve([.init(id:"write",function:.init(name:"complete_personal_todo",arguments:"{}"))])==nil)
    }
    @Test func mixedMutationAndTopicShiftDoNotBecomeCombinedReadRequests() {
        let (_,context,messages)=fixture()
        for text in ["未完成里面第二个负责人是谁，顺便创建待办","换话题，第二个负责人是谁","未完成里面第二个标记完成",String(repeating:"第",count:401)+"谁负责"] {
            let next=Array(messages.dropLast())+[AssistantMessage(text:text,isUser:true)]
            #expect(ReferenceQuestionContext.make(messages:next,context:context,scope:scope,runID:runID)==nil)
        }
    }
    @Test func uniqueResolutionAnswersWithOnlyOneExactMattersFacts() async throws {
        let (q,context,_)=fixture();ReferenceQuestionFixtureProtocol.configure([.init(calls:[ReferenceQuestionAcceptance.call()]),.init(text:"负责人为周二，截止日期未提供。")])
        let result=try await turn(q,context)
        #expect(result.referenceQuestionAnswered && result.modelRounds==2 && result.readToolCallCount==1 && result.toolCalls.isEmpty && result.semanticReference?.candidates.first?.reference == .personal(context.todos[2].id))
        let bodies=ReferenceQuestionFixtureProtocol.captured
        #expect(bodies.count==2 && bodies[1].contains("周二") && !bodies[1].contains("林一") && !bodies[1].contains(context.todos[1].id.uuidString))
        let body=try #require(JSONSerialization.jsonObject(with:Data(bodies[1].utf8)) as? [String:Any]);#expect(body["tools"]==nil && body["tool_choice"]==nil && body["max_tokens"] as? Int==2048)
    }
    @Test func ambiguousResolutionStoresQuestionAndDoesNotSpendAnswerRound() async throws {
        let (q,context,_)=fixture(ReferenceQuestionAcceptance.ambiguous)
        ReferenceQuestionFixtureProtocol.configure([.init(calls:[ReferenceQuestionAcceptance.call("unclear_position_state",request:ReferenceQuestionAcceptance.ambiguous)])])
        let result=try await turn(q,context)
        #expect(result.modelRounds==1 && result.readToolCallCount==1 && !result.referenceQuestionAnswered && result.semanticReference?.status=="ambiguous" && result.referenceQuestionPending?.question==q.reference.request && ReferenceQuestionFixtureProtocol.captured.count==1)
    }
    func continuation() throws -> (ReferenceQuestionContext,AssistantReadContext,[AssistantMessage]) {
        let (q,context,messages)=fixture(ReferenceQuestionAcceptance.ambiguous)
        let (resolution,pending)=try #require(q.resolve([ReferenceQuestionAcceptance.call("unclear_position_state",request:ReferenceQuestionAcceptance.ambiguous)]))
        let reply=AssistantMessage(text:resolution.text,isUser:false,conversationFocus:resolution.savedFocus(messageID:pending.originMessageID,selected:[],hidden:[]),referenceQuestionPending:pending)
        let saved=try JSONDecoder().decode([AssistantMessage].self,from:JSONEncoder().encode(messages+[reply]))
        let resumed=saved+[AssistantMessage(text:"第二个",isUser:true)]
        return(try #require(ReferenceQuestionContext.make(messages:resumed,context:context,scope:scope,runID:runID)),context,resumed)
    }
    @Test func restartSelectionKeepsOriginalQuestionAndNeedsOnlyAnswerRequest() async throws {
        let (q,context,messages)=try continuation()
        #expect(q.binding?.candidates.first?.reference == .personal(context.todos[2].id) && q.pending.question==ReferenceQuestionAcceptance.ambiguous)
        #expect(ReferenceQuestionContext.continuationRunID(messages:Array(messages.dropLast()),request:"第二个")==runID)
        ReferenceQuestionFixtureProtocol.configure([.init(text:"负责人为周二。")]);let result=try await turn(q,context)
        #expect(result.referenceQuestionAnswered && result.modelRounds==1 && result.readToolCallCount==1 && result.referenceQuestionPending==nil)
        #expect(ReferenceQuestionFixtureProtocol.captured.first?.contains("resolve_reference_question") != true)
    }
    @Test func scopeOriginTimeAndMissingIdInvalidateContinuationWithoutNetwork() async throws {
        let (_,context,messages)=try continuation()
        var missing=context;missing.todos.remove(at:2)
        for candidate in [ReferenceQuestionContext.make(messages:messages,context:context,scope:"different",runID:runID),ReferenceQuestionContext.make(messages:messages,context:missing,scope:scope,runID:runID),ReferenceQuestionContext.make(messages:messages,context:context,scope:scope,runID:runID,now:Date(timeIntervalSinceNow:86_401))] {
            let q=try #require(candidate);#expect(q.blocked != nil)
            ReferenceQuestionFixtureProtocol.configure([]);let result=try await turn(q,context)
            #expect(result.modelRounds==0 && result.readToolCallCount==0 && ReferenceQuestionFixtureProtocol.captured.isEmpty)
        }
    }
    @Test func zeroBudgetDoesNotCallAndSingleRoundCannotAnswerByResettingBudget() async throws {
        let (q,context,_)=fixture();ReferenceQuestionFixtureProtocol.configure([])
        let none=try await turn(q,context,budget:.init(maxModelRounds:0,maxReadCalls:1,maxSeconds:30,maxTotalTokens:1000))
        #expect(none.modelRounds==0 && ReferenceQuestionFixtureProtocol.captured.isEmpty)
        ReferenceQuestionFixtureProtocol.configure([.init(calls:[ReferenceQuestionAcceptance.call()])])
        let one=try await turn(q,context,budget:.init(maxModelRounds:1,maxReadCalls:1,maxSeconds:30,maxTotalTokens:1000))
        #expect(one.modelRounds==1 && !one.referenceQuestionAnswered && one.stopReason=="reference_question_budget" && ReferenceQuestionFixtureProtocol.captured.count==1)
    }
    @Test func answerPhaseRejectsBusinessCalls() async throws {
        let (q,context,_)=fixture();let write=DeepSeekToolCall(id:"write",function:.init(name:"complete_personal_todo",arguments:"{}"))
        ReferenceQuestionFixtureProtocol.configure([.init(calls:[ReferenceQuestionAcceptance.call()]),.init(calls:[write])])
        let result=try await turn(q,context)
        #expect(!result.referenceQuestionAnswered && result.toolCalls.isEmpty && result.stopReason=="reference_question_answer_invalid")
    }
    @Test func boundFactsKeepUnknownAndImportanceWithoutReadingOtherMatters() throws {
        let (q,context,_)=fixture();let resolution=try #require(q.resolve([ReferenceQuestionAcceptance.call()])?.0)
        let facts=try #require(ReferenceQuestionContext.facts(resolution,context:context))
        #expect(facts.contains("unknown") && facts.contains("高") && facts.contains("周二") && !facts.contains("林一"))
        var removed=context;removed.todos.remove(at:2);#expect(ReferenceQuestionContext.facts(resolution,context:removed)==nil)
    }
    @Test func answeringDropsOnlyResolvedReferenceClauseAndRetainsAllQuestionFields() {
        #expect(ReferenceQuestionContext.answerQuestion("未完成的里面第二个，负责人和截止日期是什么？")=="负责人和截止日期是什么？")
        #expect(ReferenceQuestionContext.answerQuestion("刚才第二个没完成的，负责人是谁？")=="负责人是谁？")
        #expect(ReferenceQuestionContext.answerQuestion("第二个的负责人是谁，截止日期是什么？")=="第二个的负责人是谁，截止日期是什么？")
        #expect(ReferenceQuestionContext.answerQuestion("未完成的里面第二个负责人是谁？")=="未完成的里面第二个负责人是谁？")
    }
    @Test func invalidModeRecordsBoundedDiagnosticsAndDoesNotCallAnswerModel() async throws {
        let (q,context,_)=fixture()
        let invalid=DeepSeekToolCall(id:"invalid",function:.init(name:ReferenceQuestionContext.name,arguments:"{\"mode\":\"filter_then_position\",\"position\":2,\"state\":\"open\",\"quote\":\"未完成的里面第二个\"}"))
        ReferenceQuestionFixtureProtocol.configure([.init(calls:[invalid])]);let result=try await turn(q,context)
        #expect(!result.referenceQuestionAnswered && result.modelRounds==1 && result.referenceQuestionInterpretation=="mode=filter_then_position;position=2;state=open" && ReferenceQuestionFixtureProtocol.captured.count==1)
    }
    @Test func cancellationDoesNotReturnLateAnswer() async throws {
        let (q,context,_)=fixture();ReferenceQuestionFixtureProtocol.configure([.init(calls:[ReferenceQuestionAcceptance.call()])],delay:0.3)
        let task=Task {try await turn(q,context)};try await Task.sleep(for:.milliseconds(20));task.cancel()
        do {_=try await task.value;Issue.record("late reference answer returned")} catch {#expect(error is CancellationError || (error as? URLError)?.code == .cancelled)}
        #expect(ReferenceQuestionFixtureProtocol.captured.count<=1)
    }
}
