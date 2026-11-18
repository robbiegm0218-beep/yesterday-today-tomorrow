import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct StageRevisionTests {
    let scope=AssistantRun.digest("revision-scope")
    func fixture(start:Bool=true) throws ->(AssistantRunStore,AssistantRunLedger,UUID,UUID?) {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("revision-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let store=AssistantRunStore(directory:dir),ledger=AssistantRunLedger(store:store)
        let id=try ledger.start(message:.init(text:"请分阶段规划目标",isUser:true),scope:scope)
        let plan=AssistantGoalStagePlan(requestHash:ledger.rows[0].requestHash,stages:[.init(title:"创建",instruction:"创建旧标题待办",criterion:"核对创建回执",reviewMode:"confirmed_operation",dependencies:[],actionTool:"create_personal_todo"),.init(title:"总结",instruction:"只读总结",criterion:"核对结果",reviewMode:"read_review",dependencies:[0])])
        let reply=AssistantMessage(text:"待采用",isUser:false,goalPlanDraft:plan)
        try ledger.finish(id,reply:reply,state:.awaitingConfirmation,note:"待采用");try ledger.installStagePlan(plan,parentID:id,replyID:reply.id,scope:scope)
        let child=start ? try ledger.start(message:.init(text:"原阶段请求",isUser:true),scope:scope,parentID:id,stageIndex:0) : nil
        if let child {
            try ledger.event(.modelStarted,id:child);try ledger.event(.modelFinished(.init(promptTokens:10,completionTokens:2,totalTokens:12)),id:child)
            try ledger.finish(child,reply:.init(text:"待核对",isUser:false),state:.responded,note:"取得旧结果")
        }
        return(store,ledger,id,child)
    }
    func draft(_ ledger:AssistantRunLedger,_ parent:UUID)->StageRevisionDraft {
        let row=ledger.rows.first{$0.id==parent}!;var d=StageRevisionDraft(parent:row,stage:row.stagePlan!.stages[0],child:ledger.rows.first{$0.parentRunID==parent});d.title="新阶段";d.instruction="创建修订后的银杏待办，无截止日期";d.reason="标题理解有误";return d
    }
    @Test func revisionPreservesIdentityBudgetAndRequiresNewResult() throws {
        let (store,l,p,c)=try fixture();defer{try? FileManager.default.removeItem(at:store.directory)}
        let before=l.rows.first{$0.id==c}!,d=draft(l,p);try l.reviseStage(d,scope:scope)
        let after=l.rows.first{$0.id==c}!
        #expect(l.rows.count==2 && after.requestHash==before.requestHash && after.originalMessageID==before.originalMessageID)
        #expect(after.modelRequests==before.modelRequests && after.readCalls==before.readCalls && after.tokens==before.tokens && after.elapsedMilliseconds==before.elapsedMilliseconds)
        #expect(after.stageRevisionPending==true && after.state == .paused && l.rows[0].stageRevisions?.count==1)
        #expect(throws:(any Error).self){try l.reviewStage(parentID:p,stageID:d.stageID,note:"旧回复",scope:scope)}
        let restored=AssistantRunLedger(store:store);#expect(restored.rows==l.rows)
    }
    @Test func pendingCardIsDismissedAndCannotExecuteAfterRevision() throws {
        let (store,l,p,c)=try fixture();defer{try? FileManager.default.removeItem(at:store.directory)};let child=c!
        let action=PendingAssistantAction(summary:"旧卡片",operation:.createTodo(title:"旧标题",dueAt:nil,importance:.normal,projectName:nil))
        try l.finish(child,reply:.init(text:"待确认",isUser:false,pendingActions:[action]),state:.awaitingConfirmation,note:"旧卡片")
        try l.reviseStage(draft(l,p),scope:scope)
        #expect(l.rows[1].receipts.first?.state=="dismissed")
        #expect(l.filtered([action],id:child).count==1)
        #expect(throws:(any Error).self){try l.applying(action.id)}
        try l.reconcile(messages:[.init(text:"仍显示旧pending卡片",isUser:false,pendingActions:[action])])
        #expect(l.rows[1].receipts.first?.state=="dismissed")
    }
    @Test func completedOrUnknownReceiptsCannotBeOverwritten() throws {
        for state in ["completed","unverified"] {
            let (store,l,p,c)=try fixture();defer{try? FileManager.default.removeItem(at:store.directory)}
            try l.stageTransaction { rows in rows[1].receipts=[.init(actionID:UUID(),messageID:UUID(),key:scope,summary:"回执",state:state)] }
            let before=l.rows
            #expect(throws:(any Error).self){try l.reviseStage(draft(l,p),scope:scope)}
            #expect(l.rows==before && l.rows[1].id==c)
        }
    }
    @Test func runningEndedScopeAndStaleEditorRefuseWithoutMutation() throws {
        let (store,l,p,c)=try fixture();defer{try? FileManager.default.removeItem(at:store.directory)}
        let d=draft(l,p),before=l.rows
        #expect(throws:(any Error).self){try l.reviseStage(d,scope:AssistantRun.digest("other"))};#expect(l.rows==before)
        try l.resume(c!,messageID:UUID(),scope:scope)
        #expect(throws:(any Error).self){try l.reviseStage(d,scope:scope)}
        try l.finish(c!,reply:nil,state:.paused,note:"暂停");try l.reviseStage(draft(l,p),scope:scope)
        #expect(throws:(any Error).self){try l.reviseStage(d,scope:scope)}
        let latest=draft(l,p);try l.endStagePlan(p)
        #expect(throws:(any Error).self){try l.reviseStage(latest,scope:scope)}
    }
    @Test func unstartedStageRetainsDependenciesAndDoesNotStart() throws {
        let (store,l,p,_)=try fixture(start:false);defer{try? FileManager.default.removeItem(at:store.directory)}
        try l.reviseStage(draft(l,p),scope:scope)
        #expect(l.rows.count==1 && l.rows[0].stagePlan?.stages[0].childRunID==nil && l.rows[0].stagePlan?.stages[1].dependencies==[0])
    }
    @Test func fourRevisionLimitAndInvalidFieldsAreAtomic() throws {
        let (store,l,p,_)=try fixture();defer{try? FileManager.default.removeItem(at:store.directory)}
        var bad=draft(l,p);bad.criterion="";let before=l.rows
        #expect(throws:(any Error).self){try l.reviseStage(bad,scope:scope)};#expect(l.rows==before)
        for i in 0..<4 {var d=draft(l,p);d.title="修订\(i)";try l.reviseStage(d,scope:scope)}
        #expect(throws:(any Error).self){try l.reviseStage(draft(l,p),scope:scope)}
    }
    @Test func questionAndSupplementsAreArchivedAndOldQuestionCannotResume() throws {
        let (store,l,p,c)=try fixture();defer{try? FileManager.default.removeItem(at:store.directory)};let child=c!
        let q=AssistantStageQuestion(runID:child,purpose:"missing_details",question:"标题是什么？",choices:[])
        try l.finish(child,reply:.init(text:q.question,isUser:false,stageQuestion:q),state:.responded,note:"等待")
        try l.reviseStage(draft(l,p),scope:scope)
        #expect(l.rows[1].stageQuestion==nil && l.rows[0].stageRevisions?.first?.previousQuestion==q)
        let id=UUID()
        #expect(throws:(any Error).self){try l.resume(child,messageID:id,scope:scope,supplement:.init(questionID:q.id,messageID:id,text:"旧问题回答",selected:nil))}
    }
    @Test func onlyExplicitFieldSyntaxProducesCorrectionDraft() {
        #expect(StageRevisionPolicy.fieldCorrection("这个阶段的标题改成「银杏核对」")?.1=="银杏核对")
        #expect(StageRevisionPolicy.fieldCorrection("这个阶段改成删除项目")==nil)
        #expect(StageRevisionPolicy.fieldCorrection("另外问一下，标题是什么")==nil)
    }
    @Test func completedDependencyCannotBeRevisedAndHistoryDamageIsRejected() throws {
        let (store,l,p,c)=try fixture();defer{try? FileManager.default.removeItem(at:store.directory)}
        try l.stageTransaction {rows in rows[0].stagePlan!.stages[0].reviewNote="已核对";rows[0].stagePlan!.stages[0].reviewedAt=Date()}
        let before=l.rows
        #expect(throws:(any Error).self){try l.reviseStage(draft(l,p),scope:scope)};#expect(l.rows==before)
        var damaged=before;damaged[1].supersededActionIDs=[UUID()]
        #expect(throws:(any Error).self){try AssistantRunStore.validate(damaged)}
        #expect(c != nil)
    }

}
