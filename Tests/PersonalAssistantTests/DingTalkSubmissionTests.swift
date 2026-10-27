import Foundation
import Testing
@testable import PersonalAssistant

extension CoreWorkflowTests {
    @Test func repeatedConfirmationCreatesOnceAndVerifiesTheSameTask() throws {
        let fixture = SubmissionFixture()
        let (service, root) = try service(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = draft(fixture.profile)
        for _ in 0..<2 {
            let receipt = try service.submitConfirmed(draft, title: "验收事项", dueAt: nil, priority: 20, selectedIDs: [fixture.profile.id])
            #expect(receipt.taskID == "remote-task")
            #expect(receipt.state == .verified)
        }
        #expect(fixture.creations == 1)
        #expect(fixture.detailReads == 2)
        #expect(fixture.profilesUsed.allSatisfy { $0 == fixture.profile.id })
        #expect(try LocalDingTalkWriteStore.load(from: service.ledgerURL).count == 1)
    }

    @Test func internalAccountIDRequiresCompleteExecutorScopedMembership() throws {
        let fixture = SubmissionFixture()
        fixture.detailExecutor = "internal-account-id"
        let (service, root) = try service(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = draft(fixture.profile)
        #expect(throws: DingTalkSubmissionError.self) { try service.submitConfirmed(item, title: "验收事项", dueAt: nil, priority: 20, selectedIDs: [fixture.profile.id]) }
        fixture.belongsToCurrentExecutor = true
        fixture.ownListComplete = false
        #expect(throws: DingTalkSubmissionError.self) { try service.reconcile(receiptID: item.submissionKey, selectedIDs: [fixture.profile.id]) }
        fixture.ownListComplete = true
        let verified = try service.reconcile(receiptID: item.submissionKey, selectedIDs: [fixture.profile.id])
        #expect(verified.state == .verified)
        #expect(fixture.creations == 1)
        #expect(fixture.profilesUsed.allSatisfy { $0 == fixture.profile.id })
    }

    @Test func creationTimeoutIsDurablyBlockedAcrossServiceRestart() throws {
        let fixture = SubmissionFixture()
        fixture.creationError = DingTalkCLIError.timedOut
        let (service, root) = try service(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = draft(fixture.profile)
        #expect(throws: DingTalkSubmissionError.self) { try service.submitConfirmed(draft, title: "验收事项", dueAt: nil, priority: 20, selectedIDs: [fixture.profile.id]) }
        let restarted = DingTalkTodoSubmissionService(client: fixture, ledgerURL: service.ledgerURL)
        #expect(throws: DingTalkSubmissionError.self) { try restarted.submitConfirmed(draft, title: "验收事项", dueAt: nil, priority: 20, selectedIDs: [fixture.profile.id]) }
        #expect(fixture.creations == 1)
        #expect(try LocalDingTalkWriteStore.load(from: service.ledgerURL).first?.state == .submitting)
    }

    @Test func failedReadbackCanBeReconciledWithoutReplayingCreation() throws {
        let fixture = SubmissionFixture()
        fixture.readError = DingTalkCLIError.timedOut
        let (service, root) = try service(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = draft(fixture.profile)
        #expect(throws: DingTalkSubmissionError.self) { try service.submitConfirmed(draft, title: "验收事项", dueAt: nil, priority: 20, selectedIDs: [fixture.profile.id]) }
        #expect(try LocalDingTalkWriteStore.load(from: service.ledgerURL).first?.state == .created)
        fixture.readError = nil
        let verified = try service.reconcile(receiptID: draft.submissionKey, selectedIDs: [fixture.profile.id])
        #expect(verified.state == .verified)
        #expect(fixture.creations == 1)
    }

    @Test func wrongExecutorOrDeadlineDoesNotPassReadbackVerification() throws {
        let fixture = SubmissionFixture()
        let (service, root) = try service(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        fixture.detailExecutor = "someone-else"
        let draft = draft(fixture.profile)
        #expect(throws: DingTalkSubmissionError.self) { try service.submitConfirmed(draft, title: "验收事项", dueAt: nil, priority: 20, selectedIDs: [fixture.profile.id]) }
        fixture.detailExecutor = fixture.profile.userID
        fixture.detailDue = 1_793_016_000_000
        #expect(throws: DingTalkSubmissionError.self) { try service.reconcile(receiptID: draft.submissionKey, selectedIDs: [fixture.profile.id]) }
        #expect(fixture.creations == 1)
    }

    @Test func organizationChangeAndCorruptLedgerPreventAnyRemoteWrite() throws {
        let fixture = SubmissionFixture()
        let (service, root) = try service(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = draft(fixture.profile)
        #expect(throws: DingTalkSubmissionError.self) { try service.submitConfirmed(draft, title: "验收事项", dueAt: nil, priority: 20, selectedIDs: ["different-profile"]) }
        try Data("broken-json".utf8).write(to: service.ledgerURL)
        #expect(throws: DingTalkSubmissionError.self) { try service.submitConfirmed(draft, title: "验收事项", dueAt: nil, priority: 20, selectedIDs: [fixture.profile.id]) }
        #expect(fixture.creations == 0)
    }

    @Test func restoringAnOlderBackupPreservesNewerRemoteWriteEvidence() throws {
        let fixture = SubmissionFixture()
        let (service, root) = try service(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try service.submitConfirmed(draft(fixture.profile), title: "验收事项", dueAt: nil, priority: 20, selectedIDs: [fixture.profile.id])
        var old = receipt
        old.state = .submitting; old.taskID = nil; old.updatedAt = .distantPast
        let archive = LocalAssistantDataExport(exportedAt: Date(), profile: .init(name: "验收", personality: "", tone: "", address: "", avatar: "warm", relationshipPoints: 0, automaticMemoryEnabled: false), conversation: [], memories: [], projects: [], personalTodos: [], skills: [], knowledgeBases: [], dingTalkWrites: [old])
        let suite = "com.yuan.restore-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try LocalAssistantDataManager.restore(archive, defaults: defaults, appDataDirectory: root)
        let restored = try LocalDingTalkWriteStore.load(from: service.ledgerURL)
        #expect(restored == [receipt])
    }

    private func draft(_ profile: DingTalkProfile) -> DingTalkTodoDraft {
        DingTalkTodoDraft(minute: .init(taskID: "synthetic-note", title: "合成验收纪要", startsAt: nil, sourceURL: nil, organizationName: nil, profile: profile), action: .init(title: "验收事项", owner: "", dueText: "", sourceQuote: "请整理验收事项", confidence: "高"))
    }

    private func service(_ fixture: SubmissionFixture) throws -> (DingTalkTodoSubmissionService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-submission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (DingTalkTodoSubmissionService(client: fixture, ledgerURL: root.appendingPathComponent("dingtalk-writes.json")), root)
    }
}

private final class SubmissionFixture: DingTalkTodoAccess {
    let profile = DingTalkProfile(corpID: "corp", userID: "user", corpName: "合成验收组织", userName: "验收本人", isOrgCurrent: true)
    var creations = 0
    var detailReads = 0
    var profilesUsed: [String] = []
    var creationError: Error?
    var readError: Error?
    var detailExecutor = "user"
    var detailDue = 0
    var belongsToCurrentExecutor = false
    var ownListComplete = true
    func listProfiles() throws -> [DingTalkProfile] { [profile] }
    func createOwnTodo(title: String, dueAt: Date?, priority: Int, profile: DingTalkProfile) throws -> DingTalkCLIResult {
        creations += 1; profilesUsed.append(profile.id)
        if let creationError { throw creationError }
        return .init(data: Data(#"{"success":true,"result":{"taskId":"remote-task"}}"#.utf8), exitCode: 0)
    }
    func run(_ operation: DingTalkReadOperation, profile: DingTalkProfile?) throws -> DingTalkCLIResult {
        profilesUsed.append(profile?.id ?? "missing")
        if let readError { throw readError }
        if case .ownOpenTodos = operation {
            let todos: [[String: Any]] = belongsToCurrentExecutor ? [["taskId": "remote-task"]] : []
            let object: [String: Any] = ["ok": true, "outcome": "success", "data": ["complete": ownListComplete, "count": todos.count, "todos": todos]]
            return .init(data: try JSONSerialization.data(withJSONObject: object), exitCode: 0)
        }
        guard case let .todoDetails(id) = operation, id == "remote-task" else { throw DingTalkCLIError.invalidResponse }
        detailReads += 1
        let object: [String: Any] = ["success": true, "result": ["todoDetailModel": ["taskId": id, "subject": "验收事项", "priority": 20, "executorIds": [detailExecutor], "dueTime": detailDue]]]
        return .init(data: try JSONSerialization.data(withJSONObject: object), exitCode: 0)
    }
}
