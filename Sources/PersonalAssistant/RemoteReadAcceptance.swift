import Foundation

/// Opt-in read-only integration probe. Never prints task IDs, titles or raw DWS output.
@MainActor
enum RemoteReadAcceptance {
    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["YUAN_RUN_REMOTE_READ_ACCEPTANCE"] == "1" else { return false }
        do {
            let selected = Set(AssistantRuntime.preferences.stringArray(forKey: "dingTalkSelectedProfiles") ?? [])
            guard selected.count == 1, let profileID = selected.first,
                  let executable = DingTalkCLIClient().resolveExecutable() else { return false }
            let root = try DingTalkJSON.decode(try await BoundedReadProcess().run(executable: executable,
                arguments: DingTalkReadOperation.ownOpenTodos.arguments() + ["--profile", profileID],
                environment: DingTalkCLIClient.processEnvironment(for: executable), timeout: 20))
            guard let data = root["data"] as? [String: Any], data["complete"] as? Bool == true,
                  let todos = data["todos"] as? [[String: Any]], data["count"] as? Int == todos.count else { return false }
            let hidden = try hiddenIDs()
            let candidates = todos.compactMap { $0["taskId"] as? String }.map { "dingtalk-\(profileID)-\($0)" }.filter { !hidden.contains($0) }
            guard let id = candidates.first else { return false }
            let reader = AssistantLiveTodoReader(scope: {
                guard let currentHidden = try? hiddenIDs(), !currentHidden.contains(id) else { return .init() }
                return .init(selected: Set(AssistantRuntime.preferences.stringArray(forKey: "dingTalkSelectedProfiles") ?? []), readableIDs: [id])
            })
            let result = try await reader.read(id: id, timeout: 20)
            let body = try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]
            return body?["live_verified"] as? Bool == true && body?["target_id"] as? String == id && body?["mode"] as? String == "live_exact_task_read"
        } catch { return false }
    }
    private static func hiddenIDs() throws -> Set<String> {
        let url = LocalAssistantPaths.dataDirectory.appendingPathComponent("hidden-external-todos.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try JSONDecoder().decode([HiddenExternalTodo].self, from: Data(contentsOf: url)).map(\.id))
    }
}

final class SyntheticLiveTodoRead: AssistantLiveTodoReading {
    let fail: Bool
    private(set) var calls = 0
    init(fail: Bool = false) { self.fail = fail }
    func detail(taskID: String, profileID: String, timeout: TimeInterval) async throws -> DingTalkCLIResult {
        calls += 1
        if fail { throw DingTalkCLIError.timedOut }
        return .init(data: try JSONSerialization.data(withJSONObject: ["result": ["todoDetailModel": ["taskId": taskID, "subject": "合成状态核对任务", "isDone": true]]]), exitCode: 0)
    }
}
