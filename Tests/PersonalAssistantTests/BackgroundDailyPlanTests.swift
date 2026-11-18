import Testing
import Foundation
@testable import PersonalAssistant

private actor BackgroundTestGate {
    var entered = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    var resume: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true; waiting.forEach { $0.resume() }; waiting = []
        await withCheckedContinuation { resume = $0 }
    }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { resume?.resume(); resume = nil }
}

@Suite(.serialized)
struct BackgroundDailyPlanTests {
    func store() throws -> BackgroundPlanStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-background-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return BackgroundPlanStore(directory: url)
    }
    func date(hour: Int = 10) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: hour))! }
    func result(at now: Date) -> BackgroundPlanResult {
        .init(generatedAt: now, sourceLabel: "合成", plan: .init(day: DailyPlanSchedulePolicy.dayKey(for: now), timeZone: TimeZone.current.identifier, steps: [.init(title: "准备材料")]))
    }

    @Test func disabledBeforeNineAndRepeatedSuccessDoNotGenerate() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let runner = BackgroundDailyPlanRunner(); let now = date(); let result = result(at: now)
        #expect(await runner.run(store: store, trigger: "test", clock: { now }, generate: { throw ProjectUpdateError.invalid("不得调用") }) == "disabled")
        try store.setEnabled(true)
        let early = date(hour: 8)
        #expect(await runner.run(store: store, trigger: "test", clock: { early }, generate: { throw ProjectUpdateError.invalid("不得调用") }) == "not-due")
        #expect(!FileManager.default.fileExists(atPath: store.stateURL.path))
        #expect(await runner.run(store: store, trigger: "test", clock: { now }, generate: { result }) == "success")
        let bytes = try Data(contentsOf: store.stateURL)
        #expect(await runner.run(store: store, trigger: "repeat", retry: true, clock: { now }, generate: { throw ProjectUpdateError.invalid("不得调用") }) == "not-due")
        #expect(try Data(contentsOf: store.stateURL) == bytes)
        #expect(try store.state().history.count == 1)
    }

    @Test func twoIndependentRunnersShareOSLease() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.setEnabled(true)
        let gate = BackgroundTestGate(); let now = date(); let result = result(at: now)
        let first = Task { await BackgroundDailyPlanRunner().run(store: store, trigger: "first", clock: { now }, generate: { await gate.block(); return result }) }
        await gate.wait()
        #expect(await BackgroundDailyPlanRunner().run(store: store, trigger: "second", clock: { now }, generate: { result }) == "busy")
        await gate.release()
        #expect(await first.value == "success")
        #expect(try store.state().history.count == 1)
    }

    @Test func failuresBackOffStopAfterThreeAndAllowManualRetry() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.setEnabled(true); let runner = BackgroundDailyPlanRunner(); let start = date()
        let fail: () async throws -> BackgroundPlanResult = { throw ProjectUpdateError.invalid("模拟断网") }
        #expect(await runner.run(store: store, trigger: "test", clock: { start }, generate: fail) == "failed")
        #expect(try store.state().nextRetryAt == start.addingTimeInterval(300))
        #expect(await runner.run(store: store, trigger: "test", clock: { start.addingTimeInterval(299) }, generate: fail) == "not-due")
        #expect(await runner.run(store: store, trigger: "test", clock: { start.addingTimeInterval(300) }, generate: fail) == "failed")
        #expect(try store.state().nextRetryAt == start.addingTimeInterval(1_200))
        #expect(await runner.run(store: store, trigger: "test", clock: { start.addingTimeInterval(1_200) }, generate: fail) == "failed")
        #expect(await runner.run(store: store, trigger: "test", clock: { start.addingTimeInterval(3_600) }, generate: fail) == "not-due")
        let success = result(at: start)
        #expect(await runner.run(store: store, trigger: "manual", retry: true, clock: { start.addingTimeInterval(3_600) }, generate: { success }) == "success")
        #expect(try store.state().attemptsToday == 4)
    }

    @Test func disableDuringRequestDoesNotPublishResult() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.setEnabled(true); let now = date(); let result = result(at: now)
        let outcome = await BackgroundDailyPlanRunner().run(store: store, trigger: "test", clock: { now }, generate: { try store.setEnabled(false); return result })
        #expect(outcome == "cancelled")
        #expect(try store.state().result == nil)
        #expect(try store.state().successKey == nil)
    }

    @Test func interruptedRunRecoversAndCorruptStateFailsClosed() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.setEnabled(true); let now = date(); var state = BackgroundPlanState()
        state.runKey = BackgroundPlanSchedule.key(now: now); state.attemptsToday = 1; state.status = "running"
        state.history = [.init(id: UUID(), startedAt: now.addingTimeInterval(-600), runKey: state.runKey, trigger: "old", status: "running")]
        try store.save(state); let result = result(at: now)
        #expect(await BackgroundDailyPlanRunner().run(store: store, trigger: "recover", clock: { now }, generate: { result }) == "success")
        #expect(try store.state().history.first?.status == "interrupted")
        try Data("broken".utf8).write(to: store.stateURL)
        #expect(await BackgroundDailyPlanRunner().run(store: store, trigger: "corrupt", clock: { now }, generate: { result }) == "storage-error")
        #expect(try Data(contentsOf: store.stateURL) == Data("broken".utf8))
    }

    @Test func latePreviousDayResultIsRejectedAndNextDayCanRun() async throws {
        let store = try store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.setEnabled(true)
        let now = date(); let next = now.addingTimeInterval(86_400)
        let stale = result(at: now.addingTimeInterval(-86_400))
        #expect(await BackgroundDailyPlanRunner().run(store: store, trigger: "stale", clock: { now }, generate: { stale }) == "failed")
        #expect(try store.state().result == nil)
        let fresh = result(at: next)
        #expect(await BackgroundDailyPlanRunner().run(store: store, trigger: "wake", clock: { next }, generate: { fresh }) == "success")
        #expect(try store.state().attemptsToday == 1)
    }

    @Test func wakeCatchupCrossDayAndDSTUseLocalNineOClock() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let morning = calendar.date(from: .init(year: 2026, month: 11, day: 1, hour: 9))!
        var state = BackgroundPlanState(); state.successKey = BackgroundPlanSchedule.key(now: morning, calendar: calendar)
        let next = try #require(BackgroundPlanSchedule.next(state: state, now: morning, calendar: calendar))
        #expect(calendar.component(.hour, from: next) == 9)
        #expect(calendar.component(.day, from: next) == 2)
        #expect(!BackgroundPlanSchedule.due(state: state, now: morning, calendar: calendar))
        #expect(BackgroundPlanSchedule.due(state: state, now: next.addingTimeInterval(3_600), calendar: calendar))
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        #expect(BackgroundPlanSchedule.due(state: state, now: morning, calendar: calendar))
    }
}
