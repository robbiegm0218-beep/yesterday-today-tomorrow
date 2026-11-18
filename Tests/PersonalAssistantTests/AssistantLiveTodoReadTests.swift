import Foundation
import Testing
import Darwin
@testable import PersonalAssistant

struct AssistantLiveTodoReadTests {
    private let id = "dingtalk-org:user-real-task-with-dashes"
    private func data(_ taskID: String = "real-task-with-dashes", done: Any = true) throws -> DingTalkCLIResult {
        let detail: [String: Any] = ["taskId": taskID, "subject": "新的服务端标题", "isDone": done, "privateField": "must-not-leak"]
        return .init(data: try JSONSerialization.data(withJSONObject: ["result": ["todoDetailModel": detail]]), exitCode: 0)
    }
    @Test @MainActor func exactReadReturnsCurrentFactAndNeverRawBody() async throws {
        let backend = LiveReadStub(result: try data())
        let reader = AssistantLiveTodoReader(client: backend, scope: { .init(selected: ["org:user"], readableIDs: [id]) })
        let result = try await reader.read(id: id, timeout: 3)
        #expect(result.content.contains("已完成") && result.content.contains("live_exact_task_read"))
        #expect(!result.content.contains("must-not-leak") && backend.calls == 1)
        #expect(backend.lastTaskID == "real-task-with-dashes" && backend.lastProfileID == "org:user")
    }
    @Test @MainActor func unknownHiddenAndUnselectedIDsNeverReachRemote() async throws {
        let backend = LiveReadStub(result: try data())
        for scope in [AssistantRemoteReadScope(selected: [], readableIDs: [id]), .init(selected: ["org:user"], readableIDs: [])] {
            let result = try await AssistantLiveTodoReader(client: backend, scope: { scope }).read(id: id, timeout: 3)
            #expect(result.content.contains("target_unavailable"))
        }
        #expect(backend.calls == 0)
        let remote = TodoRecord(id: id, title: "旧快照", dueAt: nil, importance: .normal, sourceURL: nil, isComplete: false)
        let reader = AssistantLiveTodoReader(client: backend, scope: { .init(selected: ["org:user"], readableIDs: [id]) })
        let context = AssistantReadContext(external: [remote], selected: ["org:user"], hidden: [id], liveReader: reader)
        let result = try await context.execute(.init(id: "r", function: .init(name: "read_dingtalk_todo_live", arguments: "{\"target_id\":\"\(id)\"}")), timeout: 3)
        #expect(result.content.contains("target_unavailable") && backend.calls == 0)
    }
    @Test @MainActor func scopeRevokedDuringIOAndWrongReturnedIDDoNotLeakFacts() async throws {
        let box = LiveScopeBox(scope: .init(selected: ["org:user"], readableIDs: [id]))
        let backend = LiveReadStub(result: try data())
        backend.onRead = { box.scope = .init() }
        let reader = AssistantLiveTodoReader(client: backend, scope: { box.scope })
        let result = try await reader.read(id: id, timeout: 3)
        #expect(result.content.contains("scope_changed") && !result.content.contains("新的服务端标题"))
        let wrong = LiveReadStub(result: try data("other-task"))
        let invalid = try await AssistantLiveTodoReader(client: wrong, scope: { .init(selected: ["org:user"], readableIDs: [id]) }).read(id: id, timeout: 3)
        #expect(invalid.content.contains("identity_or_format_unverified") && !invalid.content.contains("新的服务端标题"))
        let malformed = LiveReadStub(result: try data(done: "true"))
        let bad = try await AssistantLiveTodoReader(client: malformed, scope: { .init(selected: ["org:user"], readableIDs: [id]) }).read(id: id, timeout: 3)
        #expect(bad.content.contains("identity_or_format_unverified"))
    }
    @Test @MainActor func failedReadReportsUnknownAndCancellationPropagates() async throws {
        let backend = LiveReadStub(result: try data()); backend.error = DingTalkCLIError.timedOut
        let reader = AssistantLiveTodoReader(client: backend, scope: { .init(selected: ["org:user"], readableIDs: [id]) })
        let failed = try await reader.read(id: id, timeout: 1)
        #expect(failed.content.contains("timeout") && failed.content.contains("unknown") && !failed.content.contains("新的服务端标题"))
        backend.error = CancellationError()
        do { _ = try await reader.read(id: id, timeout: 1); Issue.record("Cancellation swallowed") }
        catch is CancellationError { }
    }
    @Test func realProcessTimeoutAndOutputLimitsAreBounded() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await BoundedReadProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.1)
            Issue.record("Timeout missing")
        } catch DingTalkCLIError.timedOut { }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
        do {
            _ = try await BoundedReadProcess(outputLimit: 30).run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: [String(repeating: "X", count: 100)], timeout: 2)
            Issue.record("Oversized output accepted")
        } catch DingTalkCLIError.invalidResponse { }
    }
    @Test func rapidChildExitsNeverWaitOnAnExecutorRunLoop() async throws {
        for _ in 0..<12 {
            let result = try await BoundedReadProcess().run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["ready"], timeout: 1)
            #expect(String(decoding: result.data, as: UTF8.self) == "ready")
        }
    }
    @Test func realProcessCancellationReapsChild() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-read-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = "import os,time;open(__import__('sys').argv[1],'w').write(str(os.getpid()));time.sleep(10)"
        let task = Task { try await BoundedReadProcess().run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script, marker.path], timeout: 15) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(Int32(String(contentsOf: marker)))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation missing") }
        catch is CancellationError { }
        #expect(kill(pid, 0) == -1)
    }
}

@MainActor private final class LiveScopeBox {
    var scope: AssistantRemoteReadScope
    init(scope: AssistantRemoteReadScope) { self.scope = scope }
}
private final class LiveReadStub: AssistantLiveTodoReading {
    var calls = 0
    var lastTaskID: String?
    var lastProfileID: String?
    var error: Error?
    var onRead: (@MainActor () -> Void)?
    let result: DingTalkCLIResult
    init(result: DingTalkCLIResult) { self.result = result }
    func detail(taskID: String, profileID: String, timeout: TimeInterval) async throws -> DingTalkCLIResult {
        calls += 1; lastTaskID = taskID; lastProfileID = profileID
        await onRead?()
        if let error { throw error }
        return result
    }
}
