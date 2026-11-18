import Foundation
import UserNotifications
import CryptoKit

struct ActiveReminderSettings: Codable {
    var enabled = false
}
struct ActiveReminderCandidate: Codable, Equatable {
    let id: String
    let title: String
    let body: String
    let kind: String
    var eventStartsAt: Date?
    var followupAt: Date?
    func eligible(at date: Date) -> Bool {
        if let followupAt { let due = FollowupPolicy.deliveryDate(followupAt); return date >= due && date.timeIntervalSince(due) <= ActiveReminderPolicy.grace }
        return eventStartsAt.map { $0 > date && $0.timeIntervalSince(date) <= 7_200 } ?? true
    }
}
struct ActiveReminderRecord: Codable, Identifiable {
    let id: String
    let day: String
    let slot: Int
    var fireDate: Date
    var source: ActiveReminderCandidate
    var status: String
    var consumesQuota = false
    var updatedAt: Date
    var error: String?
}
struct ActiveReminderEvent: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let title: String
    let status: String
    let detail: String?
}
struct ActiveReminderState: Codable {
    var records: [ActiveReminderRecord] = []
    var history: [ActiveReminderEvent] = []
    var candidates: [ActiveReminderCandidate] = []
    var lastCheckedAt: Date?
    var lastSourceAttemptAt: Date?
    var fingerprint = ""
    var unavailableSourceKinds: [String]?
    var sourceFailure: Bool?
    var error: String?
}
struct ActiveReminderStore {
    let directory: URL
    init(directory: URL = LocalAssistantPaths.dataDirectory) { self.directory = directory }
    var stateURL: URL { directory.appendingPathComponent("proactive-reminders.json") }
    var settingsURL: URL { directory.appendingPathComponent("proactive-reminder-settings.json") }
    func state() throws -> ActiveReminderState { try read(stateURL, fallback: .init()) }
    func settings() throws -> ActiveReminderSettings { try read(settingsURL, fallback: .init()) }
    func read<T: Decodable>(_ url: URL, fallback: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch { throw ProjectUpdateError.invalid("提醒记录无法读取，已暂停新增；原文件保留，请先检查本机资料。") }
    }
    func save(_ state: ActiveReminderState) throws { try LocalJSONFileStore.save(state, to: stateURL) }
    func setEnabled(_ enabled: Bool) throws { try LocalJSONFileStore.save(ActiveReminderSettings(enabled: enabled), to: settingsURL) }
}

