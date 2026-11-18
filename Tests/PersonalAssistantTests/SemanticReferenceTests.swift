import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized)
struct SemanticReferenceTests {
    private func fixture(_ text: String = "刚才第二个没完成的", states: [Bool] = [true,false,false,false]) -> (SemanticReferenceContext,[PersonalTodo],[AssistantMessage]) {
        let todos = states.map { value -> PersonalTodo in var row = PersonalTodo(title: "接口评审", importance: .normal); row.isComplete = value; return row }
        let user = AssistantMessage(text: "比较接口评审事项", isUser: true)
        let focus = AssistantConversationFocus(references: todos.map { .personal($0.id) }, isChoice: true, originMessageID: user.id, selected: [], hidden: [])
        let messages = [user,AssistantMessage(text: "应用显示的候选列表", isUser: false, conversationFocus: focus),AssistantMessage(text: text, isUser: true)]
        return (SemanticReferenceContext.make(messages: messages, context: .init(todos: todos))!,todos,messages)
    }
    private func call(_ mode: String, _ position: Int, _ state: String, quote: String = "刚才第二个没完成的") -> DeepSeekToolCall {
        let data = try! JSONSerialization.data(withJSONObject: ["mode":mode,"position":position,"state":state,"quote":quote])
        return .init(id: "reference-call", function: .init(name: SemanticReferenceContext.name, arguments: String(decoding:data,as:UTF8.self)))
    }
    @Test func ambiguousOrdinalAndStateReturnsBothInterpretations() throws {
        let (context,todos,_) = fixture()
        let result = try #require(context.execute(call("unclear_position_state",2,"open")).semanticReference)
        #expect(result.status == "ambiguous" && result.candidates.map(\.reference) == [.personal(todos[1].id), .personal(todos[2].id)])
        #expect(result.text.contains("筛选后") && result.text.contains("没有修改事项"))
    }
    @Test func identicalInterpretationsResolveOneOriginalID() {
        let (context,todos,_) = fixture(states: [false,false,true])
        let result = context.execute(call("unclear_position_state",2,"open")).semanticReference
        #expect(result?.status == "resolved" && result?.candidates.map(\.reference) == [.personal(todos[1].id)])
    }
    @Test func explicitFilterOrderAndOriginalOrderRemainDifferent() {
        let (context,todos,_) = fixture()
        #expect(context.execute(call("state_then_position",2,"open")).semanticReference?.candidates.map(\.reference) == [.personal(todos[2].id)])
        #expect(context.execute(call("position_with_state",2,"open")).semanticReference?.candidates.map(\.reference) == [.personal(todos[1].id)])
    }
    @Test func oneInvalidInterpretationStillRequiresConfirmation() {
        let (context,_,_) = fixture(states: [false,true,false])
        let result = context.execute(call("unclear_position_state",2,"open")).semanticReference
        #expect(result?.status == "ambiguous" && result?.candidates.count == 1)
    }
    @Test func ordinalCannotSlidePastCompletedOriginalItem() {
        let (context,_,_) = fixture(states: [false,true,false])
        #expect(context.execute(call("position_with_state",2,"open")).semanticReference?.status == "unknown")
        #expect(context.execute(call("original_position",2,"any")).semanticReference?.candidates.first?.position == 2)
    }
    @Test func uniqueStateDoesNotGuessBetweenMultipleMatches() {
        let (context,_,_) = fixture()
        #expect(context.execute(call("unique_state",0,"open")).semanticReference?.status == "ambiguous")
        #expect(context.execute(call("unique_state",0,"complete")).semanticReference?.status == "resolved")
    }
    @Test func malformedAndInventedQuoteDoNotProduceFocus() {
        let (context,_,_) = fixture()
        for operation in [call("state_then_position",99,"open"),call("invented",2,"open"),call("unique_state",1,"open"),call("original_position",2,"unknown"),call("other",0,"any"),call("original_position",2,"any",quote:"用户没有说过的话")] {
            #expect(context.execute(operation).semanticReference?.status == "unknown")
        }
        var bad = call("original_position",2,"any")
        bad = .init(id: bad.id, function: .init(name: SemanticReferenceContext.name, arguments: "{\"mode\":\"original_position\",\"position\":true,\"state\":\"any\",\"quote\":\"刚才\"}"))
        #expect(context.execute(bad).semanticReference?.status == "unknown")
    }
    @Test func missingOriginalInvalidatesWholeListInsteadOfReindexing() {
        let (_,todos,messages) = fixture()
        let context = SemanticReferenceContext.make(messages: messages, context: .init(todos: Array(todos.dropFirst())))
        #expect(context?.unavailable == true && context?.rows.isEmpty == true)
        #expect(context?.execute(call("original_position",2,"any")).semanticReference?.status == "unknown")
    }
    @Test func changedScopeOrExpiryCannotRevealOldChoices() {
        let (_,todos,messages) = fixture()
        for context in [AssistantReadContext(todos:todos,selected:["other:self"]),.init(todos:todos,hidden:["old-hidden"])] {
            let value = SemanticReferenceContext.make(messages:messages,context:context)
            #expect(value?.rows.isEmpty == true && value?.message.content.contains(todos[0].id.uuidString) == false)
        }
        #expect(SemanticReferenceContext.make(messages:messages,context:.init(todos:todos),now:Date().addingTimeInterval(90000))?.unavailable == true)
    }
    @Test func arbitraryModelListsDoNotBecomeCandidates() {
        let (_,todos,_) = fixture()
        let messages: [AssistantMessage] = [.init(text:"事项",isUser:true),.init(text:"1. 接口评审 2. 接口评审",isUser:false),.init(text:"刚才第二个没完成的",isUser:true)]
        #expect(SemanticReferenceContext.make(messages:messages,context:.init(todos:todos)) == nil)
    }
    @Test func remoteAndProjectStatesRemainUnknownForFiltering() {
        let id = "dingtalk-org:user-task"
        let remote = TodoRecord(id:id,title:"评审",dueAt:nil,importance:.normal,sourceURL:nil,isComplete:false)
        let user = AssistantMessage(text:"原列表",isUser:true)
        let focus = AssistantConversationFocus(references:[.init(kind:"external",id:id)],isChoice:true,originMessageID:user.id,selected:["org:user"],hidden:[])
        let messages = [user,.init(text:"候选",isUser:false,conversationFocus:focus),.init(text:"刚才第二个没完成的",isUser:true)]
        let context = SemanticReferenceContext.make(messages:messages,context:.init(external:[remote],selected:["org:user"]))!
        #expect(context.execute(call("unique_state",0,"open")).semanticReference?.status == "unknown")
        #expect(context.execute(call("original_position",1,"any")).semanticReference?.status == "resolved")
    }
    @Test func persistedAmbiguityIsDiscussionOnlyAndSupportsOrdinalAfterRestart() throws {
        let (context,todos,messages) = fixture()
        let result = context.execute(call("unclear_position_state",2,"open")).semanticReference!
        var thread = messages;thread.append(.init(text:result.text,isUser:false,conversationFocus:result.savedFocus(messageID:messages.last!.id,selected:[],hidden:[])))
        thread = try JSONDecoder().decode([AssistantMessage].self,from:JSONEncoder().encode(thread));thread.append(.init(text:"第二个",isUser:true))
        let recall = AssistantContextRecall.make(messages:thread,context:.init(todos:todos))
        #expect(recall.candidates.map(\.reference) == [.personal(todos[2].id)] && recall.isFocusCorrection)
        #expect(recall.continuationRequest == nil && recall.correctionAcknowledgement != nil)
    }
    @Test func toolAvailabilityIsScopedAndCancelIsHonored() async throws {
        let (reference,todos,_) = fixture()
        var context = AssistantReadContext(todos:todos)
        #expect(!context.availableNames.contains(SemanticReferenceContext.name))
        context.semanticReference = reference
        #expect(context.availableNames.contains(SemanticReferenceContext.name))
        #expect(context.availableDefinitions.filter { $0.function.name == SemanticReferenceContext.name }.count == 1)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await context.execute(call("original_position",2,"any"),timeout:1) }
        do { _ = try await task.value; Issue.record("cancelled reference returned") } catch is CancellationError {}
    }
    @Test func toolReadRespectsExistingBudgetAndReturnsWithoutAnotherModelRound() async throws {
        let (reference,todos,_) = fixture()
        let operation = call("unclear_position_state",2,"open")
        SemanticReferenceFixtureProtocol.configure(operation)
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [SemanticReferenceFixtureProtocol.self]
        var context = AssistantReadContext(todos:todos);context.semanticReference = reference
        let client = DeepSeekClient(session:URLSession(configuration:config))
        let payload = [reference.message,DeepSeekChatMessage(role:"user",content:reference.request)]
        let exhausted = try await client.assistantTurn(to:payload,enabledSkillIDs:[],apiKey:"offline",readContext:context,budget:.init(maxModelRounds:1,maxReadCalls:0,maxSeconds:2,maxTotalTokens:1000))
        #expect(exhausted.semanticReference == nil && exhausted.readToolCallCount == 0 && exhausted.stopReason == "read_budget")
        SemanticReferenceFixtureProtocol.configure(operation)
        let result = try await client.assistantTurn(to:payload,enabledSkillIDs:[],apiKey:"offline",readContext:context,budget:.init(maxModelRounds:1,maxReadCalls:1,maxSeconds:2,maxTotalTokens:1000))
        #expect(result.semanticReference?.status == "ambiguous" && result.modelRounds == 1 && result.readToolCallCount == 1)
        #expect(SemanticReferenceFixtureProtocol.captured.count == 1 && result.toolCalls.isEmpty)
    }
    @Test func cancellationDoesNotReturnLateSemanticResolution() async throws {
        let (reference,todos,_) = fixture()
        SemanticReferenceFixtureProtocol.configure(call("unclear_position_state",2,"open"),delay:0.2)
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [SemanticReferenceFixtureProtocol.self]
        var context = AssistantReadContext(todos:todos);context.semanticReference = reference
        let captured = context, client = DeepSeekClient(session:URLSession(configuration:config))
        let task = Task { try await client.assistantTurn(to:[reference.message,.init(role:"user",content:reference.request)],enabledSkillIDs:[],apiKey:"offline",readContext:captured,budget:.init(maxSeconds:2)) }
        try await Task.sleep(for:.milliseconds(20));task.cancel()
        do { _ = try await task.value;Issue.record("late reference returned after cancellation") } catch { #expect(error is CancellationError) }
    }

    @Test func confirmationLookupCannotBypassDisabledWriteCapability() async throws {
        let todo = PersonalTodo(title:"接口评审",importance:.normal)
        let user = AssistantMessage(text:"完成待办接口评审",isUser:true)
        var context = AssistantReadContext(todos:[todo])
        context.todoConfirmationRequest = .init(originMessageID:user.id,originalRequest:user.text,scopeHash:"scope",localOnly:true,priorityOnly:false)
        let data = try JSONSerialization.data(withJSONObject:["query":"接口评审","state":"open"])
        SemanticReferenceFixtureProtocol.configure(.init(id:"lookup",function:.init(name:"find_matter",arguments:String(decoding:data,as:UTF8.self))))
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [SemanticReferenceFixtureProtocol.self]
        let result = try await DeepSeekClient(session:URLSession(configuration:config)).assistantTurn(to:[.init(role:"user",content:user.text)],enabledSkillIDs:[],apiKey:"offline",readContext:context,budget:.init(maxModelRounds:1,maxReadCalls:1,maxSeconds:2,maxTotalTokens:1000))
        #expect(result.toolCalls.isEmpty && result.stopReason == "unavailable_tool")
    }

    @Test func knownLiteralAndTopicSwitchDoNotNeedNewModelInterpretation() {
        #expect(!SemanticReferenceContext.needsInterpretation("第二个"))
        #expect(!SemanticReferenceContext.needsInterpretation("换成另一个"))
        #expect(!SemanticReferenceContext.needsInterpretation("换个话题，第二个宇宙是什么"))
        #expect(SemanticReferenceContext.needsInterpretation("刚才第二个没完成的"))
        #expect(SemanticReferenceContext.needsInterpretation("剩下那条还没做完的"))
    }
}
