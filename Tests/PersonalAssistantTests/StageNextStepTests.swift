import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct StageNextStepTests {
    let scope=AssistantRun.digest("next-scope")
    func fixture(action:String?=nil,status:String="complete",done:Bool=false) throws ->(URL,AssistantRunLedger,UUID,UUID,UUID,PersonalTodo) {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("next-step-"+UUID().uuidString);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        var todo=PersonalTodo(title:"银杏核对",importance:.normal);todo.isComplete=done;try write([todo],dir)
        let ledger=AssistantRunLedger(store:.init(directory:dir)),p=try ledger.start(message:.init(text:"请分阶段核对",isUser:true),scope:scope)
        let first=AssistantGoalStage(title:"核对",instruction:"按指定ID核对",criterion:"符合明确字段",reviewMode:action==nil ? "read_review" : "confirmed_operation",dependencies:[],factCriterion:.init(targetID:todo.id,expectedStatus:status,expectedTitle:nil),actionTool:action)
        let plan=AssistantGoalStagePlan(requestHash:ledger.rows[0].requestHash,stages:[first,.init(title:"总结",instruction:"只读总结",criterion:"人工",reviewMode:"read_review",dependencies:[0])])
        let reply=AssistantMessage(text:"方案",isUser:false,goalPlanDraft:plan);try ledger.finish(p,reply:reply,state:.awaitingConfirmation,note:"待采用");try ledger.installStagePlan(plan,parentID:p,replyID:reply.id,scope:scope)
        let c=try ledger.start(message:.init(text:"核对",isUser:true),scope:scope,parentID:p,stageIndex:0)
        try ledger.finish(c,reply:.init(text:"取得当前结果",isUser:false),state:.responded,note:"人工核对")
        _=try ledger.checkStageFacts(parentID:p,stageID:first.id,scope:scope,directory:dir)
        return(dir,ledger,p,c,first.id,todo)
    }
    func write(_ rows:[PersonalTodo],_ dir:URL) throws {try JSONEncoder().encode(rows).write(to:dir.appendingPathComponent("personal-todos.json"),options:.atomic)}
    func stage(_ ledger:AssistantRunLedger)->AssistantGoalStage {ledger.rows[0].stagePlan!.stages[0]}
    func next(_ l:AssistantRunLedger)->StageNextStepKind {StageNextStepPolicy.decide(stage:stage(l),child:l.rows.last,parentState:l.rows[0].state).kind}
    func token(_ l:AssistantRunLedger)->StageNextStepToken {
        let parent=l.rows[0],child=l.rows[1],s=stage(l)
        return .init(parentID:parent.id,stageID:s.id,childID:child.id,parentRevision:parent.revision,childRevision:child.revision,criterionHash:StageFactPolicy.hash(s),proofSignature:StageNextStepPolicy.signature(s.factCheck!),kind:next(l))
    }
    @Test func readOnlyGapSuggestsAdjustmentWithoutInventingWrite() throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)}
        #expect(next(l) == .adjust && l.rows.count==2 && l.rows[1].modelRequests==0)
    }
    @Test func adoptedCompatibleOperationSuggestsSameRunContinuation() throws {
        let(d,l,_,_,_,todo)=try fixture(action:"complete_personal_todo");defer{try? FileManager.default.removeItem(at:d)}
        #expect(next(l) == .resume)
        #expect(StageNextStepPolicy.matches(.completeTodo(id:todo.id),target:todo.id))
        #expect(!StageNextStepPolicy.matches(.completeTodo(id:UUID()),target:todo.id))
        #expect(!StageNextStepPolicy.matches(.createTodo(title:"同名",dueAt:nil,importance:.normal,projectName:nil),target:todo.id))
    }
    @Test func unknownSourceStopsAfterOneUnchangedRecheckAndRecoversOnNewFacts() throws {
        let(d,l,p,_,s,todo)=try fixture();defer{try? FileManager.default.removeItem(at:d)}
        try Data("broken".utf8).write(to:d.appendingPathComponent("personal-todos.json"))
        _=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d);#expect(next(l) == .query)
        let before=l.rows[1]
        _=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d,selectedRecheck:true);#expect(next(l) == .stop && stage(l).nextStep?.rechecks==1)
        _=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d,selectedRecheck:true);#expect(next(l) == .stop && stage(l).nextStep?.rechecks==1)
        var done=todo;done.isComplete=true;try write([done],d)
        _=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d);#expect(next(l) == .review && stage(l).nextStep?.rechecks==0 && l.rows[1]==before)
    }
    @Test func missingTargetAsksOnceThenRequiresExplicitRevision() throws {
        let(d,l,p,c,s,todo)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try write([],d)
        _=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d);#expect(next(l) == .ask)
        let q=AssistantStageQuestion(runID:c,purpose:"missing_details",question:"请确认目标信息",choices:[]),reply=AssistantMessage(text:"请确认目标",isUser:false,stageQuestion:q),before=l.rows[1]
        try l.askNextStep(parentID:p,stageID:s,reply:reply,scope:scope);#expect(next(l) == .answer)
        #expect(throws:(any Error).self){try l.askNextStep(parentID:p,stageID:s,reply:reply,scope:scope)}
        let userID=UUID();try l.resume(c,messageID:userID,scope:scope,supplement:.init(questionID:q.id,messageID:userID,text:"原ID已删除",selected:nil))
        try l.finish(c,reply:.init(text:"需要调整目标",isUser:false),state:.responded,note:"保留原目标")
        _=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d)
        #expect(next(l) == .adjust && l.rows[1].modelRequests==before.modelRequests && stage(l).factCriterion?.targetID==todo.id)
        let restored=AssistantRunLedger(store:.init(directory:d));#expect(restored.rows==l.rows && stage(restored).nextStep?.clarificationUsed==true)
    }
    @Test func pendingAndUnknownReceiptsTakePriorityOverModelSuggestions() throws {
        for state in ["pending","unverified"] {
            let(d,l,_,_,_,_)=try fixture(action:"complete_personal_todo");defer{try? FileManager.default.removeItem(at:d)}
            try l.stageTransaction{rows in rows[1].receipts=[.init(actionID:UUID(),messageID:UUID(),key:scope,summary:"原操作",state:state)]}
            #expect(next(l) == .inspect)
        }
    }
    @Test func completedReceiptAndUnmetOrMissingFactsNeverReplay() throws {
        let(d,l,p,_,s,_)=try fixture(action:"complete_personal_todo");defer{try? FileManager.default.removeItem(at:d)}
        try l.stageTransaction{rows in rows[1].receipts=[.init(actionID:UUID(),messageID:UUID(),key:scope,summary:"已执行",state:"completed")]}
        #expect(next(l) == .query)
        _=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d);#expect(next(l) == .stop)
        try write([],d);_=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d);#expect(next(l) == .stop)
    }
    @Test func cancelledOperationsStopButRevisionSupersededCardsDoNot() throws {
        let(d,l,_,_,_,_)=try fixture(action:"complete_personal_todo");defer{try? FileManager.default.removeItem(at:d)};let id=UUID()
        try l.stageTransaction{rows in rows[1].receipts=[.init(actionID:id,messageID:UUID(),key:scope,summary:"已取消",state:"dismissed")]}
        #expect(next(l) == .stop)
        try l.stageTransaction{rows in rows[1].supersededActionIDs=[id]};#expect(next(l) == .resume)
    }
    @Test func satisfiedFactsAllowHumanReviewEvenAtBudgetLimit() throws {
        let(d,l,_,_,_,_)=try fixture(done:true);defer{try? FileManager.default.removeItem(at:d)}
        try l.stageTransaction{rows in rows[1].modelRequests=4};#expect(next(l) == .review)
    }
    @Test func satisfiedWriteWithoutReceiptAvoidsRedundantExecution() throws {
        let(d,l,_,_,_,_)=try fixture(action:"complete_personal_todo",done:true);defer{try? FileManager.default.removeItem(at:d)}
        #expect(next(l) == .adjust)
        try l.stageTransaction{rows in rows[1].modelRequests=4};#expect(next(l) == .stop)
    }
    @Test func budgetEndedRunningAndRevisionStatesAreBounded() throws {
        let(d,l,_,_,_,_)=try fixture(action:"complete_personal_todo");defer{try? FileManager.default.removeItem(at:d)}
        try l.stageTransaction{rows in rows[1].modelRequests=4};#expect(next(l) == .stop)
        try l.stageTransaction{rows in rows[1].modelRequests=1;rows[1].stageRevisionPending=true};#expect(next(l) == .resume)
        try l.stageTransaction{rows in rows[1].state = .running};#expect(next(l) == .wait)
        try l.stageTransaction{rows in rows[1].state = .paused;rows[0].state = .cancelled};#expect(next(l) == .stop)
    }
    @Test func staleScopeAndVersionTokensDoNotMutateLedger() throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let t=token(l),before=l.rows
        #expect(throws:(any Error).self){try l.validateNextStep(t,scope:AssistantRun.digest("other"))};#expect(l.rows==before)
        try l.stageTransaction{rows in rows[1].revision+=1}
        #expect(throws:(any Error).self){try l.validateNextStep(t,scope:scope)}
    }
    @Test func proofSignatureIgnoresClockButDetectsChangedSourceFields() throws {
        let(d,l,_,_,_,todo)=try fixture();defer{try? FileManager.default.removeItem(at:d)}
        let a=try #require(StageFactPolicy.read(stage:stage(l),directory:d,now:Date(timeIntervalSince1970:1))),b=try #require(StageFactPolicy.read(stage:stage(l),directory:d,now:Date(timeIntervalSince1970:2)))
        #expect(StageNextStepPolicy.signature(a)==StageNextStepPolicy.signature(b))
        var renamed=todo;renamed.title="已更名";try write([renamed],d)
        #expect(StageNextStepPolicy.signature(a) != StageNextStepPolicy.signature(StageFactPolicy.read(stage:stage(l),directory:d)!))
    }
    @Test func malformedDecisionAndLegacyOptionalFieldsAreValidated() throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};var damaged=l.rows
        damaged[0].stagePlan!.stages[0].nextStep = .init(kind:.query,reason:"错误版本",proofSignature:scope,rechecks:2)
        #expect(throws:(any Error).self){try AssistantRunStore.validate(damaged)}
        var old=stage(l);old.nextStep=nil;let restored=try JSONDecoder().decode(AssistantGoalStage.self,from:JSONEncoder().encode(old));#expect(restored.nextStep==nil)
    }
    @Test func newlyConfirmedOperationRequiresOneFreshFactReadThenHumanReview() throws {
        let(d,l,p,_,s,todo)=try fixture(action:"complete_personal_todo");defer{try? FileManager.default.removeItem(at:d)}
        let id=UUID();try l.stageTransaction{rows in rows[1].receipts=[.init(actionID:id,messageID:UUID(),key:scope,summary:"已执行",state:"completed")]}
        #expect(next(l) == .query)
        var done=todo;done.isComplete=true;try write([done],d)
        _=try l.checkStageFacts(parentID:p,stageID:s,scope:scope,directory:d,selectedRecheck:true)
        #expect(next(l) == .review && stage(l).nextStep?.verifiedReceiptIDs==[id])
    }
    @Test func satisfiedFactWithoutValidReplyCannotSkipResultRecovery() throws {
        let(d,l,_,_,_,_)=try fixture(done:true);defer{try? FileManager.default.removeItem(at:d)}
        try l.stageTransaction{rows in rows[1].state = .failed;rows[1].replyIDs=[]}
        #expect(next(l) == .resume)
        try l.stageTransaction{rows in rows[1].modelRequests=4};#expect(next(l) == .stop)
    }

    @Test func targetClarificationToolCannotReappearAfterOneGuidedQuestion() async throws {
        let context=AssistantReadContext(goalStageRunID:UUID(),goalStageInputAllowed:false)
        #expect(!context.availableNames.contains(StageQuestionTool.name))
        let call=DeepSeekToolCall(id:"repeat",function:.init(name:StageQuestionTool.name,arguments:"{\"purpose\":\"missing_details\",\"question\":\"重复追问\",\"candidates\":[]}"))
        let result=try await context.execute(call,timeout:1)
        #expect(result.stageQuestion==nil && result.content.contains("stage_clarification_unavailable"))
    }

    @Test func knownExactStateOperationDoesNotRequireAnotherApprovalQuestion() throws {
        let(d,l,_,_,_,_)=try fixture(action:"complete_personal_todo");defer{try? FileManager.default.removeItem(at:d)}
        let row=stage(l),proof=StageFactPolicy.read(stage:row,directory:d)
        #expect(StageNextStepPolicy.canProposeKnownStateChange(stage:row,proof:proof))
        var read=AssistantGoalStage(title:row.title,instruction:row.instruction,criterion:row.criterion,reviewMode:"read_review",dependencies:[],factCriterion:row.factCriterion);read.id=row.id
        #expect(!StageNextStepPolicy.canProposeKnownStateChange(stage:read,proof:proof))
        try write([],d)
        #expect(!StageNextStepPolicy.canProposeKnownStateChange(stage:row,proof:StageFactPolicy.read(stage:row,directory:d)))
        var ambiguous=row;ambiguous.requiredInput="target_choice"
        #expect(!StageNextStepPolicy.canProposeKnownStateChange(stage:ambiguous,proof:proof))
    }

}
