import SwiftUI
import ServiceManagement
import Darwin

final class DingTalkEventCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
/// Independent stdout/stderr drains prevent a full pipe from blocking the CLI.
/// Oversized lines are discarded through their newline, never parsed as fragments.
final class DingTalkEventLines: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = [Data(), Data()]
    private var dropping = [false, false]
    private var lines = [[Data](), [Data]()]
    private var rejected = 0
    private var queuedBytes = [0, 0]
    func append(_ bytes: Data, channel: Int) {
        lock.lock(); defer { lock.unlock() }
        for byte in bytes {
            if byte == 10 {
                if !dropping[channel], !partial[channel].isEmpty {
                    if lines[channel].count < 256 && queuedBytes[channel] + partial[channel].count <= 1_048_576 { lines[channel].append(partial[channel]); queuedBytes[channel] += partial[channel].count } else { rejected += 1 }
                }
                partial[channel].removeAll(keepingCapacity: true); dropping[channel] = false
            } else if !dropping[channel] {
                if partial[channel].count < 262_144 { partial[channel].append(byte) }
                else { partial[channel].removeAll(keepingCapacity: true); dropping[channel] = true; rejected += 1 }
            }
        }
    }
    func drain() -> (out: [Data], err: [Data], rejected: Int) {
        lock.lock(); defer { lock.unlock() }
        let result = (lines[0], lines[1], rejected); lines = [[], []]; queuedBytes = [0, 0]; rejected = 0; return result
    }
}

