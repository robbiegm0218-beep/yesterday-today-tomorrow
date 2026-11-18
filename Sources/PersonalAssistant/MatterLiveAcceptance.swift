import SwiftUI

/// Synthetic cloud-model check: never persists acceptance content in user stores.
struct MatterLiveAcceptanceView: View {
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_MATTER_ACCEPTANCE"] == "1" else { NSApplication.shared.terminate(nil); return }
            var checks: [String: Bool] = [:]
            var failure = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let todo = PersonalTodo(title: "合成验收：发布方案", importance: .normal)
                    let targets = MatterContextPolicy.targets(todos: [todo], projects: [], external: [])
                    let user = AssistantMessage(text: "给待办「合成验收：发布方案」补充进展：接口清单还没拿到，在等小林回复。请记录阻塞，确认后再保存，不要新建或完成待办。", isUser: true)
                    let context = AssistantChatWorkbenchContext.message(personalTodos: [todo], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: Date(), matterTargets: targets)
                    let response = try await DeepSeekClient().assistantTurn(to: [.init(role: "system", content: "使用append_matter_context记录用户给出的事项进展，引用本轮逐字原话并生成确认卡片，不创建任务。"), context, .init(role: "user", content: user.text)], enabledSkillIDs: ["todo-priority"], apiKey: key)
                    let actions = AssistantActionParser.proposals(from: response.toolCalls, todos: [todo], projects: [], matterTargets: targets, sourceMessage: user)
                    checks["single_grounded_proposal"] = actions.count == 1
                    if let action = actions.first, case let .appendMatterContext(entry, revision) = action.operation {
                        checks["correct_target_and_quote"] = entry.reference == .personal(todo.id) && user.text.contains(entry.quote) && entry.sourceMessageID == user.id
                        let saved = try MatterContextPolicy.appending(entry, expectedRevision: revision, entries: [], targets: targets)
                        checks["idempotent_confirmation"] = try MatterContextPolicy.appending(entry, expectedRevision: revision, entries: saved, targets: targets) == saved
                        let recallContext = AssistantChatWorkbenchContext.message(personalTodos: [todo], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: Date(), matterEntries: saved, matterTargets: targets)
                        let recalled = try await DeepSeekClient().assistantTurn(to: [.init(role: "system", content: "根据已确认记录回答，区分当时进展与当前状态。"), recallContext, .init(role: "user", content: "只查看：合成验收：发布方案，上次卡在哪里，在等谁？")], enabledSkillIDs: ["todo-priority"], apiKey: key)
                        checks["recalls_evidence_without_writing"] = recalled.toolCalls.isEmpty && (recalled.text?.contains("小林") == true) && (recalled.text?.contains("接口清单") == true)
                    }
                } catch { failure = error.localizedDescription.replacingOccurrences(of: key, with: "[hidden]") }
            } else { failure = "Saved credential unavailable" }
            let report: [String: Any] = ["checks": checks, "passed": checks.count == 4 && checks.values.allSatisfy { $0 }, "error": failure, "user_store_writes": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("MATTER_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
