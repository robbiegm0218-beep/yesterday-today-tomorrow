import Foundation
import Darwin

struct BackgroundPlanSettings: Codable {
    var enabled = false
}
struct BackgroundPlanResult: Codable {
    let generatedAt: Date
    let sourceLabel: String
    let plan: SavedDayPlan
}
struct BackgroundPlanAttempt: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    let runKey: String
    let trigger: String
    var status: String
    var error: String?
}
struct BackgroundPlanState: Codable {
    var runKey = ""
    var attemptsToday = 0
    var status = "idle"
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var successKey: String?
    var nextRetryAt: Date?
    var error: String?
    var result: BackgroundPlanResult?
    var history: [BackgroundPlanAttempt] = []
}

enum BackgroundPlanSchedule {
    static func key(now: Date, calendar: Calendar = .current) -> String {
        DailyPlanSchedulePolicy.dayKey(for: now, calendar: calendar) + "|" + calendar.timeZone.identifier
    }
    static func due(state: BackgroundPlanState, now: Date, calendar: Calendar = .current, retry: Bool = false) -> Bool {
        let key = key(now: now, calendar: calendar)
        guard calendar.component(.hour, from: now) >= 9, state.successKey != key else { return false }
        if state.runKey != key { return true }
        if retry { return true }
        guard state.attemptsToday < 3 else { return false }
        return state.nextRetryAt.map { $0 <= now } ?? true
    }
    static func next(state: BackgroundPlanState, now: Date, calendar: Calendar = .current) -> Date? {
        guard let today = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) else { return nil }
        if now < today { return today }
        let key = key(now: now, calendar: calendar)
        if state.successKey != key && (state.runKey != key || state.attemptsToday < 3) {
            return max(now, state.runKey == key ? state.nextRetryAt ?? now : now)
        }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }
}

struct BackgroundPlanStore {
    let directory: URL
    init(directory: URL = LocalAssistantPaths.dataDirectory) { self.directory = directory }
    var stateURL: URL { directory.appendingPathComponent("background-daily-plan.json") }
    var settingsURL: URL { directory.appendingPathComponent("background-daily-plan-settings.json") }
    func state() throws -> BackgroundPlanState { try read(stateURL, fallback: BackgroundPlanState()) }
    func settings() throws -> BackgroundPlanSettings { try read(settingsURL, fallback: BackgroundPlanSettings()) }
    private func read<T: Decodable>(_ url: URL, fallback: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch { throw ProjectUpdateError.invalid("后台计划记录无法读取，原文件已保留；请先检查本机资料。") }
    }
    func save(_ state: BackgroundPlanState) throws { try LocalJSONFileStore.save(state, to: stateURL) }
    func setEnabled(_ enabled: Bool) throws { try LocalJSONFileStore.save(BackgroundPlanSettings(enabled: enabled), to: settingsURL) }
    func lease() throws -> BackgroundPlanLease? { try BackgroundPlanLease(directory: directory) }
}

