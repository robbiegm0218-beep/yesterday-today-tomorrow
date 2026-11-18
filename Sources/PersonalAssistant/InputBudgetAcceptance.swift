import Foundation

@MainActor enum InputBudgetAcceptance {
    static func run() async -> Bool {
        var checks: [String: Bool] = [:], failure: String?
        do {
            AssistantRuntime.preferences.set(false, forKey: "autoMemoryEnabled")
            AssistantRuntime.preferences.set([String](), forKey: "dingTalkSelectedProfiles")
            try LocalSkillStore.save(AssistantSkill.defaults)
            LocalConversationStore.save([])
            let app = StageReferenceAcceptance.model()
            StageReferenceFixtureProtocol.configure(target: UUID(), title: "", replyText: "模拟预算核对，无业务操作。")
            func send(_ text: String) async throws { app.draft = text; app.sendMessage(); try await StageReferenceAcceptance.settle(app) }
            try await send("只读解释准备步骤，不要记住")
            let first = try AssistantTurnDiagnosticStore().load().last
            checks["normal_has_named_modules"] = first?.inputAudit?.modules.contains { $0.name == "current_request" } == true && first?.inputAudit?.modules.contains { $0.name == "workbench" } == true
            checks["per_request_actual_usage_comparison"] = first?.inputRequests?.last?.actualPromptTokens == 10 && first?.inputRequests?.last?.estimateMinusActual != nil
            let calls = StageReferenceFixtureProtocol.captured.count
            let big = "只读解释长材料，不要记住：" + String(repeating: "synthetic-material ", count: 12_000) + "材料结束"
            try await send(big)
            let blocked = try AssistantTurnDiagnosticStore().load().last
            checks["oversized_block_has_no_dispatch"] = StageReferenceFixtureProtocol.captured.count == calls && blocked?.errorCategory == "input_budget" && blocked?.inputRequests?.last?.state == "blocked_before_network"
            checks["source_preserved_and_recovery_explained"] = app.messages.contains { $0.isUser && $0.text == big } && app.messages.last?.text.contains("仅以本条为准") == true
            let oldIDs = app.messages.map(\.id)
            try await send("仅以本条为准：只读解释新的小问题，不要记住")
            let recovered = try AssistantTurnDiagnosticStore().load().last
            checks["explicit_recovery_dispatches_once"] = StageReferenceFixtureProtocol.captured.count == calls + 1 && recovered?.inputRequests?.last?.state == "completed"
            checks["recovery_keeps_authority_modules"] = recovered?.inputAudit?.modules.contains { $0.name == "workbench" } == true && recovered?.inputAudit?.modules.contains { $0.name == "dialogue_receipts_focus" } == true
            checks["history_remains_and_no_business_actions"] = Array(app.messages.prefix(oldIDs.count).map(\.id)) == oldIDs && app.messages.allSatisfy { ($0.pendingActions ?? []).isEmpty }
            checks["ordinary_history_excluded_only_by_explicit_request"] = recovered?.inputAudit?.modules.contains { $0.name == "recent_history" } == false && StageReferenceFixtureProtocol.captured.last?.contains("synthetic-material") == false
            try await send("接着解释新的小问题，不要记住")
            let continued = try AssistantTurnDiagnosticStore().load().last
            checks["ordinary_followup_keeps_explicit_boundary"] = StageReferenceFixtureProtocol.captured.count == calls + 2 && StageReferenceFixtureProtocol.captured.last?.contains("synthetic-material") == false && continued?.historySelection == "explicit_history_boundary"
            guard let runID = app.messages.last(where: { $0.isUser })?.assistantRunID else { throw ProjectUpdateError.invalid("fixture_missing_run") }
            let store = AssistantRunStore(); var rows = try store.load()
            guard let at = rows.firstIndex(where: { $0.id == runID }) else { throw ProjectUpdateError.invalid("fixture_missing_ledger") }
            rows[at].tokens = 63_500
            let original = rows[at], rowCount = rows.count
            try LocalJSONFileStore.save(rows, to: store.url)
            let resumed = StageReferenceAcceptance.model()
            let beforeResumeCalls = StageReferenceFixtureProtocol.captured.count
            resumed.continueAssistantRun(runID)
            try await StageReferenceAcceptance.settle(resumed)
            let resumedDiagnostic = try AssistantTurnDiagnosticStore().load().last
            let saved = resumed.assistantRuns.first { $0.id == runID }
            checks["remaining_ledger_budget_blocks_without_network"] = StageReferenceFixtureProtocol.captured.count == beforeResumeCalls && resumedDiagnostic?.inputRequests?.last?.remainingRunTokens == 500 && resumedDiagnostic?.inputRequests?.last?.state == "blocked_before_network"
            checks["resume_preserves_original_tokens_receipts_and_run"] = resumed.assistantRuns.count == rowCount && saved?.tokens == original.tokens && saved?.readCalls == original.readCalls && saved?.receipts == original.receipts && saved?.modelRequests == original.modelRequests + 1
            checks["normal_requests_have_joint_output_reservation"] = first?.inputRequests?.last?.remainingRunTokens == 64_000 && first?.inputRequests?.last?.effectiveOutputTokens != nil
        } catch { failure = error.localizedDescription }
        let passed = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["case_id":"INT-151", "outcome":passed ? "pass":"fail", "checks":checks, "failure":failure ?? "none", "modelRequests":0, "externalModelRequests":0, "simulatedModelRequests":StageReferenceFixtureProtocol.captured.count, "tokens":0, "usageComplete":true, "automaticBusinessWrites":0, "sandboxPath":LocalAssistantPaths.dataDirectory.path, "processID":ProcessInfo.processInfo.processIdentifier, "scope":"offline primary input audit, oversized preflight and explicit fresh-request recovery"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print("AGENT_SCENARIO_RESULT: " + String(decoding:data,as:UTF8.self)); fflush(stdout) }
        AssistantRuntime.finishEvaluationPreferences(); return passed
    }
}
