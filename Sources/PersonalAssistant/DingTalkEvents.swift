import Foundation
import CryptoKit

struct DingTalkEventSettings: Codable, Equatable {
    var enabled = false
    var profile: DingTalkProfile? = nil
    var kind = "at-me"
    var target = ""
    var keyword = ""
    var notify = true
    var eventKey: String { ["at-me":"user_im_message_receive_at", "group":"user_im_message_receive_group", "sender":"user_im_message_receive_user"][kind] ?? "" }
    var scopeKey: String { DingTalkResearchItem.digest([profile?.id ?? "", kind, target, keyword]) }
    var valid: Bool {
        !enabled || (profile.map { !$0.corpID.isEmpty && !$0.userID.isEmpty } == true && ["at-me", "group", "sender"].contains(kind) && target.count <= 200 && keyword.count <= 200 &&
            (kind == "at-me" ? target.isEmpty : !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }
    func arguments(duration: String? = nil, dryRun: Bool = false) throws -> [String] {
        guard valid, let profile else { throw DingTalkContentError.selectOrganization }
        var args = ["event", "+listen-im", "--kind", kind, "--events", "message", "--profile", profile.id, "--format", "ndjson"]
        if kind == "group" { args += ["--chat-query", target] }
        if kind == "sender" { args += ["--user-query", target] }
        if !keyword.isEmpty { args += ["--query", keyword] }
        if let duration { args += ["--duration", duration] }
        if dryRun { args += ["--dry-run"] }
        return args
    }
}
struct DingTalkReceivedEvent: Identifiable, Codable, Equatable {
    let id: String
    let scopeKey: String
    let eventID: String
    let subscriptionID: String
    let item: DingTalkResearchItem
    let receivedAt: Date
    var dismissed = false
}
struct DingTalkEventBudget: Codable {
    var attempts = 0
    var lastFailure: Date?
    var nextAllowedAt: Date?
    var retryability = "unknown"
    var continuesAutomaticRecovery: Bool { retryability == "true" }
    func allows(at now: Date) -> Bool {
        let limit = retryability == "false" ? 1 : retryability == "true" ? 3 : 2
        guard nextAllowedAt.map({ now >= $0 }) ?? true else { return false }
        if let failure = lastFailure, now.timeIntervalSince(failure) >= 86400 { return true }
        return attempts < limit
    }
}
struct DingTalkEventState: Codable {
    var status = "disabled"
    var scopeKey = ""
    var subscriptionID: String?
    var readyAt: Date?
    var heartbeatAt: Date?
    var lastEventAt: Date?
    var error: String?
    var rejectedLines = 0
    var events: [DingTalkReceivedEvent] = []
    var budgets: [String: DingTalkEventBudget] = [:]
}
enum DingTalkEventPolicy {
    static let statuses = Set(["disabled", "starting", "ready", "stopping", "stopped", "retry-wait", "paused", "failed"])
    static func validate(_ state: DingTalkEventState) throws {
        guard statuses.contains(state.status), state.events.count <= 200, Set(state.events.map(\.id)).count == state.events.count,
              state.budgets.count <= 30, state.budgets.allSatisfy({ $0.key.count == 64 && (0...3).contains($0.value.attempts) && ["true", "false", "unknown"].contains($0.value.retryability) }),
              state.events.allSatisfy({ !$0.eventID.isEmpty && $0.eventID.count <= 1_000 && !$0.subscriptionID.isEmpty && $0.subscriptionID.count <= 1_000 && $0.scopeKey.count == 64 && $0.receivedAt.timeIntervalSince1970.isFinite && $0.id == "im-" + DingTalkResearchItem.digest([$0.item.profile.id, $0.item.containerID, $0.item.sourceID]) && DingTalkResearchPolicy.valid($0.item) && $0.item.kind == "message" }),
              (state.error?.count ?? 0) <= 300 else { throw ProjectUpdateError.invalid("事件监听记录无效，已暂停以保留原数据。") }
    }
    static func readySubscription(_ line: String) -> String? {
        guard line.hasPrefix("[event] ready event_key="), let range = line.range(of: "subscribe_id=") else { return nil }
        let id = String(line[range.upperBound...].prefix { !$0.isWhitespace })
        return id.isEmpty || id.count > 1_000 ? nil : id
    }
    static func parse(_ line: Data, settings: DingTalkEventSettings, subscriptionID: String, now: Date) throws -> DingTalkReceivedEvent {
        guard line.count <= 262_144, settings.valid, settings.enabled, let profile = settings.profile,
              let raw = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = raw["type"] as? String, type == settings.eventKey,
              raw["subscribe_id"] as? String == subscriptionID,
              let eventID = raw["event_id"] as? String, !eventID.isEmpty, eventID.count <= 1_000,
              let messageID = raw["message_id"] as? String, !messageID.isEmpty,
              let cid = raw["conversation_id"] as? String, !cid.isEmpty,
              let content = raw["content"] as? String,
              let sourceTime = DingTalkJSON.date(raw["event_time"] ?? raw["timestamp"]) ?? DingTalkResearchService.messageDate(raw["create_time"]) else { throw DingTalkContentError.invalidResponse }
        guard sourceTime <= now.addingTimeInterval(300) else { throw DingTalkContentError.invalidResponse }
        let sender = raw["sender"] as? String ?? "发送者未提供"
        let item = DingTalkResearchItem(kind: "message", profile: profile, sourceID: messageID, containerID: cid, title: String(sender.prefix(200)), excerpt: String(content.prefix(2_000)), sourceURL: nil, sourceTime: sourceTime,
            fingerprint: DingTalkResearchItem.digest([content, sender, String(sourceTime.timeIntervalSince1970)]))
        let id = "im-" + DingTalkResearchItem.digest([profile.id, cid, messageID])
        return .init(id: id, scopeKey: settings.scopeKey, eventID: eventID, subscriptionID: subscriptionID, item: item, receivedAt: now)
    }
    static func ingest(_ event: DingTalkReceivedEvent, state: DingTalkEventState) throws -> DingTalkEventState {
        var next = state
        // Reconnect/subscription IDs do not change identity. Do not alert twice.
        if next.events.contains(where: { $0.id == event.id }) { return next }
        next.events.insert(event, at: 0); next.events = Array(next.events.prefix(200)); next.lastEventAt = event.receivedAt
        try validate(next); return next
    }
    static func candidate(_ event: DingTalkReceivedEvent, settings: DingTalkEventSettings, selected: Set<String>, now: Date) -> ActiveReminderCandidate? {
        guard settings.enabled, settings.notify, settings.scopeKey == event.scopeKey, !event.dismissed,
              selected.contains(event.item.profile.id), let time = event.item.sourceTime,
              now.timeIntervalSince(time) >= -300, now.timeIntervalSince(time) <= ActiveReminderPolicy.grace,
              now.timeIntervalSince(event.receivedAt) <= ActiveReminderPolicy.grace else { return nil }
        return .init(id: event.id, title: "钉钉消息有新动态", body: "\(event.item.profile.corpName)的关注消息有新动态，可在工作台查看。", kind: "dingtalk-im", followupAt: event.receivedAt)
    }
}
struct DingTalkEventStore {
    var directory = LocalAssistantPaths.dataDirectory
    var settingsURL: URL { directory.appendingPathComponent("dingtalk-event-settings.json") }
    var stateURL: URL { directory.appendingPathComponent("dingtalk-event-state.json") }
    func settings() throws -> DingTalkEventSettings {
        let value: DingTalkEventSettings = try read(settingsURL, fallback: .init())
        guard value.valid else { throw ProjectUpdateError.invalid("事件监听配置无效，未建立连接。") }; return value
    }
    func state() throws -> DingTalkEventState { let state: DingTalkEventState = try read(stateURL, fallback: .init()); try DingTalkEventPolicy.validate(state); return state }
    private func read<T: Decodable>(_ url: URL, fallback: T) throws -> T {
        if !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) { return fallback }
        guard let value = LocalJSONFileStore.load(from: url, as: T.self) else { throw ProjectUpdateError.invalid("事件监听记录无法读取，已暂停；原文件保留。") }
        return value
    }
    func setSettings(_ settings: DingTalkEventSettings) throws { guard settings.valid else { throw DingTalkContentError.invalidResponse }; _ = try self.settings(); try LocalJSONFileStore.save(settings, to: settingsURL) }
    func update(_ body: (inout DingTalkEventState) throws -> Void) throws {
        var acquired: BackgroundPlanLease?
        for _ in 0..<20 {
            acquired = try BackgroundPlanLease(directory: directory, fileName: "dingtalk-event-state.lock")
            if acquired != nil { break }; Thread.sleep(forTimeInterval: 0.01)
        }
        guard let lease = acquired else { throw ProjectUpdateError.invalid("事件记录正在更新，请稍后重试。") }
        defer { withExtendedLifetime(lease) {} }
        var state = try self.state(); try body(&state); try DingTalkEventPolicy.validate(state); try LocalJSONFileStore.save(state, to: stateURL)
    }
}
