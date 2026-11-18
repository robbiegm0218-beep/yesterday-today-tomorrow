import SwiftUI

struct MemoryActionAcceptanceView: View {
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_MEMORY_ACTION_ACCEPTANCE"] == "1" else { NSApplication.shared.terminate(nil); return }
            var checks: [String: Bool] = [:]; var error = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let now = Date()
                    let short = AssistantMemory(content: "合成用户明确选择简短回复", category: "个人偏好", actionPreferences: [.init(kind: .replyLength, value: "brief", end: nil, confirmedAt: now)])
                    let shortReply = try await DeepSeekClient().reply(to: [MemoryActionPolicy.context([short]), .init(role: "user", content: "我有两份材料要核对，怎么开始比较省力？没有其他已知安排，请按默认回复习惯建议，不创建事项。")], apiKey: key)
                    checks["brief_default"] = !shortReply.isEmpty && shortReply.count <= 450
                    let detailed = try MemoryActionPolicy.setting([.init(kind: .replyLength, value: "detailed", end: nil, confirmedAt: now)], for: short.id, among: [short])
                    let longReply = try await DeepSeekClient().reply(to: [MemoryActionPolicy.context(detailed), .init(role: "user", content: "我有两份材料要核对，怎么开始比较省力？请按默认回复习惯说明，不创建事项。")], apiKey: key)
                    checks["correction_changes_response"] = longReply.count > shortReply.count && longReply.count > 160
                    let override = try await DeepSeekClient().reply(to: [MemoryActionPolicy.context(detailed), .init(role: "user", content: "这次只用一句话告诉我如何开始核对两份材料，最多40字。")], apiKey: key)
                    checks["current_request_overrides_default"] = !override.isEmpty && override.count <= 80
                    let focus = AssistantMemory(content: "合成专注偏好", category: "个人偏好", actionPreferences: [.init(kind: .focusWindow, value: "19:00", end: "20:00", confirmedAt: now)])
                    let todo = PersonalTodo(title: "合成方案核对", dueAt: nil, importance: .normal)
                    let context = AssistantChatWorkbenchContext.message(personalTodos: [todo], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: now)
                    let response = try await DeepSeekClient().assistantTurn(to: [.init(role: "system", content: "为合成场景提出今日计划，用propose_day_plan生成确认提案；只安排用户提供的任务，不写入。"), context, MemoryActionPolicy.context([focus], planning: true), .init(role: "user", content: "帮我安排今天。今天18:00到21:00已确认空闲，把合成方案核对安排20分钟，按我的专注偏好给出具体开始时间。")], enabledSkillIDs: ["daily-planning"], apiKey: key)
                    let actions = AssistantActionParser.proposals(from: response.toolCalls, todos: [todo], projects: [], planReferences: [.init(kind: "personal", id: todo.id.uuidString, title: todo.title)])
                    if actions.count == 1, case let .saveDayPlan(plan, _) = actions[0].operation {
                        checks["focus_changes_new_plan"] = plan.steps.count == 1 && plan.steps[0].sourceID == todo.id.uuidString && !plan.steps[0].plannedTime.isEmpty && MemoryActionPolicy.planningWarnings(plan, memories: [focus]).isEmpty
                    } else { checks["focus_changes_new_plan"] = false }
                    print("MEMORY_ACTION_LENGTHS: \(shortReply.count),\(longReply.count),\(override.count)")
                } catch let issue { error = issue.localizedDescription.replacingOccurrences(of: key, with: "[hidden]") }
            } else { error = "Saved credential unavailable" }
            let report: [String: Any] = ["checks": checks, "passed": checks.count == 4 && checks.values.allSatisfy { $0 }, "error": error, "user_store_writes": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("MEMORY_ACTION_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
