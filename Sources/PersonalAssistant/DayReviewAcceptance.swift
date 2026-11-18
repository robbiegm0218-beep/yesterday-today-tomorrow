import SwiftUI

struct DayReviewAcceptanceView: View {
    struct Fixture: Encodable { let plans: [SavedDayPlan]; let conversation: [AssistantMessage] }
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_DAY_REVIEW_ACCEPTANCE"] == "1" else { NSApplication.shared.terminate(nil); return }
            var checks: [String: Bool] = [:]; var failure = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let now = Date(), zone = TimeZone.current.identifier
                    let completed = DayPlanStep(title: "合成已勾选", isDone: true)
                    let carry = DayPlanStep(title: "合成方案", plannedTime: "10:00", durationMinutes: 45)
                    let later = DayPlanStep(title: "合成材料", durationMinutes: 20)
                    let skip = DayPlanStep(title: "合成旧安排")
                    let origin = SavedDayPlan(day: DayReviewPolicy.yesterday(now: now), timeZone: zone, revision: 2, steps: [completed, carry, later, skip])
                    let today = SavedDayPlan(day: DailyPlanSchedulePolicy.dayKey(for: now), timeZone: zone, revision: 1, steps: [.init(title: "合成今日安排", plannedTime: "16:00", durationMinutes: 45)])
                    let tomorrow = DailyPlanSchedulePolicy.dayKey(for: Calendar.current.date(byAdding: .day, value: 1, to: now)!)
                    let user = AssistantMessage(text: "把昨天的“合成方案”今天继续，先不定时间；昨天的“合成材料”改到\(tomorrow)再安排，“合成旧安排”不再安排。已勾选和今天已有安排保留，未完成原因未知，先给衔接确认卡片。", isUser: true)
                    let context = AssistantChatWorkbenchContext.message(personalTodos: [], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: now, savedPlan: today, reviewPlans: [origin, today])
                    let turn = try await DeepSeekClient().assistantTurn(to: [.init(role: "system", content: "用review_previous_day仅为用户指定的三个未勾选步骤提出今天继续/later/skip，choices_json为扁平数组。未知原因必须省略，不重建今天。"), context, .init(role: "user", content: user.text)], enabledSkillIDs: ["daily-planning"], apiKey: key, hasSavedDayPlan: true, hasDayReviewSource: true)
                    let actions = AssistantActionParser.proposals(from: turn.toolCalls, todos: [], projects: [], plans: [origin, today], sourceMessage: user)
                    checks["one_review_proposal"] = actions.count == 1
                    if let action = actions.first, case let .reviewPreviousDay(proposal) = action.operation {
                        checks["only_requested_decisions"] = proposal.decisions.count == 3 && proposal.decisions.first { $0.stepID == carry.id }?.choice == "today" && proposal.decisions.first { $0.stepID == later.id }?.targetDay == tomorrow && proposal.decisions.first { $0.stepID == skip.id }?.choice == "skip" && proposal.decisions.allSatisfy { $0.reason.isEmpty }
                        let result = try DayReviewPolicy.saving(proposal, among: [origin, today], references: [])
                        let savedToday = result.first { $0.day == today.day }
                        checks["today_and_origin_preserved"] = savedToday?.steps.count == 2 && savedToday?.steps.first == today.steps.first && savedToday?.steps.last?.plannedTime == "" && result.first { $0.day == origin.day }?.steps == origin.steps
                        let repeated = try DayReviewPolicy.saving(proposal, among: result, references: [])
                        checks["atomic_idempotent_commit"] = repeated == result && savedToday?.revision == 2
                        if checks.count == 4 && checks.values.allSatisfy({ $0 }), let path = ProcessInfo.processInfo.environment["YUAN_DAY_REVIEW_FIXTURE"] {
                            try JSONEncoder().encode(Fixture(plans: [origin, today], conversation: [user, .init(text: "已整理回顾决策，确认后才衔接。", isUser: false, pendingActions: [action])])).write(to: URL(fileURLWithPath: path), options: .atomic)
                        }
                    }
                    if checks.count != 4 || !checks.values.allSatisfy({ $0 }) { for call in turn.toolCalls { print("DAY_REVIEW_SYNTHETIC_TOOL: " + call.function.name + " " + call.function.arguments) } }
                } catch { failure = error.localizedDescription.replacingOccurrences(of: key, with: "[hidden]") }
            } else { failure = "Saved credential unavailable" }
            let report: [String: Any] = ["checks": checks, "passed": checks.count == 4 && checks.values.allSatisfy { $0 }, "error": failure, "user_store_writes": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("DAY_REVIEW_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
