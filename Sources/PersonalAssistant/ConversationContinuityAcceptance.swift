import Foundation

/// Exercises production send/recall/save paths with intercepted streaming only.
@MainActor enum ConversationContinuityAcceptance {
    static func run(_ index: Int) async -> Bool {
        let root = LocalAssistantPaths.dataDirectory
        let resuming = CommandLine.arguments.contains { $0.hasPrefix("--resume-sandbox=") }
        var checks: [String: Bool] = [:], failure: String?, checkpoint = false
        do {
            if !resuming {
                AssistantRuntime.preferences.set(false, forKey: "autoMemoryEnabled")
                AssistantRuntime.preferences.set([String](), forKey: "dingTalkSelectedProfiles")
                try LocalSkillStore.save(AssistantSkill.defaults)
                let a = PersonalTodo(title: "连续对话评审", importance: .normal)
                let b = PersonalTodo(title: index == 109 ? "另一项任务" : "连续对话评审", importance: .normal)
                try LocalTodoStore.save([a,b]); LocalConversationStore.save([])
            }
            let app = StageReferenceAcceptance.model()
            let a = app.personalTodos[0], b = app.personalTodos.last!
            StageReferenceFixtureProtocol.configure(target: a.id, title: a.title)
            let before = try Data(contentsOf: root.appendingPathComponent("personal-todos.json"))
            func send(_ text: String) async throws {
                app.draft = text; app.sendMessage(); try await StageReferenceAcceptance.settle(app)
            }
            if index == 109 {
                try await send("查看连续对话评审的当前状态")
                for text in ["它的进度呢？", "刚才那个的下一步呢？", "它呢"] {
                    try await send(text)
                    checks["focus_" + text] = app.messages.last?.conversationFocus?.references == [.personal(a.id)]
                }
                checks["four_intercepted_turns_same_id"] = StageReferenceFixtureProtocol.captured.count == 4 && StageReferenceFixtureProtocol.captured.last?.contains("saved_conversation_focus") == true
            } else if index == 110 {
                if !resuming {
                    try await send("查看连续对话评审的当前状态")
                    checks["clarification_has_numbered_ids_without_model"] = app.messages.last?.conversationFocus?.references == [.personal(a.id), .personal(b.id)] && app.messages.last?.text.contains("2. 连续对话评审") == true && StageReferenceFixtureProtocol.captured.isEmpty
                    try JSONEncoder().encode(checks).write(to: root.appendingPathComponent("continuity-checks.json"))
                    AssistantRuntime.preferences.synchronize(); checkpoint = true
                } else {
                    try await send("第二个")
                    checks["restart_selects_original_second_id"] = app.messages.last?.conversationFocus?.references == [.personal(b.id)]
                    checks["request_carries_pending_intent_and_selection"] = StageReferenceFixtureProtocol.captured.count == 1 && StageReferenceFixtureProtocol.captured[0].contains("continuation_request") && StageReferenceFixtureProtocol.captured[0].contains("saved_numbered_choice")
                    try await send("它的进度呢？")
                    checks["selected_focus_continues"] = app.messages.last?.conversationFocus?.references == [.personal(b.id)] && StageReferenceFixtureProtocol.captured.count == 2
                }
            } else if index == 111 {
                try await send("查看连续对话评审的当前状态")
                app.selectedDingTalkProfileIDs = ["unselected-fixture:self"]
                try await send("第二个")
                checks["scope_change_stops_before_model"] = StageReferenceFixtureProtocol.captured.isEmpty && app.messages.last?.conversationFocus == nil && app.messages.last?.text.contains("来源范围发生变化") == true
            } else {
                try await send("查看连续对话评审的当前状态")
                try await send("第九个")
                checks["out_of_range_not_guessed"] = StageReferenceFixtureProtocol.captured.isEmpty && app.messages.last?.text.contains("编号不在") == true
                try await send("换个话题，解释黑洞")
                checks["new_topic_drops_choices"] = app.messages.last?.conversationFocus == nil
                let count = StageReferenceFixtureProtocol.captured.count
                try await send("第二个")
                checks["cannot_select_after_topic_switch"] = StageReferenceFixtureProtocol.captured.count == count && app.messages.last?.text.contains("没有可用的编号") == true
            }
            checks["source_unchanged_no_cards"] = try Data(contentsOf: root.appendingPathComponent("personal-todos.json")) == before && app.messages.allSatisfy { ($0.pendingActions ?? []).isEmpty }
            if resuming, let old = try? JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: root.appendingPathComponent("continuity-checks.json"))) { checks.merge(old) { a,_ in a } }
        } catch { failure = error.localizedDescription }
        let passed = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["case_id": "INT-\(index)", "outcome": checkpoint ? "restart_required" : passed ? "pass" : "fail", "failure": failure ?? "none", "checks": checks, "processID": ProcessInfo.processInfo.processIdentifier, "sandboxPath": root.path, "processRestarted": resuming, "scope": "offline conversation continuity, production send path, intercepted streaming; no external model or enterprise API", "modelRequests": 0, "tokens": 0, "usageComplete": true, "simulatedModelRequests": StageReferenceFixtureProtocol.captured.count, "externalModelRequests": 0, "automaticBusinessWrites": 0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print("AGENT_SCENARIO_RESULT: " + String(decoding: data, as: UTF8.self)); fflush(stdout) }
        AgentScenarioAcceptance.didCheckpoint = checkpoint
        if !checkpoint { AssistantRuntime.finishEvaluationPreferences() }
        return passed && !checkpoint
    }
}
