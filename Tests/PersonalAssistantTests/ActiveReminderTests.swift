import Testing
import Foundation
@testable import PersonalAssistant

private actor FakeActiveNotifications: ActiveNotificationTransport {
    var permission = true
    var sent: [String] = []
    var visible: Set<String> = []
    var fail = false
    func allowed() -> Bool { permission }
    func pendingIDs() -> Set<String> { [] }
    func deliveredIDs() -> Set<String> { visible }
    func submit(id: String, title: String, body: String) throws {
        if fail { throw ProjectUpdateError.invalid("模拟系统错误") }
        sent.append(id); visible.insert(id)
    }
    func remove(_ ids: [String]) { visible.subtract(ids) }
    func deny() { permission = false }
    func allow() { permission = true }
    func setFailure(_ value: Bool) { fail = value }
}

private actor ReminderTestGate {
    var entered = false
    var waiting: CheckedContinuation<Void, Never>?
    var releaseWaiting: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true; waiting?.resume(); waiting = nil
        await withCheckedContinuation { releaseWaiting = $0 }
    }
    func wait() async { if !entered { await withCheckedContinuation { waiting = $0 } } }
    func release() { releaseWaiting?.resume(); releaseWaiting = nil }
}

@Suite(.serialized)
struct ActiveReminderTests {
    func time(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: .init(year: 2026, month: 10, day: 28, hour: hour, minute: minute))!
    }
    func candidates(_ count: Int = 8) -> [ActiveReminderCandidate] {
        (0..<count).map { .init(id: "personal-\($0)", title: "事项\($0)", body: "请按实际进度处理事项\($0)", kind: "personal") }
    }
    func store() throws -> ActiveReminderStore {
        let store = ActiveReminderStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("yuan-reminder-test-" + UUID().uuidString))
        try store.setEnabled(true); return store
    }

    @Test func onlyDueSlotsSubmitAndRefreshNeverDuplicates() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let transport = FakeActiveNotifications(); let runner = ActiveReminderRunner(); let items = candidates(); let before = time(9)
        #expect(await runner.synchronize(store: store, transport: transport, limit: 2, clock: { before }, fingerprint: { "a" }, load: { .init(candidates: items) }) == "checked")
        #expect(await transport.sent.isEmpty)
        #expect(try store.state().records.filter { $0.status == "planned" }.count == 2)
        let due = time(9, 15)
        #expect(await runner.synchronize(store: store, transport: transport, limit: 2, clock: { due }, fingerprint: { "a" }, load: { .init(candidates: items) }) == "submitted")
        _ = await runner.synchronize(store: store, transport: transport, limit: 2, force: true, clock: { due }, fingerprint: { "a" }, load: { .init(candidates: items) })
        #expect(await transport.sent.count == 1)
        #expect(try store.state().records.contains { $0.status == "system-record" })
    }

    @Test func quotaAndAffinityNeverExceedFiveAndOneSourceOnlyOnce() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let transport = FakeActiveNotifications(); let runner = ActiveReminderRunner(); let items = candidates()
        let first = time(9, 15)
        _ = await runner.synchronize(store: store, transport: transport, limit: 1, clock: { first }, fingerprint: { "a" }, load: { .init(candidates: items) })
        let second = time(11, 15)
        _ = await runner.synchronize(store: store, transport: transport, limit: 1, clock: { second }, fingerprint: { "a" }, load: { .init(candidates: items) })
        #expect(await transport.sent.count == 1)
        for slot in ReminderSchedulePolicy.slots.dropFirst() {
            let now = time(slot.hour, slot.minute)
            _ = await runner.synchronize(store: store, transport: transport, limit: 99, force: true, clock: { now }, fingerprint: { "a" }, load: { .init(candidates: items) })
        }
        #expect(await transport.sent.count == 5)
        let used = try store.state().records.filter(\.consumesQuota)
        #expect(Set(used.map { $0.source.id }).count == 5)
    }

    @Test func completionWithdrawsExistingAndCancelsFutureWithoutCompletingAnything() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let transport = FakeActiveNotifications(); let runner = ActiveReminderRunner(); let items = candidates(2); let now = time(9, 15)
        _ = await runner.synchronize(store: store, transport: transport, limit: 2, clock: { now }, fingerprint: { "a" }, load: { .init(candidates: items) })
        #expect(await transport.sent.count == 1)
        _ = await runner.synchronize(store: store, transport: transport, limit: 2, force: true, clock: { now }, fingerprint: { "b" }, load: { .init(candidates: []) })
        let records = try store.state().records
        #expect(records.contains { $0.status == "withdrawn" && $0.consumesQuota })
        #expect(records.contains { $0.status == "cancelled" && !$0.consumesQuota })
        #expect(await transport.visible.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("personal-todos.json").path))
    }

    @Test func quietHoursAndSleepLateWakeDoNotSubmitOldReminders() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let transport = FakeActiveNotifications(); let runner = ActiveReminderRunner(); let items = candidates()
        for now in [time(8, 59), time(12, 30), time(12, 59), time(21), time(23)] {
            #expect(await runner.synchronize(store: store, transport: transport, limit: 5, clock: { now }, fingerprint: { "a" }, load: { .init(candidates: items) }) == "quiet-hours")
        }
        let late = time(20, 40)
        _ = await runner.synchronize(store: store, transport: transport, limit: 5, clock: { late }, fingerprint: { "a" }, load: { .init(candidates: items) })
        #expect(await transport.sent.isEmpty)
    }

    @Test func permissionDenialAndDisableClearPlansAndRecover() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let transport = FakeActiveNotifications(); let runner = ActiveReminderRunner(); let items = candidates(); let now = time(9)
        _ = await runner.synchronize(store: store, transport: transport, limit: 3, clock: { now }, fingerprint: { "a" }, load: { .init(candidates: items) })
        await transport.deny()
        #expect(await runner.synchronize(store: store, transport: transport, limit: 3, clock: { now }, fingerprint: { "a" }, load: { .init(candidates: items) }) == "permission-denied")
        #expect(try store.state().records.allSatisfy { $0.status == "cancelled" })
        await transport.allow(); let due = time(9, 15)
        _ = await runner.synchronize(store: store, transport: transport, limit: 3, force: true, clock: { due }, fingerprint: { "b" }, load: { .init(candidates: items) })
        #expect(await transport.sent.count == 1)
        try store.setEnabled(false)
        #expect(await runner.synchronize(store: store, transport: transport, limit: 3, clock: { due }, fingerprint: { "b" }, load: { .init(candidates: items) }) == "disabled")
        #expect(await transport.visible.isEmpty)
    }

    @Test func unknownCrashReservationIsNeverReplayed() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = time(9, 15); let items = candidates(1); let day = DailyPlanSchedulePolicy.dayKey(for: now)
        var state = ActiveReminderState(); state.records = [.init(id: ActiveReminderPolicy.prefix + day + "-0", day: day, slot: 0, fireDate: now, source: items[0], status: "submitting", consumesQuota: true, updatedAt: now)]
        try store.save(state)
        let transport = FakeActiveNotifications()
        _ = await ActiveReminderRunner().synchronize(store: store, transport: transport, limit: 5, clock: { now }, fingerprint: { "a" }, load: { .init(candidates: items) })
        #expect(await transport.sent.isEmpty)
        #expect(try store.state().records[0].status == "uncertain")
        #expect(try ActiveReminderPolicy.quota(store.state().records, day: day) == 1)
    }

    @Test func sourceFailureDoesNotReuseStaleCandidatesAndSubmitFailureNeedsExplicitRetry() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let transport = FakeActiveNotifications(); let runner = ActiveReminderRunner(); let items = candidates(); let now = time(9, 15)
        #expect(await runner.synchronize(store: store, transport: transport, limit: 3, clock: { now }, fingerprint: { "a" }, load: { throw ProjectUpdateError.invalid("模拟同步失败") }) == "source-failed")
        #expect(await transport.sent.isEmpty)
        await transport.setFailure(true)
        _ = await runner.synchronize(store: store, transport: transport, limit: 3, force: true, clock: { now }, fingerprint: { "b" }, load: { .init(candidates: items) })
        #expect(try store.state().records.contains { $0.status == "failed" && !$0.consumesQuota })
        await transport.setFailure(false)
        _ = await runner.synchronize(store: store, transport: transport, limit: 3, force: true, clock: { now }, fingerprint: { "b" }, load: { .init(candidates: items) })
        #expect(await transport.sent.isEmpty)
        _ = await runner.synchronize(store: store, transport: transport, limit: 3, force: true, retryFailed: true, clock: { now }, fingerprint: { "b" }, load: { .init(candidates: items) })
        #expect(await transport.sent.count == 1)
    }

    @Test func testReminderCountsTowardsQuotaAndWorksWithoutSourceAccess() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = time(10); let transport = FakeActiveNotifications(); let runner = ActiveReminderRunner()
        #expect(await runner.synchronize(store: store, transport: transport, limit: 1, test: true, clock: { now }, fingerprint: { "a" }, load: { throw ProjectUpdateError.invalid("不得读取") }) == "submitted")
        #expect(await runner.synchronize(store: store, transport: transport, limit: 1, test: true, clock: { now }, fingerprint: { "a" }, load: { .init(candidates: []) }) == "quota-used")
        #expect(await transport.sent.count == 1)
    }

    @Test func independentProcessesCannotDoubleSubmit() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let transport = FakeActiveNotifications(); let gate = ReminderTestGate(); let now = time(9, 15); let items = candidates()
        let first = Task { await ActiveReminderRunner().synchronize(store: store, transport: transport, limit: 3, clock: { now }, fingerprint: { "a" }, load: { await gate.block(); return .init(candidates: items) }) }
        await gate.wait()
        #expect(await ActiveReminderRunner().synchronize(store: store, transport: transport, limit: 3, clock: { now }, fingerprint: { "a" }, load: { .init(candidates: items) }) == "busy")
        await gate.release()
        #expect(await first.value == "submitted")
        #expect(await transport.sent.count == 1)
    }

    @Test func restoringOlderBackupPreservesUsedQuotaAndKeepsRemindersOff() throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = time(9, 15); let day = DailyPlanSchedulePolicy.dayKey(for: now)
        var current = ActiveReminderState(); current.records = [.init(id: ActiveReminderPolicy.prefix + day + "-0", day: day, slot: 0, fireDate: now, source: candidates()[0], status: "submitted", consumesQuota: true, updatedAt: now)]
        try store.save(current)
        let suite = "yuan-reminder-backup-" + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = LocalAssistantDataExport(exportedAt: now, profile: .init(name: "验收", personality: "温柔陪伴型", tone: "温柔亲切", address: "你", avatar: "warm", relationshipPoints: 0, automaticMemoryEnabled: true), conversation: [], memories: [], projects: [], personalTodos: [], skills: AssistantSkill.defaults, knowledgeBases: [], activeReminderState: .init())
        try LocalAssistantDataManager.restore(archive, defaults: defaults, appDataDirectory: store.directory)
        #expect(try !store.settings().enabled)
        #expect(try ActiveReminderPolicy.quota(store.state().records, day: day) == 1)
        #expect(try store.state().records[0].status == "withdrawn")
    }

    @Test func sourceReadCrossingQuietHoursDoesNotSubmit() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let transport = FakeActiveNotifications(); let times = [time(20, 15), time(21)]; let items = candidates()
        var index = 0
        let clock: () -> Date = { let date = times[min(index, times.count - 1)]; index += 1; return date }
        _ = await ActiveReminderRunner().synchronize(store: store, transport: transport, limit: 3, clock: clock, fingerprint: { "a" }, load: { .init(candidates: items) })
        #expect(await transport.sent.isEmpty)
        #expect(try store.state().records.allSatisfy { !$0.consumesQuota })
    }

    @Test func unavailableExternalSourceKeepsPersonalRemindersAndDoesNotClaimCompletion() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let transport = FakeActiveNotifications(); let runner = ActiveReminderRunner(); let now = time(9)
        let local = candidates(1)[0]
        let remote = ActiveReminderCandidate(id: "remote-1", title: "企业事项", body: "真实源事项", kind: "external")
        _ = await runner.synchronize(store: store, transport: transport, limit: 3, clock: { now }, fingerprint: { "a" }, load: { .init(candidates: [local, remote]) })
        let due = time(9, 15)
        #expect(await runner.synchronize(store: store, transport: transport, limit: 3, force: true, clock: { due }, fingerprint: { "b" }, load: { .init(candidates: [local], warning: "外部不可用，本机仍正常提醒", unavailableKinds: ["external", "event"]) }) == "submitted")
        #expect(await transport.sent.count == 1)
        let state = try store.state()
        #expect(state.records.contains { $0.source.kind == "personal" && $0.consumesQuota })
        #expect(!state.records.contains { $0.source.kind == "external" && $0.status == "planned" })
        #expect(state.history.contains { $0.title == remote.title && $0.detail?.contains("并非确认事项已完成") == true })
        #expect(state.error?.contains("本机") == true)
        let later = time(11, 15)
        _ = await runner.synchronize(store: store, transport: transport, limit: 3, force: true, clock: { later }, fingerprint: { "c" }, load: { .init(candidates: [local, remote]) })
        #expect(await transport.sent.count == 2)
        #expect(try store.state().error == nil)
    }

    @Test func corruptReminderStateIsNotOverwritten() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        try Data("broken".utf8).write(to: store.stateURL)
        let now = time(9, 15); let transport = FakeActiveNotifications()
        #expect(await ActiveReminderRunner().synchronize(store: store, transport: transport, clock: { now }, fingerprint: { "a" }, load: { .init(candidates: []) }) == "storage-error")
        #expect(try Data(contentsOf: store.stateURL) == Data("broken".utf8))
        #expect(await transport.sent.isEmpty)
    }
}

