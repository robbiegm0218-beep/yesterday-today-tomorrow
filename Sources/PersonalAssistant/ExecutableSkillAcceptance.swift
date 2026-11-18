import SwiftUI

struct ExecutableSkillAcceptanceView: View {
    struct Fixture: Codable { let runs: [SkillRun]; let todos: [PersonalTodo] }
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_SKILL_ACCEPTANCE"] == "1" else { NSApplication.shared.terminate(nil); return }
            var checks: [String: Bool] = [:]; var failure = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let now = Date(), todo = PersonalTodo(title: "合成字段核对", dueAt: nil, importance: .normal)
                    let facts = AssistantChatWorkbenchContext.message(personalTodos: [todo], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: now)
                    let request = "帮我安排今天，把合成字段核对列入安排，预计20分钟，时间先不定；只生成确认提案。"
                    let turn = try await DeepSeekClient().assistantTurn(to: [.init(role: "system", content: "执行日程规划技能，只生成一个propose_day_plan提案，引用提供的任务ID；不得编造事项或空闲时间。"), facts, .init(role: "user", content: request)], enabledSkillIDs: ["daily-planning"], apiKey: key)
                    let actions = AssistantActionParser.proposals(from: turn.toolCalls, todos: [todo], projects: [], planReferences: [.init(kind: "personal", id: todo.id.uuidString, title: todo.title)], sourceMessage: .init(text: request, isUser: true))
                    var daily = SkillRun(skillID: "daily-planning", startedAt: now, updatedAt: now)
                    if actions.count == 1 { daily.action = actions[0] }
                    daily.status = .awaitingConfirmation; daily.completedSteps = 3; daily.sourceSummary = "合成待办与当前日期，无外部数据"
                    if let action = daily.action, case let .saveDayPlan(plan, _) = action.operation { checks["daily_bound_to_real_fixture_id"] = plan.steps.count == 1 && plan.steps[0].sourceID == todo.id.uuidString && plan.steps[0].plannedTime.isEmpty }
                    let source = "会议决定：我负责核对字段清单。我负责更新验收说明。两项都没有确定截止时间。"
                    let extracted = try await DeepSeekClient().extractMeetingActions(from: source, apiKey: key)
                    var meeting = SkillRun(skillID: "minutes-actions", startedAt: now, updatedAt: now)
                    meeting.meetingProposals = try SkillRunPolicy.meetingProposals(extracted, source: source, title: "合成评审纪要")
                    meeting.status = .awaitingConfirmation; meeting.completedSteps = 3; meeting.sourceSummary = "合成评审纪要；仅保留行动摘录"
                    checks["all_actions_have_evidence"] = meeting.meetingProposals.count == 2 && meeting.meetingProposals.allSatisfy { $0.evidence.dueText.isEmpty || $0.evidence.dueText.contains("未") || $0.evidence.dueText.contains("无") }
                    var commit = meeting; commit.status = .committing; commit.selectedEvidenceIDs = commit.meetingProposals.map(\.id)
                    let saved = try SkillRunPolicy.meetingResult(commit, among: [todo])
                    checks["idempotent_atomic_meeting_commit"] = try SkillRunPolicy.meetingResult(commit, among: saved) == saved && saved.count == 3
                    let recovered = SkillRunPolicy.recovered([commit])[0]
                    let verified = try SkillRunPolicy.verify(recovered, plans: [], todos: saved)
                    checks["interrupted_commit_readback"] = recovered.status == .verificationNeeded && verified.contains("2项")
                    try SkillRunPolicy.validate([daily, meeting])
                    if checks.count == 4 && checks.values.allSatisfy({ $0 }), let path = ProcessInfo.processInfo.environment["YUAN_SKILL_FIXTURE"] {
                        try JSONEncoder().encode(Fixture(runs: [daily, meeting], todos: [todo])).write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                } catch { failure = error.localizedDescription.replacingOccurrences(of: key, with: "[hidden]") }
            } else { failure = "Saved credential unavailable" }
            let report: [String: Any] = ["checks": checks, "passed": checks.count == 4 && checks.values.allSatisfy { $0 }, "error": failure, "user_store_writes": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("SKILL_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
