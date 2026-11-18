import Foundation

@MainActor enum ConversationCorrectionAcceptance {
    static func run(_ index: Int) async -> Bool {
        let root = LocalAssistantPaths.dataDirectory
        let resuming = CommandLine.arguments.contains { $0.hasPrefix("--resume-sandbox=") }
        var checks: [String: Bool] = [:], failure: String?, checkpoint = false
        do {
            if !resuming {
                AssistantRuntime.preferences.set(false, forKey: "autoMemoryEnabled")
                AssistantRuntime.preferences.set([String](), forKey: "dingTalkSelectedProfiles")
                try LocalSkillStore.save(AssistantSkill.defaults)
                let rows = (0..<(index == 115 ? 3 : 2)).map { _ in PersonalTodo(title: "改选评审", importance: .normal) }
                try LocalTodoStore.save(rows); LocalConversationStore.save([])
            }
            var memoryExtractions = 0
            func makeApp() -> AssistantModel {
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StageReferenceFixtureProtocol.self]
                return AssistantModel(dailyDataSource: LocalOnlyDailyDataSource(), services: .init(chatClient: DeepSeekClient(session: URLSession(configuration: config)), memoryExtractor: { _,_ in memoryExtractions += 1; return [] }, apiKey: { "offline-placeholder" }))
            }
            var app = makeApp()
            let a = app.personalTodos[0], b = app.personalTodos[1]
            StageReferenceFixtureProtocol.configure(target: a.id, title: a.title, replyText: "离线拦截响应：用于验证发送的上下文，不评价模型回答质量。")
            func send(_ text: String) async throws {
                app.draft = text; app.sendMessage(); try await StageReferenceAcceptance.settle(app)
            }
            if !resuming {
                try await send("只读查看改选评审")
                checks["initial_choices_no_model"] = StageReferenceFixtureProtocol.captured.isEmpty && app.messages.last?.conversationFocus?.isChoice == true
                try await send("第二个")
                checks["selection_retains_original_list"] = app.messages.last?.conversationFocus?.references == [.personal(b.id)] && app.messages.last?.conversationFocus?.choiceReferences?.count == app.personalTodos.count
            }
            let before = try Data(contentsOf: root.appendingPathComponent("personal-todos.json"))
            if index == 113 {
                if !resuming {
                    try JSONEncoder().encode(checks).write(to: root.appendingPathComponent("correction-checks.json"))
                    AssistantRuntime.preferences.synchronize(); checkpoint = true
                } else {
                    app.showingMemoryExtraction = true
                    try await send("不是第二个，是第一个")
                    checks["correction_does_not_extract_memory"] = memoryExtractions == 0 && !app.isUpdatingMemory && app.memoryStatus.contains("未提取长期记忆")
                    app.showingMemoryExtraction = false
                    checks["actual_restart_correction_without_model"] = app.messages.last?.conversationFocus?.references == [.personal(a.id)] && StageReferenceFixtureProtocol.captured.isEmpty && app.messages.last?.text.contains("已切换讨论对象") == true
                    try await send("它的进度呢？")
                    checks["next_turn_uses_corrected_id"] = app.messages.last?.conversationFocus?.references == [.personal(a.id)] && StageReferenceFixtureProtocol.captured.count == 1 && StageReferenceFixtureProtocol.captured[0].contains("saved_conversation_focus")
                }
            } else if index == 114 {
                var rows = app.personalTodos; rows[0].isComplete = true
                try CreatedTodoAcceptance.raw(rows); app = makeApp()
                let requests = StageReferenceFixtureProtocol.captured.count
                let changedBytes = try Data(contentsOf: root.appendingPathComponent("personal-todos.json"))
                try await send("刚才那个已完成的")
                checks["local_status_qualifier_only_switches_focus"] = app.messages.last?.conversationFocus?.references == [.personal(a.id)] && StageReferenceFixtureProtocol.captured.count == requests && app.messages.last?.text.contains("没有查询远端") == true
                checks["external_source_not_enabled"] = app.selectedDingTalkProfileIDs.isEmpty
                // Fixture changes the local state explicitly; correction must not change it again.
                checks["correction_preserves_loaded_fields"] = try Data(contentsOf: root.appendingPathComponent("personal-todos.json")) == changedBytes
            } else if index == 115 {
                let requests = StageReferenceFixtureProtocol.captured.count
                try await send("换成另一个")
                checks["several_others_require_new_choice"] = app.messages.last?.conversationFocus?.isChoice == true && app.messages.last?.conversationFocus?.references == [.personal(a.id), .personal(app.personalTodos[2].id)] && StageReferenceFixtureProtocol.captured.count == requests
                try await send("第一个")
                checks["new_displayed_list_resolves_first_without_model"] = app.messages.last?.conversationFocus?.references == [.personal(a.id)] && StageReferenceFixtureProtocol.captured.count == requests && app.messages.last?.text.contains("已切换讨论对象") == true
            } else {
                let requests = StageReferenceFixtureProtocol.captured.count
                try await send("换成另一个")
                checks["unique_other_no_model"] = app.messages.last?.conversationFocus?.references == [.personal(a.id)] && StageReferenceFixtureProtocol.captured.count == requests
                var remaining = app.personalTodos; remaining.removeAll { $0.id == b.id }; try CreatedTodoAcceptance.raw(remaining)
                let changedBytes = try Data(contentsOf: root.appendingPathComponent("personal-todos.json"))
                app = makeApp()
                try await send("换成第二个")
                checks["missing_target_query_does_not_write"] = try Data(contentsOf: root.appendingPathComponent("personal-todos.json")) == changedBytes
                checks["missing_alternative_invalidates_original_numbering"] = app.messages.last?.conversationFocus == nil && app.messages.last?.text.contains("原目标已不可用") == true && StageReferenceFixtureProtocol.captured.count == requests
            }
            if index != 114 && index != 116 { checks["no_business_write"] = try Data(contentsOf: root.appendingPathComponent("personal-todos.json")) == before }
            checks["no_generated_business_cards"] = app.messages.allSatisfy { ($0.pendingActions ?? []).isEmpty }
            if resuming, let old = try? JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: root.appendingPathComponent("correction-checks.json"))) { checks.merge(old) { a,_ in a } }
        } catch { failure = error.localizedDescription }
        let passed = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["case_id": "INT-\(index)", "outcome": checkpoint ? "restart_required" : passed ? "pass" : "fail", "failure": failure ?? "none", "checks": checks, "processID": ProcessInfo.processInfo.processIdentifier, "sandboxPath": root.path, "processRestarted": resuming, "scope": "offline focus correction; production send path; intercepted streaming; no external API", "modelRequests": 0, "tokens": 0, "usageComplete": true, "simulatedModelRequests": StageReferenceFixtureProtocol.captured.count, "externalModelRequests": 0, "automaticBusinessWrites": 0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print("AGENT_SCENARIO_RESULT: " + String(decoding: data, as: UTF8.self)); fflush(stdout) }
        AgentScenarioAcceptance.didCheckpoint = checkpoint
        if !checkpoint { AssistantRuntime.finishEvaluationPreferences() }
        return passed && !checkpoint
    }
}
