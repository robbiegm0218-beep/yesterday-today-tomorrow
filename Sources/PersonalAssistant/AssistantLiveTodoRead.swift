import Foundation
import CoreFoundation
import Darwin

/// Separate from write execution: bounded, cancellable, and never invokes a shell.
struct BoundedReadProcess {
    var outputLimit = 2_000_000
    func run(executable: URL, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval) async throws -> DingTalkCLIResult {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { throw DingTalkCLIError.timedOut }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        let errors = directory.appendingPathComponent("error")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let outputHandle = try FileHandle(forWritingTo: output)
        defer { try? outputHandle.close() }
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? errorHandle.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // Files avoid pipe backpressure and inherited pipes keeping a read alive.
        process.standardOutput = outputHandle; process.standardError = errorHandle
        let exit = ReadProcessExit()
        process.terminationHandler = { task in exit.finish(task.terminationStatus) }
        try process.run()
        let start = ProcessInfo.processInfo.systemUptime
        func withinLimit() throws -> Bool {
            let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            let errorSize = (try FileManager.default.attributesOfItem(atPath: errors.path)[.size] as? NSNumber)?.intValue ?? 0
            return size <= max(0, outputLimit) && errorSize <= 64_000
        }
        do {
            while exit.status == nil {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime - start < min(20, timeout) else { throw DingTalkCLIError.timedOut }
                guard try withinLimit() else { throw DingTalkCLIError.invalidResponse }
                try await Task.sleep(for: .milliseconds(25))
            }
            try Task.checkCancellation()
            guard try withinLimit() else { throw DingTalkCLIError.invalidResponse }
            let data = try Data(contentsOf: output)
            guard data.count <= max(0, outputLimit) else { throw DingTalkCLIError.invalidResponse }
            guard let status = exit.status, status == 0 else {
                throw DingTalkCLIError.classifying(exitCode: exit.status ?? -1, stderr: try Data(contentsOf: errors))
            }
            return .init(data: data, exitCode: 0)
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            // Foundation reaps the child in its termination handler. Never call
            // waitUntilExit across Swift task executor threads: its run-loop
            // wait can hang even after the child has exited.
            await Task.detached {
                for _ in 0..<100 {
                    if exit.status != nil { return }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }.value
            throw error
        }
    }
}

private final class ReadProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var status: Int32? { lock.lock(); defer { lock.unlock() }; return value }
    func finish(_ status: Int32) { lock.lock(); defer { lock.unlock() }; value = status }
}

protocol AssistantLiveTodoReading {
    func detail(taskID: String, profileID: String, timeout: TimeInterval) async throws -> DingTalkCLIResult
}
struct DingTalkLiveTodoClient: AssistantLiveTodoReading {
    func detail(taskID: String, profileID: String, timeout: TimeInterval) async throws -> DingTalkCLIResult {
        let client = DingTalkCLIClient()
        guard let executable = client.resolveExecutable() else { throw DingTalkCLIError.notInstalled }
        return try await BoundedReadProcess().run(executable: executable,
            arguments: DingTalkReadOperation.todoDetails(id: taskID).arguments() + ["--profile", profileID],
            environment: DingTalkCLIClient.processEnvironment(for: executable), timeout: timeout)
    }
}

struct AssistantRemoteReadScope {
    var selected: Set<String> = []
    var readableIDs: Set<String> = []
    func profileID(for id: String) -> String? {
        guard readableIDs.contains(id) else { return nil }
        let matches = selected.filter { !$0.isEmpty && id.hasPrefix("dingtalk-\($0)-") }
        return matches.count == 1 ? matches.first : nil
    }
}

struct AssistantLiveTodoReader {
    var client: any AssistantLiveTodoReading = DingTalkLiveTodoClient()
    let scope: @MainActor () -> AssistantRemoteReadScope

    func read(id: String, timeout: TimeInterval) async throws -> AssistantReadResult {
        try Task.checkCancellation()
        let initial = await scope()
        guard let profile = initial.profileID(for: id) else { return response(["error": "target_unavailable"]) }
        let taskID = String(id.dropFirst("dingtalk-\(profile)-".count))
        guard !taskID.isEmpty, taskID.count <= 1000 else { return response(["error": "target_unavailable"]) }
        do {
            let result = try await client.detail(taskID: taskID, profileID: profile, timeout: min(20, timeout))
            try Task.checkCancellation()
            // The user may hide the item or deselect the organization during I/O.
            guard await scope().profileID(for: id) == profile else { return response(["error": "scope_changed", "live_verified": false]) }
            let root = try DingTalkJSON.decode(result)
            guard let detail = (root["result"] as? [String: Any])?["todoDetailModel"] as? [String: Any],
                  detail["taskId"] as? String == taskID,
                  let title = detail["subject"] as? String, !title.isEmpty, title.count <= 1000,
                  let done = detail["isDone"] as? NSNumber, CFGetTypeID(done) == CFBooleanGetTypeID() else {
                return response(["error": "identity_or_format_unverified", "live_verified": false])
            }
            // Return only verified fields. No raw body, auth metadata or unrelated content.
            return response(["kind": "external", "target_id": id, "title": title,
                             "status": done.boolValue ? "已完成" : "未完成", "live_verified": true,
                             "checked_at": AssistantFactTime.timestamp(Date()), "mode": "live_exact_task_read",
                             "coverage": "one_task_only_not_an_organization_refresh",
                             "snapshot_note": "This exact task observation supersedes older snapshots for the answer, not an execution receipt. No write was performed."])
        } catch is CancellationError { throw CancellationError() }
        catch {
            let category: String
            if case DingTalkCLIError.timedOut = error { category = "timeout" }
            else { category = "remote_read_failed" }
            return response(["error": category, "live_verified": false,
                             "hint": "Current status is unknown. Never infer completion/deletion or silently substitute an old snapshot."])
        }
    }
    private func response(_ value: [String: Any]) -> AssistantReadResult {
        let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return .init(content: bytes.map { String(decoding: $0, as: UTF8.self) } ?? "{\"error\":\"encoding_failed\"}", liveVerified: value["live_verified"] as? Bool)
    }
}
