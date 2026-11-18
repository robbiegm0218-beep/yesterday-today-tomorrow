import SwiftUI

struct DayPlanAdjustmentAcceptanceView: View {
    struct Fixture: Encodable {
        let plans: [SavedDayPlan]
        let conversation: [AssistantMessage]
    }
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_PLAN_ADJUSTMENT_ACCEPTANCE"] == "1" else { NSApplication.shared.terminate(nil); return }
            var checks: [String: Bool] = [:]
            var failure = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let completed = DayPlanStep(title: "合成已完成工作", plannedTime: "09:00", durationMinutes: 30, isDone: true)
                    let moving = DayPlanStep(title: "合成方案", plannedTime: "14:00", durationMinutes: 60)
                    let untouched = DayPlanStep(title: "合成晚间回顾", plannedTime: "20:00", durationMinutes: 20)
                    let original = SavedDayPlan(day: DailyPlanSchedulePolicy.dayKey(for: Date()), timeZone: TimeZone.current.identifier, revision: 2, steps: [completed, moving, untouched])
                    let user = AssistantMessage(text: "调整今天的计划：把“合成方案”安排到15:00，预计45分钟，其他安排保持。先给差异，确认后保存。", isUser: true)
                    let context = AssistantChatWorkbenchContext.message(personalTodos: [], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: Date(), savedPlan: original)
                    let response = try await DeepSeekClient().assistantTurn(to: [.init(role: "system", content: "对已保存的计划使用adjust_day_plan提交最小调整，保留其他内容，引用本轮原话。"), context, .init(role: "user", content: user.text)], enabledSkillIDs: ["daily-planning"], apiKey: key, hasSavedDayPlan: true)
                    let actions = AssistantActionParser.proposals(from: response.toolCalls, todos: [], projects: [], plans: [original], sourceMessage: user)
                    checks["one_patch_proposal"] = actions.count == 1
                    if actions.count != 1 {
                        for call in response.toolCalls { print("PLAN_ADJUSTMENT_SYNTHETIC_TOOL: " + call.function.name + " " + call.function.arguments) }
                        for call in response.toolCalls where call.function.name == "adjust_day_plan" {
                            do {
                                let args = try JSONDecoder().decode(DayPlanAdjustmentArguments.self, from: Data(call.function.arguments.utf8))
                                _ = try DayPlanAdjustmentPolicy.proposal(args, original: original, references: [], user: user)
                            } catch { print("PLAN_ADJUSTMENT_SYNTHETIC_DIAG: " + error.localizedDescription) }
                        }
                    }
                    if let action = actions.first, case let .adjustDayPlan(change) = action.operation {
                        checks["only_requested_step_changes"] = change.proposed.steps.count == 3 && change.proposed.steps[0] == completed && change.proposed.steps[2] == untouched && change.proposed.steps[1].id == moving.id && change.proposed.steps[1].plannedTime == "15:00" && change.proposed.steps[1].durationMinutes == 45
                        checks["grounded_diff"] = user.text.contains(change.quote) && DayPlanReview.differences(from: original, to: change.proposed).count == 1
                        try DayPlanAdjustmentPolicy.validateConfirmation(change, current: original)
                        let saved = try SavedDayPlanPolicy.saving(change.proposed, among: [original], expectedRevision: original.revision, references: [], actionID: action.id)
                        let repeated = try SavedDayPlanPolicy.saving(change.proposed, among: saved, expectedRevision: original.revision, references: [], actionID: action.id)
                        checks["version_and_idempotency"] = saved[0].revision == 3 && repeated == saved
                        if checks.values.allSatisfy({ $0 }), let path = ProcessInfo.processInfo.environment["YUAN_PLAN_ADJUSTMENT_FIXTURE"] {
                            let fixture = Fixture(plans: [original], conversation: [user, .init(text: "已整理局部调整，确认前不会保存。", isUser: false, pendingActions: [action])])
                            try JSONEncoder().encode(fixture).write(to: URL(fileURLWithPath: path), options: .atomic)
                        }
                    }
                } catch { failure = error.localizedDescription.replacingOccurrences(of: key, with: "[hidden]") }
            } else { failure = "Saved credential unavailable" }
            let report: [String: Any] = ["checks": checks, "passed": checks.count == 4 && checks.values.allSatisfy { $0 }, "error": failure, "user_store_writes": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("PLAN_ADJUSTMENT_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
