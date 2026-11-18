import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct CreatedTodoReceiptTests {
    let scope=AssistantRun.digest("created-result-scope")
    func write(_ todos:[PersonalTodo],_ dir:URL) throws {try JSONEncoder().encode(todos).write(to:dir.appendingPathComponent("personal-todos.json"),options:.atomic)}
    func fixture() throws ->(URL,AssistantRunLedger,UUID,UUID,AssistantMessage,PersonalTodo) {
        let d=FileManager.default.temporaryDirectory.appendingPathComponent("created-receipt-"+UUID().uuidString);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)
        let ledger=AssistantRunLedger(store:.init(directory:d)),user=AssistantMessage(text:"分阶段创建并核对",isUser:true),parent=try ledger.start(message:user,scope:scope)
        let first=AssistantGoalStage(title:"创建",instruction:"创建银杏核对",criterion:"用户确认创建，并核对原ID存在",reviewMode:"confirmed_operation",dependencies:[],actionTool:"create_personal_todo")
        let plan=AssistantGoalStagePlan(requestHash:ledger.rows[0].requestHash,stages:[first,.init(title:"总结",instruction:"只读总结",criterion:"人工核对",reviewMode:"read_review",dependencies:[0])])
        let draft=AssistantMessage(text:"方案",isUser:false,goalPlanDraft:plan);try ledger.finish(parent,reply:draft,state:.awaitingConfirmation,note:"待采用");try ledger.installStagePlan(plan,parentID:parent,replyID:draft.id,scope:scope)
        let child=try ledger.start(message:.init(text:"开始创建",isUser:true),scope:scope,parentID:parent,stageIndex:0)
        try ledger.event(.modelStarted,id:child);try ledger.event(.modelFinished(.init(promptTokens:10,completionTokens:2,totalTokens:12)),id:child)
        let action=PendingAssistantAction(summary:"创建银杏核对",operation:.createTodo(title:"银杏核对",dueAt:nil,importance:.normal,projectName:nil))
        let reply=AssistantMessage(text:"请确认",isUser:false,pendingActions:[action]);try ledger.finish(child,reply:reply,state:.awaitingConfirmation,note:"待确认")
        let todo=PersonalTodo(title:"银杏核对",importance:.normal,sourceActionID:action.id);try write([todo],d)
        return(d,ledger,parent,child,reply,todo)
    }
    func completed(_ reply:AssistantMessage)->AssistantMessage {var m=reply;m.pendingActions![0].status = .completed;return m}
    func stageID(_ l:AssistantRunLedger)->UUID {l.rows[0].stagePlan!.stages[0].id}
    func result(_ l:AssistantRunLedger)->AssistantCreatedTodoResult? {l.rows[1].receipts[0].createdTodo}
    @Test func pendingCardDoesNotBindEvenWhenSourceMarkerExists() throws {
        let(d,l,_,_,m,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)}
        try l.reconcile(messages:[m],directory:d)
        #expect(l.rows[1].receipts[0].operationKind==CreatedTodoReceiptPolicy.operationKind && result(l)==nil)
    }
    @Test func completedCardBindsByActionAndExactIDNotSameTitle() throws {
        let(d,l,_,_,m,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)}
        var same=t;same.id=UUID();same.sourceActionID=nil;same.isComplete=true;try write([same,t],d)
        try l.reconcile(messages:[completed(m)],directory:d)
        #expect(result(l)?.targetID==t.id && result(l)?.isLocated==true && result(l)?.observedComplete==false)
        #expect(l.rows[0].stagePlan?.stages[0].isComplete==false && l.rows.count==2)
    }
    @Test func boundTargetSurvivesRestartAndNeverRetargetsReplacement() throws {
        let(d,l,p,_,m,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reconcile(messages:[completed(m)],directory:d)
        let restored=AssistantRunLedger(store:.init(directory:d));var replacement=t;replacement.id=UUID();try write([replacement],d)
        try restored.checkCreatedStageTargets(parentID:p,stageID:stageID(restored),scope:scope,directory:d)
        #expect(result(restored)?.targetID==t.id && result(restored)?.status=="target_missing")
    }
    @Test func duplicateActionMarkerAndChangedProvenanceAreUnknown() throws {
        let(d,l,p,_,m,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reconcile(messages:[completed(m)],directory:d)
        var duplicate=t;duplicate.id=UUID();try write([t,duplicate],d)
        try l.checkCreatedStageTargets(parentID:p,stageID:stageID(l),scope:scope,directory:d);#expect(result(l)?.status=="ambiguous_source_action" && result(l)?.targetID==t.id)
        var changed=t;changed.sourceActionID=UUID();try write([changed],d)
        try l.checkCreatedStageTargets(parentID:p,stageID:stageID(l),scope:scope,directory:d);#expect(result(l)?.status=="provenance_mismatch" && result(l)?.targetID==t.id)
    }
    @Test func firstBindingRejectsAmbiguityAndDuplicateRecordIDs() throws {
        let(d,_,_,_,m,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let a=m.pendingActions![0].id
        var duplicate=t;duplicate.id=UUID();try write([t,duplicate],d)
        let ambiguous=CreatedTodoReceiptPolicy.read(actionID:a,previous:nil,directory:d);#expect(ambiguous.targetID==nil && ambiguous.status=="ambiguous_source_action")
        try write([t,t],d);#expect(CreatedTodoReceiptPolicy.read(actionID:a,previous:nil,directory:d).status=="source_unavailable")
    }
    @Test func corruptCurrentSourceNeverUsesBackupOrOldLocatedResult() throws {
        let(d,l,p,_,m,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reconcile(messages:[completed(m)],directory:d)
        try JSONEncoder().encode([t]).write(to:d.appendingPathComponent("personal-todos.json.backup"));try Data("broken".utf8).write(to:d.appendingPathComponent("personal-todos.json"))
        try l.checkCreatedStageTargets(parentID:p,stageID:stageID(l),scope:scope,directory:d)
        #expect(result(l)?.status=="source_unavailable" && result(l)?.targetID==t.id && result(l)?.observedTitle==nil)
    }
    @Test func unverifiedOrDismissedReceiptCannotClaimBoundCreation() throws {
        let(d,l,_,_,m,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)}
        try l.applying(m.pendingActions![0].id);try l.reconcile(messages:[m],directory:d)
        #expect(l.rows[1].receipts[0].state=="unverified" && result(l)==nil)
        try l.reconcile(messages:[completed(m)],directory:d);#expect(result(l)?.isLocated==true)
        var invalid=l.rows;invalid[1].receipts[0].state="dismissed"
        #expect(throws:(any Error).self){try AssistantRunStore.validate(invalid)}
    }
    @Test func humanReviewRereadsDeletedTargetAndDoesNotAdvanceDependency() throws {
        let(d,l,p,_,m,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reconcile(messages:[completed(m)],directory:d)
        try write([],d)
        #expect(throws:(any Error).self){try l.reviewStage(parentID:p,stageID:stageID(l),note:"之前已创建",scope:scope,directory:d)}
        #expect(result(l)?.status=="target_missing" && l.rows[0].stagePlan?.stages[0].isComplete==false && l.rows[0].stagePlan?.stages[1].childRunID==nil)
    }
    @Test func freshLocatedResultAllowsOnlyExplicitHumanStageReview() throws {
        let(d,l,p,_,m,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reconcile(messages:[completed(m)],directory:d)
        let bytes=try Data(contentsOf:d.appendingPathComponent("personal-todos.json")),used=l.rows[1]
        try l.reviewStage(parentID:p,stageID:stageID(l),note:"确认创建且原ID仍存在，其余文字条件已人工核对",scope:scope,directory:d)
        #expect(l.rows[0].stagePlan?.stages[0].isComplete==true && l.rows[0].stagePlan?.stages[1].childRunID==nil)
        #expect(result(l)?.targetID==t.id && l.rows[1].tokens==used.tokens && l.rows[1].modelRequests==used.modelRequests)
        #expect(try Data(contentsOf:d.appendingPathComponent("personal-todos.json"))==bytes)
    }
    @Test func scopeEndedAndPendingGuardsPreserveLedger() throws {
        let(d,l,p,_,m,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let old=l.rows
        #expect(throws:(any Error).self){try l.checkCreatedStageTargets(parentID:p,stageID:stageID(l),scope:scope,directory:d)}
        #expect(l.rows==old);try l.reconcile(messages:[completed(m)],directory:d);let before=l.rows
        #expect(throws:(any Error).self){try l.checkCreatedStageTargets(parentID:p,stageID:stageID(l),scope:AssistantRun.digest("other"),directory:d)}
        #expect(l.rows==before);try l.endStagePlan(p)
        #expect(throws:(any Error).self){try l.checkCreatedStageTargets(parentID:p,stageID:stageID(l),scope:scope,directory:d)}
    }
    @Test func legacyReceiptEnrichmentRequiresExactOriginalCardParameters() throws {
        let(d,l,_,_,m,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)}
        try l.stageTransaction{rows in rows[1].receipts[0].operationKind=nil};let old=try JSONDecoder().decode([AssistantRun].self,from:JSONEncoder().encode(l.rows));#expect(old[1].receipts[0].createdTodo==nil)
        var forged=completed(m);forged.pendingActions![0].operation = .createTodo(title:"另一事项",dueAt:nil,importance:.normal,projectName:nil)
        #expect(throws:(any Error).self){try l.reconcile(messages:[forged],directory:d)}
        try l.reconcile(messages:[completed(m)],directory:d);#expect(result(l)?.targetID==t.id)
    }
    @Test func persistedBindingCanRefreshWithoutOldChatMessage() throws {
        let(d,l,p,_,m,t)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.reconcile(messages:[completed(m)],directory:d)
        var renamed=t;renamed.title="新标题";renamed.isComplete=true;try write([renamed],d)
        let restored=AssistantRunLedger(store:.init(directory:d));try restored.reconcile(messages:[],directory:d)
        try restored.checkCreatedStageTargets(parentID:p,stageID:stageID(restored),scope:scope,directory:d)
        #expect(result(restored)?.targetID==t.id && result(restored)?.observedTitle=="新标题" && result(restored)?.observedComplete==true)
    }
}
