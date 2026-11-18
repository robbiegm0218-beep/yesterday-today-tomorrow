import Foundation

/// Normal app behavior is unchanged. A dedicated headless evaluation process
/// can install one disposable data/prefs scope before constructing a model.
enum AssistantRuntime {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var directory: URL?
        var defaults: UserDefaults?
        var suite: String?
    }
    private static let state = State()
    static var evaluationDirectory: URL? { state.lock.lock(); defer { state.lock.unlock() }; return state.directory }
    static var preferences: UserDefaults { state.lock.lock(); defer { state.lock.unlock() }; return state.defaults ?? .standard }
    static var isEvaluating: Bool { evaluationDirectory != nil }
    static func beginEvaluation() throws -> URL {
        guard CommandLine.arguments.contains("--verify-agent-scenario"), ProcessInfo.processInfo.environment["YUAN_RUN_AGENT_ACCEPTANCE"] == "1" else { throw ProjectUpdateError.invalid("评估入口未启用。") }
        state.lock.lock(); defer { state.lock.unlock() }
        guard state.directory == nil else { throw ProjectUpdateError.invalid("每个评估进程只运行一个隔离场景。") }
        let resume = CommandLine.arguments.first(where: { $0.hasPrefix("--resume-sandbox=") }).map { String($0.dropFirst("--resume-sandbox=".count)) }
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root: URL
        let id: String
        if let resume {
            root = URL(fileURLWithPath: resume).resolvingSymlinksInPath()
            id = String(root.lastPathComponent.dropFirst("yuan-agent-e2e-".count))
            guard root.deletingLastPathComponent() == parent, root.lastPathComponent.hasPrefix("yuan-agent-e2e-"), UUID(uuidString: id) != nil,
                  (try? String(contentsOf: root.appendingPathComponent(".evaluation-root"))) == id else { throw ProjectUpdateError.invalid("无效的评估恢复目录。") }
        } else {
            id = UUID().uuidString
            root = parent.appendingPathComponent("yuan-agent-e2e-\(id)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try id.write(to: root.appendingPathComponent(".evaluation-root"), atomically: true, encoding: .utf8)
        }
        guard let defaults = UserDefaults(suiteName: "com.yuan.personal-assistant.evaluation.\(id)") else { throw ProjectUpdateError.invalid("无法创建隔离偏好。") }
        state.directory = root; state.defaults = defaults; state.suite = "com.yuan.personal-assistant.evaluation.\(id)"
        return root
    }
    static func finishEvaluationPreferences() {
        state.lock.lock(); defer { state.lock.unlock() }
        if let suite = state.suite {
            state.defaults?.removePersistentDomain(forName: suite)
            state.defaults?.synchronize()
        }
    }

}

struct AssistantModelServices {
    var chatClient = DeepSeekClient()
    var memoryExtractor: (@MainActor (AssistantMessage, [AssistantMemory]) async throws -> [ExtractedMemory])? = nil
    var apiKey: () -> String? = { DeepSeekCredentialStore.load() }
    var todoClient: any DingTalkTodoMutating = DingTalkCLIClient()
    var researchClient: any AssistantResearchReading = DingTalkAssistantResearchClient()
    var liveTodoClient: any AssistantLiveTodoReading = DingTalkLiveTodoClient()
    var initialProfiles: [DingTalkProfile] = []
}
