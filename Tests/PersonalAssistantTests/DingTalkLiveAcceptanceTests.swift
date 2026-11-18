import Foundation
import Testing
@testable import PersonalAssistant

/// Opt-in only. The human must approve creation AND cleanup immediately before
/// the caller supplies this flag. Normal test runs perform no remote writes.
struct DingTalkLiveAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YUAN_DINGTALK_LIVE_CREATE_DELETE"] == "CONFIRMED_ONE_TEMPORARY_TASK"))
    func createsVerifiesAndCleansUpExactlyOneApprovedTemporaryTask() throws {
        let selected = try #require(ProcessInfo.processInfo.environment["YUAN_DINGTALK_LIVE_PROFILE"])
        let expectedOrganization = try #require(ProcessInfo.processInfo.environment["YUAN_DINGTALK_LIVE_ORGANIZATION"])
        let client = DingTalkCLIClient()
        let profile = try #require(client.listProfiles().first { $0.id == selected && $0.corpName == expectedOrganization })
        let title = "【予安验收】钉钉待办写入闭环"
        let before = try openTasks(client, profile: profile)
        guard !before.contains(where: { $0["subject"] as? String == title }) else {
            Issue.record("已存在同标题记录，验收已在零写入时停止，避免混淆清理目标。")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-live-dingtalk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = root.appendingPathComponent("dingtalk-writes.json")
        let service = DingTalkTodoSubmissionService(client: client, ledgerURL: ledger)
        let minute = DingTalkMinute(taskID: "synthetic-live-acceptance", title: "合成验收资料（非真实听记）", startsAt: nil, sourceURL: nil, organizationName: nil, profile: profile)
        let action = ExtractedMeetingAction(title: title, owner: "本人", dueText: "", sourceQuote: "创建且清理一条经过用户确认的临时验收待办。", confidence: "高")
        let draft = DingTalkTodoDraft(minute: minute, action: action)
        var submissionError: Error?
        var createdID: String?
        do {
            let first = try service.submitConfirmed(draft, title: title, dueAt: nil, priority: 20, selectedIDs: [selected])
            createdID = first.taskID
            #expect(first.state == .verified)
            let second = try service.submitConfirmed(draft, title: title, dueAt: nil, priority: 20, selectedIDs: [selected])
            #expect(second.taskID == first.taskID)
            let matching = try openTasks(client, profile: profile).filter { $0["subject"] as? String == title }
            #expect(matching.count == 1)
            if ProcessInfo.processInfo.environment["YUAN_DINGTALK_LIVE_COMPLETION"] == "CONFIRMED_SAME_TEMPORARY_TASK" {
                let taskID = try #require(first.taskID)
                let completion = DingTalkTodoCompletionService(client: client)
                let target = try completion.prepare(localID: "dingtalk-\(profile.id)-\(taskID)", expectedTitle: title, selectedIDs: [selected])
                #expect(!target.isDone)
                let completed = try completion.completeConfirmed(target, selectedIDs: [selected])
                #expect(completed.isDone && completed.taskID == taskID)
                // Reconciliation is read-only, including after a verified success.
                #expect(try completion.verifyCompleted(target, selectedIDs: [selected]).isDone)
            }
        } catch { submissionError = error }

        // Reconcile unknown results before cleanup; never replay creation.
        if createdID == nil {
            createdID = (try? LocalDingTalkWriteStore.load(from: ledger))?.first?.taskID
        }
        if createdID == nil {
            let matching = try openTasks(client, profile: profile).filter { $0["subject"] as? String == title }
            if matching.count == 1 { createdID = matching[0]["taskId"] as? String }
        }
        guard let createdID else {
            Issue.record("未获得可核对的本轮创建 ID；已停止，写入记录保留在 \(ledger.path)。\(submissionError?.localizedDescription ?? "")")
            return
        }
        if submissionError != nil {
            // Diagnostic failure must never prevent cleanup of the approved ID.
            do {
            let response = try client.run(.todoDetails(id: createdID), profile: profile)
            let object = try DingTalkJSON.decode(response)
            let detail = (object["result"] as? [String: Any])?["todoDetailModel"] as? [String: Any] ?? [:]
            let safe: [String: Any] = [
                "detailPresent": !detail.isEmpty,
                "taskIDMatches": detail["taskId"] as? String == createdID,
                "titleMatches": detail["subject"] as? String == title,
                "priority": detail["priority"] ?? NSNull(),
                "dueTime": detail["dueTime"] ?? NSNull(),
                "executorCount": (detail["executorIds"] as? [Any])?.count ?? -1,
                "observedExecutorIDs": detail["executorIds"] ?? NSNull(),
                "observedCreatorID": detail["creatorId"] ?? NSNull(),
                "expectedExecutorID": profile.userID,
                "executorMatches": (detail["executorIds"] as? [String]).map { Set($0) == [profile.userID] } ?? false
            ]
            try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: ".build/p2-live-verification-diagnostic.json"), options: .atomic)
            } catch { Issue.record("诊断读取失败，仍继续清理本轮精确任务 ID。") }
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/dws")
        process.arguments = ["todo", "task", "delete", "--task-id", createdID, "--profile", selected, "--format", "json", "--yes"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let deletion = try DingTalkJSON.decode(.init(data: data, exitCode: process.terminationStatus))
        #expect(deletion["success"] as? Bool == true)
        let remaining = try openTasks(client, profile: profile)
        #expect(!remaining.contains { $0["taskId"] as? String == createdID })
        if let submissionError { Issue.record("临时远端任务已清理；写入核验仍需修复：\(submissionError.localizedDescription)；本机记录保留在 \(ledger.path)") }
        else { try FileManager.default.removeItem(at: root) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YUAN_DINGTALK_LIVE_READONLY"] == "YES"))
    func verifiesAnExistingOwnTaskWithoutCreatingOrChangingIt() throws {
        let selected = try #require(ProcessInfo.processInfo.environment["YUAN_DINGTALK_LIVE_PROFILE"])
        let expectedOrganization = try #require(ProcessInfo.processInfo.environment["YUAN_DINGTALK_LIVE_ORGANIZATION"])
        let client = DingTalkCLIClient()
        let profile = try #require(client.listProfiles().first { $0.id == selected && $0.corpName == expectedOrganization })
        let own = try DingTalkJSON.decode(client.run(.ownOpenTodos, profile: profile))
        let data = try #require(own["data"] as? [String: Any])
        #expect(data["complete"] as? Bool == true)
        let tasks = try #require(data["todos"] as? [[String: Any]])
        let taskID = try #require(tasks.first?["taskId"] as? String)
        let detailRoot = try DingTalkJSON.decode(client.run(.todoDetails(id: taskID), profile: profile))
        let detail = try #require((detailRoot["result"] as? [String: Any])?["todoDetailModel"] as? [String: Any])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-readonly-verification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("dingtalk-writes.json")
        let receipt = DingTalkWriteReceipt(id: "synthetic-readonly-verification", profileID: selected, minuteID: "synthetic-readonly", sourceTitle: "只读核验（不创建或修改待办）", sourceURL: nil, evidence: "仅使用已存在待办核对身份与字段", title: try #require(detail["subject"] as? String), dueAt: DingTalkJSON.date(detail["dueTime"]), priority: try #require(detail["priority"] as? Int), taskID: taskID, state: .created, updatedAt: Date())
        try LocalDingTalkWriteStore.save([receipt], to: ledger)
        let verified = try DingTalkTodoSubmissionService(client: client, ledgerURL: ledger).reconcile(receiptID: receipt.id, selectedIDs: [selected])
        #expect(verified.state == .verified)
        #expect(verified.taskID == taskID)
    }

    private func openTasks(_ client: DingTalkCLIClient, profile: DingTalkProfile) throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        for page in 1...40 {
            let root = try DingTalkJSON.decode(client.run(.openTodos(page: page, size: 20), profile: profile))
            let result = try #require(root["result"] as? [String: Any])
            items += try #require(result["todoCards"] as? [[String: Any]])
            if result["hasMore"] as? Bool != true { return items }
        }
        throw DingTalkContentError.incomplete
    }
}
