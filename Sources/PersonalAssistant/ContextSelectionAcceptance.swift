import Foundation

@MainActor enum ContextSelectionAcceptance {
    static func run() async -> Bool {
        var checks:[String:Bool]=[:], failure:String?, counts:[String:Int]=[:]
        do {
            AssistantRuntime.preferences.set(false,forKey:"autoMemoryEnabled")
            AssistantRuntime.preferences.set([String](),forKey:"dingTalkSelectedProfiles")
            try LocalSkillStore.save(AssistantSkill.defaults)
            let todos=(0..<40).map {PersonalTodo(title:"背景验收事项\($0)",dueAt:nil,importance:.normal)}
            try LocalTodoStore.save(todos);LocalConversationStore.save([])
            try LocalMemoryStore.save([AssistantMemory(content:"缓存偏好 private-cache-memory",category:"个人偏好")])
            try LocalKnowledgeStore.saveChecked([LocalKnowledgeBase(name:"合成缓存库",folderPath:"/synthetic",documents:[.init(urlPath:"/synthetic/cache.md",title:"缓存概念",content:"缓存用于复用数据。private-cache-document",indexedAt:Date(),modifiedAt:nil,fileSize:nil)])])
            let app=StageReferenceAcceptance.model()
            StageReferenceFixtureProtocol.configure(target:UUID(),title:"",replyText:"本地模拟背景选择答复。")
            let before=try Data(contentsOf:LocalAssistantPaths.dataDirectory.appendingPathComponent("personal-todos.json"))
            func send(_ text:String) async throws {app.draft=text;app.sendMessage();try await StageReferenceAcceptance.settle(app)}
            try await send("你好")
            let social=try AssistantTurnDiagnosticStore().load().last
            checks["social_uses_compact_policy"]=social?.contextSelection?.policy=="exact_social_allowlist_v1"
            checks["social_omits_three_optional_modules"]=social?.contextSelection?.omittedOptionalMessages==3
            let socialWire=StageReferenceFixtureProtocol.captured.last ?? ""
            checks["social_has_no_workbench_titles_or_ids"] = !socialWire.contains(todos[0].title) && !socialWire.contains(todos[0].id.uuidString)
            checks["social_keeps_receipts_and_current_request"]=social?.inputAudit?.modules.contains{$0.name=="dialogue_receipts_focus"}==true && social?.inputAudit?.modules.contains{$0.name=="current_request"}==true
            counts["socialRequestBytes"]=social?.inputRequests?.last?.requestBytes
            try await send("今天有哪些待办")
            let business=try AssistantTurnDiagnosticStore().load().last
            checks["business_falls_back_full"]=business?.contextSelection?.policy=="full_business_context"
            checks["business_preserves_source_title_and_id"]=StageReferenceFixtureProtocol.captured.last?.contains(todos[0].title)==true && StageReferenceFixtureProtocol.captured.last?.contains(todos[0].id.uuidString)==true
            counts["businessRequestBytes"]=business?.inputRequests?.last?.requestBytes
            checks["social_payload_smaller_than_business_fixture"]=(counts["socialRequestBytes"] ?? Int.max)<(counts["businessRequestBytes"] ?? 0)
            try await send("你好，今天几个会议")
            checks["mixed_request_is_not_social"]=(try AssistantTurnDiagnosticStore().load().last?.contextSelection?.policy)=="full_business_context"
            try await send("请解释缓存概念")
            let normal = try AssistantTurnDiagnosticStore().load().last
            let normalWire = StageReferenceFixtureProtocol.captured.last ?? ""
            checks["recall_modules_are_separate"] = normal?.inputAudit?.modules.contains{$0.name=="recalled_memory"}==true && normal?.inputAudit?.modules.contains{$0.name=="recalled_knowledge"}==true && normal?.inputAudit?.modules.contains{$0.name=="system_rules_skills"}==true
            checks["ordinary_request_keeps_retrieved_knowledge"] = normalWire.contains("private-cache-document") && !(app.messages.last?.knowledgeSources ?? []).isEmpty
            try await send("只解释通用概念：缓存是什么")
            let general = try AssistantTurnDiagnosticStore().load().last
            let generalWire = StageReferenceFixtureProtocol.captured.last ?? ""
            let json = try JSONSerialization.jsonObject(with:Data(generalWire.utf8)) as? [String:Any]
            checks["explicit_general_mode_selected"] = general?.contextSelection?.policy=="explicit_general_concept_v1"
            checks["general_omits_personal_data_and_tools"] = !generalWire.contains("private-cache-document") && !generalWire.contains("private-cache-memory") && json?["tools"]==nil
            checks["omitted_sources_not_claimed_as_citations"] = (app.messages.last?.knowledgeSources ?? []).isEmpty
            checks["general_keeps_current_request_and_receipts"] = general?.inputAudit?.modules.contains{$0.name=="current_request"}==true && general?.inputAudit?.modules.contains{$0.name=="dialogue_receipts_focus"}==true
            try await send("只解释通用概念：我的会议")
            checks["contradictory_personal_request_keeps_full_context"] = (try AssistantTurnDiagnosticStore().load().last?.contextSelection?.policy)=="full_business_context"
            let after = try Data(contentsOf:LocalAssistantPaths.dataDirectory.appendingPathComponent("personal-todos.json"))
            checks["no_business_write_or_source_change"]=app.messages.allSatisfy{($0.pendingActions ?? []).isEmpty} && after==before
        } catch {failure=error.localizedDescription}
        let passed=failure==nil && !checks.isEmpty && checks.values.allSatisfy{$0}
        let report:[String:Any]=["case_id":"INT-152","outcome":passed ? "pass":"fail","failure":failure ?? "none","checks":checks,"metrics":counts,"modelRequests":0,"externalModelRequests":0,"simulatedModelRequests":StageReferenceFixtureProtocol.captured.count,"tokens":0,"usageComplete":true,"automaticBusinessWrites":0,"sandboxPath":LocalAssistantPaths.dataDirectory.path,"processID":ProcessInfo.processInfo.processIdentifier,"scope":"offline exact social routing and full business fallback; synthetic sources; no language quality or latency claim"]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {print("AGENT_SCENARIO_RESULT: "+String(decoding:data,as:UTF8.self));fflush(stdout)}
        AssistantRuntime.finishEvaluationPreferences();return passed
    }
}
