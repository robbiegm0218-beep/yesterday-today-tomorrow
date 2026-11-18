import SwiftUI

struct FollowupAcceptanceView: View {
    struct Fixture: Encodable { let todos: [PersonalTodo]; let conversation: [AssistantMessage] }
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_FOLLOWUP_ACCEPTANCE"] == "1" else { NSApplication.shared.terminate(nil); return }
            var checks: [String: Bool] = [:]; var failure = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let todo = PersonalTodo(title: "合成验收：发布方案", importance: .high)
                    let targets = MatterContextPolicy.targets(todos: [todo], projects: [], external: [])
                    let due = Date().addingTimeInterval(7_200); let timestamp = AssistantFactTime.timestamp(due)
                    let user = AssistantMessage(text: "安排跟进已有待办“合成验收：发布方案”：等待小林，拿到接口清单就算解决。请在\(timestamp)跟进，下一步核对清单并安排评审。不要新建待办，先给跟进确认卡片。", isUser: true)
                    let context = AssistantChatWorkbenchContext.message(personalTodos: [todo], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: Date(), matterTargets: targets)
                    let turn = try await DeepSeekClient().assistantTurn(to: [.init(role: "system", content: "使用create_matter_followup为已有事项提出跟进确认卡片，引用当前逐字原话，不创建待办。"), context, .init(role: "user", content: user.text)], enabledSkillIDs: ["todo-priority"], apiKey: key)
                    let actions = AssistantActionParser.proposals(from: turn.toolCalls, todos: [todo], projects: [], matterTargets: targets, sourceMessage: user)
                    checks["one_followup_proposal"] = actions.count == 1
                    if let action = actions.first, case let .createFollowup(rule) = action.operation {
                        checks["target_time_and_evidence"] = rule.reference == .personal(todo.id) && abs(rule.checkAt.timeIntervalSince(due)) < 2 && user.text.contains(rule.quote) && rule.waitingFor.contains("小林") && rule.criterion.contains("接口清单")
                        let saved = try FollowupPolicy.creating(rule, among: [], targets: targets)
                        let updatedContext = AssistantChatWorkbenchContext.message(personalTodos: [todo], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: Date(), matterTargets: targets, followups: saved)
                        let feedback = AssistantMessage(text: "小林已经给了接口清单，请把这次跟进反馈为已解决；原待办状态保持。", isUser: true)
                        let response = try await DeepSeekClient().assistantTurn(to: [.init(role: "system", content: "用respond_matter_followup仅反馈已有跟进，不能完成原待办。"), updatedContext, .init(role: "user", content: feedback.text)], enabledSkillIDs: ["todo-priority"], apiKey: key)
                        let proposals = AssistantActionParser.proposals(from: response.toolCalls, todos: [todo], projects: [], matterTargets: targets, sourceMessage: feedback, followups: saved)
                        if proposals.count == 1, let result = proposals.first, case let .respondFollowup(id, revision, status, detail, nextDate) = result.operation {
                            checks["feedback_not_task_completion"] = id == rule.id && status == "resolved" && !todo.isComplete
                            let closed = try FollowupPolicy.responding(id: id, revision: revision, action: status, detail: detail, nextDate: nextDate, actionID: result.id, rules: saved)
                            let repeated = try FollowupPolicy.responding(id: id, revision: revision, action: status, detail: detail, nextDate: nextDate, actionID: result.id, rules: closed)
                            checks["closed_idempotently"] = repeated == closed && closed[0].outcomes.count == 1
                        }
                        if let path = ProcessInfo.processInfo.environment["YUAN_FOLLOWUP_FIXTURE"], checks.values.allSatisfy({ $0 }) {
                            try JSONEncoder().encode(Fixture(todos: [todo], conversation: [user, .init(text: "已整理跟进安排，确认前不会保存。", isUser: false, pendingActions: [action])])).write(to: URL(fileURLWithPath: path), options: .atomic)
                        }
                    }
                    if checks.count != 4 || !checks.values.allSatisfy({ $0 }) { for call in turn.toolCalls { print("FOLLOWUP_SYNTHETIC_TOOL: " + call.function.name + " " + call.function.arguments) } }
                } catch { failure = error.localizedDescription.replacingOccurrences(of: key, with: "[hidden]") }
            } else { failure = "Saved credential unavailable" }
            let report: [String: Any] = ["checks": checks, "passed": checks.count == 4 && checks.values.allSatisfy { $0 }, "error": failure, "user_store_writes": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("FOLLOWUP_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
