import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct ReferenceExclusionTests {
    let scope=AssistantRun.digest("exclusion"),runID=UUID()
    func fixture(_ request:String,states:[Bool]=[true,false,false,true]) -> (ReferenceQuestionContext,AssistantReadContext,[AssistantMessage]) {
        var todos=states.map{_ in PersonalTodo(title:"同名方案评审",importance:.normal)}
        for i in todos.indices {todos[i].isComplete=states[i];todos[i].owner="负责人\(i+1)"}
        let user=AssistantMessage(text:"查看同名方案评审",isUser:true)
        let focus=AssistantConversationFocus(references:todos.map{.personal($0.id)},isChoice:true,originMessageID:user.id,selected:[],hidden:[])
        let messages=[user,AssistantMessage(text:"应用原候选",isUser:false,conversationFocus:focus),AssistantMessage(text:request,isUser:true)],context=AssistantReadContext(todos:todos)
        return(ReferenceQuestionContext.make(messages:messages,context:context,scope:scope,runID:runID)!,context,messages)
    }
    func plan(_ text:String) throws->ReferenceExclusion.Plan {
        guard case let .plan(plan)=ReferenceExclusion.parse(text) else {throw ProjectUpdateError.invalid("no plan")};return plan
    }
    @Test func explicitCorrectionBindsOriginalIdAndPreservesQuestion() throws {
        for verb in ["是","问","改成","换成","我说的是"] {
            let text="不是第二个，"+verb+"第三个，负责人是谁？",(q,context,_)=fixture(text)
            #expect(q.binding?.status=="resolved" && q.binding?.candidates.first?.reference == .personal(context.todos[2].id))
            #expect(q.pending.question==text && ReferenceQuestionContext.answerQuestion(text)=="负责人是谁？" && !ReferenceQuestionContext.hasMutation(text))
        }
    }
    @Test func multipleExclusionsNeverSlideOriginalNumbering() throws {
        let (q,context,_)=fixture("排除原列表第二个和第三个，剩下的负责人是谁？")
        #expect(q.binding?.status=="ambiguous" && q.binding?.candidates.map(\.reference)==[.personal(context.todos[0].id),.personal(context.todos[3].id)])
        #expect(q.binding?.candidates.map(\.position)==[1,4])
        #expect(try plan("原列表里，排除第二项与第三条，负责人是谁？").excluded==[2,3])
    }
    @Test func stateFilteringRequiresOriginalListAnchorAndUsesOnlyKnownLocalFields() {
        let (q,context,_)=fixture("排除原列表第二个，剩下未完成那项负责人是谁？")
        #expect(q.binding?.status=="resolved" && q.binding?.candidates.first?.reference == .personal(context.todos[2].id))
        let (ambiguous,_,_)=fixture("排除第二个，剩下未完成那项负责人是谁？")
        #expect(ambiguous.blocked != nil && ambiguous.binding==nil)
    }
    @Test func conflictingDuplicateOutOfRangeAndUnsupportedNegativeDoNotGuess() {
        for text in ["不是第二个，是第二个，负责人是谁？","排除第二个和第二个，负责人是谁？","排除第七个，负责人是谁？","不是第二个，是第七个，负责人是谁？","不是未完成里面第二个，负责人是谁？","不是第二个，是第三个和第四个，负责人是谁？","排除原列表第二个，是第三个，还不要第三个，负责人是谁？"] {
            let (q,_,_)=fixture(text);#expect(q.blocked != nil || q.binding?.status=="unknown")
        }
        let (q,_,_)=fixture("不是第二个，是第五个，负责人是谁？")
        #expect(q.binding?.status=="unknown" && q.binding?.candidates.isEmpty==true)
    }
    @Test func correctionPrefixCannotHideBusinessMutationInRemainingSentence() {
        for text in ["不是第二个，改成第三个，再修改负责人为林一","不是第二个，是第三个，负责人是谁，顺便创建待办"] {
            let (q,_,_)=fixture(text);#expect(q.blocked != nil && q.binding==nil)
            #expect(ReferenceQuestionContext.hasMutation(text))
        }
    }
    @Test func unavailableOriginalIdAndChangedScopeCannotRebindSameTitle() {
        let text="不是第二个，是第三个，负责人是谁？",(_,context,messages)=fixture(text)
        var missing=context;missing.todos.remove(at:2);missing.todos.append(.init(title:"同名方案评审",importance:.normal))
        let q=ReferenceQuestionContext.make(messages:messages,context:missing,scope:scope,runID:runID)
        #expect(q?.binding?.status=="unknown")
        var changed=context;changed.selected=["another-profile"]
        #expect(ReferenceQuestionContext.make(messages:messages,context:changed,scope:scope,runID:runID)?.binding?.status=="unknown")
    }
    @Test func exclusionClarificationPersistsFullQuestionAndOriginalBudgetId() throws {
        let text="排除原列表第二个和第三个，剩下的负责人是谁？",(q,context,messages)=fixture(text),resolution=q.binding!
        let reply=AssistantMessage(text:resolution.text,isUser:false,conversationFocus:resolution.savedFocus(messageID:q.pending.originMessageID,selected:[],hidden:[]),referenceQuestionPending:q.pending)
        let restored=try JSONDecoder().decode([AssistantMessage].self,from:JSONEncoder().encode(messages+[reply]))
        let continued=try #require(ReferenceQuestionContext.make(messages:restored+[.init(text:"第二个",isUser:true)],context:context,scope:scope,runID:runID))
        #expect(continued.binding?.candidates.first?.reference == .personal(context.todos[3].id) && continued.pending.question==text && continued.pending.runID==runID)
    }
    @Test func literalCorrectionOnlyNeedsOneAnswerCallAndNoInterpretationModel() async throws {
        let (q,context,_)=fixture("不是第二个，是第三个，负责人是谁？")
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ExclusionFixtureProtocol.self]
        ExclusionFixtureProtocol.configure([.init(text:"负责人为负责人3。")])
        var reads=context;reads.referenceQuestion=q
        let result=try await DeepSeekClient(session:URLSession(configuration:config)).assistantTurn(to:[],enabledSkillIDs:["todo-priority"],apiKey:"offline",readContext:reads)
        #expect(result.referenceQuestionAnswered && result.modelRounds==1 && result.readToolCallCount==1 && result.referenceQuestionInterpretation?.contains("excluded=2;included=3")==true)
        #expect(ExclusionFixtureProtocol.captured.count==1 && ExclusionFixtureProtocol.captured.first?.contains("负责人2") != true)
    }
    @Test func ambiguousExclusionAndFocusOnlyCorrectionAreEntirelyLocal() async throws {
        for text in ["排除原列表第二个和第三个，剩下的负责人是谁？","排除原列表第二个，是第三个"] {
            let (q,context,_)=fixture(text)
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ExclusionFixtureProtocol.self];ExclusionFixtureProtocol.configure([])
            var reads=context;reads.referenceQuestion=q
            let result=try await DeepSeekClient(session:URLSession(configuration:config)).assistantTurn(to:[],enabledSkillIDs:[],apiKey:"offline",readContext:reads)
            #expect(result.modelRounds==0 && result.readToolCallCount==1 && ExclusionFixtureProtocol.captured.isEmpty && result.toolCalls.isEmpty)
            if text.contains("负责人") {#expect(result.referenceQuestionPending?.question==text)} else {#expect(result.referenceQuestionPending==nil && result.semanticReference?.status=="resolved")}
        }
    }
}
