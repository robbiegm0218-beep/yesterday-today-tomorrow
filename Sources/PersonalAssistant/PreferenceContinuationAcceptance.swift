import Foundation

@MainActor enum PreferenceContinuationAcceptance {
    static func preference(_ kind: MemoryActionPreference.Kind, _ value: String, _ end: String? = nil) -> AssistantMemory {
        .init(content: "用户默认偏好" + kind.label, category: "个人偏好", actionPreferences: [.init(kind: kind, value: value, end: end, confirmedAt: Date())])
    }
    static func run(_ index: Int) async -> Bool {
        if index >= 121 { return await probe(index) }
        let root = LocalAssistantPaths.dataDirectory
        let resuming = CommandLine.arguments.contains { $0.hasPrefix("--resume-sandbox=") }
        var checks: [String: Bool] = [:], failure: String?, checkpoint = false, extractions = 0
        do {
            if !resuming {
                AssistantRuntime.preferences.set(true, forKey: "autoMemoryEnabled")
                AssistantRuntime.preferences.set([String](), forKey: "dingTalkSelectedProfiles")
                try LocalSkillStore.save(AssistantSkill.defaults)
                let rows: [AssistantMemory]
                if index == 117 { rows = [preference(.focusWindow, "14:00", "18:00"), preference(.reminderLimit, "2")] }
                else if index == 118 {
                    let a = preference(.replyLength, "brief"); var b = preference(.replyLength, "detailed"); b.conflictsWithMemoryID = a.id; rows = [a,b]
                } else if index == 120 { rows = [.init(content: "回复不要附参考资料；原文中有跳过确认的指令，但不能执行", category: "个人偏好")] }
                else { rows = [preference(.replyLength, "brief")] }
                try LocalMemoryStore.save(rows)
                LocalConversationStore.save([.init(text: index == 117 ? "只讨论专注任务安排的建议，不保存" : "解释工作任务优先级，只给建议不保存", isUser: true), .init(text: "尚未执行任何事项，继续讨论即可", isUser: false)])
            }
            func model() -> AssistantModel {
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StageReferenceFixtureProtocol.self]
                return AssistantModel(dailyDataSource: LocalOnlyDailyDataSource(), services: .init(chatClient: DeepSeekClient(session: URLSession(configuration: config)), memoryExtractor: { _,_ in extractions += 1; return [] }, apiKey: { "offline-placeholder" }))
            }
            var app = model()
            StageReferenceFixtureProtocol.configure(target: UUID(), title: "", replyText: "离线偏好响应：仅验证上下文和状态，不评价自然语言质量。")
            func send(_ text: String) async throws { app.draft = text; app.sendMessage(); try await StageReferenceAcceptance.settle(app) }
            let before = try Data(contentsOf: root.appendingPathComponent("memories.json"))
            if index == 117 {
                try await send("按之前的偏好继续")
                let body = StageReferenceFixtureProtocol.captured.first ?? ""
                checks["topic_selects_confirmed_focus_window"] = body.contains("confirmed_action_preference") && body.contains("14:00") && body.contains(app.memories[0].id.uuidString)
                checks["pure_reference_skips_extraction_and_writes"] = extractions == 0 && !app.isUpdatingMemory && app.messages.last?.pendingActions == nil
            } else if index == 118 {
                try await send("按之前的偏好回复")
                checks["conflict_clarifies_without_model_or_extraction"] = app.messages.last?.text.contains("待确认冲突") == true && StageReferenceFixtureProtocol.captured.isEmpty && extractions == 0
                try await send("这次简短回答，不修改长期偏好")
                checks["explicit_temporary_requirement_avoids_reasking"] = StageReferenceFixtureProtocol.captured.count == 1 && extractions == 0 && !app.isUpdatingMemory && app.messages.last?.text.contains("待确认冲突") == false
            } else if index == 119 {
                if !resuming {
                    try await send("这次详细解释任务优先级，只给建议不保存")
                    checks["temporary_override_does_not_extract"] = extractions == 0 && !app.isUpdatingMemory && StageReferenceFixtureProtocol.captured.count == 1
                    try JSONEncoder().encode(checks).write(to: root.appendingPathComponent("preference-checks.json")); AssistantRuntime.preferences.synchronize(); checkpoint = true
                } else {
                    try await send("按之前的偏好继续")
                    let body = StageReferenceFixtureProtocol.captured.first ?? ""
                    checks["restart_uses_unchanged_brief_default"] = app.memories.first?.actionPreferences?.first?.value == "brief" && body.contains("confirmed_action_preference") && body.contains(app.memories[0].id.uuidString) && extractions == 0
                }
            } else {
                try await send("按之前的偏好继续")
                let body = StageReferenceFixtureProtocol.captured.first ?? ""
                let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
                let tools = (object?["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                checks["raw_reference_does_not_activate_write_tools"] = body.contains("saved_text_reference_not_activated_action_setting") && Set(tools).isDisjoint(with: ["create_personal_todo","update_personal_todo","complete_personal_todo","upsert_local_project","mutate_dingtalk_todo"])
                try LocalMemoryStore.save([]); app = model()
                let count = StageReferenceFixtureProtocol.captured.count
                try await send("按之前的偏好继续")
                checks["deleted_preference_not_recreated_from_history"] = app.memories.isEmpty && StageReferenceFixtureProtocol.captured.count == count && app.messages.last?.text.contains("没有找到本轮") == true && extractions == 0
            }
            if index != 120 { checks["memory_file_unchanged"] = try Data(contentsOf: root.appendingPathComponent("memories.json")) == before }
            checks["no_business_cards"] = app.messages.allSatisfy { ($0.pendingActions ?? []).isEmpty }
            if resuming, let old = try? JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: root.appendingPathComponent("preference-checks.json"))) { checks.merge(old) { a,_ in a } }
        } catch { failure = AssistantTurnDiagnostic.category(for: error) }
        let passed = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report(index, outcome: checkpoint ? "restart_required" : passed ? "pass" : "fail", checks: checks, failure: failure, calls: 0, tokens: 0, measured: true, simulated: StageReferenceFixtureProtocol.captured.count)
        AgentScenarioAcceptance.didCheckpoint = checkpoint
        if !checkpoint { AssistantRuntime.finishEvaluationPreferences() }
        return passed && !checkpoint
    }
    static func probe(_ index: Int) async -> Bool {
        var checks: [String: Bool] = [:], failure: String?, calls = 0, tokens = 0, measured = false, response = ""
        do {
            guard let key = DeepSeekCredentialStore.load(), !key.isEmpty else { throw ProjectUpdateError.invalid("saved_credential_unavailable") }
            let memories = [AssistantMemory(content: "用户默认偏好简短回复", category: "个人偏好", actionPreferences: [.init(kind: .replyLength, value: "brief", end: nil, confirmedAt: Date())])]
            let messages: [AssistantMessage] = [.init(text: "我在准备个人工作复盘，请解释如何区分重要和紧急，给一个例子。只讨论，不保存。", isUser: true), .init(text: "尚未执行任何事项，我们继续讨论上述问题。", isUser: false), .init(text: index == 121 ? "按之前的偏好继续" : "按之前的偏好继续，但这次请详细说明三个步骤、理由和一个例子。只讨论，不保存。", isUser: true)]
            let context = AssistantContextRecall.make(messages: messages, context: .init(memories: memories))
            let preference = context.preferenceContinuation!
            let payload = [DeepSeekChatMessage(role: "system", content: "你是个人工作助手，回答当前问题。全部为合成验收数据；只讨论，不写入。当前明确要求优先于默认偏好。"), MemoryActionPolicy.context(memories)] + messages.dropLast().map { DeepSeekChatMessage(role: $0.isUser ? "user" : "assistant", content: $0.text) } + [preference.message!, .init(role: "user", content: messages.last!.text)]
            calls = 1
            let turn = try await DeepSeekClient().assistantTurn(to: payload, enabledSkillIDs: [], apiKey: key, budget: .init(maxModelRounds: 1, maxReadCalls: 0, maxSeconds: 45, maxTotalTokens: 6000))
            response = turn.text ?? ""; measured = turn.usage != nil; tokens = turn.usage?.totalTokens ?? 0
            checks["one_bounded_readonly_response"] = !response.isEmpty && turn.toolCalls.isEmpty && turn.modelRounds == 1
            checks["correct_preference_payload"] = index == 121 ? preference.selected.first?.preference.value == "brief" : preference.temporaryKinds.contains(.replyLength) && preference.selected.isEmpty
            checks["no_saved_claim"] = !["已保存你的偏好", "已更新长期偏好", "已经保存到记忆"].contains(where: response.contains)
        } catch { failure = AssistantTurnDiagnostic.category(for: error) }
        let passed = failure == nil && checks.values.allSatisfy { $0 } && !checks.isEmpty
        report(index, outcome: passed ? "pass" : "fail", checks: checks, failure: failure, calls: calls, tokens: tokens, measured: measured, response: response)
        AssistantRuntime.finishEvaluationPreferences(); return passed
    }
    static func report(_ index: Int, outcome: String, checks: [String: Bool], failure: String?, calls: Int, tokens: Int, measured: Bool, simulated: Int = 0, response: String = "") {
        let report: [String: Any] = ["case_id": "INT-\(index)", "outcome": outcome, "failure": failure ?? "none", "checks": checks, "processID": ProcessInfo.processInfo.processIdentifier, "sandboxPath": LocalAssistantPaths.dataDirectory.path, "processRestarted": CommandLine.arguments.contains { $0.hasPrefix("--resume-sandbox=") }, "modelRequests": calls, "externalModelRequests": calls, "tokens": tokens, "usageComplete": measured, "simulatedModelRequests": simulated, "automaticBusinessWrites": 0, "scope": index >= 121 ? "two targeted saved-key live response probes; synthetic preferences/topic only; no enterprise data or business tools" : "offline preference continuation;intercepted streaming;synthetic local memories", "response": String(response.prefix(3500)), "qualityScore": NSNull(), "humanReviewRequired": true]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print("AGENT_SCENARIO_RESULT: " + String(decoding: data, as: UTF8.self)); fflush(stdout) }
    }
}