protocol ActiveNotificationTransport {
    func allowed() async -> Bool
    func pendingIDs() async -> Set<String>
    func deliveredIDs() async -> Set<String>
    func submit(id: String, title: String, body: String) async throws
    func remove(_ ids: [String]) async
}
struct SystemActiveNotifications: ActiveNotificationTransport {
    func allowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
    func pendingIDs() async -> Set<String> { Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)) }
    func deliveredIDs() async -> Set<String> { Set(await UNUserNotificationCenter.current().deliveredNotifications().map { $0.request.identifier }) }
    func submit(id: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        content.userInfo = ["destination": "workbench"]
        // Submit now only. No future OS queue can replay a stale slot after wake.
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    func remove(_ ids: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
}

enum ActiveReminderPolicy {
    static let prefix = "yuan-active-reminder-"
    static let grace: TimeInterval = 600
    static func quota(_ records: [ActiveReminderRecord], day: String) -> Int { records.filter { $0.day == day && $0.consumesQuota }.count }
    static func plan(candidates: [ActiveReminderCandidate], records: [ActiveReminderRecord], limit: Int, now: Date, calendar: Calendar = .current) -> [ActiveReminderRecord] {
        let day = DailyPlanSchedulePolicy.dayKey(for: now, calendar: calendar)
        let allowance = max(0, min(5, limit) - quota(records, day: day))
        guard allowance > 0 else { return [] }
        let usedSources = Set(records.filter { $0.day == day && $0.consumesQuota }.map { $0.source.id })
        var used = usedSources
        var planned: [ActiveReminderRecord] = []
        // Explicit follow-ups reserve shared quota ahead of general nudges.
        for candidate in candidates.filter({ $0.followupAt != nil }).sorted(by: { $0.followupAt! < $1.followupAt! }) {
            guard planned.count < allowance, let requested = candidate.followupAt else { continue }
            let date = FollowupPolicy.deliveryDate(requested, calendar: calendar)
            guard calendar.isDate(date, inSameDayAs: now), date >= now.addingTimeInterval(-grace),
                  !records.contains(where: { $0.source.id == candidate.id && $0.consumesQuota }) else { continue }
            let suffix = SHA256.hash(data: Data(candidate.id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            let id = prefix + day + "-followup-" + suffix
            guard !records.contains(where: { $0.id == id && !["planned", "cancelled", "missed"].contains($0.status) }) else { continue }
            planned.append(.init(id: id, day: day, slot: -2, fireDate: date, source: candidate, status: "planned", updatedAt: now))
            used.insert(candidate.id)
        }
        for (index, slot) in ReminderSchedulePolicy.slots.enumerated() {
            guard planned.count < allowance,
                  let date = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: now),
                  date >= now.addingTimeInterval(-grace), ReminderSchedulePolicy.isAllowedTime(date, calendar: calendar) else { continue }
            let id = prefix + day + "-" + String(index)
            // Never replay a submitted, uncertain or failed slot automatically.
            if records.contains(where: { $0.id == id && $0.status != "planned" && $0.status != "cancelled" && $0.status != "missed" }) { continue }
            guard let candidate = candidates.first(where: { !used.contains($0.id) && $0.followupAt == nil && $0.eligible(at: max(now, date)) }) else { continue }
            used.insert(candidate.id)
            planned.append(.init(id: id, day: day, slot: index, fireDate: date, source: candidate, status: "planned", updatedAt: now))
        }
        return planned.sorted { $0.fireDate < $1.fireDate }
    }
}

actor ActiveReminderRunner {
    static let shared = ActiveReminderRunner()
    func synchronize(store: ActiveReminderStore = .init(), transport: any ActiveNotificationTransport = SystemActiveNotifications(),
                     limit: Int = ActiveReminderSources.limit(), assistantName: String = AssistantRuntime.preferences.string(forKey: "assistantName") ?? "予安",
                     force: Bool = false, test: Bool = false, retryFailed: Bool = false, clock: @escaping () -> Date = Date.init,
                     fingerprint: @escaping () -> String = ActiveReminderSources.fingerprint,
                     load: @escaping () async throws -> ActiveReminderSourceBatch = ActiveReminderSources.load) async -> String {
        do {
            guard let lease = try BackgroundPlanLease(directory: store.directory, fileName: "proactive-reminders.lock") else { return "busy" }
            defer { withExtendedLifetime(lease) {} }
            let now = clock(); let zone = TimeZone.current.identifier; let day = DailyPlanSchedulePolicy.dayKey(for: now)
            var state = try store.state()
            let pending = await transport.pendingIDs(), delivered = await transport.deliveredIDs()
            var changed = false
            func record(_ index: Int, status: String, detail: String? = nil) {
                guard state.records[index].status != status || detail != nil else { return }
                state.records[index].status = status; state.records[index].updatedAt = now; state.records[index].error = detail
                state.history.append(.init(date: now, title: state.records[index].source.title, status: status, detail: detail)); changed = true
            }
            for i in state.records.indices {
                if delivered.contains(state.records[i].id) { record(i, status: "system-record") }
                else if state.records[i].status == "submitting" { record(i, status: pending.contains(state.records[i].id) ? "submitted" : "uncertain", detail: "上次提交中断，未自动重发。") }
                else if state.records[i].status == "planned" && (state.records[i].day != day || now.timeIntervalSince(state.records[i].fireDate) > ActiveReminderPolicy.grace) { record(i, status: "missed", detail: "已错过时段，不补发旧提醒。") }
            }
            let enabled = try store.settings().enabled
            let authorized = await transport.allowed()
            guard enabled && authorized else {
                await transport.remove(Array((pending.union(delivered)).filter { $0.hasPrefix(ActiveReminderPolicy.prefix) || $0.hasPrefix("yuan-daily-reminder-") }))
                for i in state.records.indices where ["planned", "submitted", "system-record"].contains(state.records[i].status) {
                    record(i, status: state.records[i].consumesQuota ? "withdrawn" : "cancelled", detail: enabled ? "系统通知权限未允许。" : "提醒已关闭。")
                }
                let message = enabled ? "系统通知权限未允许，请在系统设置中恢复。" : nil
                if state.error != message { state.error = message; changed = true }
                if changed { state.history = Array(state.history.suffix(200)); try store.save(state) }
                return enabled ? "permission-denied" : "disabled"
            }
            guard ReminderSchedulePolicy.isAllowedTime(now) else {
                if changed { state.history = Array(state.history.suffix(200)); try store.save(state) }
                return "quiet-hours"
            }
            let key = fingerprint()
            let due = state.records.contains { $0.status == "planned" && $0.fireDate <= now }
            if !test && !force && key == state.fingerprint && state.sourceFailure == true && now.timeIntervalSince(state.lastSourceAttemptAt ?? .distantPast) < 300 { return "source-failed" }
            if !test && (force || due || key != state.fingerprint || now.timeIntervalSince(state.lastCheckedAt ?? .distantPast) >= 300) {
                do {
                    let batch = try await load()
                    state.candidates = batch.candidates; state.unavailableSourceKinds = batch.unavailableKinds
                    state.lastCheckedAt = now; state.lastSourceAttemptAt = now; state.fingerprint = key; state.error = batch.warning; state.sourceFailure = false; changed = true
                } catch {
                    state.error = String(error.localizedDescription.prefix(240)); state.sourceFailure = true; state.candidates = []; state.fingerprint = key; state.lastSourceAttemptAt = now
                    for i in state.records.indices where state.records[i].status == "planned" { record(i, status: "cancelled", detail: "数据未能刷新，未提交提醒。") }
                    state.history = Array(state.history.suffix(200)); try store.save(state); return "source-failed"
                }
            }
            let validIDs = Set(state.candidates.map(\.id))
            for i in state.records.indices where state.records[i].source.kind != "test" && !validIDs.contains(state.records[i].source.id) && ["planned", "submitted", "system-record"].contains(state.records[i].status) {
                await transport.remove([state.records[i].id])
                let unavailable = state.unavailableSourceKinds?.contains(state.records[i].source.kind) ?? false
                record(i, status: state.records[i].consumesQuota ? "withdrawn" : "cancelled", detail: unavailable ? "该来源暂不可用，已暂停对应提醒；并非确认事项已完成。" : (state.records[i].source.kind.hasPrefix("followup") ? "跟进已反馈、改期或来源不可用；原任务状态未自动改变。" : "事项已完成、隐藏、删除或日程已结束。"))
            }
            if retryFailed {
                for i in state.records.indices where state.records[i].status == "failed" && now.timeIntervalSince(state.records[i].fireDate) <= ActiveReminderPolicy.grace {
                    record(i, status: "cancelled", detail: "用户要求重新核对后重试。")
                }
            }
            state.records = state.records.filter { $0.updatedAt > now.addingTimeInterval(-8 * 86_400) }
            var plan = ActiveReminderPolicy.plan(candidates: state.candidates, records: state.records, limit: limit, now: now)
            if test {
                guard ActiveReminderPolicy.quota(state.records, day: day) < min(5, limit), !state.records.contains(where: { $0.day == day && $0.source.kind == "test" && $0.consumesQuota }) else { return "quota-used" }
                let source = ActiveReminderCandidate(id: "test-" + day, title: "提醒功能测试", body: "这是一条测试提醒。正式提醒会核对当前事项，并遵守亲密度额度与免打扰规则。", kind: "test")
                plan = [.init(id: ActiveReminderPolicy.prefix + day + "-test", day: day, slot: -1, fireDate: now, source: source, status: "planned", updatedAt: now)]
            }
            let wanted = Set(plan.map(\.id))
            for i in state.records.indices where state.records[i].status == "planned" && !wanted.contains(state.records[i].id) { record(i, status: "cancelled", detail: "额度或有效事项变化，已重新核对。") }
            for proposed in plan {
                if let i = state.records.firstIndex(where: { $0.id == proposed.id }) {
                    if state.records[i].status != "planned" || state.records[i].source != proposed.source || state.records[i].fireDate != proposed.fireDate {
                        state.records[i] = proposed; state.history.append(.init(date: now, title: proposed.source.title, status: "planned", detail: nil)); changed = true
                    }
                } else { state.records.append(proposed); state.history.append(.init(date: now, title: proposed.source.title, status: "planned", detail: nil)); changed = true }
            }
            state.history = Array(state.history.suffix(200))
            if changed { try store.save(state) }
            var submitted = 0
            for id in plan.filter({ $0.fireDate <= now }).map(\.id) {
                guard let i = state.records.firstIndex(where: { $0.id == id }), state.records[i].status == "planned" else { continue }
                let at = clock()
                guard try store.settings().enabled, ReminderSchedulePolicy.isAllowedTime(at), DailyPlanSchedulePolicy.dayKey(for: at) == day, TimeZone.current.identifier == zone, at.timeIntervalSince(state.records[i].fireDate) <= ActiveReminderPolicy.grace,
                      state.records[i].source.eligible(at: at), test || fingerprint() == key,
                      ActiveReminderPolicy.quota(state.records, day: day) < min(5, limit) else { continue }
                // Persist reservation before calling the OS. A crash cannot replay it.
                state.records[i].consumesQuota = true; record(i, status: "submitting"); try store.save(state)
                do {
                    try await transport.submit(id: id, title: assistantName + "的提醒", body: state.records[i].source.body)
                    record(i, status: "submitted"); submitted += 1
                    if try !store.settings().enabled {
                        await transport.remove([id]); record(i, status: "withdrawn", detail: "提交期间关闭提醒，已撤下。")
                    }
                } catch {
                    state.records[i].consumesQuota = false; record(i, status: "failed", detail: String(error.localizedDescription.prefix(240)))
                    state.error = "通知提交失败，可在状态页核对后重试。"
                }
                state.history = Array(state.history.suffix(200)); try store.save(state)
            }
            return submitted > 0 ? "submitted" : "checked"
        } catch { return "storage-error" }
    }
}
