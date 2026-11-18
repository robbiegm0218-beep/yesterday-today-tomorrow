import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct AssistantRunTests {
    private func store() throws -> AssistantRunStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("run-ledger-\(UUID())")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return .init(directory:url)
    }
    private let scope = AssistantRun.digest("selected-source-and-skills")
    @Test func pauseAndNewLedgerPreserveIdentityAndConsumedBudget() throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at:store.directory) }
        let ledger = AssistantRunLedger(store:store)
        let user = AssistantMessage(text:"核对目标，不自动写入",isUser:true)
        let id = try ledger.start(message:user,scope:scope)
        try ledger.event(.modelStarted,id:id)
        try ledger.finish(id,reply:nil,state:.paused,note:"暂停")
        let restored = AssistantRunLedger(store:store)
        #expect(restored.rows[0].id == id && restored.rows[0].modelRequests == 1 && !restored.rows[0].usageComplete)
        try restored.resume(id,messageID:UUID(),scope:scope)
        for _ in 0..<3 {
            try restored.event(.modelStarted,id:id)
            try restored.event(.modelFinished(.init(promptTokens:10,completionTokens:2,totalTokens:12)),id:id)
        }
        #expect(throws:(any Error).self) { try restored.event(.modelStarted,id:id) }
        #expect(restored.rows[0].modelRequests == 4 && restored.rows[0].tokens == 36)
        #expect(!restored.rows[0].canContinue)
    }
    @Test func crashedInFlightIsPausedWithoutNetworkOrBudgetReset() throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at:store.directory) }
        let ledger = AssistantRunLedger(store:store)
        let id = try ledger.start(message:.init(text:"原目标",isUser:true),scope:scope)
        try ledger.event(.modelStarted,id:id)
        let restored = AssistantRunLedger(store:store)
        let row = try #require(restored.rows.first)
        #expect(row.state == .paused && row.modelRequests == 1 && !row.inFlight && !row.usageComplete)
        #expect(row.elapsedMilliseconds >= 45_000 && row.elapsedMilliseconds < 90_000)
        #expect(row.canContinue && row.requestHash == AssistantRun.digest("原目标"))
    }
    @Test func pendingAndUnknownReceiptsCannotResumeAndClosedWritesAreNotReplayed() throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at:store.directory) }
        let ledger = AssistantRunLedger(store:store)
        let user = AssistantMessage(text:"创建本机任务",isUser:true)
        let id = try ledger.start(message:user,scope:scope)
        let action = PendingAssistantAction(summary:"创建",operation:.createTodo(title:"准备评审",dueAt:nil,importance:.normal,projectName:nil))
        var reply = AssistantMessage(text:"待确认",isUser:false,pendingActions:[action])
        try ledger.finish(id,reply:reply,state:.awaitingConfirmation,note:"待确认")
        #expect(throws:(any Error).self) { try ledger.resume(id,messageID:UUID(),scope:scope) }
        try ledger.applying(action.id)
        reply.pendingActions?[0].failureMessage = "提交结果尚未核验"
        try ledger.reconcile(messages:[reply])
        reply.pendingActions?[0].status = .dismissed
        try ledger.reconcile(messages:[reply])
        #expect(ledger.rows[0].state == .blocked && !ledger.rows[0].canContinue)
        reply.pendingActions?[0].status = .completed
        reply.pendingActions?[0].failureMessage = nil
        try ledger.reconcile(messages:[reply])
        #expect(ledger.rows[0].state == .ready && ledger.rows[0].canContinue)
        #expect(throws:(any Error).self) { try ledger.applying(action.id) }
        let regenerated = PendingAssistantAction(summary:"新卡片UUID",operation:.createTodo(title:"准备评审",dueAt:Date(),importance:.high,projectName:nil))
        #expect(ledger.filtered([regenerated],id:id).isEmpty)
        let distinct = PendingAssistantAction(summary:"另一任务",operation:.createTodo(title:"整理资料",dueAt:nil,importance:.normal,projectName:nil))
        #expect(ledger.filtered([distinct],id:id).count == 1)
    }
    @Test func cancelledProposalAlsoBlocksSemanticReplayAndOldPendingCannotEraseReceipt() throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at:store.directory) }
        let ledger = AssistantRunLedger(store:store)
        let id = try ledger.start(message:.init(text:"原目标",isUser:true),scope:scope)
        let action = PendingAssistantAction(summary:"完成",operation:.completeTodo(id:UUID()))
        var reply = AssistantMessage(text:"待确认",isUser:false,pendingActions:[action])
        try ledger.finish(id,reply:reply,state:.awaitingConfirmation,note:"待确认")
        let old = reply
        reply.pendingActions?[0].status = .dismissed
        try ledger.reconcile(messages:[reply]); try ledger.reconcile(messages:[old])
        #expect(ledger.rows[0].receipts[0].state == "dismissed" && ledger.filtered([action],id:id).isEmpty)
        #expect(throws:(any Error).self) { try ledger.applying(action.id) }
        var staleFailed = old; staleFailed.pendingActions?[0].failureMessage = "旧状态失败"
        try ledger.reconcile(messages:[staleFailed])
        #expect(ledger.rows[0].receipts[0].state == "dismissed")
    }
    @Test func changedScopeAndConcurrentStoreCannotBeOverwritten() throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at:store.directory) }
        let ledger = AssistantRunLedger(store:store)
        let id = try ledger.start(message:.init(text:"原目标",isUser:true),scope:scope)
        try ledger.finish(id,reply:nil,state:.paused,note:"暂停")
        #expect(throws:(any Error).self) { try ledger.resume(id,messageID:UUID(),scope:AssistantRun.digest("another-source")) }
        let other = AssistantRunLedger(store:store)
        try other.resume(id,messageID:UUID(),scope:scope)
        #expect(throws:(any Error).self) { try ledger.resume(id,messageID:UUID(),scope:scope) }
        #expect(try store.load() == other.rows)
    }
    @Test func writeInFlightIsAlreadyUnknownAndEndingDoesNotTurnItIntoCancellationProof() throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at:store.directory) }
        let ledger = AssistantRunLedger(store:store)
        let id = try ledger.start(message:.init(text:"原目标",isUser:true),scope:scope)
        let action = PendingAssistantAction(summary:"创建",operation:.createTodo(title:"评审",dueAt:nil,importance:.normal,projectName:nil))
        var reply = AssistantMessage(text:"待确认",isUser:false,pendingActions:[action])
        try ledger.finish(id,reply:reply,state:.awaitingConfirmation,note:"待确认")
        try ledger.applying(action.id)
        #expect(ledger.rows[0].receipts[0].state == "unverified")
        reply.pendingActions?[0].status = .dismissed
        try ledger.reconcile(messages:[reply])
        #expect(ledger.rows[0].state == .blocked && !ledger.rows[0].canContinue)
        try ledger.finish(id,reply:nil,state:.cancelled,note:"明确结束，不撤销源写入")
        #expect(throws:(any Error).self) { try ledger.applying(action.id) }
        reply.pendingActions?[0].status = .completed
        try ledger.reconcile(messages:[reply])
        #expect(ledger.rows[0].state == .cancelled && ledger.rows[0].receipts[0].state == "completed")
    }

    @Test func replaySignatureSurvivesExistingISO8601BackupPrecision() throws {
        let rule = MatterFollowup(reference:.personal(UUID()),title:"评审",waitingFor:"字段回复",criterion:"回复到达",nextStep:"核对字段",checkAt:Date(timeIntervalSince1970:1_800_000_000.98765),quote:"收到回复后核对",sourceMessageID:UUID())
        let original = PendingAssistantAction(summary:"跟进",operation:.createFollowup(rule:rule))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(PendingAssistantAction.self,from:encoder.encode(original))
        #expect(AssistantRunReplay.key(original.operation) == AssistantRunReplay.key(restored.operation))
    }

    @Test func corruptLedgerAndInvalidArchiveDoNotOverwriteOriginal() throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at:store.directory) }
        try Data("broken".utf8).write(to:store.url)
        try Data("broken backup".utf8).write(to:store.url.appendingPathExtension("backup"))
        let ledger = AssistantRunLedger(store:store)
        #expect(ledger.error != nil)
        #expect(throws:(any Error).self) { _ = try ledger.start(message:.init(text:"不能覆盖",isUser:true),scope:scope) }
        #expect(try Data(contentsOf:store.url) == Data("broken".utf8))
        var forged = AssistantRun(originalMessageID:UUID(),requestHash:scope,goal:"原目标",scopeHash:scope,messageIDs:[])
        forged.modelRequests = 5
        #expect(throws:(any Error).self) { try AssistantRunStore.validate([forged]) }
    }
}
