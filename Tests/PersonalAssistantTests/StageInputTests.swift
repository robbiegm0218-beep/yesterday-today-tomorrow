import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct StageInputTests {
    private let scope=AssistantRun.digest("stage-input-scope")
    private func choices()->[AssistantStageChoice] {
        [.init(reference:.personal(UUID()),title:"同名评审",detail:"负责人：小林"),.init(reference:.personal(UUID()),title:"同名评审",detail:"负责人：小周")]
    }
    private func fixture()->(AssistantRun,AssistantRun,AssistantStageQuestion) {
        var parent=AssistantRun(originalMessageID:UUID(),requestHash:scope,goal:"父目标",scopeHash:scope,messageIDs:[]);parent.state = .ready
        var stage=AssistantGoalStage(title:"核对",instruction:"选择后读取",criterion:"取得当前状态",reviewMode:"read_review",dependencies:[])
        var other=stage;other.id=UUID()
        var child=AssistantRun(originalMessageID:UUID(),requestHash:scope,goal:"核对",scopeHash:scope,messageIDs:[]);child.parentRunID=parent.id;child.parentStageID=stage.id;child.state = .responded
        stage.childRunID=child.id;parent.stagePlan = .init(requestHash:scope,stages:[stage,other],status:"confirmed")
        let q=AssistantStageQuestion(runID:child.id,purpose:"target_choice",question:"选择哪一条？",choices:choices());child.stageQuestion=q
        return(parent,child,q)
    }
    private func targets(_ q:AssistantStageQuestion)->[MatterTarget] {q.choices.map{.init(reference:$0.reference,title:$0.title)}}
    @Test func secondChoiceUsesExactIDAndDuplicateTitleDoesNotChooseFirst() throws {
        let (_,_,q)=fixture()
        let selected=try q.answer("第二个。",targets:targets(q))
        #expect(selected.1==q.choices[1].reference && selected.0.contains(q.choices[1].reference.id))
        #expect(throws:(any Error).self) {try q.answer("同名评审",targets:targets(q))}
        #expect(throws:(any Error).self) {try q.answer("第九个",targets:targets(q))}
        #expect(q.choices[0].label != q.choices[1].label && q.choices[1].label.contains("小周"))
    }
    @Test func removedHiddenOrAmbiguousSourceCannotBeSelected() throws {
        let (_,_,q)=fixture()
        #expect(throws:(any Error).self) {try q.answer("第二个",targets:[targets(q)[0]])}
        #expect(throws:(any Error).self) {try q.answer("个人的那个",targets:targets(q))}
        let first=try q.answer(q.choices[0].reference.id,targets:targets(q))
        #expect(first.1==q.choices[0].reference)
    }
    @Test func stableIDSurvivesRenameAndUsesCurrentTitle() throws {
        let (_,_,q)=fixture();var list=targets(q);list[1] = .init(reference:list[1].reference,title:"已更名的评审")
        let result=try q.answer("2",targets:list)
        #expect(result.1==q.choices[1].reference && result.0.contains("已更名的评审"))
    }
    @Test func freeInputBoundedAndGoalChangeRequiresSeparateRevision() throws {
        let q=AssistantStageQuestion(runID:UUID(),purpose:"missing_details",question:"待办标题是什么？",choices:[])
        #expect(try q.answer("标题为银杏核对",targets:[]).0=="标题为银杏核对")
        #expect(throws:(any Error).self) {try q.answer(String(repeating:"长",count:1501),targets:[])}
        #expect(throws:(any Error).self) {try q.answer("这个阶段改成删除项目",targets:[])}
    }
    @Test func latestStructuredQuestionRoutesNaturalReplyWithinSameStage() {
        let (p,c,q)=fixture();let bot=AssistantMessage(text:q.displayText,isUser:false,stageQuestion:q)
        #expect(StageInputRouting.decide(text:"我指的是第二个",messages:[bot],runs:[p,c]) == .answer(c.id))
        #expect(StageInputRouting.decide(text:"换个话题，聊专注",messages:[bot],runs:[p,c]) == .ordinary)
        #expect(StageInputRouting.decide(text:"怎么提高效率？",messages:[bot],runs:[p,c]) == .ordinary)
        #expect(StageInputRouting.decide(text:"谢谢",messages:[bot],runs:[p,c]) == .ordinary)
        if case .blocked=StageInputRouting.decide(text:"这个阶段改成另一个操作",messages:[bot],runs:[p,c]) {} else {Issue.record("Goal change was silently appended")}
    }
    @Test func oldQuestionOrEndedGoalCannotStealNewConversation() {
        var (p,c,q)=fixture();let bot=AssistantMessage(text:q.displayText,isUser:false,stageQuestion:q)
        c.stageQuestion=nil
        if case .blocked=StageInputRouting.decide(text:"第二个",messages:[bot],runs:[p,c]) {} else {Issue.record("Stale question created a new goal")}
        c.stageQuestion=q;p.state = .cancelled
        if case .blocked=StageInputRouting.decide(text:"第二个",messages:[bot],runs:[p,c]) {} else {Issue.record("Stale question created a new goal")}
        p.state = .ready
        let unrelated=AssistantMessage(text:"新的话题回答",isUser:false)
        #expect(StageInputRouting.decide(text:"第二个",messages:[bot,unrelated],runs:[p,c]) == .ordinary)
    }
    @Test func multipleWaitingStagesNeverDefaultToFirstWithoutFocus() {
        let (p,c,_)=fixture();var second=c;second.id=UUID();second.stageQuestion = .init(runID:second.id,purpose:"missing_details",question:"补充什么？",choices:[])
        var p2=p;p2.id=UUID();second.parentRunID=p2.id;p2.stagePlan!.stages[0].childRunID=second.id
        if case .blocked=StageInputRouting.decide(text:"补充本阶段信息",messages:[],runs:[p,c,p2,second]) {} else {Issue.record("Multiple stages defaulted to first")}
    }
    @Test func questionToolRejectsUnknownTargetsAndCredentials() throws {
        let (_,c,q)=fixture()
        func call(_ text:String,_ rows:[[String:String]]) throws -> DeepSeekToolCall {.init(id:"q",function:.init(name:StageQuestionTool.name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:["purpose":"target_choice","question":text,"candidates":rows]),as:UTF8.self)))}
        let valid=try call("选择事项",q.choices.map {["kind":$0.reference.kind,"target_id":$0.reference.id]})
        #expect(StageQuestionTool.make(valid,runID:c.id,targets:targets(q)).stageQuestion?.runID==c.id)
        let unknown=try call("选择事项",[["kind":"personal","target_id":UUID().uuidString]])
        #expect(StageQuestionTool.make(unknown,runID:c.id,targets:targets(q)).stageQuestion==nil)
        let key=try call("请提供API Key",q.choices.map {["kind":$0.reference.kind,"target_id":$0.reference.id]})
        #expect(StageQuestionTool.make(key,runID:c.id,targets:targets(q)).stageQuestion==nil)
        #expect(!AssistantReadContext().availableNames.contains(StageQuestionTool.name))
    }
    @Test func supplementPersistsWithOriginalChildAndBudgetAndCannotBeReplayed() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("stage-input-\(UUID())");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        var (p,c,q)=fixture();c.modelRequests=1;c.readCalls=1;c.tokens=150;c.replyIDs=[UUID()]
        let store=AssistantRunStore(directory:dir);try store.save([p,c]);let ledger=AssistantRunLedger(store:store)
        let id=UUID();let input=AssistantStageSupplement(questionID:q.id,messageID:id,text:"用户选择第二项",selected:q.choices[1].reference)
        try ledger.resume(c.id,messageID:id,scope:scope,supplement:input)
        let resumed=try #require(ledger.rows.first{$0.id==c.id})
        #expect(resumed.parentRunID==p.id && resumed.modelRequests==1 && resumed.tokens==150 && resumed.budget.maxModelRounds==3 && resumed.stageQuestion==nil)
        #expect(resumed.stageSupplements?.first?.selected==q.choices[1].reference)
        try ledger.finish(c.id,reply:.init(text:"已经核对",isUser:false),state:.responded,note:"完成回复")
        #expect(throws:(any Error).self) {try ledger.resume(c.id,messageID:UUID(),scope:scope,supplement:input)}
        let restored=AssistantRunLedger(store:store);#expect(restored.rows.count==2 && restored.rows[1].stageSupplements?.count==1)
    }
    @Test func pendingQuestionCannotBeHumanReviewedOrContinuedWithoutAnswer() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("stage-input-\(UUID())");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        var (p,c,_)=fixture();c.replyIDs=[UUID()]
        let store=AssistantRunStore(directory:dir);try store.save([p,c]);let ledger=AssistantRunLedger(store:store)
        #expect(throws:(any Error).self) {try ledger.resume(c.id,messageID:UUID(),scope:scope)}
        #expect(throws:(any Error).self) {try ledger.reviewStage(parentID:p.id,stageID:p.stagePlan!.stages[0].id,note:"只是提问也算完成",scope:scope)}
        #expect(ledger.rows[1].stageQuestion != nil && ledger.rows[1].modelRequests==0)
    }
    @Test func scopeOrBudgetChangeRefusesAnswerWithoutNewRun() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("stage-input-\(UUID())");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        var (p,c,q)=fixture();c.modelRequests=4
        let store=AssistantRunStore(directory:dir);try store.save([p,c]);let ledger=AssistantRunLedger(store:store);let id=UUID()
        let input=AssistantStageSupplement(questionID:q.id,messageID:id,text:"补充",selected:nil)
        #expect(throws:(any Error).self) {try ledger.resume(c.id,messageID:id,scope:scope,supplement:input)}
        #expect(throws:(any Error).self) {try ledger.resume(c.id,messageID:id,scope:AssistantRun.digest("changed"),supplement:input)}
        #expect(ledger.rows.count==2 && ledger.rows[1].stageQuestion?.id==q.id)
    }
    @Test func legacyAndNewConversationAndLedgerFieldsRoundTrip() throws {
        let (_,c,q)=fixture();let message=AssistantMessage(text:q.displayText,isUser:false,stageQuestion:q)
        let restored=try JSONDecoder().decode(AssistantMessage.self,from:JSONEncoder().encode(message))
        #expect(restored.stageQuestion==q)
        var object=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(message)) as? [String:Any]);object.removeValue(forKey:"stageQuestion")
        #expect(try JSONDecoder().decode(AssistantMessage.self,from:JSONSerialization.data(withJSONObject:object)).stageQuestion==nil)
        #expect(try JSONDecoder().decode(AssistantRun.self,from:JSONEncoder().encode(c)).stageQuestion==q)
    }
    @Test func declaredMissingTitleAsksLocallyOnce() {
        let (_,child,_)=fixture()
        let stage=AssistantGoalStage(title:"创建",instruction:"标题待补",criterion:"确认回执",reviewMode:"confirmed_operation",dependencies:[],actionTool:"create_personal_todo",requiredInput:"todo_title")
        #expect(StageQuestionTool.initial(stage:stage,run:child,targets:[],todos:[],projects:[],external:[])?.purpose=="missing_details")
        var resumed=child;resumed.modelRequests=1
        #expect(StageQuestionTool.initial(stage:stage,run:resumed,targets:[],todos:[],projects:[],external:[])==nil)
    }
    @Test func declaredChoiceKeepsExactCandidatesAndKnownIDSkipsQuestion() {
        let (_,child,q)=fixture();var stage=AssistantGoalStage(title:"选择",instruction:"用户选择事项",criterion:"读状态",reviewMode:"read_review",dependencies:[],requiredInput:"target_choice",inputTargetKind:"personal")
        let ask=StageQuestionTool.initial(stage:stage,run:child,targets:targets(q),todos:[],projects:[],external:[])
        #expect(ask?.choices.map(\.reference)==q.choices.map(\.reference))
        stage=AssistantGoalStage(title:"选择",instruction:q.choices[1].reference.id,criterion:"读状态",reviewMode:"read_review",dependencies:[],requiredInput:"target_choice",inputTargetKind:"personal")
        #expect(StageQuestionTool.initial(stage:stage,run:child,targets:targets(q),todos:[],projects:[],external:[])==nil)
    }
    @Test func naturalRequiredQuestionCannotClaimSuccessOrAskCredentials() {
        let (_,child,_)=fixture()
        #expect(StageQuestionTool.legacyQuestion("请告诉我待办标题是什么？",run:child) != nil)
        #expect(StageQuestionTool.legacyQuestion("已创建待办，请告诉我下一步。",run:child)==nil)
        #expect(StageQuestionTool.legacyQuestion("请提供API Key",run:child)==nil)
    }

}
