import AppKit
import SwiftUI
import Combine

@MainActor enum ComposerPerformanceAcceptance {
    static func run() async -> Bool {
        var checks: [String: Bool] = [:], metrics: [[String: Any]] = []
        var errorText: String?
        do {
            AssistantRuntime.preferences.set(false, forKey: "autoMemoryEnabled")
            AssistantRuntime.preferences.set(true, forKey: "profileSetupComplete")
            AssistantRuntime.preferences.set([String](), forKey: "dingTalkSelectedProfiles")
            try LocalSkillStore.save(AssistantSkill.defaults)
            let model = StageReferenceAcceptance.model()
            ChatPerformanceMetrics.enabled = true
            defer { ChatPerformanceMetrics.enabled = false }
            for count in [225, 500] {
                model.messages = (0..<count).map { .init(text: $0.isMultiple(of: 2) ? "合成用户问题 \($0)：评审准备与下一步" : "## 合成答复 \($0)\n- 核对材料\n- 明确风险\n\n这是用于本地布局的合成段落。", isUser: $0.isMultiple(of: 2)) }
                ChatPerformanceMetrics.reset()
                let hostStart = ProcessInfo.processInfo.systemUptime
                let host = NSHostingView(rootView: ChatView().environmentObject(model).defaultAppStorage(AssistantRuntime.preferences))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                let hostConstructionLayoutMs = (ProcessInfo.processInfo.systemUptime - hostStart) * 1000
                try await Task.sleep(for: .milliseconds(150))
                model.draft = "合成草稿"
                host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80))
                let initiallyRenderedMessages = ChatPerformanceMetrics.renderedMessageIDs.count
                checks["initial_\(count)_message_construction_bounded"] = initiallyRenderedMessages > 0 && initiallyRenderedMessages <= ConversationHistoryWindow.pageSize
                ChatPerformanceMetrics.reset()
                var globalPublications = 0
                let subscription = model.objectWillChange.sink { globalPublications += 1 }
                var times: [Double] = []
                for index in 0..<30 {
                    let start = ProcessInfo.processInfo.systemUptime
                    model.draft = "合成草稿：" + String(repeating: "测试", count: index + 1)
                    host.layoutSubtreeIfNeeded()
                    times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    try await Task.sleep(for: .milliseconds(10))
                }
                subscription.cancel()
                times.sort()
                metrics.append(["historyCount": count, "initialVisibleLimit": min(count, ConversationHistoryWindow.pageSize), "initialRenderedDistinctMessages": initiallyRenderedMessages, "hostConstructionLayoutMs": hostConstructionLayoutMs, "updates": times.count, "globalModelPublications": globalPublications, "historyBodies": ChatPerformanceMetrics.historyBodies, "composerBodies": ChatPerformanceMetrics.composerBodies, "richTextCache": AssistantRichText.cacheStatistics, "programmaticUpdateLayoutP50ms": times[times.count / 2], "programmaticUpdateLayoutP95ms": times[Int(Double(times.count - 1) * 0.95)]])
                checks["typing_\(count)_does_not_publish_global_model"] = globalPublications == 0
                checks["composer_\(count)_updates"] = ChatPerformanceMetrics.composerBodies > 0
                checks["rich_cache_\(count)_bounded_and_reused"] = AssistantRichText.cacheStatistics["blockEntries", default: 0] <= 256 && AssistantRichText.cacheStatistics["inlineEntries", default: 0] <= 512 && AssistantRichText.cacheStatistics["blockHits", default: 0] + AssistantRichText.cacheStatistics["inlineHits", default: 0] > 0
                checks["draft_\(count)_keeps_complete_text"] = model.draft == "合成草稿：" + String(repeating: "测试", count: 30)
                window.close()
            }
            // Exercise bounded old-history hosts and reflow without a network request.
            for target in [0, 250] {
                let ids = model.messages.map(\.id)
                var page = ConversationHistoryWindow(); page.recent(in: ids)
                _ = page.reveal(ids[target], in: ids)
                ChatPerformanceMetrics.reset()
                let host = NSHostingView(rootView: ChatView(historyWindow: page).environmentObject(model).defaultAppStorage(AssistantRuntime.preferences))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(150))
                let before = ChatPerformanceMetrics.renderedMessageIDs
                model.draft = "旧历史尺寸恢复草稿🙂"
                for width in [720.0, 1080.0, 1000.0] {
                    window.setContentSize(NSSize(width: width, height: 760))
                    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80))
                }
                let after = ChatPerformanceMetrics.renderedMessageIDs
                checks["old_\(target)_construction_bounded"] = !before.isEmpty && after.count <= ConversationHistoryWindow.maximumVisible
                checks["old_\(target)_resize_keeps_message_ids"] = before == after
                checks["old_\(target)_resize_keeps_draft"] = model.draft == "旧历史尺寸恢复草稿🙂"
                metrics.append(["oldTargetIndex": target, "renderedDistinctMessages": after.count, "maximumVisible": ConversationHistoryWindow.maximumVisible, "resizeWidths": [720, 1080, 1000]])
                window.close()
            }
            StageReferenceFixtureProtocol.configure(target: UUID(), title: "", replyText: "合成发送答复")
            model.draft = "只读解释准备步骤，不要记住"; model.sendMessage()
            try await StageReferenceAcceptance.settle(model)
            checks["send_consumes_draft_once"] = model.draft.isEmpty && model.messages.filter { $0.isUser && $0.text == "只读解释准备步骤，不要记住" }.count == 1
            model.draft = "下一条未发送草稿"; model.cancelChatRequest()
            checks["cancel_preserves_unsent_draft"] = model.draft == "下一条未发送草稿"
            checks["no_business_actions"] = model.messages.allSatisfy { ($0.pendingActions ?? []).isEmpty }
        } catch { errorText = error.localizedDescription }
        let passed = errorText == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["case_id": "INT-150", "outcome": passed ? "pass" : "fail", "failure": errorText ?? "none", "checks": checks, "metrics": metrics, "sandboxPath": LocalAssistantPaths.dataDirectory.path, "processID": ProcessInfo.processInfo.processIdentifier, "modelRequests": 0, "externalModelRequests": 0, "simulatedModelRequests": StageReferenceFixtureProtocol.captured.count, "tokens": 0, "usageComplete": true, "automaticBusinessWrites": 0, "scope": "hidden NSHostingView; synthetic programmatic updates, not real keyboard/IME or end-to-end input latency"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print("AGENT_SCENARIO_RESULT: " + String(decoding: data, as: UTF8.self)); fflush(stdout) }
        AssistantRuntime.finishEvaluationPreferences(); return passed
    }
}
