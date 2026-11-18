import Foundation
import Testing
@testable import PersonalAssistant

struct DingTalkTodoMutationTests {
    private func fixture() throws -> (MutationClient, DingTalkTodoMutationService, URL) {
        let client = MutationClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-mutation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (client, .init(client: client, store: .init(url: root.appendingPathComponent("dingtalk-todo-mutations.json"))), root)
    }
    private func preview(_ c: MutationClient, _ s: DingTalkTodoMutationService) throws -> DingTalkTodoMutationTarget {
        try s.prepare(localID: c.localID, expectedTitle: c.title, selected: [c.profile.id])
    }
    @Test func editPreservesUnspecifiedFieldsAndNeverReplaysAcrossRestart() throws {
        let (c,s,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try preview(c,s)
        let request = DingTalkTodoMutationRequest(localID: c.localID, expectedTitle: c.title, mode: .update, patch: .init(title: "改后的标题"))
        let after = try s.confirmed(request, preview: before, selected: [c.profile.id])
        #expect(after.title == "改后的标题" && after.priority == 20 && after.dueAt == before.dueAt && !after.isDone)
        #expect(c.writes == 1)
        #expect(try s.store.load().first?.state == .verified)
        let restarted = DingTalkTodoMutationService(client: c, store: s.store)
        #expect(try restarted.confirmed(request, preview: before, selected: [c.profile.id]).title == after.title)
        #expect(c.writes == 1)
    }
    @Test func updateDeadlinePriorityThenCompleteReopenAndKeepFields() throws {
        let (c,s,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let due = Date(timeIntervalSince1970: 1_900_000_000)
        var before = try preview(c,s)
        let edit = DingTalkTodoMutationRequest(localID: c.localID, expectedTitle: c.title, mode: .update, patch: .init(dueAt: due, priority: 30))
        before = try s.confirmed(edit, preview: before, selected: [c.profile.id])
        #expect(before.dueAt == due && before.priority == 30)
        let done = DingTalkTodoMutationRequest(localID: c.localID, expectedTitle: c.title, mode: .complete)
        before = try s.confirmed(done, preview: before, selected: [c.profile.id]); #expect(before.isDone)
        #expect(try s.completed(selected: [c.profile.id]).items.map(\.id) == [c.localID])
        let reopen = DingTalkTodoMutationRequest(localID: c.localID, expectedTitle: c.title, mode: .reopen)
        let reopened = try s.confirmed(reopen, preview: before, selected: [c.profile.id])
        #expect(!reopened.isDone && reopened.priority == 30 && reopened.dueAt == due && c.writes == 3)
        #expect(try s.completed(selected: [c.profile.id]).items.isEmpty)
    }
    @Test func changedRevisionOrganizationTitleOrExecutorBlocksBeforeWrite() throws {
        for kind in 0..<5 {
            let (c,s,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let before = try preview(c,s)
            let request = DingTalkTodoMutationRequest(localID: c.localID, expectedTitle: c.title, mode: .complete)
            if kind == 0 { c.modified += 1 }
            if kind == 1 { c.title = "别人改名" }
            if kind == 2 { c.owns = false }
            if kind == 3 { c.partial = true }
            #expect(throws: (any Error).self) { try s.confirmed(request, preview: before, selected: kind == 4 ? [] : [c.profile.id]) }
            #expect(c.writes == 0)
            #expect(try s.store.load().isEmpty)
        }
    }
    @Test func ambiguousWriteOnlyReconcilesEvenAfterServiceRestart() throws {
        let (c,s,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try preview(c,s)
        let request = DingTalkTodoMutationRequest(localID: c.localID, expectedTitle: c.title, mode: .update, patch: .init(priority: 40))
        c.ambiguous = true
        #expect(throws: DingTalkTodoMutationError.self) { try s.confirmed(request, preview: before, selected: [c.profile.id]) }
        #expect(c.writes == 1)
        #expect(try s.store.load().first?.state == .submitting)
        let restarted = DingTalkTodoMutationService(client: c, store: s.store)
        #expect(try restarted.reconcile(request.id, selected: [c.profile.id]).priority == 40)
        #expect(c.writes == 1)
    }
    @Test func serverMismatchRetainsReceiptAndBlocksRetryInsteadOfFalseSuccess() throws {
        let (c,s,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try preview(c,s); c.apply = false
        let request = DingTalkTodoMutationRequest(localID: c.localID, expectedTitle: c.title, mode: .complete)
        #expect(throws: DingTalkTodoMutationError.self) { try s.confirmed(request, preview: before, selected: [c.profile.id]) }
        #expect(throws: DingTalkTodoMutationError.self) { try s.confirmed(request, preview: before, selected: [c.profile.id]) }
        #expect(c.writes == 1)
        #expect(try s.store.load().first?.state == .submitting)
        var reopenedPanelRequest = request; reopenedPanelRequest.id = UUID()
        #expect(throws: DingTalkTodoMutationError.self) { try s.confirmed(reopenedPanelRequest, preview: before, selected: [c.profile.id]) }
        #expect(c.writes == 1)
        var different = request; different.patch = .init(priority: 10)
        #expect(throws: DingTalkTodoMutationError.self) { try s.confirmed(different, preview: before, selected: [c.profile.id]) }
        #expect(c.writes == 1)
    }
    @Test func corruptLedgerOrMalformedServerFieldsFailClosed() throws {
        let (c,s,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for kind in 0..<3 {
            c.wrongID = kind == 0; c.malformed = kind == 1; c.partial = kind == 2
            #expect(throws: (any Error).self) { try preview(c,s) }
        }
        c.wrongID = false; c.malformed = false; c.partial = false
        let before = try preview(c,s)
        try Data("broken".utf8).write(to: s.store.url)
        let request = DingTalkTodoMutationRequest(localID: c.localID, expectedTitle: c.title, mode: .complete)
        #expect(throws: (any Error).self) { try s.confirmed(request, preview: before, selected: [c.profile.id]) }
        #expect(c.writes == 0)
    }
    @Test func alreadyAchievedStateIsReadOnlyAndMergedBackupKeepsProtection() throws {
        let (c,s,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        c.done = true; let before = try preview(c,s)
        let request = DingTalkTodoMutationRequest(localID: c.localID, expectedTitle: c.title, mode: .complete)
        #expect(try s.confirmed(request, preview: before, selected: [c.profile.id]).isDone)
        let current = try #require(s.store.load().first)
        var old = current; old.state = .submitting
        #expect(DingTalkTodoMutationStore.merge([current], [old]).first?.state == .verified)
        #expect(c.writes == 0)
    }
    @Test func restoringOldArchiveKeepsVerifiedMutationReceipt() throws {
        let (c,s,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try preview(c,s)
        let request = DingTalkTodoMutationRequest(localID: c.localID, expectedTitle: c.title, mode: .complete)
        _ = try s.confirmed(request, preview: before, selected: [c.profile.id])
        let receipt = try #require(s.store.load().first)
        var old = receipt; old.state = .submitting
        let archive = LocalAssistantDataExport(exportedAt: Date(), profile: .init(name: "QA", personality: "自然", tone: "自然", address: "你", avatar: "warm", relationshipPoints: 0, automaticMemoryEnabled: false), conversation: [], memories: [], projects: [], personalTodos: [], skills: [], knowledgeBases: [], dingTalkMutations: [old])
        let suite = "com.yuan.dg02.restore.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try LocalAssistantDataManager.restore(archive, defaults: defaults, appDataDirectory: root)
        #expect(try s.store.load().first?.state == .verified)
        #expect(try s.reconcile(request.id, selected: [c.profile.id]).isDone)
        #expect(c.writes == 1)
    }
    @Test func parserRejectsUnknownTargetsAmbiguousNamesAndUngroundedPatches() throws {
        let c = MutationClient()
        let target = DingTalkTodoChatTarget(id: c.localID, title: c.title, organization: c.profile.corpName, isComplete: false)
        func parsed(_ text: String, _ json: String, targets: [DingTalkTodoChatTarget]? = nil) throws -> PendingAssistantAction? {
            let args = try JSONDecoder().decode(DingTalkTodoMutationArguments.self, from: Data(json.utf8))
            return DingTalkTodoMutationParser.proposal(args, user: .init(text: text, isUser: true), targets: targets ?? [target], personal: [])
        }
        let good = "{\"target_id\":\"\(c.localID)\",\"operation\":\"update\",\"title\":\"新标题\",\"quote\":\"改成新标题\"}"
        #expect(try parsed("把钉钉的合成待办改成新标题", good) != nil)
        #expect(try parsed("不要改成新标题", good) == nil)
        #expect(try parsed("如何改成新标题", good) == nil)
        #expect(try parsed("把钉钉的合成待办改成新标题", good.replacingOccurrences(of: c.localID, with: "dingtalk-unknown")) == nil)
        #expect(try parsed("把钉钉的合成待办改成新标题", good, targets: [target, .init(id: "dingtalk-other-id", title: c.title, organization: "别的组织", isComplete: false)]) == nil)
        #expect(try parsed("改成新标题", good.replacingOccurrences(of: "\"title\":\"新标题\"", with: "\"title\":\"凭空标题\"")) == nil)
    }
    @Test func dateOnlyProposalUsesEndOfLocalDayAndRejectsUnsupportedClear() throws {
        let c = MutationClient(); let user = AssistantMessage(text: "把钉钉合成待办改期到2026-11-03", isUser: true)
        let json = "{\"target_id\":\"\(c.localID)\",\"operation\":\"update\",\"due_date\":\"2026-11-03\",\"quote\":\"改期到2026-11-03\"}"
        let args = try JSONDecoder().decode(DingTalkTodoMutationArguments.self, from: Data(json.utf8))
        let action = try #require(DingTalkTodoMutationParser.proposal(args, user: user, targets: [.init(id: c.localID, title: c.title, organization: c.profile.corpName, isComplete: false)], personal: []))
        guard case .externalTodoMutation(let request) = action.operation else { Issue.record("错误操作"); return }
        let patch = try #require(request.patch); let date = try #require(patch.dueAt)
        #expect(patch.dateOnly && Calendar.current.component(.hour, from: date) == 23 && Calendar.current.component(.second, from: date) == 59)
        #expect(!DingTalkTodoPatch().isValid && !DingTalkTodoPatch(priority: 100).isValid)
    }
}
private final class MutationClient: DingTalkTodoMutating {
    let profile = DingTalkProfile(corpID: "corp", userID: "employee", corpName: "隔离组织", userName: "合成本人", isOrgCurrent: true)
    var localID: String { "dingtalk-\(profile.id)-task-with-hyphens" }
    var title = "合成待办"; var priority = 20; var due: Date? = nil; var done = false; var modified = 100.0
    var owns = true; var partial = false; var wrongID = false; var malformed = false; var ambiguous = false; var apply = true; var writes = 0
    func listProfiles() throws -> [DingTalkProfile] { [profile] }
    func result(_ object: [String: Any]) throws -> DingTalkCLIResult { .init(data: try JSONSerialization.data(withJSONObject: object), exitCode: 0) }
    func run(_ operation: DingTalkReadOperation, profile: DingTalkProfile?) throws -> DingTalkCLIResult {
        #expect(profile == self.profile)
        switch operation {
        case .todoDetails(let id):
            return try result(["success": true, "result": ["todoDetailModel": ["taskId": wrongID ? "other" : id, "subject": title, "isDone": done, "modifiedTime": modified, "priority": malformed ? -1 : priority, "dueTime": due.map { $0.timeIntervalSince1970 * 1000 } ?? 0]]])
        case .ownOpenTodos, .ownCompletedTodos:
            let status: Bool; if case .ownCompletedTodos = operation { status = true } else { status = false }
            let rows: [[String: Any]] = owns && done == status ? [["taskId":"task-with-hyphens", "subject":title]] : []
            return try result(["ok":true, "data":["complete":!partial, "count":rows.count, "todos":rows]])
        default: throw DingTalkTodoMutationError.invalid
        }
    }
    func completeTodo(taskID: String, profile: DingTalkProfile) throws -> DingTalkCLIResult { try mutateTodo(taskID: taskID, mode: .complete, patch: nil, profile: profile) }
    func mutateTodo(taskID: String, mode: DingTalkTodoMutationRequest.Mode, patch: DingTalkTodoPatch?, profile: DingTalkProfile) throws -> DingTalkCLIResult {
        #expect(taskID == "task-with-hyphens" && profile == self.profile)
        writes += 1
        if apply {
            title = patch?.title ?? title; due = patch?.dueAt ?? due; priority = patch?.priority ?? priority
            if mode == .complete { done = true }; if mode == .reopen { done = false }; modified += 1
        }
        if ambiguous { throw DingTalkTodoMutationError.unverified }
        return try result(["ok":true])
    }
}
