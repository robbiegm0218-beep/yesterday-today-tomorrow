import SwiftUI

/// Synthetic model acceptance: never writes the personal data stores.
struct ProjectLiveAcceptanceView: View {
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_PROJECT_ACCEPTANCE"] == "1" else {
                NSApplication.shared.terminate(nil)
                return
            }
            var checks: [String: Bool] = [:]
            var failure = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let project = AssistantProject(name: "演示项目", progressNote: "访谈已完成")
                    let context = AssistantChatWorkbenchContext.message(personalTodos: [], projects: [project], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: Date())
                    let response = try await DeepSeekClient().assistantTurn(to: [
                        .init(role: "system", content: "根据项目快照更新已存在项目，必须用工具生成确认卡片，保留未提及字段。"),
                        context, .init(role: "user", content: "更新演示项目：状态改为受阻，下一步准备评审材料，阻塞是缺少评审意见，正在等小林回复。确认后再保存。")
                    ], enabledSkillIDs: ["project-followup"], apiKey: key)
                    let proposals = AssistantActionParser.proposals(from: response.toolCalls, todos: [], projects: [project])
                    checks["single_proposal"] = proposals.count == 1
                    if let action = proposals.first, case let .saveProject(candidate, expected) = action.operation {
                        checks["existing_identity_preserved"] = candidate.id == project.id && candidate.dueAt == project.dueAt && candidate.progressNote == project.progressNote
                        checks["followup_fields_grounded"] = candidate.status == "受阻" && candidate.nextStep?.contains("评审材料") == true && candidate.blocker?.contains("评审意见") == true && candidate.waitingFor?.contains("小林") == true
                        let saved = try ProjectUpdatePolicy.saving(candidate, among: [project], expectedUpdatedAt: expected, actionID: action.id)
                        checks["retry_is_idempotent"] = try ProjectUpdatePolicy.saving(candidate, among: saved, expectedUpdatedAt: expected, actionID: action.id) == saved
                    }
                } catch { failure = error.localizedDescription.replacingOccurrences(of: key, with: "[hidden]") }
            } else { failure = "Saved credential unavailable" }
            let report: [String: Any] = ["checks": checks, "passed": checks.count == 4 && checks.values.allSatisfy { $0 }, "error": failure, "user_store_writes": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("PROJECT_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
