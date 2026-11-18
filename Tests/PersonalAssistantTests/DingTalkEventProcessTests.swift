import Foundation
import Testing
@testable import PersonalAssistant

struct DingTalkEventProcessTests {
    let profile = DingTalkProfile(corpID: "synthetic", userID: "synthetic", corpName: "隔离测试", userName: "本人", isOrgCurrent: true)
    @Test func actualPipeLifecycleGatesReadySkipsBadLinesDeduplicatesAndGracefullyStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-process-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DingTalkEventStore(directory: root); let settings = DingTalkEventSettings(enabled: true, profile: profile)
        try store.setSettings(settings)
        let script = #"""
import sys,time,json,signal
from pathlib import Path
marker=Path(sys.argv[1])
def stop(*args):
 marker.write_text('graceful')
 sys.exit(0)
signal.signal(signal.SIGTERM,stop)
print('[event] ready event_key=user_im_message_receive_at bus_pid=123 subscribe_id=test-sub',file=sys.stderr,flush=True)
print('invalid-json',flush=True)
e={'type':'user_im_message_receive_at','event_id':'test-event','subscribe_id':'test-sub','message_id':'test-message','conversation_id':'test-cid','content':'仅本机合成事件','event_time':int(time.time()*1000)}
print(json.dumps(e),flush=True)
print(json.dumps(e),flush=True)
time.sleep(30)
"""#
        let cancellation = DingTalkEventCancellation()
        let worker = DingTalkEventWorker(store: store, notify: {})
        let task = Task { try await worker.consume(settings: settings, cancellation: cancellation, executableOverride: URL(fileURLWithPath: "/usr/bin/python3"), argumentsOverride: ["-c",script,root.appendingPathComponent("stopped.txt").path]) }
        var ready = false
        for _ in 0..<50 {
            if let state = try? store.state(), state.status == "ready", state.events.count == 1, state.rejectedLines == 1 { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        cancellation.cancel()
        let outcome = try await task.value
        #expect(ready && outcome.stopped)
        #expect(try store.state().events.count == 1)
        #expect(try String(contentsOf: root.appendingPathComponent("stopped.txt"), encoding: .utf8) == "graceful")
    }
    @Test func subprocessWithoutReadyCannotPersistEventsAndReportsRetryContract() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-no-ready-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DingTalkEventStore(directory: root); let settings = DingTalkEventSettings(enabled: true, profile: profile)
        try store.setSettings(settings)
        let script = #"""
import sys,json,time
print(json.dumps({'type':'user_im_message_receive_at','event_id':'e','subscribe_id':'s','message_id':'m','conversation_id':'c','content':'未就绪','event_time':int(time.time()*1000)}),flush=True)
print(json.dumps({'error':{'retryable':False,'retry_after_seconds':120}}),file=sys.stderr,flush=True)
time.sleep(.2)
sys.exit(1)
"""#
        let outcome = try await DingTalkEventWorker(store: store, notify: {}).consume(settings: settings, cancellation: .init(), executableOverride: URL(fileURLWithPath: "/usr/bin/python3"), argumentsOverride: ["-c",script])
        #expect(!outcome.stopped && outcome.retryable == "false" && outcome.retryAfter >= 120)
        #expect(try store.state().events.isEmpty)
    }
}
