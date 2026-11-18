import SwiftUI

/// Synthetic model inputs only; no DingTalk client or business write is invoked.
struct DingTalkTodoMutationAcceptanceView: View {
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_DG02_MODEL_ACCEPTANCE"] == "1" else { NSApplication.shared.terminate(nil); return }
            var checks: [String: Bool] = [:]; var error = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let target = DingTalkTodoChatTarget(id: "dingtalk-synthetic:synthetic-task-id", title: "合成评审材料", organization: "隔离组织", isComplete: false)
                    let encoded = String(data: try JSONEncoder().encode([target]), encoding: .utf8)!
                    let examples: [(String, DingTalkTodoMutationRequest.Mode)] = [
                        ("把钉钉的合成评审材料标题改成合成评审材料终稿，优先级改为高，截止日期改期到2026-11-03。", .update),
                        ("把钉钉的合成评审材料标记为完成。", .complete),
                        ("重新打开钉钉的合成评审材料。", .reopen)
                    ]
                    for (text, mode) in examples {
                        let turn = try await DeepSeekClient().assistantTurn(to: [.init(role: "system", content: "这是合成验收。只用mutate_dingtalk_todo生成待确认提案，不执行写入。externalTodoMutationTargets=" + encoded), .init(role: "user", content: text)], enabledSkillIDs: ["todo-priority"], apiKey: key, canMutateExternalTodos: true, forceExternalTodoMutation: true)
                        let actions = AssistantActionParser.proposals(from: turn.toolCalls, todos: [], projects: [], sourceMessage: .init(text: text, isUser: true), externalTodoTargets: [target])
                        if actions.count == 1, case let .externalTodoMutation(request) = actions[0].operation {
                            checks[mode.rawValue] = request.localID == target.id && request.mode == mode
                            if mode == .update { checks["only_requested_fields"] = request.patch?.title == "合成评审材料终稿" && request.patch?.priority == 30 && request.patch?.dateOnly == true }
                        } else { checks[mode.rawValue] = false }
                    }
                } catch let issue { error = issue.localizedDescription.replacingOccurrences(of: key, with: "[hidden]") }
            } else { error = "Saved credential unavailable" }
            let report: [String: Any] = ["checks":checks, "passed":checks.count == 4 && checks.values.allSatisfy { $0 }, "error":error, "enterprise_writes":0, "user_store_writes":0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("DG02_MODEL_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
