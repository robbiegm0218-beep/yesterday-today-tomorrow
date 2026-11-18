import SwiftUI

/// Explicit local acceptance command; synthetic inputs, no user-store writes.
/// Run the signed app executable with --verify-memory-extraction and
/// YUAN_RUN_MEMORY_ACCEPTANCE=1. Only aggregate results go to stdout.
struct MemoryLiveAcceptanceView: View {
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_MEMORY_ACCEPTANCE"] == "1" else {
                print("MEMORY_ACCEPTANCE: not enabled")
                NSApplication.shared.terminate(nil)
                return
            }
            var results: [String: Bool] = [:]
            var failure = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let client = DeepSeekClient()
                    let source = AssistantMessage(text: "我写周报时习惯先给三条结论，再展开证据。", isUser: true)
                    let first = try await client.extractMemories(from: [.init(role: "user", content: source.text)], apiKey: key)
                    let saved = MemoryEvolution.apply(first, to: [], source: source)
                    results["new_fact_has_verified_source"] = saved.added > 0 && saved.memories.allSatisfy { $0.evidence?.first?.messageID == source.id }
                    let repeatSource = AssistantMessage(text: "整理周报，我还是喜欢先列三个结论，然后补充依据。", isUser: true)
                    let repeated = try await client.extractMemories(from: [.init(role: "user", content: repeatSource.text)], apiKey: key, existing: saved.memories)
                    let merged = MemoryEvolution.apply(repeated, to: saved.memories, source: repeatSource)
                    results["paraphrase_enriches_without_new_record"] = merged.added == 0 && merged.enriched > 0
                    let change = AssistantMessage(text: "以后周报不要先列结论了，我改为先列证据、最后给结论。", isUser: true)
                    let changed = try await client.extractMemories(from: [.init(role: "user", content: change.text)], apiKey: key, existing: merged.memories)
                    let flagged = MemoryEvolution.apply(changed, to: merged.memories, source: change)
                    results["conflict_preserves_old_fact"] = flagged.memories.contains { $0.conflictsWithMemoryID != nil } && merged.memories.allSatisfy { old in flagged.memories.contains { $0 == old } }
                } catch {
                    failure = error.localizedDescription.replacingOccurrences(of: key, with: "[hidden]")
                }
            } else {
                failure = "Saved credential unavailable; no interactive authorization requested"
            }
            let report: [String: Any] = ["checks": results, "passed": results.count == 3 && results.values.allSatisfy { $0 }, "error": failure, "user_store_writes": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("MEMORY_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}

struct DayPlanLiveAcceptanceView: View {
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_PLAN_ACCEPTANCE"] == "1" else {
                print("PLAN_ACCEPTANCE: not enabled")
                NSApplication.shared.terminate(nil)
                return
            }
            var checks: [String: Bool] = [:]
            var failure = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let todo = PersonalTodo(title: "整理产品演示材料", dueAt: nil, importance: .high, projectName: nil)
                    let context = AssistantChatWorkbenchContext.message(personalTodos: [todo], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: Date())
                    let response = try await DeepSeekClient().assistantTurn(to: [
                        .init(role: "system", content: "根据快照安排今天，只生成可核对计划提案，优先关联提供的本地待办，不编造时段。"),
                        context, .init(role: "user", content: "帮我安排今天，先准备产品演示材料，预计45分钟；生成可调整计划，确认后再保存。")
                    ], enabledSkillIDs: ["daily-planning"], apiKey: key)
                    let refs = [DayPlanReference(kind: "personal", id: todo.id.uuidString, title: todo.title)]
                    let proposals = AssistantActionParser.proposals(from: response.toolCalls, todos: [todo], projects: [], planReferences: refs)
                    checks["tool_proposal_created"] = proposals.count == 1
                    if let action = proposals.first, case let .saveDayPlan(plan, revision) = action.operation {
                        checks["source_reference_valid"] = plan.steps.contains { $0.sourceID == todo.id.uuidString && $0.sourceKind == "personal" }
                        let saved = try SavedDayPlanPolicy.saving(plan, among: [], expectedRevision: revision, references: refs, actionID: action.id)
                        checks["confirm_and_retry_are_idempotent"] = try SavedDayPlanPolicy.saving(plan, among: saved, expectedRevision: revision, references: refs, actionID: action.id) == saved
                    }
                } catch { failure = error.localizedDescription.replacingOccurrences(of: key, with: "[hidden]") }
            } else { failure = "Saved credential unavailable" }
            let report: [String: Any] = ["checks": checks, "passed": checks.count == 3 && checks.values.allSatisfy { $0 }, "error": failure, "user_store_writes": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("PLAN_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
