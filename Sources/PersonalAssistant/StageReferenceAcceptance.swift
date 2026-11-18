import Foundation

/// Every URL request in these isolated scenarios is intercepted locally.
final class StageReferenceFixtureProtocol:URLProtocol,@unchecked Sendable {
    private static let lock=NSLock()
    private static var target="",title="",bodies:[String]=[],replyText:String?
    static func configure(target:UUID,title:String,replyText:String? = nil) {lock.lock();defer{lock.unlock()};self.target=target.uuidString;self.title=title;self.replyText=replyText;bodies=[]}
    static var captured:[String] {lock.lock();defer{lock.unlock()};return bodies}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        var bytes=request.httpBody ?? Data()
        if bytes.isEmpty,let stream=request.httpBodyStream {stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0 {break};bytes.append(buffer,count:n)}}
        Self.lock.lock();Self.bodies.append(String(decoding:bytes,as:UTF8.self));let text=Self.replyText ?? ("离线响应夹具：已只读核对原创建事项ID "+Self.target+"，当前标题："+Self.title+"。没有修改、重新创建或完成事项。");Self.lock.unlock()
        let chunk:[String:Any]=["choices":[["index":0,"delta":["content":text],"finish_reason":"stop"]],"model":"offline-fixture","usage":["prompt_tokens":10,"completion_tokens":2,"total_tokens":12]]
        let json=(try? JSONSerialization.data(withJSONObject:chunk)) ?? Data()
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"text/event-stream"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(("data: "+String(decoding:json,as:UTF8.self)+"\n\ndata: [DONE]\n\n").utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor enum StageReferenceAcceptance {
    static var suppliedFixtureKey=0
    static func model()->AssistantModel {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StageReferenceFixtureProtocol.self]
        return AssistantModel(dailyDataSource:LocalOnlyDailyDataSource(),services:.init(chatClient:DeepSeekClient(session:URLSession(configuration:config)),apiKey:{suppliedFixtureKey+=1;return "offline-placeholder"}))
    }
    static func settle(_ app:AssistantModel) async throws {
        for _ in 0..<2000 {if !app.isSending && !app.isRefreshing{return};try await Task.sleep(for:.milliseconds(10))}
        app.cancelChatRequest();throw ProjectUpdateError.invalid("offline_reference_did_not_settle")
    }
    static func run(_ index:Int) async ->Bool {
        let root=LocalAssistantPaths.dataDirectory,resuming=CommandLine.arguments.contains(where:{$0.hasPrefix("--resume-sandbox=")})
        var checks:[String:Bool]=[:],failure:String?,checkpoint=false
        do {
            suppliedFixtureKey=0
            let p:UUID,s:UUID,target:UUID,action:UUID
            var app:AssistantModel
            if resuming {
                let saved=try JSONDecoder().decode([String:UUID].self,from:Data(contentsOf:root.appendingPathComponent("reference-fixture.json")))
                guard let parent=saved["parent"],let stage=saved["stage"],let id=saved["target"],let card=saved["action"] else {throw ProjectUpdateError.invalid("reference_fixture_missing")}
                p=parent;s=stage;target=id;action=card;app=model()
                var todos=app.personalTodos;let i=todos.firstIndex{$0.id==target}!;todos[i].title="重启后原ID的新标题";try CreatedTodoAcceptance.raw(todos)
                app=model();checks["reference_and_receipt_survive_actual_restart"]=app.assistantRuns.first{$0.id==p}?.stagePlan?.stages[1].createdTargetReference?.targetID==target
            } else {
                AssistantRuntime.preferences.set(false,forKey:"autoMemoryEnabled");AssistantRuntime.preferences.set([String](),forKey:"dingTalkSelectedProfiles");try LocalSkillStore.save(AssistantSkill.defaults)
                try LocalTodoStore.save([PersonalTodo(title:"同名创建事项",importance:.normal)])
                let l=AssistantRunLedger(),user=AssistantMessage(text:"分阶段创建，再只读核对原创建事项",isUser:true)
                p=try l.start(message:user,scope:CreatedTodoAcceptance.scope())
                let first=AssistantGoalStage(title:"创建",instruction:"创建个人待办「同名创建事项」",criterion:"确认创建并核对原ID",reviewMode:"confirmed_operation",dependencies:[],actionTool:"create_personal_todo")
                let second=AssistantGoalStage(title:"继续核对",instruction:"只读核对前阶段原创建事项的当前标题和完成状态，不修改事项",criterion:"取得原ID当前字段后人工核对",reviewMode:"read_review",dependencies:[0]);s=second.id
                let plan=AssistantGoalStagePlan(requestHash:l.rows[0].requestHash,stages:[first,second]),proposal=AssistantMessage(text:"离线阶段夹具",isUser:false,goalPlanDraft:plan)
                try l.finish(p,reply:proposal,state:.awaitingConfirmation,note:"方案夹具");try l.installStagePlan(plan,parentID:p,replyID:proposal.id,scope:CreatedTodoAcceptance.scope())
                let request=AssistantMessage(text:"创建个人待办「同名创建事项」",isUser:true),child=try l.start(message:request,scope:CreatedTodoAcceptance.scope(),parentID:p,stageIndex:0)
                let a=PendingAssistantAction(summary:"创建同名事项",operation:.createTodo(title:"同名创建事项",dueAt:nil,importance:.normal,projectName:nil));action=a.id
                let b=PendingAssistantAction(summary:"创建第二条同名事项",operation:.createTodo(title:"同名创建事项",dueAt:nil,importance:.normal,projectName:nil))
                let reply=AssistantMessage(text:"离线工具响应夹具",isUser:false,pendingActions:index==100 ? [a,b] : [a]);try l.finish(child,reply:reply,state:.awaitingConfirmation,note:"夹具卡片")
                LocalConversationStore.save([user,proposal,request,reply]);app=model();app.confirmPendingAction(messageID:reply.id,actionID:a.id)
                if index==100 {app.confirmPendingAction(messageID:reply.id,actionID:b.id)}
                try await settle(app);target=app.personalTodos.first{$0.sourceActionID==a.id}!.id
                app.reviewGoalStage(p,stageID:first.id,note:"已确认原创建并核对ID存在")
                guard app.assistantRuns.first(where:{$0.id==p})?.stagePlan?.stages[0].isComplete==true else {throw ProjectUpdateError.invalid("source_stage_not_reviewed")}
                StageReferenceFixtureProtocol.configure(target:target,title:"同名创建事项")
                app.draft="下一阶段用刚创建的那个";app.sendMessage()
                if index==100 {
                    checks["multiple_candidates_keep_draft_without_model_or_default"]=app.stageRevisionDraft==nil && !app.draft.isEmpty && StageReferenceFixtureProtocol.captured.isEmpty && suppliedFixtureKey==0
                    app.draft="";app.beginCreatedStageReference(p,stageID:s,actionID:b.id)
                    checks["explicit_card_selection_uses_second_exact_target"]=app.stageRevisionDraft?.createdTargetReference?.targetID==app.personalTodos.first{$0.sourceActionID==b.id}?.id
                    app.stageRevisionDraft=nil
                } else {
                    guard let preview=app.stageRevisionDraft else {throw ProjectUpdateError.invalid("natural_reference_preview_missing")}
                    checks["natural_request_opens_exact_preview_without_model"]=preview.createdTargetReference?.targetID==target && app.assistantRuns.count==2 && suppliedFixtureKey==0
                    if index==97 {app.stageRevisionDraft=nil;checks["cancel_preserves_original_composer"]=app.draft=="下一阶段用刚创建的那个";app.sendMessage()}
                    guard let change=app.stageRevisionDraft,app.applyStageRevision(change) else {throw ProjectUpdateError.invalid("reference_revision_not_saved")}
                    checks["adoption_is_explicit_and_does_not_start"]=app.draft.isEmpty && app.assistantRuns.count==2 && app.assistantRuns.first{$0.id==p}?.stagePlan?.stages[1].childRunID==nil
                }
                if index==98 {
                    try JSONEncoder().encode(["parent":p,"stage":s,"target":target,"action":action]).write(to:root.appendingPathComponent("reference-fixture.json"));try JSONEncoder().encode(checks).write(to:root.appendingPathComponent("reference-checks.json"));AssistantRuntime.preferences.synchronize();checkpoint=true
                }
            }
            if (index==97 || index==98) && !checkpoint {
                let todo=app.personalTodos.first{$0.id==target}!
                StageReferenceFixtureProtocol.configure(target:target,title:todo.title)
                let bytes=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))
                app.startGoalStage(p,index:1);try await settle(app)
                let stage=app.assistantRuns.first{$0.id==p}!.stagePlan!.stages[1]
                checks["request_carries_original_id_and_reference"]=StageReferenceFixtureProtocol.captured.count==1 && StageReferenceFixtureProtocol.captured[0].contains(target.uuidString) && StageReferenceFixtureProtocol.captured[0].contains("createdTargetReference")
                let unchanged=try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))==bytes
                checks["same_parent_fresh_source_no_write_or_auto_completion"]=app.assistantRuns.count==3 && stage.factCheck?.status=="satisfied" && stage.factCheck?.observedTitle==todo.title && !stage.isComplete && app.messages.last?.pendingActions==nil && unchanged
                checks["original_create_not_replayed"]=app.personalTodos.filter{$0.sourceActionID==action}.count==1 && app.assistantRuns.filter{$0.parentRunID==p}.count==2
            } else if index==99 {
                var todos=app.personalTodos.filter{$0.id != target};var replacement=PersonalTodo(title:"同名创建事项",importance:.normal,sourceActionID:action);replacement.isComplete=true;todos.append(replacement);try CreatedTodoAcceptance.raw(todos)
                app.startGoalStage(p,index:1)
                checks["missing_original_blocks_before_key_or_new_child"]=app.assistantRuns.count==2 && app.draft.isEmpty && suppliedFixtureKey==0 && app.runStatus != nil
                checks["does_not_retarget_or_recreate"]=app.assistantRuns.first{$0.id==p}?.stagePlan?.stages[1].createdTargetReference?.targetID==target && StageReferenceFixtureProtocol.captured.isEmpty
            }
            if resuming,let old=try? JSONDecoder().decode([String:Bool].self,from:Data(contentsOf:root.appendingPathComponent("reference-checks.json"))) {checks.merge(old){a,_ in a}}
        } catch {failure=error.localizedDescription}
        let passed=failure==nil && !checks.isEmpty && checks.values.allSatisfy{$0}
        let report:[String:Any]=["case_id":String(format:"INT-%02d",index),"outcome":checkpoint ? "restart_required" : passed ? "pass" : "fail","failure":failure ?? "none","checks":checks,"processID":ProcessInfo.processInfo.processIdentifier,"sandboxPath":root.path,"processRestarted":resuming,"scope":"offline cross-stage reference, intercepted request and fixture stream; no external API","modelRequests":0,"tokens":0,"usageComplete":true,"simulatedModelRequests":StageReferenceFixtureProtocol.captured.count,"fixtureModelResponse":true,"externalModelRequests":0,"automaticBusinessWrites":0,"realExternalWrites":0,"realNotifications":0]
        if let bytes=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {print("AGENT_SCENARIO_RESULT: "+String(decoding:bytes,as:UTF8.self));fflush(stdout)}
        AgentScenarioAcceptance.didCheckpoint=checkpoint;if !checkpoint {AssistantRuntime.finishEvaluationPreferences()};return passed && !checkpoint
    }
}
