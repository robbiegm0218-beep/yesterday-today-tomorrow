import Foundation
import Testing
@testable import PersonalAssistant

struct DingTalkTodoCompletionTests {
    let profile = DingTalkProfile(corpID: "corp", userID: "employee", corpName: "隔离组织", userName: "测试本人", isOrgCurrent: true)
    var localID: String { "dingtalk-\(profile.id)-task-with-hyphens" }
    private func target(_ client: CompletionClient) throws -> DingTalkTodoCompletionTarget {
        try DingTalkTodoCompletionService(client: client).prepare(localID: localID, expectedTitle: "合成待办", selectedIDs: [profile.id])
    }
    private func client() -> CompletionClient { CompletionClient(profile: profile) }

    @Test func prepareIsReadOnlyAndKeepsExactTaskAndOrganization() throws {
        let client = client(); let target = try target(client)
        #expect(target.taskID == "task-with-hyphens" && target.profile == profile && !target.isDone)
        #expect(client.writes == 0)
    }
    @Test func confirmedCompletionReadsBackAndSecondConfirmationDoesNotWrite() throws {
        let client = client(); let original = try target(client); let service = DingTalkTodoCompletionService(client: client)
        #expect(try service.completeConfirmed(original, selectedIDs: [profile.id]).isDone)
        #expect(try service.completeConfirmed(original, selectedIDs: [profile.id]).isDone)
        #expect(client.writes == 1)
    }
    @Test func organizationAndTitleOrRevisionChangesRejectBeforeWrite() throws {
        for kind in 0..<3 {
            let client = client(); let original = try target(client); let service = DingTalkTodoCompletionService(client: client)
            if kind == 1 { client.title = "已改名" }
            if kind == 2 { client.modified += 1 }
            #expect(throws: DingTalkTodoCompletionError.self) { try service.completeConfirmed(original, selectedIDs: kind == 0 ? [] : [profile.id]) }
            #expect(client.writes == 0)
        }
    }
    @Test func missingExecutorOrIncompleteCollectionPreventsCompletion() throws {
        for partial in [false, true] {
            let client = client(); client.owns = partial; client.complete = !partial
            #expect(throws: DingTalkTodoCompletionError.self) { try target(client) }
            #expect(client.writes == 0)
        }
    }
    @Test func reassignedAfterPreviewAndWrongReturnedIDRejectWithoutWrite() throws {
        let client = client(); let original = try target(client); client.owns = false
        #expect(throws: DingTalkTodoCompletionError.self) { try DingTalkTodoCompletionService(client: client).completeConfirmed(original, selectedIDs: [profile.id]) }
        #expect(client.writes == 0)
        client.wrongID = true
        #expect(throws: DingTalkTodoCompletionError.self) { try target(client) }
    }
    @Test func unknownWriteDoesNotReplayAndReadOnlyReconciliationCanRecover() throws {
        let client = client(); let original = try target(client); let service = DingTalkTodoCompletionService(client: client)
        client.ambiguousWrite = true
        #expect(throws: DingTalkTodoCompletionError.self) { try service.completeConfirmed(original, selectedIDs: [profile.id]) }
        #expect(client.writes == 1)
        #expect(try service.verifyCompleted(original, selectedIDs: [profile.id]).isDone)
        #expect(client.writes == 1)
    }
    @Test func successfulReceiptWithoutChangedServerStateIsNotSuccess() throws {
        let client = client(); let original = try target(client); client.applyWrite = false
        #expect(throws: DingTalkTodoCompletionError.self) { try DingTalkTodoCompletionService(client: client).completeConfirmed(original, selectedIDs: [profile.id]) }
        #expect(!client.done && client.writes == 1)
    }
    @Test func alreadyDoneAndMalformedPersonalOrUnselectedTargetsNeverWrite() throws {
        let client = client(); client.done = true
        let target = try target(client)
        #expect(try DingTalkTodoCompletionService(client: client).completeConfirmed(target, selectedIDs: [profile.id]).isDone)
        for id in ["personal-UUID", "dingtalk-foreign-task", "dingtalk-\(profile.id)-"] {
            #expect(throws: DingTalkTodoCompletionError.self) { try DingTalkTodoCompletionService(client: client).prepare(localID: id, expectedTitle: "合成待办", selectedIDs: [profile.id]) }
        }
        #expect(client.writes == 0)
    }
    @Test func snapshotOnlyCompletesSelectedExternalTaskPreservingOriginalRecords() {
        let records = [TodoRecord(id: localID, title: "合成待办", dueAt: nil, importance: .high, projectName: "项目", relatedEventID: nil, sourceURL: nil, isComplete: false),
                       TodoRecord(id: "personal", title: "个人", dueAt: nil, importance: nil, projectName: nil, relatedEventID: nil, sourceURL: nil, isComplete: false, isPersonal: true)]
        let original = DailyDataSnapshot(events: [], todos: records, sourceLabel: "隔离", usesDemoData: false)
        let result = original.completingExternalTodo(localID)
        #expect(!original.todos[0].isComplete && result.todos[0].isComplete && !result.todos[1].isComplete)
        #expect(result.todos[0].projectName == "项目" && result.todos[0].importance == .high)
        #expect(DailyPlanComposer().compose(snapshot: result, now: Date()).todos.filter { !$0.isComplete }.count == 1)
    }
}

private final class CompletionClient: DingTalkTodoCompleting {
    let profile: DingTalkProfile
    var writes = 0; var done = false; var modified = 100.0; var title = "合成待办"
    var owns = true; var complete = true; var wrongID = false; var ambiguousWrite = false; var applyWrite = true
    init(profile: DingTalkProfile) { self.profile = profile }
    func listProfiles() throws -> [DingTalkProfile] { [profile] }
    func result(_ object: [String: Any]) throws -> DingTalkCLIResult { .init(data: try JSONSerialization.data(withJSONObject: object), exitCode: 0) }
    func run(_ operation: DingTalkReadOperation, profile: DingTalkProfile?) throws -> DingTalkCLIResult {
        #expect(profile == self.profile)
        switch operation {
        case .todoDetails(let id):
            return try result(["success": true, "result": ["todoDetailModel": ["taskId": wrongID ? "other" : id, "subject": title, "isDone": done, "modifiedTime": modified]]])
        case .ownOpenTodos:
            return try result(["ok": true, "data": ["complete": complete, "count": owns ? 1 : 0, "todos": owns ? [["taskId": "task-with-hyphens"]] : []]])
        default: throw DingTalkTodoCompletionError.invalidTarget
        }
    }
    func completeTodo(taskID: String, profile: DingTalkProfile) throws -> DingTalkCLIResult {
        #expect(taskID == "task-with-hyphens" && profile == self.profile)
        writes += 1
        if applyWrite { done = true; modified += 1 }
        if ambiguousWrite { throw DingTalkTodoCompletionError.unverified }
        return try result(["ok": true])
    }
}
