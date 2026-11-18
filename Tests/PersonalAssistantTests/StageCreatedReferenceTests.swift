import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct StageCreatedReferenceTests {
    let helper=CreatedTodoReceiptTests()
    var scope:String {helper.scope}
    func fixture() throws ->(URL,AssistantRunLedger,UUID,UUID,PersonalTodo) {
        let(d,l,p,_,m,t)=try helper.fixture();try l.reconcile(messages:[helper.completed(m)],directory:d)
        try l.reviewStage(parentID:p,stageID:l.rows[0].stagePlan!.stages[0].id,note:"已核对原创建记录",scope:scope,directory:d)
        return(d,l,p,l.rows[0].stagePlan!.stages[1].id,t)
    }
    func revision(_ l:AssistantRunLedger,_ s:UUID)->StageRevisionDraft {
        let parent=l.rows[0],stage=parent.stagePlan!.stages.first{$0.id==s}!
        var draft=StageRevisionDraft(parent:parent,stage:stage)
        draft.createdTargetReference=StageCreatedReferencePolicy.candidates(parent:parent,stageID:s,rows:l.rows)[0].reference
        draft.factEnabled=true;draft.factTargetID=draft.createdTargetReference!.targetID.uuidString;draft.factStatus="any";draft.reason="明确引用前置创建结果"
        return draft
    }
    @Test func explicitReferenceKeepsExactIDAndOnlyOpensNextReadStage() throws {
        let(d,l,p,s,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let used=l.rows[1].modelRequests
        let draft=revision(l,s);try l.reviseStage(draft,scope:scope)
        #expect(l.rows.count==2 && l.rows[0].stagePlan!.stages[1].childRunID==nil && l.rows[1].modelRequests==used)
        let stage=l.rows[0].stagePlan!.stages[1];#expect(stage.createdTargetReference?.targetID==t.id)
        #expect(StageRevisionPolicy.request(stage,index:1).contains(t.id.uuidString))
        let child=try l.start(message:.init(text:StageRevisionPolicy.request(stage,index:1),isUser:true),scope:scope,parentID:p,stageIndex:1)
        #expect(l.rows.count==3 && l.rows.last?.id==child && l.rows.last?.parentRunID==p)
    }
    @Test func deletedTargetCannotBeReplacedWithSameActionOrTitle() throws {
        let(d,l,p,s,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reviseStage(revision(l,s),scope:scope)
        var replacement=t;replacement.id=UUID();try helper.write([replacement],d);let before=l.rows
        #expect(throws:(any Error).self){try l.start(message:.init(text:"开始下一阶段",isUser:true),scope:scope,parentID:p,stageIndex:1)}
        #expect(l.rows==before && StageFactPolicy.read(stage:l.rows[0].stagePlan!.stages[1],directory:d)?.status=="unknown")
    }
    @Test func sameIDWithChangedSourceOrDuplicateMarkerIsUnknown() throws {
        let(d,l,_,s,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reviseStage(revision(l,s),scope:scope);let stage=l.rows[0].stagePlan!.stages[1]
        var changed=t;changed.sourceActionID=UUID();try helper.write([changed],d);#expect(StageFactPolicy.read(stage:stage,directory:d)?.status=="unknown")
        var duplicate=t;duplicate.id=UUID();try helper.write([t,duplicate],d);#expect(StageFactPolicy.read(stage:stage,directory:d)?.gaps==["target_invalid"])
    }
    @Test func renamedOriginalIsStillSameTargetAndFactsAreFresh() throws {
        let(d,l,_,s,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reviseStage(revision(l,s),scope:scope)
        var renamed=t;renamed.title="原ID更新后的标题";renamed.isComplete=true;try helper.write([renamed],d)
        let proof=StageFactPolicy.read(stage:l.rows[0].stagePlan!.stages[1],directory:d)
        #expect(proof?.status=="satisfied" && proof?.targetID==t.id && proof?.observedTitle==renamed.title && proof?.observedComplete==true)
    }
    @Test func restartPreservesReferenceAndOriginalSourceReceipt() throws {
        let(d,l,_,s,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reviseStage(revision(l,s),scope:scope)
        let restored=AssistantRunLedger(store:.init(directory:d));#expect(restored.error==nil && restored.rows==l.rows)
        #expect(restored.rows[0].stagePlan!.stages[1].createdTargetReference?.targetID==t.id)
    }
    @Test func writeStageAndMismatchedFactTargetCannotUseReference() throws {
        let(d,l,_,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)}
        var change=revision(l,s);change.actionTool="complete_personal_todo"
        #expect(throws:(any Error).self){try l.reviseStage(change,scope:scope)}
        change=revision(l,s);change.factTargetID=UUID().uuidString
        #expect(throws:(any Error).self){try l.reviseStage(change,scope:scope)}
    }
    @Test func fabricatedReceiptOrUnrelatedStageCannotSatisfyReference() throws {
        let(d,l,_,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};var change=revision(l,s)
        change.createdTargetReference = .init(sourceStageID:UUID(),actionID:UUID(),targetID:change.createdTargetReference!.targetID)
        #expect(throws:(any Error).self){try l.reviseStage(change,scope:scope)}
        change=revision(l,s);change.createdTargetReference = .init(sourceStageID:change.createdTargetReference!.sourceStageID,actionID:UUID(),targetID:change.createdTargetReference!.targetID)
        #expect(throws:(any Error).self){try l.reviseStage(change,scope:scope)}
    }
    @Test func scopeStalePreviewAndBudgetArePreserved() throws {
        let(d,l,_,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let change=revision(l,s),before=l.rows
        #expect(throws:(any Error).self){try l.reviseStage(change,scope:AssistantRun.digest("other"))};#expect(l.rows==before)
        try l.reviseStage(change,scope:scope)
        #expect(throws:(any Error).self){try l.reviseStage(change,scope:scope)}
        #expect(l.rows[1].modelRequests==before[1].modelRequests && l.rows[1].tokens==before[1].tokens)
    }
    @Test func referenceUnknownStopsGuidanceWithoutRepeatedQuestion() throws {
        let(d,l,p,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reviseStage(revision(l,s),scope:scope)
        let c=try l.start(message:.init(text:"核对引用",isUser:true),scope:scope,parentID:p,stageIndex:1);try l.finish(c,reply:.init(text:"当前字段",isUser:false),state:.responded,note:"回复不是业务完成")
        try helper.write([],d);_=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d)
        let stage=l.rows[0].stagePlan!.stages[1];#expect(StageNextStepPolicy.decide(stage:stage,child:l.rows.last,parentState:l.rows[0].state).kind == .stop)
        #expect(throws:(any Error).self){try l.resume(c,messageID:UUID(),scope:scope)}
    }
    @Test func humanStageReviewRereadsReferenceAndCannotUseOldReply() throws {
        let(d,l,p,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reviseStage(revision(l,s),scope:scope)
        let c=try l.start(message:.init(text:"读取引用",isUser:true),scope:scope,parentID:p,stageIndex:1);try l.finish(c,reply:.init(text:"已经定位",isUser:false),state:.responded,note:"核对")
        _=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d);try helper.write([],d)
        #expect(throws:(any Error).self){try l.reviewStage(parentID:p,stageID:s,note:"之前已定位",scope:scope,directory:d)}
        #expect(l.rows[0].stagePlan!.isComplete==false)
    }
    @Test func legacyHashUnchangedWhenNoReferenceAndChangedWhenBound() throws {
        let(d,l,_,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let stage=l.rows[0].stagePlan!.stages[1],encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let old=AssistantRun.digest(stage.id.uuidString+stage.instruction+stage.criterion+String(decoding:try encoder.encode(stage.factCriterion),as:UTF8.self));#expect(StageFactPolicy.hash(stage)==old)
        try l.reviseStage(revision(l,s),scope:scope);#expect(StageFactPolicy.hash(l.rows[0].stagePlan!.stages[1]) != old)
    }
    @Test func naturalReferenceRecognizesOnlyExplicitBoundedRequest() {
        #expect(StageCreatedReferencePolicy.requested("下一阶段用刚创建的那个。"))
        #expect(!StageCreatedReferencePolicy.requested("刚创建的那个是什么意思？"))
        #expect(!StageCreatedReferencePolicy.requested("删除刚创建的那个"))
    }
}
