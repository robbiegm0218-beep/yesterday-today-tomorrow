import SwiftUI

struct DingTalkExtensionsAcceptanceView: View {
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_DG030405_READONLY_ACCEPTANCE"] == "1" else { NSApplication.shared.terminate(nil); return }
            var checks: [String: Bool] = [:]; var error = ""
            do {
                let selected = Set(AssistantRuntime.preferences.stringArray(forKey: "dingTalkSelectedProfiles") ?? [])
                let profiles = try await Task.detached { try DingTalkContentService().profiles(selectedIDs: selected) }.value
                guard profiles.count == 1, profiles[0].corpName == "上海易碳数字科技有限公司" else { throw DingTalkContentError.selectOrganization }
                let profile = profiles[0]
                let spaces = try await Task.detached { try DingTalkResearchService().spaces(profile: profile, selected: selected) }.value
                let matches = spaces.filter { $0.name == "产品组文件管理" }; guard matches.count == 1 else { throw DingTalkContentError.invalidResponse }
                let space = matches[0]
                let result = try await Task.detached { try DingTalkResearchService().searchAcrossWiki(space: space, query: "产品组的正确食用方式", selected: selected) }.value
                checks["cross_directory_search_complete"] = result.complete && !result.items.isEmpty
                checks["every_result_workspace_verified"] = result.items.allSatisfy { $0.containerID == space.workspaceID && $0.profile.id == profile.id }
                checks["listener_still_disabled"] = try !DingTalkEventStore().settings().enabled
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-im-acceptance-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let at = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
                let settings = DingTalkEventSettings(enabled: true, profile: profile)
                let raw: [String: Any] = ["type":"user_im_message_receive_at","event_id":"synthetic-event","subscribe_id":"synthetic-subscription","message_id":"synthetic-message","conversation_id":"synthetic-conversation","content":"【隔离验收】仅本机合成消息，不是真实钉钉消息","sender":"合成来源","event_time":at.timeIntervalSince1970 * 1000]
                let frame = try JSONSerialization.data(withJSONObject: raw)
                let event = try DingTalkEventPolicy.parse(frame, settings: settings, subscriptionID: "synthetic-subscription", now: at)
                let store = DingTalkEventStore(directory: root)
                try store.update { $0 = try DingTalkEventPolicy.ingest(event, state: $0) }
                try store.update { $0 = try DingTalkEventPolicy.ingest(event, state: $0) }
                checks["duplicate_event_persists_once"] = try store.state().events.count == 1
                let candidate = DingTalkEventPolicy.candidate(event, settings: settings, selected: selected, now: at)
                guard let candidate else { throw DingTalkContentError.invalidResponse }
                let reminder = ActiveReminderStore(directory: root); try reminder.setEnabled(true)
                let transport = DingTalkAcceptanceNotifications()
                let runner = ActiveReminderRunner()
                for _ in 0..<2 {
                    _ = await runner.synchronize(store: reminder, transport: transport, limit: 1, assistantName: "验收", force: true, clock: { at }, fingerprint: { "synthetic" }, load: { .init(candidates: [candidate]) })
                }
                let submitted = await transport.count(); let consumed = try reminder.state().records.filter(\.consumesQuota).count
                checks["event_uses_existing_quota_without_duplicate"] = submitted == 1 && consumed == 1
                let quiet = Calendar.current.date(bySettingHour: 12, minute: 45, second: 0, of: at)!
                _ = await runner.synchronize(store: reminder, transport: transport, limit: 5, force: true, clock: { quiet }, fingerprint: { "synthetic-quiet" }, load: { .init(candidates: [candidate]) })
                checks["quiet_hours_do_not_submit"] = await transport.count() == 1
                if let path = ProcessInfo.processInfo.environment["YUAN_DG0304_QA_EVENT_FIXTURE"] {
                    var fixture = DingTalkEventState(); fixture.events = [event]
                    try JSONEncoder().encode(fixture).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
                print("DG0305_REAL_RESULTS: \(result.returnedCount)")
            } catch let issue { error = issue.localizedDescription }
            let report: [String: Any] = ["checks":checks,"passed":checks.count == 6 && checks.values.allSatisfy { $0 },"error":error,"real_subscriptions_created":0,"enterprise_writes":0,"user_store_writes":0,"notification_transport":"in-memory"]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("DG030405_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
private actor DingTalkAcceptanceNotifications: ActiveNotificationTransport {
    var ids = Set<String>(); var submissions = 0
    func allowed() async -> Bool { true }
    func pendingIDs() async -> Set<String> { ids }
    func deliveredIDs() async -> Set<String> { [] }
    func submit(id: String, title: String, body: String) async throws { ids.insert(id); submissions += 1 }
    func remove(_ ids: [String]) async { self.ids.subtract(ids) }
    func count() -> Int { submissions }
}
