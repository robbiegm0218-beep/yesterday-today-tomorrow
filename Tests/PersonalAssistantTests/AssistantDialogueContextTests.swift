import Foundation
import Testing
@testable import PersonalAssistant

struct AssistantDialogueContextTests {
    private func state(_ messages: [AssistantMessage], _ todos: [PersonalTodo], extra: [MatterTarget] = [], selected: Set<String> = [], hidden: Set<String> = []) -> AssistantDialogueContext.Snapshot {
        let history = messages.last?.isUser == true ? messages : messages + [.init(text: "刚才那个怎么样？", isUser: true)]
        return AssistantDialogueContext.snapshot(messages: history, targets: todos.map { .init(reference: .personal($0.id), title: $0.title) } + extra,
                                         todos: todos, projects: [], followups: [], selected: selected, hidden: hidden)
    }
    private func message(_ action: PendingAssistantAction) -> AssistantMessage {
        .init(text: "确认前不会写入", isUser: false, pendingActions: [action])
    }
    @Test func persistedConfirmationOverridesOldPendingWordingAndUsesCurrentID() throws {
        var action = PendingAssistantAction(summary: "创建测试任务", operation: .createTodo(title: "测试任务", dueAt: nil, importance: .normal, projectName: nil))
        var todo = PersonalTodo(title: "后来更名的任务", importance: .normal, sourceActionID: action.id)
        action.status = .completed; todo.isComplete = true
        let history = try JSONDecoder().decode([AssistantMessage].self, from: JSONEncoder().encode([message(action), .init(text: "刚才那个处理好了吗？", isUser: true)]))
        let snapshot = state(history, [todo])
        #expect(snapshot.receipts.first?.state == "verified_completed")
        #expect(snapshot.focusCandidates == [.personal(todo.id)])
    }
    @Test func cancelledAndUnverifiedActionsDoNotBecomeAnImplicitWriteTarget() {
        let todo = PersonalTodo(title: "测试任务", importance: .normal)
        var action = PendingAssistantAction(summary: "完成", operation: .completeTodo(id: todo.id)); action.status = .dismissed
        #expect(state([message(action)], [todo]).focusCandidates.isEmpty)
        action.status = .pending; action.failureMessage = "token-secret-must-not-leak"
        let snapshot = state([message(action)], [todo])
        #expect(snapshot.focusCandidates.isEmpty && snapshot.receipts.first?.state == "not_verified")
        #expect(!AssistantDialogueContext.message(snapshot).content.contains("token-secret"))
    }
    @Test func missingCreatedEntityCannotBeInventedFromAnIdenticalTitle() {
        let other = PersonalTodo(title: "测试任务", importance: .normal)
        var action = PendingAssistantAction(summary: "新增", operation: .createTodo(title: other.title, dueAt: nil, importance: .normal, projectName: nil)); action.status = .completed
        let snapshot = state([message(action)], [other])
        #expect(snapshot.receipts.first?.targets.isEmpty == true && snapshot.focusCandidates.isEmpty)
    }
    @Test func sameTitleProducesMultipleCandidatesInsteadOfPickingOne() {
        let first = PersonalTodo(title: "评审准备", importance: .normal), second = PersonalTodo(title: "评审准备", importance: .high)
        let snapshot = state([.init(text: "评审准备怎么样？", isUser: true)], [first, second])
        #expect(Set(snapshot.focusCandidates) == [.personal(first.id), .personal(second.id)])
    }
    @Test func deselectedExternalActionDoesNotFallBackToAnEarlierLocalTarget() {
        let todo = PersonalTodo(title: "本机事项", importance: .normal)
        let local = PendingAssistantAction(summary: "完成", operation: .completeTodo(id: todo.id))
        let externalRef = MatterReference(kind: "external", id: "dingtalk-other-task")
        let entry = MatterContextEntry(reference: externalRef, category: "进展", content: "private-other-org", quote: "private-other-org", sourceMessageID: nil, recordedAt: Date())
        let external = PendingAssistantAction(summary: "private-other-org", operation: .appendMatterContext(entry: entry, expectedRevision: 0))
        let snapshot = state([message(local), message(external)], [todo], selected: ["current"])
        #expect(snapshot.focusCandidates.isEmpty)
        #expect(!AssistantDialogueContext.message(snapshot).content.contains("private-other-org"))
    }
    @Test func hiddenPlanSourceRemovesTheReceiptAndPlansDoNotBecomeTaskFocus() {
        let ref = MatterReference(kind: "external", id: "dingtalk-org-task")
        let plan = SavedDayPlan(day: "2026-11-05", timeZone: "Asia/Shanghai", steps: [.init(title: "私有事项", sourceKind: "external", sourceID: ref.id)])
        let action = PendingAssistantAction(summary: "私有事项", operation: .saveDayPlan(plan: plan, expectedRevision: 0))
        let target = MatterTarget(reference: ref, title: "私有事项")
        #expect(state([message(action)], [], extra: [target], selected: ["org"], hidden: [ref.id]).receipts.isEmpty)
        #expect(state([message(action)], [], extra: [target], selected: ["org"]).focusCandidates.isEmpty)
    }
    @Test func oldOrDisplacedFocusIsNotReusedIndefinitely() {
        let todo = PersonalTodo(title: "任务", importance: .normal)
        let action = PendingAssistantAction(summary: "完成", operation: .completeTodo(id: todo.id))
        var old = message(action); old.time = Date().addingTimeInterval(-86401)
        #expect(state([old], [todo]).focusCandidates.isEmpty)
        let distant = [message(action)] + (0..<14).map { _ in AssistantMessage(text: "新话题", isUser: true) } + [.init(text: "刚才那个怎么样？", isUser: true)]
        #expect(state(distant, [todo]).focusCandidates.isEmpty)
    }
    @Test func diagnosticRetentionIsBoundedAndCorruptionCannotOverwriteOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turn-trace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssistantTurnDiagnosticStore(directory: root)
        try LocalJSONFileStore.save((0..<105).map { _ in AssistantTurnDiagnostic() }, to: store.url)
        let last = AssistantTurnDiagnostic(); try store.append(last)
        #expect(try store.load().count == 100 && store.load().last?.id == last.id)
        let broken = root.appendingPathComponent("broken"); try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let invalid = AssistantTurnDiagnosticStore(directory: broken); try Data("broken".utf8).write(to: invalid.url)
        #expect(throws: (any Error).self) { try invalid.append(last) }
        #expect(try String(contentsOf: invalid.url, encoding: .utf8) == "broken")
    }
    @Test func hiddenSourceFilterRespectsFullOrganizationBoundary() {
        #expect(WorkbenchArchivePolicy.belongsToSelectedOrganization("dingtalk-org-task", selected: ["org"]))
        #expect(!WorkbenchArchivePolicy.belongsToSelectedOrganization("dingtalk-org2-task", selected: ["org"]))
        #expect(!WorkbenchArchivePolicy.belongsToSelectedOrganization("dingtalk-org-task", selected: []))
    }
    @Test func changingTopicDoesNotInventFocusAndFailureCategoryDoesNotContainRawError() {
        let todo = PersonalTodo(title: "产品评审", importance: .normal)
        let action = PendingAssistantAction(summary: "完成", operation: .completeTodo(id: todo.id))
        let snapshot = state([message(action), .init(text: "聊一下今天的天气", isUser: true)], [todo])
        #expect(snapshot.focusCandidates.isEmpty)
        #expect(AssistantTurnDiagnostic.category(for: DeepSeekRequestError.server(status: 401, detail: "secret-key")) == "authentication_or_permission")
    }
}
