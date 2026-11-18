import Foundation

final class CardAcceptanceDataSource: DailyDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func loadSnapshot(at date: Date) async throws -> DailyDataSnapshot {
        lock.withLock { count += 1 }
        return try await LocalOnlyDailyDataSource().loadSnapshot(at:date)
    }
}

@MainActor enum TodoCardAcceptance {
    static func rows(ambiguous: Bool = false) -> [PersonalTodo] {
        let a = PersonalTodo(title:"v1_星河原型修改完善",importance:.high)
        var b = PersonalTodo(title:"继续星河原型方案设计",importance:.normal);b.isComplete = !ambiguous
        return [a,b,PersonalTodo(title:"另一条界面验收事项",importance:.normal)]
    }
    static func legacy() -> [AssistantMessage] {
        [.init(text:"优先候选把星河原型状态变更为完成",isUser:true),.init(text:"如果是本地v1_星河原型修改完善，我生成确认卡",isUser:false),.init(text:"是本地这个",isUser:true),.init(text:"你确认一下我再生成卡片",isUser:false),.init(text:"对",isUser:true),.init(text:"我现在补上确认卡",isUser:false)]
    }
    static func card(_ app: AssistantModel, target: UUID) -> (UUID,UUID)? {
        for message in app.messages.reversed() { for action in message.pendingActions ?? [] {
            if case let .completeTodo(id) = action.operation, id == target, action.status == .pending { return (message.id,action.id) }
        } };return nil
    }
    static func run(_ index: Int) async -> Bool {
        let live = index == 133, resume = CommandLine.arguments.contains { $0.hasPrefix("--resume-sandbox=") }, root = LocalAssistantPaths.dataDirectory
        var checks: [String:Bool] = [:], failure: String?, checkpoint = false, extractions = 0, external = 0, tokens = 0, measured = true
        var liveApp: AssistantModel?
        do {
            if !resume {
                AssistantRuntime.preferences.set(true,forKey:"autoMemoryEnabled");AssistantRuntime.preferences.set([String](),forKey:"dingTalkSelectedProfiles");try LocalSkillStore.save(AssistantSkill.defaults)
                try LocalTodoStore.save(rows(ambiguous:index == 131));try LocalMemoryStore.save([])
                LocalConversationStore.save(index == 129 || index == 131 || live ? legacy() : [])
            }
            let key: String
            if live { guard let saved = DeepSeekCredentialStore.load(),!saved.isEmpty else { throw ProjectUpdateError.invalid("saved_credential_unavailable") };key = saved } else { key = "offline-placeholder" }
            let dataSource = CardAcceptanceDataSource()
            func model() -> AssistantModel {
                let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [SemanticReferenceFixtureProtocol.self]
                return AssistantModel(dailyDataSource:dataSource,services:.init(chatClient:live ? DeepSeekClient() : DeepSeekClient(session:URLSession(configuration:config)),memoryExtractor:{ _,_ in extractions += 1;return [] },apiKey:{ key }))
            }
            var app = model();if live { liveApp = app };let a = app.personalTodos[0], c = app.personalTodos[2]
            let query = try JSONSerialization.data(withJSONObject:["query":"星河原型","state":"all"])
            SemanticReferenceFixtureProtocol.configure(.init(id:"find-target",function:.init(name:"find_matter",arguments:String(decoding:query,as:UTF8.self))))
            func send(_ text: String) async throws {
                app.draft = text;app.sendMessage()
                if live {
                    for _ in 0..<9500 { if !app.isSending && !app.isRefreshing { return };try await Task.sleep(for:.milliseconds(10)) }
                    app.cancelChatRequest();throw ProjectUpdateError.invalid("live_card_did_not_settle")
                } else { try await StageReferenceAcceptance.settle(app) }
            }
            let before = try Data(contentsOf:root.appendingPathComponent("personal-todos.json"))
            if index == 129 || live {
                if !resume {
                    try await send("没弹出卡片，你直接标记完成")
                    checks["actual_pending_card_not_plain_text"] = card(app,target:a.id) != nil && app.messages.last?.pendingActions?.count == 1 && app.messages.last?.todoConfirmationRequest?.boundTargetID == a.id
                    checks["one_lookup_and_no_extra_oral_confirmation"] = app.assistantRuns.last?.modelRequests == 1 && app.assistantRuns.last?.readCalls == 1
                    if !live {try JSONEncoder().encode(checks).write(to:root.appendingPathComponent("card-checks.json"));AssistantRuntime.preferences.synchronize();checkpoint = true}
                } else {
                    let count = app.messages.flatMap { $0.pendingActions ?? [] }.count
                    try await send("对")
                    checks["restart_ack_does_not_duplicate_or_confirm"] = card(app,target:a.id) != nil && app.messages.flatMap { $0.pendingActions ?? [] }.count == count && SemanticReferenceFixtureProtocol.captured.isEmpty && app.messages.last?.text.contains("原卡片") == true
                }
            } else if index == 130 {
                try await send("请把本地待办「" + a.title + "」标记完成")
                checks["named_target_produces_card_without_model"] = card(app,target:a.id) != nil && SemanticReferenceFixtureProtocol.captured.isEmpty
                try await send("对")
                checks["chat_yes_is_not_button_confirmation"] = !app.personalTodos[0].isComplete && app.messages.flatMap { $0.pendingActions ?? [] }.count == 1
                try await send("请把本地待办「" + c.title + "」标记完成")
                checks["second_explicit_target_has_its_own_card"] = card(app,target:c.id) != nil && app.messages.flatMap { $0.pendingActions ?? [] }.count == 2 && SemanticReferenceFixtureProtocol.captured.isEmpty
            } else if index == 131 {
                try await send("没弹出卡片，你直接标记完成")
                checks["ambiguous_lookup_requires_selection"] = app.messages.last?.pendingActions == nil && app.messages.last?.conversationFocus?.isChoice == true
                try await send("第二个")
                let b = app.personalTodos[1]
                checks["explicit_choice_generates_bound_card"] = card(app,target:b.id) != nil && app.messages.last?.todoConfirmationRequest?.boundTargetID == b.id && SemanticReferenceFixtureProtocol.captured.count == 1
                var remaining = app.personalTodos.filter { $0.id != b.id };let replacement = PersonalTodo(title:b.title,importance:.normal);remaining.append(replacement);try CreatedTodoAcceptance.raw(remaining)
                let changed = try Data(contentsOf:root.appendingPathComponent("personal-todos.json"));app = model()
                try await send("对")
                checks["missing_bound_id_does_not_retarget_same_title"] = app.messages.last?.pendingActions == nil && app.messages.last?.text.contains("原目标") == true && app.personalTodos.first(where:{$0.id==replacement.id})?.isComplete == false && SemanticReferenceFixtureProtocol.captured.count == 1
                checks["missing_check_does_not_write"] = try Data(contentsOf:root.appendingPathComponent("personal-todos.json")) == changed
            } else {
                try await send("请把本地待办「" + a.title + "」标记完成")
                let first = card(app,target:a.id)!
                app.dismissPendingAction(messageID:first.0,actionID:first.1)
                try await send("对");try await send("对")
                checks["dismissed_card_not_revived_by_yes"] = card(app,target:a.id) == nil && app.messages.flatMap { $0.pendingActions ?? [] }.count == 1 && SemanticReferenceFixtureProtocol.captured.isEmpty
                app.selectedDingTalkProfileIDs = ["changed:self"];try await send("对")
                checks["changed_scope_does_not_recover_legacy_intent"] = app.messages.last?.pendingActions == nil && SemanticReferenceFixtureProtocol.captured.isEmpty
            }
            if index != 131 { checks["source_unchanged_without_card_button"] = try Data(contentsOf:root.appendingPathComponent("personal-todos.json")) == before }
            checks["local_card_does_not_refresh_remote_workbench"] = dataSource.calls == 0
            checks["no_automatic_memory_extraction"] = extractions == 0 && !app.isUpdatingMemory
            if live { external = app.assistantRuns.reduce(0) { $0 + $1.modelRequests };tokens = app.assistantRuns.reduce(0) { $0 + $1.tokens };measured = app.assistantRuns.allSatisfy(\.usageComplete) }
            if resume,let old = try? JSONDecoder().decode([String:Bool].self,from:Data(contentsOf:root.appendingPathComponent("card-checks.json"))) { checks.merge(old) { a,_ in a } }
        } catch { failure = AssistantTurnDiagnostic.category(for:error) }
        if live, let app = liveApp { external = app.assistantRuns.reduce(0) { $0 + $1.modelRequests };tokens = app.assistantRuns.reduce(0) { $0 + $1.tokens };measured = app.assistantRuns.allSatisfy(\.usageComplete) }
        let pass = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let report: [String:Any] = ["case_id":"INT-\(index)","outcome":checkpoint ? "restart_required" : pass ? "pass" : "fail","checks":checks,"failure":failure ?? "none","processID":ProcessInfo.processInfo.processIdentifier,"sandboxPath":root.path,"processRestarted":resume,"modelRequests":external,"externalModelRequests":external,"tokens":tokens,"usageComplete":measured,"simulatedModelRequests":live ? 0 : SemanticReferenceFixtureProtocol.captured.count,"automaticBusinessWrites":0,"scope":live ? "full production app chat/card path,one live model lookup,synthetic tasks/history only,no confirm button or enterprise access" : "offline completion card production path,intercepted lookup,synthetic local data","qualityScore":NSNull(),"humanReviewRequired":true]
        if let data = try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) { print("AGENT_SCENARIO_RESULT: " + String(decoding:data,as:UTF8.self));fflush(stdout) }
        AgentScenarioAcceptance.didCheckpoint = checkpoint;if !checkpoint { AssistantRuntime.finishEvaluationPreferences() };return pass && !checkpoint
    }
}
