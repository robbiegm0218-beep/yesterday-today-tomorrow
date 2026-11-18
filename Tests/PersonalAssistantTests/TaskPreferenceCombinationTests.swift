import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct TaskPreferenceCombinationTests {
    let scope = AssistantRun.digest("preference-combination")
    func fixture() throws -> (AssistantRunStore, AssistantRunLedger, UUID, AssistantMessage) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preference-combination-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AssistantRunStore(directory: dir), ledger = AssistantRunLedger(store: store)
        let parent = try ledger.start(message: .init(text: "分阶段准备评审", isUser: true), scope: scope)
        let plan = AssistantGoalStagePlan(requestHash: ledger.rows[0].requestHash, stages: [
            .init(title: "核对", instruction: "先检查材料", criterion: "人工核对材料", reviewMode: "read_review", dependencies: []),
            .init(title: "整理", instruction: "整理结论", criterion: "人工核对结论", reviewMode: "read_review", dependencies: [0])])
        let preview = AssistantMessage(text: "待采用", isUser: false, goalPlanDraft: plan)
        try ledger.finish(parent, reply: preview, state: .awaitingConfirmation, note: "待采用")
        try ledger.installStagePlan(plan, parentID: parent, replyID: preview.id, scope: scope)
        var declaration = AssistantMessage(text: "本任务内详细回复，不要记住", isUser: true)
        let child = try ledger.start(message: declaration, scope: scope, parentID: parent, stageIndex: 0)
        declaration.assistantRunID = child
        try ledger.event(.modelStarted, id: child)
        try ledger.event(.modelFinished(.init(promptTokens: 10, completionTokens: 2, totalTokens: 12)), id: child)
        try ledger.finish(child, reply: .init(text: "原结果", isUser: false), state: .responded, note: "待核对")
        return (store, ledger, parent, declaration)
    }
    func revision(_ ledger: AssistantRunLedger, _ parent: UUID) -> StageRevisionDraft {
        let row = ledger.rows.first { $0.id == parent }!
        var draft = StageRevisionDraft(parent: row, stage: row.stagePlan!.stages[0], child: ledger.rows.first { $0.parentRunID == parent })
        draft.instruction = "先列材料缺口，再核对优先项"; draft.reason = "目标不变，调整做法"
        return draft
    }
    @Test func revisionPreservesPreferenceAndBudgetUntilActualStageReview() throws {
        let (store, ledger, parent, message) = try fixture(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let child = message.assistantRunID!, before = ledger.rows.first { $0.id == child }!
        let draft = revision(ledger, parent)
        try ledger.reviseStage(draft, scope: scope)
        let after = ledger.rows.first { $0.id == child }!
        #expect(TaskPreferencePolicy.state(messages: [message], runs: ledger.rows, currentRunID: child, scopeHash: scope).active)
        #expect(after.modelRequests == before.modelRequests && after.tokens == before.tokens && after.receipts == before.receipts)
        #expect(throws: (any Error).self) { try ledger.reviewStage(parentID: parent, stageID: draft.stageID, note: "不能用旧结果", scope: scope) }
        var next = AssistantMessage(text: "按修订方案继续核对", isUser: true); next.assistantRunID = child
        try ledger.resume(child, messageID: next.id, scope: scope)
        try ledger.finish(child, reply: .init(text: "新结果", isUser: false), state: .responded, note: "已核对新做法")
        try ledger.reviewStage(parentID: parent, stageID: draft.stageID, note: "已按新结果核对材料", scope: scope)
        let restored = AssistantRunLedger(store: store)
        #expect(!TaskPreferencePolicy.state(messages: [message,next], runs: restored.rows, currentRunID: child, scopeHash: scope).active)
    }
    @Test func endedRevisedStageCannotResumeAfterScopeRestorationOrReload() throws {
        let (store, ledger, parent, message) = try fixture(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let child = message.assistantRunID!, draft = revision(ledger, parent), changed = AssistantRun.digest("changed")
        let before = ledger.rows
        #expect(throws: (any Error).self) { try ledger.reviseStage(draft, scope: changed) }
        #expect(ledger.rows == before)
        try ledger.reviseStage(draft, scope: scope)
        try ledger.endStagePlan(parent)
        let restored = AssistantRunLedger(store: store), ended = restored.rows
        #expect(throws: (any Error).self) { try restored.resume(child, messageID: UUID(), scope: scope) }
        #expect(!TaskPreferencePolicy.state(messages: [message], runs: restored.rows, currentRunID: child, scopeHash: changed).active)
        #expect(!TaskPreferencePolicy.state(messages: [message], runs: restored.rows, currentRunID: child, scopeHash: scope).active)
        #expect(restored.rows == ended)
    }
    @Test func failedScopeResumeDoesNotDestroyLiveBindingOrSpendBudget() throws {
        let (store, ledger, _, message) = try fixture(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let child = message.assistantRunID!, before = ledger.rows
        #expect(throws: (any Error).self) { try ledger.resume(child, messageID: UUID(), scope: AssistantRun.digest("changed")) }
        #expect(ledger.rows == before)
        let restored = AssistantRunLedger(store: store)
        #expect(TaskPreferencePolicy.state(messages: [message], runs: restored.rows, currentRunID: child, scopeHash: scope).active)
        #expect(restored.rows == before)
    }
}
