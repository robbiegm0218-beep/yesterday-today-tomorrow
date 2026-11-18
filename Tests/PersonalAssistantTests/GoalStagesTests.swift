import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct GoalStagesTests {
    private let scope=AssistantRun.digest("original-selected-scope")
    private func row(_ index:Int,mode:String="read_review",deps:[Int]?=nil) -> [String:Any] {
        ["title":"阶段\(index+1)","instruction":"只读核对准备接口评审，说明依据和下一步","criterion":"得到可核对的当前状态和依据","review_mode":mode,"action_tool":mode=="read_review" ? "none" : "create_personal_todo","depends_on":deps ?? (index==0 ? [] : [0])]
    }
    private func draft(rows:[[String:Any]]?=nil,request:String="请分阶段推进接口评审，先只给阶段方案") throws -> AssistantGoalStagePlan {
        let args=try JSONSerialization.data(withJSONObject:["stages":rows ?? [row(0),row(1)]])
        return try #require(GoalStagePlanning.propose(.init(id:"draft",function:.init(name:GoalStagePlanning.name,arguments:String(decoding:args,as:UTF8.self))),request:request).goalPlanDraft)
    }
    private func fixture(plan:AssistantGoalStagePlan?=nil) throws -> (AssistantRunStore,AssistantRunLedger,UUID,AssistantGoalStagePlan) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("stage-tests-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let store=AssistantRunStore(directory:directory),ledger=AssistantRunLedger(store:store)
        let user=AssistantMessage(text:"请分阶段推进接口评审，先只给阶段方案",isUser:true)
        let id=try ledger.start(message:user,scope:scope);let plan=try plan ?? draft()
        let reply=AssistantMessage(text:"阶段方案",isUser:false,goalPlanDraft:plan)
        try ledger.finish(id,reply:reply,state:.awaitingConfirmation,note:"待采用")
        try ledger.installStagePlan(plan,parentID:id,replyID:reply.id,scope:scope)
        return (store,ledger,id,plan)
    }
    private func finishRead(_ ledger:AssistantRunLedger,_ id:UUID) throws {
        try ledger.event(.modelStarted,id:id);try ledger.event(.modelFinished(.init(promptTokens:10,completionTokens:2,totalTokens:12)),id:id)
        try ledger.finish(id,reply:.init(text:"已核对当前状态",isUser:false),state:.responded,note:"回复不是自动完成")
    }
    @Test func draftRejectsForwardCyclesMalformedIndexesAndMissingCriteria() throws {
        var wrongIndex=row(1);wrongIndex["depends_on"]=[true]
        for rows in [[row(0,deps:[0]),row(1)],[row(0,deps:[1]),row(1)],[row(0),wrongIndex],[row(0,mode:"auto_complete"),row(1)]] {
            let call=DeepSeekToolCall(id:"bad",function:.init(name:GoalStagePlanning.name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:["stages":rows]),as:UTF8.self)))
            #expect(GoalStagePlanning.propose(call,request:"请分阶段推进目标").goalPlanDraft==nil)
        }
        var empty=row(0);empty["criterion"]=" "
        let call=DeepSeekToolCall(id:"bad",function:.init(name:GoalStagePlanning.name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:["stages":[empty,row(1)]]),as:UTF8.self)))
        #expect(GoalStagePlanning.propose(call,request:"请分阶段推进目标").goalPlanDraft==nil)
    }
    @Test func explicitPlanningIntentOnlyAndLongOriginalGoalIsNotSilentlyTruncated() throws {
        #expect(!GoalStagePlanning.requested("解释分阶段规划是什么意思"))
        #expect(!GoalStagePlanning.requested("不要分阶段，只读查状态"))
        let args=try JSONSerialization.data(withJSONObject:["stages":[row(0),row(1)]])
        let call=DeepSeekToolCall(id:"x",function:.init(name:GoalStagePlanning.name,arguments:String(decoding:args,as:UTF8.self)))
        #expect(GoalStagePlanning.propose(call,request:"请分阶段"+String(repeating:"长",count:2100)).goalPlanDraft==nil)
        #expect(GoalStagePlanning.propose(call,request:"你好").goalPlanDraft==nil)
    }
    @Test func adoptionPreservesOriginalIdentityAndDoesNotStartAnyStage() throws {
        let (store,ledger,id,plan)=try fixture();defer {try? FileManager.default.removeItem(at:store.directory)}
        #expect(ledger.rows.count==1 && ledger.rows[0].id==id && ledger.rows[0].stagePlan?.id==plan.id)
        #expect(ledger.rows[0].stagePlan?.stages.allSatisfy{$0.childRunID==nil}==true && !ledger.rows[0].canContinue)
        let replyID=try #require(ledger.rows[0].replyIDs.first)
        try ledger.installStagePlan(plan,parentID:id,replyID:replyID,scope:scope)
        #expect(ledger.rows.count==1)
        #expect(throws:(any Error).self) {try ledger.installStagePlan(plan,parentID:id,replyID:replyID,scope:AssistantRun.digest("other"))}
    }
    @Test func dependenciesAndSingleActiveStageAreProgrammaticGuards() throws {
        let (store,ledger,id,_)=try fixture();defer {try? FileManager.default.removeItem(at:store.directory)}
        #expect(throws:(any Error).self) {try ledger.start(message:.init(text:"越过依赖",isUser:true),scope:scope,parentID:id,stageIndex:1)}
        let child=try ledger.start(message:.init(text:"阶段1",isUser:true),scope:scope,parentID:id,stageIndex:0)
        #expect(ledger.rows.count==2 && ledger.rows.last?.parentRunID==id)
        #expect(throws:(any Error).self) {try ledger.start(message:.init(text:"重复启动",isUser:true),scope:scope,parentID:id,stageIndex:0)}
        #expect(throws:(any Error).self) {try ledger.reviewStage(parentID:id,stageID:ledger.rows[0].stagePlan!.stages[0].id,note:"想跳过",scope:scope)}
        #expect(ledger.rows.last?.id==child && ledger.rows.last?.modelRequests==0)
    }
    @Test func answerNeverCompletesStageUntilUserProvidesReviewAndDependenciesStayBlocked() throws {
        let (store,ledger,id,_)=try fixture();defer {try? FileManager.default.removeItem(at:store.directory)}
        let child=try ledger.start(message:.init(text:"阶段1",isUser:true),scope:scope,parentID:id,stageIndex:0);try finishRead(ledger,child)
        let stage=ledger.rows[0].stagePlan!.stages[0]
        #expect(!stage.isComplete)
        #expect(throws:(any Error).self) {try ledger.reviewStage(parentID:id,stageID:stage.id,note:" ",scope:scope)}
        #expect(throws:(any Error).self) {try ledger.start(message:.init(text:"提前阶段2",isUser:true),scope:scope,parentID:id,stageIndex:1)}
        try ledger.reviewStage(parentID:id,stageID:stage.id,note:"已核对当前依据，满足阶段条件",scope:scope)
        #expect(ledger.rows.count==2 && ledger.rows[0].stagePlan!.stages[0].isComplete && ledger.rows[0].stagePlan!.stages[1].childRunID==nil)
        let second=try ledger.start(message:.init(text:"阶段2",isUser:true),scope:scope,parentID:id,stageIndex:1)
        #expect(second != child && ledger.rows.last?.modelRequests==0 && ledger.rows.first{$0.id==child}?.modelRequests==1)
        #expect(throws:(any Error).self) {try ledger.resume(child,messageID:UUID(),scope:scope)}
    }
    @Test func confirmedOperationRequiresActualClosedReceiptAndDoesNotMarkTaskCompleted() throws {
        let plan=try draft(rows:[row(0,mode:"confirmed_operation"),row(1)])
        let (store,ledger,id,_)=try fixture(plan:plan);defer {try? FileManager.default.removeItem(at:store.directory)}
        let child=try ledger.start(message:.init(text:"创建任务需确认",isUser:true),scope:scope,parentID:id,stageIndex:0)
        try finishRead(ledger,child);let stageID=plan.stages[0].id
        #expect(throws:(any Error).self) {try ledger.reviewStage(parentID:id,stageID:stageID,note:"文字声称创建了",scope:scope)}
        var action=PendingAssistantAction(summary:"创建评审任务",operation:.createTodo(title:"评审任务",dueAt:nil,importance:.normal,projectName:nil))
        var reply=AssistantMessage(text:"待确认",isUser:false,pendingActions:[action])
        try ledger.finish(child,reply:reply,state:.awaitingConfirmation,note:"待确认")
        #expect(throws:(any Error).self) {try ledger.reviewStage(parentID:id,stageID:stageID,note:"跳过卡片",scope:scope)}
        try ledger.applying(action.id)
        #expect(throws:(any Error).self) {try ledger.reviewStage(parentID:id,stageID:stageID,note:"结果未知",scope:scope)}
        let todo=PersonalTodo(title:"评审任务",importance:.normal,sourceActionID:action.id)
        try JSONEncoder().encode([todo]).write(to:store.directory.appendingPathComponent("personal-todos.json"))
        action.status = .completed;reply.pendingActions=[action];try ledger.reconcile(messages:[reply],directory:store.directory)
        try ledger.reviewStage(parentID:id,stageID:stageID,note:"已核对创建回执，当前条件是已创建而非任务完成",scope:scope,directory:store.directory)
        #expect(ledger.rows[0].stagePlan!.stages[0].isComplete)
    }
    @Test func restartKeepsStageIdentityBudgetAndRequiresFreshContinuation() throws {
        let (store,ledger,id,_)=try fixture();defer {try? FileManager.default.removeItem(at:store.directory)}
        let child=try ledger.start(message:.init(text:"阶段1",isUser:true),scope:scope,parentID:id,stageIndex:0)
        try ledger.event(.modelStarted,id:child)
        let recovered=AssistantRunLedger(store:store)
        #expect(recovered.rows.first{$0.id==child}?.state == .paused && recovered.rows.first{$0.id==child}?.modelRequests==1)
        #expect(recovered.rows.first{$0.id==id}?.stagePlan?.stages[0].childRunID==child)
        try recovered.resume(child,messageID:UUID(),scope:scope)
        #expect(recovered.rows.first{$0.id==child}?.budget.maxModelRounds==3)
        #expect(throws:(any Error).self) {try recovered.start(message:.init(text:"重置预算",isUser:true),scope:scope,parentID:id,stageIndex:0)}
    }
    @Test func scopeChangeBlocksStartResumeAndHumanReview() throws {
        let (store,ledger,id,_)=try fixture();defer {try? FileManager.default.removeItem(at:store.directory)}
        let changed=AssistantRun.digest("another-scope")
        #expect(throws:(any Error).self) {try ledger.start(message:.init(text:"阶段1",isUser:true),scope:changed,parentID:id,stageIndex:0)}
        let child=try ledger.start(message:.init(text:"阶段1",isUser:true),scope:scope,parentID:id,stageIndex:0);try finishRead(ledger,child)
        #expect(throws:(any Error).self) {try ledger.resume(child,messageID:UUID(),scope:changed)}
        #expect(throws:(any Error).self) {try ledger.reviewStage(parentID:id,stageID:ledger.rows[0].stagePlan!.stages[0].id,note:"确认",scope:changed)}
    }
    @Test func endingPlanCancelsFamilyAndCannotReviveOrApplyOldStageCard() throws {
        let (store,ledger,id,_)=try fixture();defer {try? FileManager.default.removeItem(at:store.directory)}
        let child=try ledger.start(message:.init(text:"阶段1",isUser:true),scope:scope,parentID:id,stageIndex:0)
        let action=PendingAssistantAction(summary:"创建",operation:.createTodo(title:"测试",dueAt:nil,importance:.normal,projectName:nil))
        try ledger.finish(child,reply:.init(text:"卡片",isUser:false,pendingActions:[action]),state:.awaitingConfirmation,note:"待确认")
        try ledger.endStagePlan(id)
        #expect(ledger.rows.allSatisfy{$0.state == .cancelled})
        #expect(throws:(any Error).self) {try ledger.applying(action.id)}
        #expect(throws:(any Error).self) {try ledger.resume(child,messageID:UUID(),scope:scope)}
        #expect(throws:(any Error).self) {try ledger.explicitRetry(id)}
    }
    @Test func graphDamageIsRejectedAndLegacyRunStillDecodes() throws {
        let (store,ledger,id,_)=try fixture();defer {try? FileManager.default.removeItem(at:store.directory)}
        _=try ledger.start(message:.init(text:"阶段1",isUser:true),scope:scope,parentID:id,stageIndex:0)
        #expect(throws:(any Error).self) {try AssistantRunStore.validate([ledger.rows[0]])}
        var child=ledger.rows[1];child.parentStageID=UUID()
        #expect(throws:(any Error).self) {try AssistantRunStore.validate([ledger.rows[0],child])}
        let legacy=AssistantRun(originalMessageID:UUID(),requestHash:scope,goal:"旧目标",scopeHash:scope,messageIDs:[])
        let restored=try JSONDecoder().decode(AssistantRun.self,from:JSONEncoder().encode(legacy))
        #expect(restored.stagePlan==nil && restored.parentRunID==nil)
    }
    @Test func planningTransportDoesNotExposeBusinessWritesAndReturnsDraftOnly() async throws {
        let rows=[row(0),row(1)]
        StageToolProtocol.toolArguments=String(decoding:try JSONSerialization.data(withJSONObject:["stages":rows]),as:UTF8.self)
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StageToolProtocol.self]
        let session=URLSession(configuration:config);defer {session.invalidateAndCancel()}
        let request="请分阶段推进目标，之后需要创建任务，先只规划"
        let result=try await DeepSeekClient(session:session).assistantTurn(to:[.init(role:"user",content:request)],enabledSkillIDs:["todo-priority"],apiKey:"unused",readContext:.init(goalPlanningRequest:request))
        #expect(result.goalPlanDraft?.stages.count==2 && result.toolCalls.isEmpty && result.modelRounds==1)
        #expect(!StageToolProtocol.tools.contains("create_personal_todo") && StageToolProtocol.tools.contains(GoalStagePlanning.name))
    }
    @Test func readReviewStageCannotExposeWriteToolsEvenWhenInstructionMentionsCreation() async throws {
        StageToolProtocol.toolArguments=nil
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StageToolProtocol.self]
        let session=URLSession(configuration:config);defer {session.invalidateAndCancel()}
        let result=try await DeepSeekClient(session:session).assistantTurn(to:[.init(role:"user",content:"创建个人待办")],enabledSkillIDs:["todo-priority"],apiKey:"unused",readContext:.init(goalStageReadOnly:true))
        #expect(result.toolCalls.isEmpty && !StageToolProtocol.tools.contains("create_personal_todo"))
    }
    @Test func confirmedTypedStageExposesOnlyItsOneEnabledOperation() async throws {
        StageToolProtocol.toolArguments=nil
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StageToolProtocol.self]
        let session=URLSession(configuration:config);defer {session.invalidateAndCancel()}
        _=try await DeepSeekClient(session:session).assistantTurn(to:[.init(role:"user",content:"在用户确认后创建个人待办，不修改其他事项")],enabledSkillIDs:["todo-priority"],apiKey:"unused",readContext:.init(goalStageActionTool:"create_personal_todo"))
        #expect(StageToolProtocol.tools.contains("create_personal_todo"))
        #expect(!StageToolProtocol.tools.contains("update_personal_todo") && !StageToolProtocol.tools.contains("mutate_dingtalk_todo"))
    }
    @Test func archiveRoundTripIncludesConfirmedGraphAndDraftWithoutChangingIdentity() throws {
        let (store,ledger,id,plan)=try fixture();defer {try? FileManager.default.removeItem(at:store.directory)}
        let child=try ledger.start(message:.init(text:"阶段1",isUser:true),scope:scope,parentID:id,stageIndex:0);try finishRead(ledger,child)
        try ledger.reviewStage(parentID:id,stageID:plan.stages[0].id,note:"已核对条件",scope:scope)
        let archive=LocalAssistantDataExport(exportedAt:Date(),profile:.init(name:"测试",personality:"测试",tone:"简洁",address:"你",avatar:"warm",relationshipPoints:0,automaticMemoryEnabled:false),conversation:[.init(text:"方案",isUser:false,goalPlanDraft:plan)],memories:[],projects:[],personalTodos:[],skills:[],knowledgeBases:[],assistantRuns:ledger.rows)
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let restored=try LocalAssistantDataManager.decodeImport(encoder.encode(archive))
        #expect(restored.assistantRuns?.first?.stagePlan?.stages[0].childRunID==child && restored.assistantRuns?.first?.stagePlan?.stages[0].isComplete==true)
        #expect(restored.conversation[0].goalPlanDraft?.id==plan.id)
    }
    @Test func redundantKnownSourceOnTitleOrNoInputIsCanonicalized() throws {
        var first=row(0,mode:"confirmed_operation");first["required_input"]="todo_title";first["input_target_kind"]="personal"
        var second=row(1);second["required_input"]="none";second["input_target_kind"]="personal"
        let result=try draft(rows:[first,second])
        #expect(result.stages[0].requiredInput=="todo_title" && result.stages[0].inputTargetKind==nil)
        #expect(result.stages[1].requiredInput==nil && result.stages[1].inputTargetKind==nil)
        first["input_target_kind"]="unknown"
        let call=DeepSeekToolCall(id:"bad",function:.init(name:GoalStagePlanning.name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:["stages":[first,second]]),as:UTF8.self)))
        #expect(GoalStagePlanning.propose(call,request:"请分阶段推进目标").goalPlanDraft==nil)
    }
}

private final class StageToolProtocol: URLProtocol, @unchecked Sendable {
    static var toolArguments:String?;static var tools:[String]=[]
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let requestData=request.httpBody ?? request.httpBodyStream.map { stream -> Data in stream.open();defer{stream.close()};var bytes=Data();var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0 {break};bytes.append(buffer,count:n)};return bytes } ?? Data()
        if let root=(try? JSONSerialization.jsonObject(with:requestData)) as? [String:Any] {Self.tools=(root["tools"] as? [[String:Any]] ?? []).compactMap { ($0["function"] as? [String:Any])?["name"] as? String }}
        var message:[String:Any]=["role":"assistant","content":"只给结果，不执行"]
        if let args=Self.toolArguments {message["tool_calls"]=[["id":"stages","type":"function","function":["name":GoalStagePlanning.name,"arguments":args]]]}
        let body:[String:Any]=["choices":[["message":message]],"usage":["prompt_tokens":10,"completion_tokens":5,"total_tokens":15]]
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }


}