/// OS releases this lock on process exit/crash. No UserDefaults check-then-set race.
final class BackgroundPlanLease {
    private let descriptor: Int32
    init?(directory: URL, fileName: String = "background-daily-plan.lock") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = Darwin.open(directory.appendingPathComponent(fileName).path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProjectUpdateError.invalid("无法建立后台计划执行锁。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); return nil }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

actor BackgroundDailyPlanRunner {
    static let shared = BackgroundDailyPlanRunner()
    func run(store: BackgroundPlanStore = BackgroundPlanStore(), trigger: String, retry: Bool = false,
             clock: @escaping () -> Date = Date.init,
             generate: @escaping () async throws -> BackgroundPlanResult = BackgroundDailyPlanGenerator.generate) async -> String {
        do {
            guard try store.settings().enabled else { return "disabled" }
            guard let lease = try store.lease() else { return "busy" }
            // Explicit lifetime extends the OS lease across all network awaits.
            defer { withExtendedLifetime(lease) {} }
            var state = try store.state()
            let now = clock()
            let interrupted = state.status == "running"
            if interrupted {
                state.status = "failed"; state.error = "上次执行中断，将重新检查。"
                state.nextRetryAt = state.attemptsToday < 3 ? now : nil
            }
            if let last = state.history.indices.last, state.history[last].status == "running" {
                state.history[last].status = "interrupted"
                state.history[last].finishedAt = now
                state.history[last].error = "上次进程中断，本次重新检查。"
            }
            if interrupted { try store.save(state) }
            guard BackgroundPlanSchedule.due(state: state, now: now, retry: retry) else { return "not-due" }
            let key = BackgroundPlanSchedule.key(now: now)
            if state.runKey != key { state.runKey = key; state.attemptsToday = 0 }
            state.attemptsToday += 1
            state.status = "running"; state.lastAttemptAt = now; state.error = nil; state.nextRetryAt = nil
            let attemptID = UUID()
            state.history.append(.init(id: attemptID, startedAt: now, runKey: key, trigger: trigger, status: "running"))
            state.history = Array(state.history.suffix(20))
            try store.save(state)
            do {
                let result = try await generate()
                let finished = clock()
                guard try store.settings().enabled else { throw ProjectUpdateError.invalid("后台计划已关闭，本次结果未采用。") }
                guard BackgroundPlanSchedule.key(now: finished) == key,
                      result.plan.day == DailyPlanSchedulePolicy.dayKey(for: finished), result.plan.timeZone == TimeZone.current.identifier else {
                    throw ProjectUpdateError.invalid("日期或时区已变化，本次旧计划未采用，将重新检查当天安排。")
                }
                try SavedDayPlanPolicy.validateShape(result.plan)
                state.result = result
                state.status = "success"; state.successKey = key; state.lastSuccessAt = finished; state.error = nil
                if let i = state.history.firstIndex(where: { $0.id == attemptID }) { state.history[i].status = "success"; state.history[i].finishedAt = finished }
                try store.save(state)
                return "success"
            } catch {
                let finished = clock()
                let stillEnabled = (try? store.settings().enabled) ?? false
                state.status = stillEnabled ? "failed" : "cancelled"; state.error = String(error.localizedDescription.prefix(240))
                state.nextRetryAt = stillEnabled && state.attemptsToday < 3 ? finished.addingTimeInterval(state.attemptsToday == 1 ? 300 : 900) : nil
                if let i = state.history.firstIndex(where: { $0.id == attemptID }) {
                    state.history[i].status = state.status; state.history[i].finishedAt = finished; state.history[i].error = state.error
                }
                try store.save(state)
                return state.status
            }
        } catch { return "storage-error" }
    }
}

enum BackgroundDailyPlanGenerator {
    private static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    private static func readJSON<T: Decodable>(_ name: String, fallback: T) throws -> T {
        let url = LocalAssistantPaths.dataDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard !FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) else { throw ProjectUpdateError.invalid("本机资料需要恢复，请打开助手检查后重试。") }
            return fallback
        }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch { throw ProjectUpdateError.invalid("本机资料读取失败，请打开助手检查后重试。") }
    }
    static func generate() async throws -> BackgroundPlanResult {
        guard let key = DeepSeekCredentialStore.load(), !key.isEmpty else {
            throw ProjectUpdateError.invalid("模型凭据当前不可读取，请打开助手设置检查连接；后台不会请求钥匙串授权。")
        }
        do {
            let now = Date()
            let snapshot = try await DingTalkDailyDataSource().loadSnapshot(at: now)
            let todos: [PersonalTodo] = try readJSON("personal-todos.json", fallback: [])
            let openTodos = todos.filter { !$0.isComplete }
            let hiddenRecords: [HiddenExternalTodo] = try readJSON("hidden-external-todos.json", fallback: [])
            let hidden = Set(hiddenRecords.map(\.id))
            let visible = snapshot.excludingHiddenExternalTodos(hidden)
            let projects: [AssistantProject] = try readJSON("projects.json", fallback: [])
            let refs = openTodos.map { DayPlanReference(kind: "personal", id: $0.id.uuidString, title: $0.title) }
                + visible.todos.filter { !$0.isComplete }.map { DayPlanReference(kind: "external", id: $0.id, title: $0.title) }
                + visible.events.filter { $0.endsAt > now }.map { DayPlanReference(kind: "event", id: $0.id, title: $0.title, time: timeLabel($0.startsAt), duration: Int($0.endsAt.timeIntervalSince($0.startsAt) / 60)) }
            if refs.isEmpty {
                return .init(generatedAt: now, sourceLabel: visible.sourceLabel, plan: SavedDayPlan(day: DailyPlanSchedulePolicy.dayKey(for: now), timeZone: TimeZone.current.identifier, steps: []))
            }
            let context = AssistantChatWorkbenchContext.message(personalTodos: openTodos, projects: projects, externalSnapshot: visible, lastSync: now, isSyncing: false, syncError: nil, now: now)
            let response = try await DeepSeekClient().assistantTurn(to: [
                .init(role: "system", content: "生成今天的个人执行安排建议。必须调用propose_day_plan，引用提供的源ID，优先逾期/重要事项；不要安排已结束日程，不编造准备依据或具体时刻。建议只在后台结果中保存，不会改写用户已经确认的计划，不修改任何待办或日历。"),
                MemoryActionPolicy.context(try readJSON("memories.json", fallback: [AssistantMemory]()), planning: true),
                context, .init(role: "user", content: "帮我安排今天，生成可核对的今日计划建议，确认后再采用。")
            ], enabledSkillIDs: ["daily-planning"], apiKey: key)
            let proposals = AssistantActionParser.proposals(from: response.toolCalls, todos: todos, projects: projects, planReferences: refs)
            guard proposals.count == 1, case let .saveDayPlan(plan, _) = proposals[0].operation else {
                throw ProjectUpdateError.invalid("模型未生成有效计划建议，下次检查会重试。")
            }
            return .init(generatedAt: Date(), sourceLabel: visible.sourceLabel, plan: plan)
        } catch {
            throw ProjectUpdateError.invalid(error.localizedDescription.replacingOccurrences(of: key, with: "[hidden]"))
        }
    }
}