struct DingTalkEventWorker {
    let store: DingTalkEventStore
    let notify: @Sendable () async -> Void
    init(store: DingTalkEventStore = .init(), notify: @escaping @Sendable () async -> Void = {
        // Notifications belong to the foreground app identity and its existing
        // permission/quota. Its foreground and five-minute background ticks
        // consume the persisted event inbox; the helper only receives events.
        guard Bundle.main.bundleIdentifier == "com.yuan.personal-assistant" else { return }
        _ = await ActiveReminderRunner.shared.synchronize(force: true)
    }) {
        self.store = store; self.notify = notify
    }
    func run() async {
        let cancellation = DingTalkEventCancellation()
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        term.setEventHandler { cancellation.cancel() }; interrupt.setEventHandler { cancellation.cancel() }
        term.resume(); interrupt.resume(); defer { term.cancel(); interrupt.cancel() }
        do {
            guard let lease = try BackgroundPlanLease(directory: store.directory, fileName: "dingtalk-event-worker.lock") else { return }
            defer { withExtendedLifetime(lease) {} }
            while !cancellation.cancelled {
                let settings = try store.settings()
                guard settings.enabled, let profile = settings.profile else { break }
                let preferences = UserDefaults(suiteName: "com.yuan.personal-assistant") ?? .standard
                preferences.synchronize()
                guard (preferences.stringArray(forKey: "dingTalkSelectedProfiles") ?? []).contains(profile.id),
                      try DingTalkCLIClient().listProfiles().contains(where: { $0.id == profile.id }) else { throw DingTalkContentError.selectOrganization }
                var budget = try store.state().budgets[settings.scopeKey] ?? .init()
                if let failure = budget.lastFailure, Date().timeIntervalSince(failure) >= 86400, budget.nextAllowedAt.map({ $0 <= Date() }) ?? true { budget = .init() }
                let limit = budget.retryability == "false" ? 1 : budget.retryability == "true" ? 3 : 2
                if let next = budget.nextAllowedAt, next > Date(), budget.attempts < limit {
                    try store.update { $0.status = "retry-wait"; $0.heartbeatAt = Date() }
                    while Date() < next, !cancellation.cancelled, try store.settings() == settings { try await Task.sleep(for: .seconds(1)) }
                    continue
                }
                guard budget.allows(at: Date()) else { try store.update { $0.status = "paused"; $0.error = "已达到本次连接恢复预算，保留失败记录；请按下次允许时间核对后再启用。" }; return }
                budget.attempts += 1
                budget.lastFailure = Date(); budget.nextAllowedAt = Date().addingTimeInterval(30) // In-flight attempts survive a host crash.
                let startingBudget = budget
                try store.update { state in
                    state.scopeKey = settings.scopeKey; state.status = "starting"; state.subscriptionID = nil; state.readyAt = nil; state.error = nil; state.heartbeatAt = Date()
                    state.budgets[settings.scopeKey] = startingBudget
                }
                let outcome = try await consume(settings: settings, cancellation: cancellation)
                if outcome.stopped {
                    if outcome.wasReady { try store.update { $0.budgets[settings.scopeKey] = DingTalkEventBudget() } }
                    break
                }
                var failureBudget = try store.state().budgets[settings.scopeKey] ?? startingBudget
                failureBudget.lastFailure = Date(); failureBudget.retryability = outcome.retryable
                failureBudget.nextAllowedAt = Date().addingTimeInterval(max(30, outcome.retryAfter))
                if outcome.protected { failureBudget.retryability = "false" }
                let failureLimit = failureBudget.retryability == "false" ? 1 : failureBudget.retryability == "true" ? 3 : 2
                if failureBudget.attempts >= failureLimit { failureBudget.nextAllowedAt = max(failureBudget.nextAllowedAt!, Date().addingTimeInterval(86400)) }
                let updatedBudget = failureBudget
                try store.update {
                    $0.budgets[settings.scopeKey] = updatedBudget
                    $0.status = updatedBudget.continuesAutomaticRecovery ? "retry-wait" : (updatedBudget.allows(at: updatedBudget.nextAllowedAt!) ? "retry-wait" : "paused")
                    $0.error = updatedBudget.continuesAutomaticRecovery && !updatedBudget.allows(at: updatedBudget.nextAllowedAt!)
                        ? "事件连接已退出（状态\(outcome.exitCode)），本轮恢复预算已用完；将在退避后再次尝试。"
                        : "事件连接已退出（状态\(outcome.exitCode)），没有把它当作仍在监听；按恢复预算处理。"
                    $0.heartbeatAt = Date()
                }
                // A retryable network/service failure must not turn into a clean
                // worker exit: KeepAlive intentionally does not relaunch clean exits.
                // Keep this host alive through the capped 24-hour backoff, then the
                // normal budget reset above permits another bounded retry round.
                if !updatedBudget.allows(at: updatedBudget.nextAllowedAt!) && !updatedBudget.continuesAutomaticRecovery { return }
                while Date() < updatedBudget.nextAllowedAt!, !cancellation.cancelled {
                    guard try store.settings() == settings else { break }
                    try store.update { $0.heartbeatAt = Date() }
                    try await Task.sleep(for: .seconds(1))
                }
                guard try store.settings() == settings else { break }
            }
            try store.update { $0.status = "stopped"; $0.subscriptionID = nil; $0.heartbeatAt = Date() }
        } catch {
            try? store.update { $0.status = "failed"; $0.error = String(error.localizedDescription.prefix(300)); $0.heartbeatAt = Date() }
        }
    }
    func consume(settings: DingTalkEventSettings, cancellation: DingTalkEventCancellation, executableOverride: URL? = nil, argumentsOverride: [String]? = nil) async throws -> (stopped: Bool, retryable: String, retryAfter: TimeInterval, protected: Bool, exitCode: Int32, wasReady: Bool) {
        guard let executable = executableOverride ?? DingTalkCLIClient().resolveExecutable() else { throw DingTalkCLIError.notInstalled }
        let process = Process(); let stdout = Pipe(), stderr = Pipe(), stdin = Pipe(); let buffer = DingTalkEventLines()
        process.executableURL = executable; process.arguments = try argumentsOverride ?? settings.arguments()
        var environment = ProcessInfo.processInfo.environment
        environment["TZ"] = TimeZone.current.identifier
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment; process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
        stdout.fileHandleForReading.readabilityHandler = { h in let data = h.availableData; if !data.isEmpty { buffer.append(data, channel: 0) } }
        stderr.fileHandleForReading.readabilityHandler = { h in let data = h.availableData; if !data.isEmpty { buffer.append(data, channel: 1) } }
        try process.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
        }
        let started = Date(); var ready: String?; var waiting: [Data] = []; var stopping = false
        var retryable = "unknown"; var retryAfter: TimeInterval = 30; var protected = false; var lastHeartbeat = Date.distantPast
        while true {
            let frames = buffer.drain()
            for frame in frames.err {
                guard let line = String(data: frame, encoding: .utf8) else { continue }
                if line.contains("event_key=" + settings.eventKey + " "), let id = DingTalkEventPolicy.readySubscription(line) {
                    ready = id
                    try store.update { $0.status = "ready"; $0.subscriptionID = id; $0.readyAt = Date(); $0.heartbeatAt = Date(); $0.error = nil }
                }
                if line.range(of: #""retryable"\s*:\s*false"#, options: .regularExpression) != nil || line.contains("retryable=false") { retryable = "false" }
                else if retryable != "false", line.range(of: #""retryable"\s*:\s*true"#, options: .regularExpression) != nil || line.contains("retryable=true") { retryable = "true" }
                if line.contains("in_flight") || line.contains("terminal_hold") || line.contains("cooldown") { protected = true }
                if let json = line.firstIndex(of: "{"), let object = try? JSONSerialization.jsonObject(with: Data(line[json...].utf8)) as? [String: Any],
                   let error = object["error"] as? [String: Any] {
                    if let value = error["retryable"] as? Bool, !value || retryable != "false" { retryable = value ? "true" : "false" }
                    if let seconds = error["retry_after_seconds"] as? NSNumber { retryAfter = max(retryAfter, seconds.doubleValue) }
                    if let next = DingTalkJSON.date(error["next_retry_at"]) { retryAfter = max(retryAfter, next.timeIntervalSinceNow) }
                }
            }
            waiting.append(contentsOf: frames.out)
            if waiting.count > 256 { waiting = Array(waiting.suffix(256)); try store.update { $0.rejectedLines += 1; $0.error = "事件队列超出上限，部分事件未处理。" } }
            if frames.rejected > 0 { try store.update { $0.rejectedLines += frames.rejected; $0.error = "事件行损坏或超过缓冲上限，已保留异常计数。" } }
            if let subscription = ready {
                for frame in waiting {
                    guard !cancellation.cancelled, try store.settings() == settings else { break }
                    do {
                        let event = try DingTalkEventPolicy.parse(frame, settings: settings, subscriptionID: subscription, now: Date())
                        try store.update { $0 = try DingTalkEventPolicy.ingest(event, state: $0) }
                    } catch { try store.update { $0.rejectedLines += 1; $0.error = "收到的事件字段无法核对，已跳过该行并继续读取后续事件。" } }
                }
                let hadEvents = !waiting.isEmpty; waiting = []
                if hadEvents { Task { await notify() } }
            }
            let current = try store.settings()
            let stop = cancellation.cancelled || !current.enabled || current != settings
            if stop && !stopping {
                stopping = true
                try store.update { $0.status = "stopping"; $0.heartbeatAt = Date() }
                try? stdin.fileHandleForWriting.close(); if process.isRunning { process.terminate() }
            }
            if ready == nil && Date().timeIntervalSince(started) > 60 && !stopping {
                // Startup never reached ready. Terminate cleanly; do not leave an orphan consumer.
                if process.isRunning { process.terminate() }
                protected = true
            }
            if !process.isRunning { return (stopping, retryable, retryAfter, protected, process.terminationStatus, ready != nil) }
            if Date().timeIntervalSince(lastHeartbeat) >= 5 { try store.update { $0.heartbeatAt = Date() }; lastHeartbeat = Date() }
            try await Task.sleep(for: .seconds(1))
        }
    }
}
