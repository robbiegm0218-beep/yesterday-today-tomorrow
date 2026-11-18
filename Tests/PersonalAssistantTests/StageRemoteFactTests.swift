import Foundation
import Testing
@testable import PersonalAssistant

final class StageRemoteTestClient:AssistantLiveTodoReading,@unchecked Sendable {
    var done=false
    var title="远端核对"
    var returnedID="task-a"
    var failure=false
    var delay:UInt64=0
    var calls=0
    var profiles:[String]=[]
    func detail(taskID:String,profileID:String,timeout:TimeInterval) async throws ->DingTalkCLIResult {
        calls+=1;profiles.append(profileID)
        if delay>0 {try await Task.sleep(nanoseconds:delay)}
        if failure {throw DingTalkCLIError.timedOut}
        return .init(data:try JSONSerialization.data(withJSONObject:["result":["todoDetailModel":["taskId":returnedID,"subject":title,"isDone":done]]]),exitCode:0)
    }
}
@Suite(.serialized) @MainActor struct StageRemoteFactTests {
    let scope=AssistantRun.digest("remote-test-scope")
    func fixture(local:Bool=false) throws ->(URL,AssistantRunLedger,UUID,UUID,UUID,PersonalTodo) {
        let d=FileManager.default.temporaryDirectory.appendingPathComponent("remote-stage-"+UUID().uuidString);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)
        let a=PersonalTodo(title:"本地条件",importance:.normal);try JSONEncoder().encode([a]).write(to:d.appendingPathComponent("personal-todos.json"))
        let ledger=AssistantRunLedger(store:.init(directory:d)),p=try ledger.start(message:.init(text:"分阶段核对远端条件",isUser:true),scope:scope)
        let first=AssistantGoalStage(title:"核对",instruction:"只读核对明确字段",criterion:"全部字段满足并人工核对",reviewMode:"read_review",dependencies:[])
        let plan=AssistantGoalStagePlan(requestHash:ledger.rows[0].requestHash,stages:[first,.init(title:"总结",instruction:"只读总结",criterion:"人工核对",reviewMode:"read_review",dependencies:[0])]),reply=AssistantMessage(text:"待采用",isUser:false,goalPlanDraft:plan)
        try ledger.finish(p,reply:reply,state:.awaitingConfirmation,note:"待采用");try ledger.installStagePlan(plan,parentID:p,replyID:reply.id,scope:scope)
        let c=try ledger.start(message:.init(text:"按需核对条件",isUser:true),scope:scope,parentID:p,stageIndex:0)
        try ledger.finish(c,reply:.init(text:"旧回复",isUser:false),state:.responded,note:"字段核对")
        try ledger.stageTransaction{rows in
            rows[0].stagePlan!.stages[0].remoteFactCriterion = .init(profileID:"corp:user",taskID:"task-a",expectedStatus:"complete",expectedTitle:nil)
            if local {rows[0].stagePlan!.stages[0].factCriterion = .init(targetID:a.id,expectedStatus:"complete",expectedTitle:nil)}
        }
        return(d,ledger,p,c,first.id,a)
    }
    func stage(_ l:AssistantRunLedger)->AssistantGoalStage {l.rows[0].stagePlan!.stages[0]}
    func reader(_ client:StageRemoteTestClient,selected:Set<String>=["corp:user"])->AssistantLiveTodoReader {.init(client:client,scope:{.init(selected:selected,readableIDs:["dingtalk-corp:user-task-a"])})}
    func read(_ l:AssistantRunLedger,_ client:StageRemoteTestClient) async throws ->AssistantStageRemoteCheck {try await StageRemoteFactPolicy.read(stage:stage(l),reader:reader(client),timeout:1)}
    @Test func exactRemoteStateIsVerifiedOnlyInOriginalOrganization() async throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let client=StageRemoteTestClient()
        let unmet=try await read(l,client);#expect(unmet.status=="unsatisfied" && unmet.observedComplete==false && client.profiles==["corp:user"])
        client.done=true;let matched=try await read(l,client);#expect(matched.status=="satisfied");try matched.validate(stage:stage(l))
    }
    @Test func wrongTaskOrFailedReadNeverUsesOldSatisfiedSnapshot() async throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let client=StageRemoteTestClient();client.done=true;#expect(try await read(l,client).status=="satisfied")
        client.returnedID="another-task";#expect(try await read(l,client).status=="unknown")
        client.failure=true;let failed=try await read(l,client);#expect(failed.status=="unknown" && failed.observedTitle==nil)
    }
    @Test func deselectedOrganizationBlocksBeforeNetwork() async throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let client=StageRemoteTestClient()
        let proof=try await StageRemoteFactPolicy.read(stage:stage(l),reader:reader(client,selected:[]),timeout:1)
        #expect(proof.status=="unknown" && client.calls==0)
    }
    @Test func scopeChangeDuringReadRejectsSuccessfulPayload() async throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let client=StageRemoteTestClient();client.delay=50_000_000;client.done=true
        var selected:Set<String>=["corp:user"]
        let reader=AssistantLiveTodoReader(client:client,scope:{.init(selected:selected,readableIDs:["dingtalk-corp:user-task-a"])})
        let task=Task{try await StageRemoteFactPolicy.read(stage:stage(l),reader:reader,timeout:1)}
        try await Task.sleep(nanoseconds:10_000_000);selected=[]
        #expect(try await task.value.status=="unknown")
    }
    @Test func readQuotaAndTimeAreReservedBeforeIO() throws {
        let(d,l,p,c,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)}
        let token=try l.reserveRemoteCheck(parentID:p,stageID:s,scope:scope)
        #expect(l.rows.first{$0.id==c}?.readCalls==1 && l.rows.first{$0.id==c}?.elapsedMilliseconds==20_000 && token.reservedMilliseconds==20_000)
        let restored=AssistantRunLedger(store:.init(directory:d));#expect(restored.rows.first{$0.id==c}?.readCalls==1 && restored.rows.first{$0.id==c}?.elapsedMilliseconds==20_000 && stage(restored).remoteFactCheck==nil)
    }
    @Test func returnedResultChargesActualTimeWithoutResettingPriorBudget() async throws {
        let(d,l,p,c,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.stageTransaction{rows in rows[1].elapsedMilliseconds=5000;rows[1].readCalls=2}
        let token=try l.reserveRemoteCheck(parentID:p,stageID:s,scope:scope),client=StageRemoteTestClient();let proof=try await read(l,client)
        _=try l.recordRemoteCheck(token,proof:proof,reply:.init(text:"实时字段结果",isUser:false),scope:scope)
        #expect(l.rows.first{$0.id==c}!.elapsedMilliseconds>=5001 && l.rows.first{$0.id==c}!.elapsedMilliseconds<25_000 && l.rows.first{$0.id==c}?.readCalls==3 && l.rows.first{$0.id==c}?.modelRequests==0)
    }
    @Test func staleRevisionAndScopeCannotCommitLateProof() async throws {
        let(d,l,p,_,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let token=try l.reserveRemoteCheck(parentID:p,stageID:s,scope:scope),client=StageRemoteTestClient();let proof=try await read(l,client)
        #expect(throws:(any Error).self){try l.recordRemoteCheck(token,proof:proof,reply:.init(text:"迟到",isUser:false),scope:AssistantRun.digest("other"))}
        try l.stageTransaction{rows in rows[0].revision+=1}
        #expect(throws:(any Error).self){try l.recordRemoteCheck(token,proof:proof,reply:.init(text:"迟到",isUser:false),scope:scope)}
        #expect(stage(l).remoteFactCheck==nil)
    }
    @Test func persistedSatisfiedSnapshotAloneCannotCompleteStage() async throws {
        let(d,l,p,_,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let client=StageRemoteTestClient();client.done=true;let token=try l.reserveRemoteCheck(parentID:p,stageID:s,scope:scope),proof=try await read(l,client)
        _=try l.recordRemoteCheck(token,proof:proof,reply:.init(text:"满足",isUser:false),scope:scope)
        #expect(throws:(any Error).self){try l.reviewStage(parentID:p,stageID:s,note:"使用旧满足快照",scope:scope,directory:d)}
        let restored=AssistantRunLedger(store:.init(directory:d));#expect(throws:(any Error).self){try restored.reviewStage(parentID:p,stageID:s,note:"重启后沿用旧结论",scope:scope,directory:d)}
    }
    @Test func freshAuthorizationAllowsOnlyManualCompletion() async throws {
        let(d,l,p,_,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let client=StageRemoteTestClient();client.done=true;let token=try l.reserveRemoteCheck(parentID:p,stageID:s,scope:scope),proof=try await read(l,client)
        let permit=try l.recordRemoteCheck(token,proof:proof,reply:.init(text:"字段满足",isUser:false),scope:scope)
        #expect(!stage(l).isComplete);try l.reviewStage(parentID:p,stageID:s,note:"本次字段已核对，其他条件人工核对",scope:scope,directory:d,remoteAuthorization:permit)
        #expect(stage(l).isComplete && l.rows[0].stagePlan!.stages[1].childRunID==nil)
        #expect(throws:(any Error).self){try l.reviewStage(parentID:p,stageID:s,note:"再次使用",scope:scope,directory:d,remoteAuthorization:permit)}
    }
    @Test func localUnmetOrUnknownBlocksCombinedCompletion() async throws {
        let(d,l,p,_,s,_)=try fixture(local:true);defer{try? FileManager.default.removeItem(at:d)};let client=StageRemoteTestClient();client.done=true;let token=try l.reserveRemoteCheck(parentID:p,stageID:s,scope:scope),proof=try await read(l,client)
        let permit=try l.recordRemoteCheck(token,proof:proof,reply:.init(text:"远端满足",isUser:false),scope:scope)
        #expect(stage(l).factCheck?.status=="unsatisfied")
        #expect(throws:(any Error).self){try l.reviewStage(parentID:p,stageID:s,note:"远端满足就算完成",scope:scope,directory:d,remoteAuthorization:permit)}
        #expect(!stage(l).isComplete)
    }
    @Test func budgetExhaustionAndEndedPlanDoNotReserveNewReads() throws {
        let(d,l,p,_,s,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.stageTransaction{rows in rows[1].readCalls=6}
        #expect(throws:(any Error).self){try l.reserveRemoteCheck(parentID:p,stageID:s,scope:scope)}
        try l.stageTransaction{rows in rows[1].readCalls=0;rows[1].elapsedMilliseconds=90_000};#expect(throws:(any Error).self){try l.reserveRemoteCheck(parentID:p,stageID:s,scope:scope)}
        try l.endStagePlan(p);#expect(throws:(any Error).self){try l.reserveRemoteCheck(parentID:p,stageID:s,scope:scope)}
    }
    @Test func cancellationCannotProduceSatisfiedResult() async throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let client=StageRemoteTestClient();client.done=true;client.delay=200_000_000
        let task=Task{try await read(l,client)};try await Task.sleep(nanoseconds:10_000_000);task.cancel()
        do {_=try await task.value;Issue.record("Cancelled read returned a proof")} catch {}
    }
    @Test func wrongExpectedTitleAndForgedProofAreRejected() async throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};try l.stageTransaction{rows in rows[0].stagePlan!.stages[0].remoteFactCriterion = .init(profileID:"corp:user",taskID:"task-a",expectedStatus:"complete",expectedTitle:"要求标题")}
        let client=StageRemoteTestClient();client.done=true;let proof=try await read(l,client);#expect(proof.status=="unsatisfied")
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(proof)) as! [String:Any];object["status"]="satisfied"
        let forged=try JSONDecoder().decode(AssistantStageRemoteCheck.self,from:JSONSerialization.data(withJSONObject:object));#expect(throws:(any Error).self){try forged.validate(stage:stage(l))}
    }
    @Test func remoteConditionCannotExpandIntoWritesOrMoreThanFourTargets() throws {
        let(d,l,_,_,_,a)=try fixture();defer{try? FileManager.default.removeItem(at:d)};var plan=l.rows[0].stagePlan!
        let first=plan.stages[0];var write=AssistantGoalStage(title:first.title,instruction:first.instruction,criterion:first.criterion,reviewMode:"confirmed_operation",dependencies:[],actionTool:"complete_personal_todo");write.remoteFactCriterion=first.remoteFactCriterion;plan.stages[0]=write
        #expect(throws:(any Error).self){try plan.validate()}
        plan=l.rows[0].stagePlan!;plan.stages[0].factCriterion = .init(targetID:a.id,expectedStatus:"any",expectedTitle:nil,allOf:(0..<3).map{_ in .init(targetID:UUID(),expectedStatus:"any",expectedTitle:nil)})
        #expect(throws:(any Error).self){try plan.validate()}
    }
    @Test func oldStageEncodingAndLocalHashStayCompatible() throws {
        let h=StageFactsTests(),a=PersonalTodo(title:"A",importance:.normal),s=h.stage(a);let bytes=try JSONEncoder().encode(s)
        #expect(!String(decoding:bytes,as:UTF8.self).contains("remoteFact"))
        let copy=try JSONDecoder().decode(AssistantGoalStage.self,from:bytes);#expect(copy.remoteFactCriterion==nil && StageFactPolicy.hash(copy)==StageFactPolicy.hash(s))
    }
    @Test func persistedResultContainsOnlyVerifiedFieldsAndFixedReason() async throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let client=StageRemoteTestClient();client.failure=true
        let proof=try await read(l,client),encoded=String(decoding:try JSONEncoder().encode(proof),as:UTF8.self)
        #expect(proof.source=="live_exact_task_read" && !encoded.contains("authorization") && !encoded.contains("todoDetailModel"))
    }
    @Test func lateSuccessfulClientCannotBypassRemainingReadDeadline() async throws {
        let(d,l,_,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let client=StageRemoteTestClient();client.done=true;client.delay=30_000_000
        let proof=try await StageRemoteFactPolicy.read(stage:stage(l),reader:reader(client),timeout:0.001)
        #expect(proof.status=="unknown" && proof.observedTitle==nil && client.calls==1)
    }

}
