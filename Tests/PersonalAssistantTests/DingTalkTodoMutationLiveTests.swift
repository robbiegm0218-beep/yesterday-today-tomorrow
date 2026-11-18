import Foundation
import Testing
@testable import PersonalAssistant

/// Exactly ONE approved temporary task, no normal test run performs business writes.
struct DingTalkTodoMutationLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YUAN_DG02_LIVE_LIFECYCLE"] == "CONFIRMED_ONE_TEMPORARY_TASK"))
    func oneTemporaryTaskUpdateCompleteReopenAndCleanup() throws {
        let selected = try #require(ProcessInfo.processInfo.environment["YUAN_DINGTALK_LIVE_PROFILE"])
        let organization = try #require(ProcessInfo.processInfo.environment["YUAN_DINGTALK_LIVE_ORGANIZATION"])
        let client = DingTalkCLIClient()
        let profile = try #require(client.listProfiles().first { $0.id == selected && $0.corpName == organization })
        let title = "【予安验收】DG-02待办变更闭环"
        let updatedTitle = title + "（已改期）"
        for state in [false, true] {
            let root = try DingTalkJSON.decode(client.run(state ? .ownCompletedTodos : .ownOpenTodos, profile: profile))
            let data = try #require(root["data"] as? [String: Any]); let rows = try #require(data["todos"] as? [[String: Any]])
            guard data["complete"] as? Bool == true, !rows.contains(where: { [title, updatedTitle].contains($0["subject"] as? String ?? "") }) else {
                Issue.record("已有验收同名待办或列表不完整，零写入停止。"); return
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-dg02-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = root.appendingPathComponent("dingtalk-writes.json")
        let create = DingTalkTodoSubmissionService(client: client, ledgerURL: ledger)
        let mutation = DingTalkTodoMutationService(client: client, store: .init(url: root.appendingPathComponent("dingtalk-todo-mutations.json")))
        let minute = DingTalkMinute(taskID: "dg02-synthetic", title: "合成验收（非业务听记）", startsAt: nil, sourceURL: nil, organizationName: nil, profile: profile)
        let action = ExtractedMeetingAction(title: title, owner: "本人", dueText: "", sourceQuote: "仅创建、修改、改期、完成、重开及清理这一个已授权临时事项。", confidence: "高")
        var taskID: String?; var issue: Error?
        do {
            let created = try create.submitConfirmed(.init(minute: minute, action: action), title: title, dueAt: nil, priority: 20, selectedIDs: [selected])
            taskID = try #require(created.taskID)
            let localID = "dingtalk-\(selected)-\(taskID!)"
            var target = try mutation.prepare(localID: localID, expectedTitle: title, selected: [selected])
            let due = Date(timeIntervalSince1970: floor(Date().addingTimeInterval(48 * 3600).timeIntervalSince1970))
            let edit = DingTalkTodoMutationRequest(localID: localID, expectedTitle: title, mode: .update, patch: .init(title: updatedTitle, dueAt: due, priority: 30))
            target = try mutation.confirmed(edit, preview: target, selected: [selected])
            #expect(target.title == updatedTitle && target.priority == 30 && target.dueAt == due && !target.isDone)
            #expect(try mutation.reconcile(edit.id, selected: [selected]).title == updatedTitle)
            target = try mutation.confirmed(.init(localID: localID, expectedTitle: updatedTitle, mode: .complete), preview: target, selected: [selected])
            #expect(target.isDone && target.priority == 30 && target.dueAt == due)
            let reopen = DingTalkTodoMutationRequest(localID: localID, expectedTitle: updatedTitle, mode: .reopen)
            target = try mutation.confirmed(reopen, preview: target, selected: [selected])
            #expect(!target.isDone && target.title == updatedTitle && target.priority == 30 && target.dueAt == due)
            #expect(try mutation.reconcile(reopen.id, selected: [selected]).isDone == false)
        } catch { issue = error }
        // A failed readback never authorizes another create. Recover only this run's recorded ID.
        if taskID == nil { taskID = (try? LocalDingTalkWriteStore.load(from: ledger))?.first?.taskID }
        guard let taskID else { Issue.record("创建结果未知，未重放、未删除不明ID。验收记录：\(root.path)；\(issue?.localizedDescription ?? "")"); return }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/dws")
        process.arguments = ["todo", "task", "delete", "--task-id", taskID, "--profile", selected, "--format", "json", "--yes"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let deletion = try DingTalkJSON.decode(.init(data: data, exitCode: process.terminationStatus))
        #expect(deletion["success"] as? Bool == true)
        for state in [false, true] {
            let root = try DingTalkJSON.decode(client.run(state ? .ownCompletedTodos : .ownOpenTodos, profile: profile))
            let data = try #require(root["data"] as? [String: Any]); let rows = try #require(data["todos"] as? [[String: Any]])
            #expect(data["complete"] as? Bool == true && !rows.contains { $0["taskId"] as? String == taskID })
        }
        if let issue { Issue.record("本轮临时待办已清理，生命周期验收仍失败：\(issue.localizedDescription)。本机记录：\(root.path)") }
        else { print("DG02_LIVE: same_task_updated_completed_reopened_deleted; profile_verified; exact_fields_verified") }
    }
}
