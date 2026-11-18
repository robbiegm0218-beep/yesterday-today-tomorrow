import Foundation

/// Synthetic DWS detail client. No process, credentials or network is invoked.
final class StageRemoteAcceptanceClient:AssistantLiveTodoReading,@unchecked Sendable {
    var done=false,fails=false,wrongID=false
    var delay:UInt64=0
    var calls=0
    var profiles:[String]=[]
    func detail(taskID:String,profileID:String,timeout:TimeInterval) async throws ->DingTalkCLIResult {
        calls+=1;profiles.append(profileID)
        if delay>0 {try await Task.sleep(nanoseconds:delay)}
        if fails {throw DingTalkCLIError.timedOut}
        return .init(data:try JSONSerialization.data(withJSONObject:["result":["todoDetailModel":["taskId":wrongID ? "other-task" : taskID,"subject":"钉钉接口评审","isDone":done]]]),exitCode:0)
    }
}
@MainActor enum StageRemoteAcceptance {
    static func scope(_ profile:String)->String {
        let values=["profiles":[profile],"hidden":[String](),"knowledge":[String](),"skills":LocalSkillStore.load().filter(\.isEnabled).map{$0.id+":"+$0.instruction}.sorted()]
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return AssistantRun.digest(String(decoding:(try? encoder.encode(values)) ?? Data(),as:UTF8.self))
    }
    static func model(_ client:StageRemoteAcceptanceClient,_ source:ScenarioRemote)->AssistantModel {
        AssistantModel(dailyDataSource:source,services:.init(apiKey:{preconditionFailure("Remote condition checks must not request a model key")},liveTodoClient:client,initialProfiles:[source.profile]))
    }
    static func settle(_ app:AssistantModel) async throws {
        for _ in 0..<3000 {if !app.remoteFactBusy && !app.isRefreshing{return};try await Task.sleep(for:.milliseconds(5))}
        app.cancelRemoteFactCheck();throw ProjectUpdateError.invalid("remote_fixture_did_not_settle")
    }
    static func awaitRead(_ client:StageRemoteAcceptanceClient) async throws {
        for _ in 0..<1000 {if client.calls>0{return};try await Task.sleep(for:.milliseconds(1))};throw ProjectUpdateError.invalid("remote_fixture_not_started")
    }
    static func run(_ index:Int) async ->Bool {
        let root=LocalAssistantPaths.dataDirectory,resuming=CommandLine.arguments.contains(where:{$0.hasPrefix("--resume-sandbox=")}),client=StageRemoteAcceptanceClient(),source=ScenarioRemote()
        var checks:[String:Bool]=[:],failure:String?,checkpoint=false
        do {
            let parentID:UUID,stageID:UUID
            var app:AssistantModel
            if resuming {
                let saved=try JSONDecoder().decode([String:UUID].self,from:Data(contentsOf:root.appendingPathComponent("remote-condition-fixture.json")))
                guard let p=saved["parent"],let s=saved["stage"],let c=saved["child"] else {throw ProjectUpdateError.invalid("remote_condition_fixture_missing")};parentID=p;stageID=s
                app=model(client,source);let before=app.assistantRuns.first{$0.id==c}!
                checks["old_satisfied_snapshot_restored_but_not_auto_completed"]=app.assistantRuns.first{$0.id==p}?.stagePlan?.stages[0].remoteFactCheck?.status=="satisfied" && app.assistantRuns.first{$0.id==p}?.stagePlan?.stages[0].isComplete==false && before.readCalls==2
                client.fails=true;app.reviewGoalStage(p,stageID:s,note:"重启后必须重新核对，不能沿用旧满足")
                try await settle(app)
                checks["restart_review_requeries_and_blocks_on_unknown"]=client.calls==1 && app.assistantRuns.first{$0.id==p}?.stagePlan?.stages[0].remoteFactCheck?.status=="unknown" && app.assistantRuns.first{$0.id==p}?.stagePlan?.stages[0].isComplete==false
                checks["restart_keeps_child_and_budget"]=app.assistantRuns.count==2 && app.assistantRuns.first{$0.id==c}?.readCalls==3 && app.assistantRuns.first{$0.id==c}!.elapsedMilliseconds>=before.elapsedMilliseconds
            } else {
                AssistantRuntime.preferences.set(false,forKey:"autoMemoryEnabled");AssistantRuntime.preferences.set([source.profile.id],forKey:"dingTalkSelectedProfiles");try LocalSkillStore.save(AssistantSkill.defaults)
                var local=PersonalTodo(title:"本地组合条件",importance:.normal);try LocalTodoStore.save([local])
                let ledger=AssistantRunLedger(),user=AssistantMessage(text:"分阶段只读核对钉钉原任务及已配置条件，不修改业务",isUser:true)
                parentID=try ledger.start(message:user,scope:scope(source.profile.id))
                let first=AssistantGoalStage(title:"核对远端字段",instruction:"按原组织核对精确任务字段，其余内容人工核对",criterion:"全部配置字段满足后人工确认",reviewMode:"read_review",dependencies:[]);stageID=first.id
                let plan=AssistantGoalStagePlan(requestHash:ledger.rows[0].requestHash,stages:[first,.init(title:"总结",instruction:"只读总结",criterion:"人工核对",reviewMode:"read_review",dependencies:[0])]),proposal=AssistantMessage(text:"离线阶段夹具",isUser:false,goalPlanDraft:plan)
                try ledger.finish(parentID,reply:proposal,state:.awaitingConfirmation,note:"方案夹具");try ledger.installStagePlan(plan,parentID:parentID,replyID:proposal.id,scope:scope(source.profile.id));LocalConversationStore.save([user,proposal])
                app=model(client,source);await app.refreshWorkbenchAndWait();app.beginStageRevision(parentID,stageID:stageID)
                guard var change=app.stageRevisionDraft,app.remoteStageFactOptions.contains(where:{$0.id==source.id}) else {throw ProjectUpdateError.invalid("remote_option_missing")}
                change.remoteFactEnabled=true;change.remoteProfileID=source.profile.id;change.remoteTaskID=source.taskID;change.remoteStatus="complete";change.reason="明确配置原组织与精确任务的只读完成条件"
                if index==105 {change.factEnabled=true;change.factTargetID=local.id.uuidString;change.factStatus="complete"}
                guard app.applyStageRevision(change) else {throw ProjectUpdateError.invalid("remote_condition_not_saved")}
                checks["adoption_does_not_query_or_start"]=client.calls==0 && app.assistantRuns.count==1 && app.assistantRuns[0].stagePlan?.stages[0].childRunID==nil
                if index==108 {
                    app.beginStageRevision(parentID,stageID:stageID);guard var wrong=app.stageRevisionDraft else {throw ProjectUpdateError.invalid("remote_second_preview_missing")}
                    wrong.remoteProfileID="other:organization";wrong.reason="错误组织不得查询"
                    checks["unselected_organization_refuses_preview"] = !app.applyStageRevision(wrong) && client.calls==0
                    wrong.remoteProfileID=source.profile.id;wrong.remoteStatus="open";wrong.reason="明确核对未完成状态";guard app.applyStageRevision(wrong) else {throw ProjectUpdateError.invalid("remote_expected_status_failed")}
                    checks["stale_preview_refused_without_read"] = !app.applyStageRevision(wrong) && client.calls==0
                    client.wrongID=true
                }
                if index==106 || index==107 {client.delay=200_000_000}
                app.startGoalStage(parentID,index:0)
                if index==106 {
                    try await awaitRead(client);app.checkRemoteGoalStage(parentID,stageID:stageID)
                    app.selectedDingTalkProfileIDs=[];try await settle(app)
                    checks["single_active_read_and_scope_change_drop_late_proof"]=client.calls==1 && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].remoteFactCheck==nil
                    client.delay=0;client.done=true;app.selectedDingTalkProfileIDs=[source.profile.id]
                    app.checkRemoteGoalStage(parentID,stageID:stageID);try await settle(app)
                    let child=app.assistantRuns.first{$0.parentRunID==parentID}!
                    checks["explicit_scope_restore_rechecks_without_budget_reset"]=client.calls==2 && child.readCalls==2 && child.elapsedMilliseconds>=20_000 && app.assistantRuns.count==2
                    try JSONEncoder().encode(["parent":parentID,"stage":stageID,"child":child.id]).write(to:root.appendingPathComponent("remote-condition-fixture.json"));try JSONEncoder().encode(checks).write(to:root.appendingPathComponent("remote-condition-checks.json"));AssistantRuntime.preferences.synchronize();checkpoint=true
                } else if index==107 {
                    try await awaitRead(client);app.cancelRemoteFactCheck();try await settle(app)
                    checks["cancelled_read_is_unknown_not_success"]=app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].remoteFactCheck?.status=="unknown"
                    client.delay=0;client.done=true
                    for _ in 0..<5 {app.checkRemoteGoalStage(parentID,stageID:stageID);try await settle(app)}
                    app.reviewGoalStage(parentID,stageID:stageID,note:"耗尽读取预算不能绕过新鲜核对")
                    checks["six_read_limit_blocks_extra_query_and_completion"]=client.calls==6 && app.assistantRuns.first{$0.parentRunID==parentID}?.readCalls==6 && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==false
                    app.endAssistantRun(parentID);app.checkRemoteGoalStage(parentID,stageID:stageID)
                    checks["ended_goal_cannot_requery"]=client.calls==6
                } else {
                    try await settle(app)
                    let first=app.assistantRuns.first{$0.id==parentID}!.stagePlan!.stages[0]
                    checks["initial_remote_observation_not_automatic_completion"]=client.calls==1 && first.remoteFactCheck?.status==(index==108 ? "unknown" : "unsatisfied") && !first.isComplete
                    if index==105 {
                        client.done=true;app.reviewGoalStage(parentID,stageID:stageID,note:"远端满足也要核对本地条件");try await settle(app)
                        checks["remote_match_does_not_hide_local_gap"]=client.calls==2 && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].factCheck?.status=="unsatisfied" && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==false
                        local.isComplete=true;try CreatedTodoAcceptance.raw([local]);app.reviewGoalStage(parentID,stageID:stageID,note:"本次原组织字段与本地条件全部核对，其他内容人工确认");try await settle(app)
                        checks["fresh_combined_match_allows_manual_stage_only"]=client.calls==3 && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==true && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[1].childRunID==nil
                    } else {
                        client.wrongID=false;app.checkRemoteGoalStage(parentID,stageID:stageID);try await settle(app)
                        checks["correct_original_identity_recovers_match"]=client.calls==2 && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].remoteFactCheck?.status=="satisfied"
                        app.hiddenExternalTodos=[.init(id:source.id,title:source.title,hiddenAt:Date())];app.reviewGoalStage(parentID,stageID:stageID,note:"隐藏后不能沿用旧满足")
                        checks["hidden_scope_blocks_query_and_old_completion"]=client.calls==2 && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==false
                    }
                }
            }
            checks["zero_model_calls_and_original_profile_only"]=app.assistantRuns.allSatisfy{$0.modelRequests==0 && $0.tokens==0} && client.profiles.allSatisfy{$0==source.profile.id} && source.writes==0
            if resuming,let old=try? JSONDecoder().decode([String:Bool].self,from:Data(contentsOf:root.appendingPathComponent("remote-condition-checks.json"))) {checks.merge(old){a,_ in a}}
        } catch {failure=error.localizedDescription}
        let passed=failure==nil && !checks.isEmpty && checks.values.allSatisfy{$0}
        let report:[String:Any]=["case_id":String(format:"INT-%02d",index),"outcome":checkpoint ? "restart_required" : passed ? "pass" : "fail","failure":failure ?? "none","checks":checks,"processID":ProcessInfo.processInfo.processIdentifier,"sandboxPath":root.path,"processRestarted":resuming,"scope":"offline DWS detail fixture; original profile, fresh review, budgets and cancellation; no external calls","modelRequests":0,"tokens":0,"usageComplete":true,"simulatedModelRequests":0,"controlledRemoteReads":client.calls,"fixtureModelResponse":true,"externalModelRequests":0,"realRemoteReads":0,"automaticBusinessWrites":0,"realExternalWrites":0,"realNotifications":0]
        if let bytes=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {print("AGENT_SCENARIO_RESULT: "+String(decoding:bytes,as:UTF8.self));fflush(stdout)}
        AgentScenarioAcceptance.didCheckpoint=checkpoint;if !checkpoint {AssistantRuntime.finishEvaluationPreferences()};return passed && !checkpoint
    }
}
