import Foundation

/// Explicit, read-only synthetic model checks. Never loads conversation/task stores.
@MainActor
enum DialogueLiveAcceptance {
    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["YUAN_RUN_DIALOGUE_ACCEPTANCE"] == "1" else { return false }
        var checks: [String: Bool] = [:]
        var usage = 0
        var measured = 0
        let start = Date()
        var failure: String?
        var syntheticFailureProbe: [String: Any] = [:]
        if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
            do {
                let todo = PersonalTodo(title: "合成接口评审任务", importance: .normal)
                let target = MatterTarget(reference: .personal(todo.id), title: todo.title)
                for (name, status, expected) in [("confirmed_receipt", AssistantActionStatus.completed, "已执行"),
                                                 ("pending_receipt", .pending, "待确认"), ("cancelled_receipt", .dismissed, "已取消")] {
                    var action = PendingAssistantAction(summary: "修改合成接口评审任务", operation: .updateTodo(id: todo.id, title: nil, dueAt: nil, importance: .high, projectName: nil))
                    action.status = status
                    let history: [AssistantMessage] = [.init(text: "我整理好了，确认前不会写入。", isUser: false, pendingActions: [action]),
                        .init(text: "刚才的修改是已执行、待确认还是已取消？只答这三个词中的一个。", isUser: true)]
                    let snapshot = AssistantDialogueContext.snapshot(messages: history, targets: [target], todos: [todo], projects: [], followups: [], selected: [], hidden: [])
                    let result = try await DeepSeekClient().assistantTurn(to: [
                        .init(role: "system", content: "根据结构化操作回执回答，旧助手文字可能早于确认状态；不要写入。"),
                        .init(role: "assistant", content: history[0].text), AssistantDialogueContext.message(snapshot),
                        .init(role: "user", content: history[1].text)], enabledSkillIDs: [], apiKey: key)
                    checks[name] = result.toolCalls.isEmpty && result.text?.trimmingCharacters(in: .whitespacesAndNewlines) == expected
                    if let count = result.usage?.totalTokens { usage += count; measured += 1 }
                }
                var action = PendingAssistantAction(summary: "完成合成任务", operation: .completeTodo(id: todo.id)); action.status = .completed
                let user = AssistantMessage(text: "刚才那个任务当前是已完成还是未完成？只回答状态。", isUser: true)
                let snapshot = AssistantDialogueContext.snapshot(messages: [.init(text: "已整理", isUser: false, pendingActions: [action]), user], targets: [target], todos: [todo], projects: [], followups: [], selected: [], hidden: [])
                let facts = AssistantChatWorkbenchContext.message(personalTodos: [todo], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: Date())
                let result = try await DeepSeekClient().assistantTurn(to: [
                    .init(role: "system", content: "历史执行回执不等于当前源状态。根据当前工作台事实回答，不写入。"),
                    facts, AssistantDialogueContext.message(snapshot), .init(role: "user", content: user.text)], enabledSkillIDs: [], apiKey: key)
                checks["current_fact_overrides_historical_receipt"] = result.toolCalls.isEmpty && result.text?.contains("未完成") == true
                if let count = result.usage?.totalTokens { usage += count; measured += 1 }
                let syntheticDocument = KnowledgeDocument(urlPath: "/synthetic/read-loop.md", title: "海盐项目验收记录", content: "海盐项目的验收代号为 SALT_7392，验证负责人为林晨。", indexedAt: Date(), modifiedAt: nil, fileSize: nil)
                let readResult = try await DeepSeekClient().assistantTurn(to: [
                    .init(role: "system", content: "回答前必须查询资料。所有内容均为合成验收数据，不得写入。没有给定事实就先使用只读工具查找，不能猜。"),
                    .init(role: "user", content: "查本地资料中海盐项目的验收代号和负责人，只回答这两项并注明来源。")], enabledSkillIDs: [], apiKey: key,
                    readContext: .init(bases: [.init(name: "合成验收资料库", folderPath: "/synthetic", documents: [syntheticDocument])]))
                checks["read_loop_retrieves_synthetic_fact"] = readResult.readToolCallCount > 0 && readResult.modelRounds >= 2 && readResult.stopReason == nil && readResult.toolCalls.isEmpty && readResult.sources.contains { $0.id == syntheticDocument.urlPath } && readResult.text?.contains("SALT_7392") == true && readResult.text?.contains("林晨") == true
                if let count = readResult.usage?.totalTokens { usage += count; measured += 1 }

                let remoteID = "dingtalk-synthetic:user-task"
                let remote = TodoRecord(id: remoteID, title: "合成状态核对任务", dueAt: nil, importance: .normal, sourceURL: nil, isComplete: false)
                let liveBackend = SyntheticLiveTodoRead()
                let live = AssistantLiveTodoReader(client: liveBackend, scope: { .init(selected: ["synthetic:user"], readableIDs: [remoteID]) })
                let verified = try await DeepSeekClient().assistantTurn(to: [
                    .init(role: "system", content: "全部为合成验收数据，无业务写入。旧快照：target_id=\(remoteID)，标题=合成状态核对任务，未完成；当前状态必须调用实时工具核对。"),
                    .init(role: "user", content: "请回查合成状态核对任务的当前钉钉状态，只回答已完成或未完成。")], enabledSkillIDs: [], apiKey: key,
                    readContext: .init(external: [remote], selected: ["synthetic:user"], liveReader: live))
                checks["live_tool_overrides_stale_snapshot"] = verified.readToolCallCount > 0 && verified.modelRounds >= 2 && verified.toolCalls.isEmpty && verified.stopReason == nil && liveBackend.calls == 1 && verified.text?.contains("已完成") == true && verified.text?.contains("未完成") != true
                if let count = verified.usage?.totalTokens { usage += count; measured += 1 }

                let failingBackend = SyntheticLiveTodoRead(fail: true)
                let failing = AssistantLiveTodoReader(client: failingBackend, scope: { .init(selected: ["synthetic:user"], readableIDs: [remoteID]) })
                let unknown = try await DeepSeekClient().assistantTurn(to: [
                    .init(role: "system", content: "合成验收：旧快照target_id=\(remoteID)，标题=合成状态核对任务，已完成，但时效已过。必须调用实时工具核对；失败不等于完成/删除，失败只回答无法核对。"),
                    .init(role: "user", content: "请实时核对合成状态核对任务是否完成。成功只答已完成或未完成，失败只答无法核对。")], enabledSkillIDs: [], apiKey: key,
                    readContext: .init(external: [remote], selected: ["synthetic:user"], liveReader: failing))
                syntheticFailureProbe = ["successBackendCalls": liveBackend.calls, "failureBackendCalls": failingBackend.calls, "readCount": unknown.readToolCallCount, "rounds": unknown.modelRounds, "stopReason": unknown.stopReason ?? "none"]
                checks["live_failure_does_not_promote_old_snapshot"] = unknown.readToolCallCount > 0 && unknown.toolCalls.isEmpty && unknown.stopReason == "remote_read_failed" && failingBackend.calls == 1 && unknown.text?.contains("无法核对当前状态") == true
                if let count = unknown.usage?.totalTokens { usage += count; measured += 1 }

            } catch { failure = AssistantTurnDiagnostic.category(for: error) }
        } else { failure = "saved_credential_unavailable" }
        let realRead = ProcessInfo.processInfo.environment["YUAN_RUN_REMOTE_READ_ACCEPTANCE"] == "1"
        if realRead { checks["real_selected_task_read"] = await RemoteReadAcceptance.run() }
        let passed = checks.count == (realRead ? 8 : 7) && checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["passed": passed, "checks": checks, "elapsedSeconds": Date().timeIntervalSince(start),
                                   "measuredTurns": measured, "totalTokens": usage, "businessDataWrites": 0,
                                   "failureCategory": failure ?? "none", "syntheticFailureProbe": syntheticFailureProbe]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: bytes, encoding: .utf8) {
            print("DIALOGUE_ACCEPTANCE: " + text)
        }
        return passed
    }
}
