import Foundation

@MainActor enum TaskPreferenceAcceptance {
    static func run() async -> Bool {
        let root = LocalAssistantPaths.dataDirectory
        let resuming = CommandLine.arguments.contains { $0.hasPrefix("--resume-sandbox=") }
        var checks: [String: Bool] = [:], failure: String?, extractions = 0, raceCalls = 0
        do {
            if !resuming {
                AssistantRuntime.preferences.set(true, forKey: "autoMemoryEnabled")
                AssistantRuntime.preferences.set([String](), forKey: "dingTalkSelectedProfiles")
                try LocalSkillStore.save(AssistantSkill.defaults)
                try LocalMemoryStore.save([PreferenceContinuationAcceptance.preference(.replyLength, "brief")])
                LocalConversationStore.save([])
            }
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StageReferenceFixtureProtocol.self]
            let app = AssistantModel(dailyDataSource: LocalOnlyDailyDataSource(), services: .init(chatClient: DeepSeekClient(session: URLSession(configuration: config)), memoryExtractor: { _,_ in extractions += 1; return [] }, apiKey: { "offline-placeholder" }))
            StageReferenceFixtureProtocol.configure(target: UUID(), title: "", replyText: "模拟答复，仅核对流程。")
            let before = try Data(contentsOf: root.appendingPathComponent("memories.json"))
            func settleMemory(_ model: AssistantModel) async throws {
                for _ in 0..<200 {
                    if !model.isUpdatingMemory { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw ProjectUpdateError.invalid("fixture_memory_queue_did_not_settle")
            }
            func send(_ text: String) async throws {
                app.draft = text; app.sendMessage(); try await StageReferenceAcceptance.settle(app)
                // Attribute counts to this turn only after earlier auxiliary jobs finish.
                try await settleMemory(app)
            }
            if !resuming {
                try await send("本任务内详细回复，不要记住")
                checks["explicit_scope_active"] = TaskPreferencePolicy.state(messages: app.messages).value == "detailed"
                checks["context_sent"] = StageReferenceFixtureProtocol.captured.last?.contains("任务级临时偏好状态") == true
            } else {
                try await send("继续本任务，解释下一步")
                checks["restart_continues_task"] = TaskPreferencePolicy.state(messages: app.messages).value == "detailed" && StageReferenceFixtureProtocol.captured.last?.contains("detailed") == true
                checks["active_task_no_extraction"] = extractions == 0
                guard let originID = app.messages.first(where: { $0.isUser && TaskPreferencePolicy.declares($0.text) })?.assistantRunID,
                      let beforeEnd = app.assistantRuns.first(where: { $0.id == originID }) else { throw ProjectUpdateError.invalid("missing_preference_origin_run") }
                checks["origin_run_sent_in_context"] = StageReferenceFixtureProtocol.captured.last?.contains(originID.uuidString) == true
                app.endAssistantRun(originID)
                try await send("继续本任务，解释下一步")
                checks["ended_origin_expires_in_real_model_context"] = StageReferenceFixtureProtocol.captured.last?.contains("run_ended") == true
                let afterEnd = app.assistantRuns.first(where: { $0.id == originID })
                checks["end_preserves_original_budget_receipts"] = afterEnd?.modelRequests == beforeEnd.modelRequests && afterEnd?.readCalls == beforeEnd.readCalls && afterEnd?.tokens == beforeEnd.tokens && afterEnd?.receipts == beforeEnd.receipts
                try await send("这不是同一任务")
                checks["negative_continuation_expires"] = !TaskPreferencePolicy.state(messages: app.messages).active
                let extractionCount = extractions
                try await send("本任务内详细回复，不要保存到长期记忆")
                checks["opt_out_preserves_task_style_without_memory"] = TaskPreferencePolicy.state(messages: app.messages).value == "detailed" && extractions == extractionCount
                try await send("取消当前任务")
                try await send("继续本任务")
                checks["cancelled_rule_never_resurrected"] = !TaskPreferencePolicy.state(messages: app.messages).active && StageReferenceFixtureProtocol.captured.last?.contains("expired") == true
                try await send("本任务内简短又详细回复")
                let count = StageReferenceFixtureProtocol.captured.count
                checks["conflict_clarified_locally"] = app.messages.last?.text.contains("请明确本任务") == true
                try await send("本任务内简短回复")
                checks["explicit_resolution"] = StageReferenceFixtureProtocol.captured.count == count + 1 && TaskPreferencePolicy.state(messages: app.messages).value == "brief"
                try await send("另外问一个项目")
                checks["topic_shift_expires"] = !TaskPreferencePolicy.state(messages: app.messages).active
                let beforeRaceExtractions = extractions
                let raceConfig = URLSessionConfiguration.ephemeral; raceConfig.protocolClasses = [ExclusionFixtureProtocol.self]
                let racing = AssistantModel(dailyDataSource: LocalOnlyDailyDataSource(), services: .init(chatClient: DeepSeekClient(session: URLSession(configuration: raceConfig)), memoryExtractor: { _,_ in extractions += 1; return [] }, apiKey: { "offline-placeholder" }))
                ExclusionFixtureProtocol.configure([.init(text: "不应出现的旧偏好迟到响应")], delay: 0.2)
                racing.draft = "本任务内详细回复，不要记住"; racing.sendMessage()
                for _ in 0..<200 { if !ExclusionFixtureProtocol.captured.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
                guard let cancelledID = racing.messages.last(where: { $0.isUser })?.assistantRunID, !ExclusionFixtureProtocol.captured.isEmpty else { throw ProjectUpdateError.invalid("race_request_not_started") }
                raceCalls += ExclusionFixtureProtocol.captured.count
                racing.cancelChatRequest(); racing.endAssistantRun(cancelledID)
                ExclusionFixtureProtocol.configure([.init(text: "这是取消后的新答复")])
                racing.draft = "继续本任务，解释下一步，不要记住"; racing.sendMessage(); try await StageReferenceAcceptance.settle(racing)
                raceCalls += ExclusionFixtureProtocol.captured.count
                try await Task.sleep(for: .milliseconds(300))
                checks["cancelled_late_response_never_overwrites_new_reply"] = racing.messages.last?.text == "这是取消后的新答复" && !racing.messages.contains(where: { $0.text == "不应出现的旧偏好迟到响应" }) && racing.streamPreview.isEmpty
                checks["ended_race_origin_expired_in_new_context"] = ExclusionFixtureProtocol.captured.last?.contains("run_ended") == true && racing.assistantRuns.first(where: { $0.id == cancelledID })?.state == .cancelled
                checks["race_never_extracts_cancelled_preference"] = extractions == beforeRaceExtractions && !racing.isUpdatingMemory
                checks["race_no_business_cards"] = racing.messages.allSatisfy { ($0.pendingActions ?? []).isEmpty }

            }
            checks["memory_file_unchanged"] = try Data(contentsOf: root.appendingPathComponent("memories.json")) == before
            if !resuming { checks["declaration_no_extraction"] = extractions == 0 }
            checks["no_business_cards"] = app.messages.allSatisfy { ($0.pendingActions ?? []).isEmpty }
            if !resuming { try JSONEncoder().encode(checks).write(to: root.appendingPathComponent("task-preference-checks.json")); AssistantRuntime.preferences.synchronize() }
            else if let saved = try? JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: root.appendingPathComponent("task-preference-checks.json"))) { checks.merge(saved) { a,_ in a } }
        } catch { failure = AssistantTurnDiagnostic.category(for: error) }
        let passed = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let checkpoint = passed && !resuming
        let report: [String: Any] = ["case_id":"INT-149", "outcome":checkpoint ? "restart_required" : passed ? "pass" : "fail", "failure":failure ?? "none", "checks":checks, "processID":ProcessInfo.processInfo.processIdentifier, "sandboxPath":root.path, "processRestarted":resuming, "modelRequests":0, "externalModelRequests":0, "tokens":0, "usageComplete":true, "simulatedModelRequests":StageReferenceFixtureProtocol.captured.count + raceCalls, "automaticBusinessWrites":0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print("AGENT_SCENARIO_RESULT: " + String(decoding: data, as: UTF8.self)); fflush(stdout) }
        AgentScenarioAcceptance.didCheckpoint = checkpoint
        if !checkpoint { AssistantRuntime.finishEvaluationPreferences() }
        return passed && !checkpoint
    }
}
