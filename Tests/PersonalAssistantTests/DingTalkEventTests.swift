import Foundation
import Testing
@testable import PersonalAssistant

struct DingTalkEventTests {
    let profile = DingTalkProfile(corpID: "corp", userID: "user", corpName: "隔离组织", userName: "测试本人", isOrgCurrent: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var settings: DingTalkEventSettings { .init(enabled: true, profile: profile) }
    func frame(id: String = "e1", message: String = "m1", subscription: String = "s1", type: String = "user_im_message_receive_at", content: String = "合成事件", stamp: Date? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["event_id":id,"message_id":message,"conversation_id":"cid","subscribe_id":subscription,"type":type,"content":content,"sender":"合成人员","event_time":(stamp ?? now).timeIntervalSince1970 * 1000])
    }
    @Test func argumentsNeverEnableAllMessagesOrSendOrMarkRead() throws {
        let args = try settings.arguments(duration: "45s")
        #expect(args.contains("+listen-im") && args.contains("at-me") && args.contains("ndjson") && args.contains(profile.id))
        #expect(!args.contains("--yes") && !args.contains("all-direct") && !args.contains("all-group"))
        var group = settings; group.kind = "group"; group.target = "合成测试群"
        #expect(try group.arguments().contains("--chat-query"))
        group.target = ""; #expect(!group.valid)
        group.kind = "all-group"; #expect(!group.valid)
    }
    @Test func readyRequiresRealReadyMarkerAndNeverUsesSubscriptionAnnouncement() {
        #expect(DingTalkEventPolicy.readySubscription("[event] subscription event_key=user_im_message_receive_at subscribe_id=s1") == nil)
        #expect(DingTalkEventPolicy.readySubscription("[event] ready event_key=user_im_message_receive_at bus_pid=123 subscribe_id=s1") == "s1")
    }
    @Test func eventParserChecksSubscriptionTypeIDsAndTime() throws {
        let event = try DingTalkEventPolicy.parse(frame(), settings: settings, subscriptionID: "s1", now: now)
        #expect(event.item.profile == profile && event.item.sourceID == "m1" && event.item.containerID == "cid")
        for bad in [try frame(subscription: "other"), try frame(type: "user_im_message_receive_group"), try frame(stamp: now.addingTimeInterval(3600)), Data("malformed".utf8)] {
            #expect(throws: (any Error).self) { try DingTalkEventPolicy.parse(bad, settings: settings, subscriptionID: "s1", now: now) }
        }
    }
    @Test func reconnectDoesNotCreateAnotherAlertForSameMessage() throws {
        let first = try DingTalkEventPolicy.parse(frame(), settings: settings, subscriptionID: "s1", now: now)
        let repeatEvent = try DingTalkEventPolicy.parse(frame(id: "other-event", subscription: "s2"), settings: settings, subscriptionID: "s2", now: now)
        var state = try DingTalkEventPolicy.ingest(first, state: .init())
        state = try DingTalkEventPolicy.ingest(repeatEvent, state: state)
        #expect(state.events.count == 1 && state.events.first?.eventID == "e1")
    }
    @Test func notificationOnlyUsesSelectedEnabledFreshUnviewedScope() throws {
        var event = try DingTalkEventPolicy.parse(frame(), settings: settings, subscriptionID: "s1", now: now)
        #expect(DingTalkEventPolicy.candidate(event, settings: settings, selected: [profile.id], now: now)?.kind == "dingtalk-im")
        #expect(DingTalkEventPolicy.candidate(event, settings: settings, selected: [], now: now) == nil)
        #expect(DingTalkEventPolicy.candidate(event, settings: settings, selected: [profile.id], now: now.addingTimeInterval(601)) == nil)
        var disabled = settings; disabled.enabled = false
        #expect(DingTalkEventPolicy.candidate(event, settings: disabled, selected: [profile.id], now: now) == nil)
        var silent = settings; silent.notify = false
        #expect(DingTalkEventPolicy.candidate(event, settings: silent, selected: [profile.id], now: now) == nil)
        event.dismissed = true; #expect(DingTalkEventPolicy.candidate(event, settings: settings, selected: [profile.id], now: now) == nil)
    }
    @Test func nativeEventSharesQuotaQuietHoursAndNeverFillsBeyondFive() throws {
        let calendar = Calendar.current
        let quiet = calendar.date(bySettingHour: 12, minute: 45, second: 0, of: now)!
        #expect(!ReminderSchedulePolicy.isAllowedTime(quiet))
        let at = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
        let event = try DingTalkEventPolicy.parse(frame(stamp: at), settings: settings, subscriptionID: "s1", now: at)
        let candidate = try #require(DingTalkEventPolicy.candidate(event, settings: settings, selected: [profile.id], now: at))
        let proposed = ActiveReminderPolicy.plan(candidates: [candidate], records: [], limit: 1, now: at)
        #expect(proposed.count <= 1)
        let records = proposed.map { row in var r = row; r.consumesQuota = true; r.status = "submitted"; return r }
        #expect(ActiveReminderPolicy.plan(candidates: [candidate], records: records, limit: 1, now: at).isEmpty)
    }
    @Test func retryBudgetSurvivesReenableAndRespectsRetryAfter() {
        var unknown = DingTalkEventBudget(attempts: 2, lastFailure: now, nextAllowedAt: now.addingTimeInterval(30), retryability: "unknown")
        #expect(!unknown.allows(at: now.addingTimeInterval(31)))
        #expect(unknown.allows(at: now.addingTimeInterval(86401)))
        unknown.nextAllowedAt = now.addingTimeInterval(172800)
        #expect(!unknown.allows(at: now.addingTimeInterval(86401)))
        #expect(!DingTalkEventBudget(attempts: 1, lastFailure: now, retryability: "false").allows(at: now))
        #expect(DingTalkEventBudget(attempts: 2, lastFailure: now, retryability: "true").allows(at: now))
        #expect(!DingTalkEventBudget(attempts: 3, lastFailure: now, retryability: "true").allows(at: now))
    }
    @Test func onlyConfirmedRetryableFailuresKeepTheWorkerAliveAfterBudget() {
        #expect(DingTalkEventBudget(retryability: "true").continuesAutomaticRecovery)
        #expect(!DingTalkEventBudget(retryability: "unknown").continuesAutomaticRecovery)
        #expect(!DingTalkEventBudget(retryability: "false").continuesAutomaticRecovery)
    }
    @Test func pipeHandlesFragmentedLinesOversizeAndContinuesAfterInvalidInput() {
        let lines = DingTalkEventLines()
        lines.append(Data("{\"a\":".utf8), channel: 0); #expect(lines.drain().out.isEmpty)
        lines.append(Data("1}\ninvalid\n".utf8), channel: 0)
        #expect(lines.drain().out.count == 2)
        lines.append(Data(repeating: 65, count: 262145), channel: 0); lines.append(Data("\nvalid\n".utf8), channel: 0)
        let next = lines.drain(); #expect(next.rejected == 1 && next.out == [Data("valid".utf8)])
        lines.append(Data("[event] ready event_key=key subscribe_id=s\n".utf8), channel: 1)
        #expect(lines.drain().err.count == 1)
    }
    @Test func corruptStoreFailsClosedAndWorkerLeasePreventsParallelHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-store-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DingTalkEventStore(directory: root); try Data("broken".utf8).write(to: store.stateURL)
        #expect(throws: (any Error).self) { try store.update { $0.status = "ready" } }
        #expect(try String(contentsOf: store.stateURL, encoding: .utf8) == "broken")
        let lease = try #require(try BackgroundPlanLease(directory: root, fileName: "dingtalk-event-worker.lock"))
        #expect(try BackgroundPlanLease(directory: root, fileName: "dingtalk-event-worker.lock") == nil)
        withExtendedLifetime(lease) {}
    }
    @Test func backupRestoresHistoryDismissedButNeverActivatesListenerOrResetsBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-restore-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        let store = DingTalkEventStore(directory: root)
        let budget = DingTalkEventBudget(attempts: 2, lastFailure: now, retryability: "unknown")
        try store.update { $0.budgets[settings.scopeKey] = budget }
        let event = try DingTalkEventPolicy.parse(frame(), settings: settings, subscriptionID: "s1", now: now)
        let archive = LocalAssistantDataExport(exportedAt: now, profile: .init(name: "QA", personality: "自然", tone: "自然", address: "你", avatar: "warm", relationshipPoints: 0, automaticMemoryEnabled: false), conversation: [], memories: [], projects: [], personalTodos: [], skills: [], knowledgeBases: [], dingTalkEventHistory: [event])
        let suite = "com.yuan.im.restore.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try LocalAssistantDataManager.restore(archive, defaults: defaults, appDataDirectory: root)
        #expect(try store.settings().enabled == false)
        #expect(try store.state().events.first?.dismissed == true)
        #expect(try store.state().budgets[settings.scopeKey]?.attempts == 2)
    }
}
