import Foundation

/// Uses the locally intercepted streaming client, real stage ledger and raw source reads.
@MainActor enum StageCompositeAcceptance {
    static func raw(_ todos:[PersonalTodo]) throws {try CreatedTodoAcceptance.raw(todos)}
    static func run(_ index:Int) async ->Bool {
        let root=LocalAssistantPaths.dataDirectory,resuming=CommandLine.arguments.contains(where:{$0.hasPrefix("--resume-sandbox=")})
        var checks:[String:Bool]=[:],failure:String?,checkpoint=false
        do {
            StageReferenceAcceptance.suppliedFixtureKey=0
            var app:AssistantModel
            let parentID:UUID,childID:UUID,stageID:UUID
            var a:PersonalTodo,b:PersonalTodo,c:PersonalTodo
            if resuming {
                let fixture=try JSONDecoder().decode([String:UUID].self,from:Data(contentsOf:root.appendingPathComponent("composite-fixture.json")))
                guard let p=fixture["parent"],let child=fixture["child"],let s=fixture["stage"] else {throw ProjectUpdateError.invalid("composite_fixture_missing")}
                parentID=p;childID=child;stageID=s;app=StageReferenceAcceptance.model()
                a=app.personalTodos[0];b=a;c=a
                let token=app.nextStepToken(parentID:parentID,stageID:stageID)!
                checks["unknown_stop_survives_actual_exit"]=token.kind == .stop && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].nextStep?.rechecks==1
                let used=app.assistantRuns.first{$0.id==childID}!.modelRequests
                app.performStageNextStep(token);app.reviewGoalStage(parentID,stageID:stageID,note:"尝试使用重启前结果")
                checks["restart_does_not_send_or_reset_or_complete"]=StageReferenceAcceptance.suppliedFixtureKey==0 && StageReferenceFixtureProtocol.captured.isEmpty && app.assistantRuns.count==2 && app.assistantRuns.first{$0.id==childID}?.modelRequests==used && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==false
            } else {
                AssistantRuntime.preferences.set(false,forKey:"autoMemoryEnabled");AssistantRuntime.preferences.set([String](),forKey:"dingTalkSelectedProfiles");try LocalSkillStore.save(AssistantSkill.defaults)
                a=PersonalTodo(title:"组合条件A",importance:.normal);b=PersonalTodo(title:"组合条件B",importance:.normal);c=PersonalTodo(title:"组合条件C",importance:.normal)
                try LocalTodoStore.save([a,b,c])
                let ledger=AssistantRunLedger(),user=AssistantMessage(text:"分阶段只读核对多条个人待办，全部条件满足才人工确认",isUser:true)
                parentID=try ledger.start(message:user,scope:CreatedTodoAcceptance.scope())
                let first=AssistantGoalStage(title:"核对条件",instruction:"只读核对当前事项字段与条件缺口，不修改事项",criterion:"所有已配置字段满足后人工核对",reviewMode:"read_review",dependencies:[],factCriterion:.init(targetID:a.id,expectedStatus:"complete",expectedTitle:nil))
                stageID=first.id
                let plan=AssistantGoalStagePlan(requestHash:ledger.rows[0].requestHash,stages:[first,.init(title:"总结",instruction:"只读总结",criterion:"人工核对",reviewMode:"read_review",dependencies:[0])]),proposal=AssistantMessage(text:"离线方案夹具",isUser:false,goalPlanDraft:plan)
                try ledger.finish(parentID,reply:proposal,state:.awaitingConfirmation,note:"夹具方案");try ledger.installStagePlan(plan,parentID:parentID,replyID:proposal.id,scope:CreatedTodoAcceptance.scope())
                let request=AssistantMessage(text:"只读核对当前条件",isUser:true);childID=try ledger.start(message:request,scope:CreatedTodoAcceptance.scope(),parentID:parentID,stageIndex:0)
                let reply=AssistantMessage(text:"旧的单项核对回复夹具，不替代新条件",isUser:false);try ledger.finish(childID,reply:reply,state:.responded,note:"旧回复")
                LocalConversationStore.save([user,proposal,request,reply]);app=StageReferenceAcceptance.model()
                app.beginStageRevision(parentID,stageID:stageID)
                guard var change=app.stageRevisionDraft else {throw ProjectUpdateError.invalid("composite_preview_missing")}
                change.extraFacts=[.init(targetID:b.id.uuidString,expectedStatus:"open",expectedTitle:b.title),.init(targetID:c.id.uuidString,expectedStatus:"any",expectedTitle:c.title)];change.reason="明确增加必须同时满足的个人待办条件"
                if index==104 {
                    let before=app.assistantRuns
                    var duplicate=change;duplicate.extraFacts[0].targetID=a.id.uuidString
                    checks["duplicate_target_refused_without_mutation"] = !app.applyStageRevision(duplicate) && app.assistantRuns==before
                    app.selectedDingTalkProfileIDs=["unexpected-scope"]
                    checks["scope_change_refuses_composite_preview"] = !app.applyStageRevision(change) && app.assistantRuns==before
                    app.selectedDingTalkProfileIDs=[]
                }
                guard app.applyStageRevision(change) else {throw ProjectUpdateError.invalid("composite_revision_failed")}
                checks["same_child_budget_and_no_automatic_model_call"]=app.assistantRuns.count==2 && app.assistantRuns.first{$0.id==childID}?.modelRequests==0 && StageReferenceAcceptance.suppliedFixtureKey==0
                if index==104 {
                    checks["stale_preview_refused_without_reset"] = !app.applyStageRevision(change) && app.assistantRuns.first{$0.id==parentID}?.stageRevisions?.count==1 && StageReferenceAcceptance.suppliedFixtureKey==0
                } else {
                    StageReferenceFixtureProtocol.configure(target:a.id,title:"多条件离线核对")
                    let bytes=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))
                    let token=app.nextStepToken(parentID:parentID,stageID:stageID)!
                    app.performStageNextStep(token);try await StageReferenceAcceptance.settle(app)
                    let proof=app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].factCheck
                    let body=StageReferenceFixtureProtocol.captured.first ?? ""
                    checks["request_contains_all_rules_and_components"]=StageReferenceFixtureProtocol.captured.count==1 && body.contains("allOf") && body.contains("components") && [a.id,b.id,c.id].allSatisfy{body.contains($0.uuidString)}
                    checks["partial_result_is_not_complete"]=proof?.status=="unsatisfied" && proof?.components?.map(\.status)==["unsatisfied","satisfied","satisfied"] && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==false
                    checks["model_reply_does_not_write_source"]=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))==bytes
                    let calls=StageReferenceFixtureProtocol.captured.count
                    if index==101 {
                        app.reviewGoalStage(parentID,stageID:stageID,note:"文字说已完成不能替代所有条件")
                        checks["unmet_component_blocks_human_completion"]=app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==false
                        a.isComplete=true;try raw([a,b,c]);app.checkGoalStageFacts(parentID,stageID:stageID)
                        app.reviewGoalStage(parentID,stageID:stageID,note:"已核对同一源快照中三项条件全部满足，其他条件人工核对")
                        checks["all_satisfied_allows_only_manual_stage_review"]=app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==true && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[1].childRunID==nil
                    } else if index==102 {
                        try raw([a,c]);app.checkGoalStageFacts(parentID,stageID:stageID)
                        let query=app.nextStepToken(parentID:parentID,stageID:stageID)!
                        checks["unknown_secondary_is_reported_not_hidden_by_unmet_primary"]=query.kind == .query && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].factCheck?.status=="unknown"
                        app.performStageNextStep(query)
                        checks["one_unchanged_recheck_then_stop"]=app.nextStepToken(parentID:parentID,stageID:stageID)?.kind == .stop
                        try JSONEncoder().encode(["parent":parentID,"child":childID,"stage":stageID]).write(to:root.appendingPathComponent("composite-fixture.json"));try JSONEncoder().encode(checks).write(to:root.appendingPathComponent("composite-checks.json"));AssistantRuntime.preferences.synchronize();checkpoint=true
                    } else {
                        try Data("broken-current-source".utf8).write(to:root.appendingPathComponent("personal-todos.json"),options:.atomic)
                        app.reviewGoalStage(parentID,stageID:stageID,note:"之前两个条件满足")
                        let unknown=app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].factCheck
                        checks["broken_primary_does_not_use_backup"]=unknown?.status=="unknown" && unknown?.components?.allSatisfy{$0.gaps==["source_unavailable"]}==true
                        try raw([a,b,c]);app.checkGoalStageFacts(parentID,stageID:stageID);let old=app.nextStepToken(parentID:parentID,stageID:stageID)!
                        a.isComplete=true;try raw([a,b,c]);app.performStageNextStep(old)
                        checks["changed_source_refreshes_without_executing_old_adjust"]=app.stageRevisionDraft==nil && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].factCheck?.status=="satisfied" && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==false
                    }
                    checks["local_rechecks_do_not_call_model"]=StageReferenceFixtureProtocol.captured.count==calls && app.assistantRuns.count==2
                }
            }
            if resuming,let old=try? JSONDecoder().decode([String:Bool].self,from:Data(contentsOf:root.appendingPathComponent("composite-checks.json"))) {checks.merge(old){a,_ in a}}
        } catch {failure=error.localizedDescription}
        let passed=failure==nil && !checks.isEmpty && checks.values.allSatisfy{$0}
        let report:[String:Any]=["case_id":String(format:"INT-%02d",index),"outcome":checkpoint ? "restart_required" : passed ? "pass" : "fail","failure":failure ?? "none","checks":checks,"processID":ProcessInfo.processInfo.processIdentifier,"sandboxPath":root.path,"processRestarted":resuming,"scope":"offline composite fact conditions; local intercepted model response; one current file snapshot","modelRequests":0,"tokens":0,"usageComplete":true,"simulatedModelRequests":StageReferenceFixtureProtocol.captured.count,"fixtureModelResponse":true,"externalModelRequests":0,"automaticBusinessWrites":0,"realExternalWrites":0,"realNotifications":0]
        if let bytes=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {print("AGENT_SCENARIO_RESULT: "+String(decoding:bytes,as:UTF8.self));fflush(stdout)}
        AgentScenarioAcceptance.didCheckpoint=checkpoint;if !checkpoint {AssistantRuntime.finishEvaluationPreferences()};return passed && !checkpoint
    }
}
