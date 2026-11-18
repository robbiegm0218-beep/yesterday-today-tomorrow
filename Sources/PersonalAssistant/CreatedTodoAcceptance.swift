import Foundation

/// Deterministic production confirmation/store checks. No credential lookup or model call.
@MainActor enum CreatedTodoAcceptance {
    static func scope()->String {
        let values=["profiles":[String](),"hidden":[String](),"knowledge":[String](),"skills":LocalSkillStore.load().filter(\.isEnabled).map{$0.id+":"+$0.instruction}.sorted()]
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return AssistantRun.digest(String(decoding:(try? encoder.encode(values)) ?? Data(),as:UTF8.self))
    }
    static func model()->AssistantModel {
        AssistantModel(dailyDataSource:LocalOnlyDailyDataSource(),services:.init(apiKey:{preconditionFailure("Offline receipt acceptance must not request credentials or models")}))
    }
    static func raw(_ todos:[PersonalTodo]) throws {try JSONEncoder().encode(todos).write(to:LocalAssistantPaths.dataDirectory.appendingPathComponent("personal-todos.json"),options:.atomic)}
    static func settle(_ model:AssistantModel) async throws {
        for _ in 0..<200 {if !model.isRefreshing{return};try await Task.sleep(for:.milliseconds(10))}
        throw ProjectUpdateError.invalid("offline_local_refresh_not_finished")
    }
    static func run(_ index:Int) async ->Bool {
        var checks:[String:Bool]=[:],failed:String?,checkpoint=false
        let root=LocalAssistantPaths.dataDirectory,resuming=CommandLine.arguments.contains(where:{$0.hasPrefix("--resume-sandbox=")})
        do {
            let parentID:UUID,childID:UUID,stageID:UUID,messageID:UUID,actionID:UUID
            var app:AssistantModel
            if resuming {
                let fixture=try JSONDecoder().decode([String:UUID].self,from:Data(contentsOf:root.appendingPathComponent("created-receipt-fixture.json")))
                guard let p=fixture["parent"],let c=fixture["child"],let s=fixture["stage"],let m=fixture["message"],let a=fixture["action"],let target=fixture["target"] else {throw ProjectUpdateError.invalid("offline_fixture_missing")}
                parentID=p;childID=c;stageID=s;messageID=m;actionID=a
                app=model()
                let child=app.assistantRuns.first{$0.id==childID}!,before=child.modelRequests
                checks["precise_target_restored_after_actual_exit"]=child.receipts[0].createdTodo?.targetID==target
                var replacement=app.personalTodos.first{$0.sourceActionID==actionID}!;replacement.id=UUID();try raw([replacement])
                app.checkCreatedGoalStage(parentID,stageID:stageID)
                let result=app.assistantRuns.first{$0.id==childID}?.receipts[0].createdTodo
                checks["same_action_replacement_does_not_retarget"]=result?.targetID==target && result?.status=="target_missing"
                app.reviewGoalStage(parentID,stageID:stageID,note:"尝试用旧创建结论完成")
                checks["stale_result_blocks_completion_without_new_run"]=app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==false && app.assistantRuns.count==2 && app.assistantRuns.first{$0.id==childID}?.modelRequests==before
            } else {
                AssistantRuntime.preferences.set(false,forKey:"autoMemoryEnabled");AssistantRuntime.preferences.set([String](),forKey:"dingTalkSelectedProfiles")
                try LocalSkillStore.save(AssistantSkill.defaults)
                try LocalTodoStore.save([PersonalTodo(title:"本机创建核对",importance:.normal)])
                let ledger=AssistantRunLedger(),original=AssistantMessage(text:"分阶段创建个人待办，再人工核对原创建结果",isUser:true)
                parentID=try ledger.start(message:original,scope:scope())
                let first=AssistantGoalStage(title:"创建并核对",instruction:"创建个人待办「本机创建核对」，无截止日期",criterion:"用户确认创建，并核对原ID仍存在；其他业务条件人工核对",reviewMode:"confirmed_operation",dependencies:[],actionTool:"create_personal_todo")
                stageID=first.id
                let plan=AssistantGoalStagePlan(requestHash:ledger.rows[0].requestHash,stages:[first,.init(title:"总结",instruction:"只读总结",criterion:"人工核对",reviewMode:"read_review",dependencies:[0])])
                let planMessage=AssistantMessage(text:"离线夹具提供的待采用方案",isUser:false,goalPlanDraft:plan)
                try ledger.finish(parentID,reply:planMessage,state:.awaitingConfirmation,note:"合成方案");try ledger.installStagePlan(plan,parentID:parentID,replyID:planMessage.id,scope:scope())
                let request=AssistantMessage(text:"创建个人待办「本机创建核对」，无截止日期",isUser:true)
                childID=try ledger.start(message:request,scope:scope(),parentID:parentID,stageIndex:0)
                let call=DeepSeekToolCall(id:"offline-create",function:.init(name:"create_personal_todo",arguments:"{\"title\":\"本机创建核对\"}"))
                guard let action=AssistantActionParser.proposals(from:[call],todos:[],projects:[]).first else {throw ProjectUpdateError.invalid("offline_proposal_rejected")}
                actionID=action.id
                let reply=AssistantMessage(text:"离线工具响应夹具，确认前不写入",isUser:false,pendingActions:[action]);messageID=reply.id
                try ledger.finish(childID,reply:reply,state:.awaitingConfirmation,note:"合成响应，无模型调用")
                LocalConversationStore.save([original,planMessage,request,reply]);app=model()
                checks["pending_not_bound_or_written"]=app.personalTodos.count==1 && app.assistantRuns.first{$0.id==childID}?.receipts[0].createdTodo==nil
                if index==95 {
                    // Controlled crash boundary: disk write occurred, chat acknowledgement did not.
                    try ledger.applying(actionID)
                    try LocalTodoStore.save(app.personalTodos+[PersonalTodo(title:"本机创建核对",importance:.normal,sourceActionID:actionID)])
                    app=model()
                    checks["unknown_acknowledgement_restored"]=app.assistantRuns.first{$0.id==childID}?.receipts[0].state=="unverified"
                }
                app.confirmPendingAction(messageID:messageID,actionID:actionID);try await settle(app)
                guard let child=app.assistantRuns.first(where:{$0.id==childID}),let result=child.receipts[0].createdTodo,let target=result.targetID else {throw ProjectUpdateError.invalid("offline_created_target_not_bound")}
                checks["confirmed_card_binds_exact_created_result"]=result.isLocated && app.personalTodos.filter{$0.sourceActionID==actionID}.count==1 && app.personalTodos.count==2
                checks["binding_does_not_complete_business_or_stage"]=app.personalTodos.first{$0.id==target}?.isComplete==false && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==false
                let bytes=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))
                app.confirmPendingAction(messageID:messageID,actionID:actionID)
                checks["repeat_confirmation_does_not_write_again"]=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))==bytes
                if index==94 {
                    try JSONEncoder().encode(["parent":parentID,"child":childID,"stage":stageID,"message":messageID,"action":actionID,"target":target]).write(to:root.appendingPathComponent("created-receipt-fixture.json"))
                    try JSONEncoder().encode(checks).write(to:root.appendingPathComponent("created-receipt-checks.json"))
                    AssistantRuntime.preferences.synchronize();checkpoint=true
                } else if index==96 {
                    try Data("broken-current-source".utf8).write(to:root.appendingPathComponent("personal-todos.json"),options:.atomic)
                    app.reviewGoalStage(parentID,stageID:stageID,note:"尝试用之前已定位结论完成")
                    let currentSource=try String(contentsOf:root.appendingPathComponent("personal-todos.json"))
                    checks["corrupt_source_blocks_review_without_backup_substitution"]=app.assistantRuns.first{$0.id==childID}?.receipts[0].createdTodo?.status=="source_unavailable" && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==false && currentSource=="broken-current-source"
                    try bytes.write(to:root.appendingPathComponent("personal-todos.json"));app.checkCreatedGoalStage(parentID,stageID:stageID)
                    checks["restored_original_source_recovers_same_target"]=app.assistantRuns.first{$0.id==childID}?.receipts[0].createdTodo?.targetID==target && app.assistantRuns.first{$0.id==childID}?.receipts[0].createdTodo?.isLocated==true
                } else {
                    app.reviewGoalStage(parentID,stageID:stageID,note:"确认原创建ID仍在，其他条件已人工核对")
                    checks["only_manual_review_completes_stage"]=app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[0].isComplete==true && app.assistantRuns.first{$0.id==parentID}?.stagePlan?.stages[1].childRunID==nil
                }
            }
            if resuming,let old=try? JSONDecoder().decode([String:Bool].self,from:Data(contentsOf:root.appendingPathComponent("created-receipt-checks.json"))) {checks.merge(old){current,_ in current}}
            checks["zero_model_requests_and_original_runs"]=app.assistantRuns.count==2 && app.assistantRuns.allSatisfy{$0.modelRequests==0 && $0.tokens==0 && !$0.inFlight}
        } catch {failed=error.localizedDescription}
        let passed=failed==nil && !checks.isEmpty && checks.values.allSatisfy{$0}
        let report:[String:Any]=["case_id":String(format:"INT-%02d",index),"outcome":checkpoint ? "restart_required" : passed ? "pass" : "fail","failure":failed ?? "none","checks":checks,"processID":ProcessInfo.processInfo.processIdentifier,"sandboxPath":root.path,"processRestarted":resuming,"scope":"offline_production_parser_confirmation_ledger_stores_and_local_source_only","modelRequests":0,"tokens":0,"usageComplete":true,"automaticBusinessWrites":0,"realExternalWrites":0,"realNotifications":0,"fixtureModelResponse":true]
        if let bytes=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {print("AGENT_SCENARIO_RESULT: "+String(decoding:bytes,as:UTF8.self));fflush(stdout)}
        AgentScenarioAcceptance.didCheckpoint=checkpoint
        if !checkpoint {AssistantRuntime.finishEvaluationPreferences()}
        return passed && !checkpoint
    }
}
