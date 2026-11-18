import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct SemanticStageRevisionTests {
    let scope = AssistantRun.digest("revision-scope")
    func fixture(start: Bool = true) throws -> (AssistantRunStore, AssistantRunLedger, UUID, UUID?) { try StageRevisionTests().fixture(start: start) }
    func operation(_ instruction: String = "先列出已有信息与缺口，再以最少必要步骤准备原待办，沿原完成条件核对", reason: String = "先补齐缺口，减少反复修改") -> DeepSeekToolCall {
        let bytes = try! JSONSerialization.data(withJSONObject: ["instruction": instruction, "reason": reason])
        return .init(id: "alternative", function: .init(name: SemanticStageRevision.name, arguments: String(decoding: bytes, as: UTF8.self)))
    }
    func preview(_ ledger: AssistantRunLedger, _ parentID: UUID) -> SemanticStageRevisionPreview {
        let parent = ledger.rows.first { $0.id == parentID }!, stage = parent.stagePlan!.stages[0]
        return .init(parentID: parentID, stageID: stage.id, parentRevision: parent.revision, childRevision: ledger.rows.first { $0.id == stage.childRunID }?.revision, scopeHash: scope, original: stage, instruction: "先准备原操作所需内容，再按原完成条件核对", reason: "减少反复查询")
    }
    @Test func ordinaryLanguageRoutesBeforeMissingInputAndRejectsOtherIntents() {
        for text in ["目标不变，换一种方案", "这个阶段换个思路，先用现有资料", "能不能换个方案？", "重新规划本阶段"] { #expect(SemanticStageRevision.requested(text)) }
        for text in ["不用换个方案", "换个话题", "如果换个方案会怎样", "换一种方案是什么意思", "换个目标，再换个方案", "这个阶段的标题改成银杏", "继续"] { #expect(!SemanticStageRevision.requested(text)) }
    }
    @Test func parsingAcceptsOnlyOneBoundedAlternativeTool() throws {
        let (store,l,p,_) = try fixture(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let stage = l.rows.first { $0.id == p }!.stagePlan!.stages[0]
        #expect(try SemanticStageRevision.parse([operation()], original: stage).0.contains("缺口"))
        for calls in [[], [operation(),operation()], [operation(stage.instruction)], [operation("", reason:"原因")], [operation(String(repeating:"长",count:601))], [operation(reason:"")], [.init(id:"bad",function:.init(name:"complete_personal_todo",arguments:"{}"))], [.init(id:"bad",function:.init(name:SemanticStageRevision.name,arguments:"{\"instruction\":\"新做法\",\"reason\":\"原因\",\"criterion\":\"放宽条件\"}"))]] {
            #expect(throws: (any Error).self) { try SemanticStageRevision.parse(calls, original: stage) }
        }
    }
    @Test func latestStructuredRunSelectsOriginalStageWithoutStartingAnother() throws {
        let (store,l,p,c) = try fixture(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let reply = AssistantMessage(text:"本阶段待核对",isUser:false)
        try l.finish(c!,reply:reply,state:.responded,note:"待核对")
        let (parent,stage) = try SemanticStageRevision.target(messages:[reply],rows:l.rows,scope:scope)
        #expect(parent.id == p && stage.childRunID == c && l.rows.count == 2)
        #expect(throws:(any Error).self) { try SemanticStageRevision.target(messages:[.init(text:"无关回复",isUser:false)],rows:l.rows,scope:scope) }
        var old = reply; old.time = Date(timeIntervalSinceNow:-86_401)
        #expect(throws:(any Error).self) { try SemanticStageRevision.target(messages:[old],rows:l.rows,scope:scope) }
    }
    @Test func previewSurvivesSerializationAndCancelDoesNotTouchPlan() throws {
        let (store,l,p,_) = try fixture(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let before = l.rows, v = preview(l,p)
        let message = AssistantMessage(text:"核对方案",isUser:false,stageRevisionPreview:v)
        let decoded = try JSONDecoder().decode(AssistantMessage.self,from:JSONEncoder().encode(message))
        #expect(decoded.stageRevisionPreview == v)
        let draft = try SemanticStageRevision.draft(decoded.stageRevisionPreview!,rows:l.rows,scope:scope)
        #expect(draft.semanticPreviewID == v.id && draft.criterion == v.original.criterion && draft.original.dependencies == v.original.dependencies)
        #expect(l.rows == before)
        var canceled = v; canceled.status = "dismissed"
        #expect(throws:(any Error).self) { try SemanticStageRevision.draft(canceled,rows:l.rows,scope:scope) }
        #expect(l.rows == before)
    }
    @Test func interpretationChargesExistingBudgetWhileRetainingQuestionAndPendingReceipt() throws {
        let (store,l,p,c) = try fixture(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let child = c!, q = AssistantStageQuestion(runID:child,purpose:"missing_details",question:"原标题是什么",choices:[])
        let action = PendingAssistantAction(summary:"原卡片",operation:.createTodo(title:"原标题",dueAt:nil,importance:.normal,projectName:nil))
        try l.finish(child,reply:.init(text:"原问题",isUser:false,pendingActions:[action],stageQuestion:q),state:.awaitingConfirmation,note:"原问题")
        let before = l.rows,stage = before[0].stagePlan!.stages[0]
        let owner = try l.beginStageInterpretation(parentID:p,stageID:stage.id,messageID:UUID(),scope:scope)
        #expect(owner.id == child && owner.state == .awaitingConfirmation)
        try l.event(.modelStarted,id:child); try l.event(.modelFinished(.init(promptTokens:8,completionTokens:4,totalTokens:12)),id:child)
        try l.finish(child,reply:nil,state:owner.state,note:"待核对预览")
        #expect(l.rows[0] == before[0] && l.rows.count == 2)
        #expect(l.rows[1].modelRequests == before[1].modelRequests + 1 && l.rows[1].tokens == before[1].tokens + 12)
        #expect(l.rows[1].receipts == before[1].receipts && l.rows[1].stageQuestion == q && l.rows[1].state == .awaitingConfirmation)
    }
    @Test func unstartedStageUsesParentBudgetAndNeverCreatesChild() throws {
        let (store,l,p,_) = try fixture(start:false); defer { try? FileManager.default.removeItem(at: store.directory) }
        let stage = l.rows[0].stagePlan!.stages[0], owner = try l.beginStageInterpretation(parentID:p,stageID:stage.id,messageID:UUID(),scope:scope)
        #expect(owner.id == p && l.rows.count == 1 && l.rows[0].stagePlan!.stages[0].childRunID == nil)
        try l.event(.modelStarted,id:p);try l.finish(p,reply:nil,state:owner.state,note:"中止")
        #expect(l.rows[0].usageComplete == false && l.rows[0].modelRequests == 1)
    }
    @Test func exhaustedBudgetScopeAndExecutedReceiptsRefuseWithoutMutation() throws {
        for kind in ["budget","scope","completed","unverified"] {
            let (store,l,p,_) = try fixture(); defer { try? FileManager.default.removeItem(at: store.directory) }
            try l.stageTransaction { rows in
                if kind == "budget" {rows[1].modelRequests = 4}
                if ["completed","unverified"].contains(kind) {rows[1].receipts=[.init(actionID:UUID(),messageID:UUID(),key:self.scope,summary:"原结果",state:kind)]}
            }
            let before=l.rows,stage=before[0].stagePlan!.stages[0]
            #expect(throws:(any Error).self) { try l.beginStageInterpretation(parentID:p,stageID:stage.id,messageID:UUID(),scope:kind == "scope" ? "other" : scope) }
            #expect(l.rows == before)
        }
    }
    @Test func staleChildParentScopeOrExpiredPreviewCannotApply() throws {
        let (store,l,p,c) = try fixture(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let v = preview(l,p)
        #expect(throws:(any Error).self) { try SemanticStageRevision.draft(v,rows:l.rows,scope:"other") }
        #expect(throws:(any Error).self) { try SemanticStageRevision.draft(v,rows:l.rows,scope:scope,now:Date(timeIntervalSinceNow:86_401)) }
        try l.finish(c!,reply:nil,state:.paused,note:"有新进展")
        #expect(throws:(any Error).self) { try SemanticStageRevision.draft(v,rows:l.rows,scope:scope) }
    }
    @Test func confirmedAlternativeKeepsCriterionDependenciesIdentityAndBudget() throws {
        let (store,l,p,c) = try fixture(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let v=preview(l,p), before=l.rows, d=try SemanticStageRevision.draft(v,rows:l.rows,scope:scope)
        try l.reviseStage(d,scope:scope)
        let after=l.rows[0].stagePlan!.stages[0]
        #expect(after.id == v.stageID && after.childRunID == c && after.dependencies == v.original.dependencies && after.criterion == v.original.criterion && after.actionTool == v.original.actionTool && after.requiredInput == v.original.requiredInput)
        #expect(l.rows[0].requestHash == before[0].requestHash && l.rows[0].goal == before[0].goal)
        #expect(l.rows[1].budget.maxModelRounds == before[1].budget.maxModelRounds && l.rows[1].tokens == before[1].tokens && l.rows[1].stageRevisionPending == true)
    }
    @Test func modelClientOffersExactlyOnePreviewToolAndChargesOneRequest() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StageAlternativeFixtureProtocol.self]
        let client=DeepSeekClient(session:URLSession(configuration:config));let (store,l,p,c)=try fixture();defer{try? FileManager.default.removeItem(at:store.directory)}
        let stage=l.rows[0].stagePlan!.stages[0];StageAlternativeFixtureProtocol.configure(operation())
        let owner=try l.beginStageInterpretation(parentID:p,stageID:stage.id,messageID:UUID(),scope:scope)
        let value=try await client.stageAlternative(parentGoal:l.rows[0].goal,stage:stage,request:"目标不变，换一种方案",apiKey:"offline",budget:owner.budget,onCheckpoint:{try l.event($0,id:c!)})
        try l.finish(c!,reply:nil,state:owner.state,note:"生成预览")
        #expect(value.0.contains("缺口") && StageAlternativeFixtureProtocol.captured.count == 1)
        let body=try #require(StageAlternativeFixtureProtocol.captured.first).data(using:.utf8)!, json=try #require(JSONSerialization.jsonObject(with:body) as? [String:Any])
        let tools=try #require(json["tools"] as? [[String:Any]])
        #expect(json["max_tokens"] as? Int == 2048)
        #expect(tools.count == 1 && (tools[0]["function"] as? [String:Any])?["name"] as? String == SemanticStageRevision.name)
        #expect(l.rows[1].modelRequests == owner.modelRequests+1 && l.rows[1].receipts == owner.receipts)
    }
}