extension ActiveReminderTests {
    @Test func loweringMemoryLimitCancelsRemainingSlotsWithoutResettingConsumedQuota() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let transport = FakeActiveNotifications(); let runner = ActiveReminderRunner(); let items = candidates()
        let first = time(9, 15)
        #expect(await runner.synchronize(store: store, transport: transport, limit: 4, clock: { first }, fingerprint: { "before" }, load: { .init(candidates: items) }) == "submitted")
        let original = try store.state()
        let day = DailyPlanSchedulePolicy.dayKey(for: first)
        #expect(ActiveReminderPolicy.quota(original.records, day: day) == 1)
        let cap = MemoryActionPreference(kind: .reminderLimit, value: "1", end: nil, confirmedAt: first)
        let memories = [AssistantMemory(content: "每天最多一次", category: "个人偏好", actionPreferences: [cap])]
        let limit = MemoryActionPolicy.reminderLimit(memories: memories, relationshipLimit: 4)
        #expect(await runner.synchronize(store: store, transport: transport, limit: limit, force: true, clock: { first.addingTimeInterval(60) }, fingerprint: { "after" }, load: { .init(candidates: items) }) == "checked")
        let updated = try store.state()
        #expect(ActiveReminderPolicy.quota(updated.records, day: day) == 1)
        #expect(updated.records.filter { $0.status == "planned" }.isEmpty)
        #expect(await transport.sent.count == 1)
    }
}
