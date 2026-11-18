import Foundation
import Darwin

enum DingTalkReadOperation {
    case calendarEvents(start: String, end: String)
    case openTodos(page: Int, size: Int)
    case minutes(start: String, end: String)
    case searchDocuments(query: String)
    case readDocument(node: String)
    case documentInfo(node: String)
    case minutesSummary(id: String)
    case minutesTodos(id: String)
    case minutesTranscription(id: String)
    case todoDetails(id: String)
    case ownOpenTodos
    case ownCompletedTodos
    case searchMessages(query: String, start: String, end: String)
    case searchWiki(workspace: String, query: String)
    case wikiNodeInfo(node: String)
    case wikiSpaces
    case wikiNodes(workspace: String, folder: String?)

    func arguments(profile: DingTalkProfile? = nil) -> [String] {
        let command: [String]
        switch self {
        case let .calendarEvents(start, end):
            command = ["calendar", "event", "list", "--start", start, "--end", end]
        case let .openTodos(page, size):
            command = ["todo", "task", "list", "--page", String(page), "--size", String(size), "--status", "false"]
        case let .minutes(start, end):
            command = ["minutes", "+search", "--start", start, "--end", end, "--scope", "all", "--page-all"]
        case let .searchDocuments(query):
            command = ["doc", "+search", "--query", query, "--page-all", "--max-pages", "20", "--max-items", "100"]
        case let .readDocument(node):
            command = ["doc", "+fetch", "--node", node]
        case let .documentInfo(node):
            command = ["drive", "info", "--node", node]
        case let .minutesSummary(id):
            command = ["minutes", "+detail", "--id", id, "--artifacts", "summary"]
        case let .minutesTodos(id):
            command = ["minutes", "+action-items", "--id", id]
        case let .minutesTranscription(id):
            command = ["minutes", "+transcript", "--id", id]
        case let .todoDetails(id):
            command = ["todo", "task", "get", "--task-id", id]
        case .ownOpenTodos:
            command = ["todo", "+get-my-tasks", "--all", "--status", "false"]
        case .ownCompletedTodos:
            command = ["todo", "+get-my-tasks", "--all", "--status", "true"]
        case let .searchMessages(query, start, end):
            command = ["chat", "+search-msg", "--query", query, "--start", start, "--end", end, "--page-all", "--page-limit", "20", "--no-reactions"]
        case let .searchWiki(workspace, query):
            command = ["wiki", "+node-search", "--workspace", workspace, "--query", query, "--limit", "30", "--page-all", "--page-limit", "40", "--max-items", "200"]
        case let .wikiNodeInfo(node):
            command = ["wiki", "+node-get", "--node", node]
        case .wikiSpaces:
            command = ["wiki", "+space-list", "--type", "orgWikiSpace", "--limit", "50", "--page-all"]
        case let .wikiNodes(workspace, folder):
            command = ["wiki", "+node-list", "--workspace", workspace, "--page-all"] + (folder.map { ["--folder", $0] } ?? [])
        }
        var arguments = command
        if let profile { arguments += ["--profile", profile.argument] }
        arguments += ["--format", "json"]
        return arguments
    }
}

struct DingTalkProfile: Identifiable, Hashable, Codable {
    let corpID: String
    let userID: String
    let corpName: String
    let userName: String?
    let isOrgCurrent: Bool

    var id: String { argument }
    var argument: String { "\(corpID):\(userID)" }

    var displayName: String {
        guard let userName, !userName.isEmpty else { return corpName }
        return "\(corpName) · \(userName)"
    }
}

struct DingTalkCLIResult {
    let data: Data
    let exitCode: Int32
}

enum DingTalkCLIError: LocalizedError {
    case notInstalled
    case commandFailed(exitCode: Int32)
    case classifiedFailure(category: String)
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled: "未找到 DWS CLI，请在钉钉接入中检查安装。"
        case let .commandFailed(exitCode): "钉钉读取暂未成功（状态 \(exitCode)）；请在接入页检查连接。本机事项不受影响。"
        case let .classifiedFailure(category):
            switch category {
            case "auth": "钉钉认证检查失败，请在接入页检查所选组织的登录状态。"
            case "api": "钉钉服务读取失败，请检查网络、组织权限或服务状态。"
            case "validation", "discovery": "钉钉命令与当前CLI不匹配，请在接入页检查版本。"
            default: "钉钉客户端执行失败，请在接入页检查连接。"
            }
        case .invalidResponse: "钉钉返回格式无法识别，请重试或检查 DWS 版本。"
        case .timedOut: "钉钉命令执行超时。读取可以重试；提交待办时请先核对钉钉中的实际状态。"
        }
    }
}

enum DingTalkCLIStatus: Equatable {
    case notChecked
    case checking
    case notInstalled
    case loginRequired
    case connected
    case checkFailed

    var label: String {
        switch self {
        case .notChecked: "尚未检查 DWS"
        case .checking: "正在检查 DWS 登录状态…"
        case .notInstalled: "未找到 DWS CLI"
        case .loginRequired: "DWS 已安装，需要先登录或开通组织访问"
        case .connected: "DWS 已登录；读取权限会在查询时确认"
        case .checkFailed: "暂时无法读取 DWS 状态"
        }
    }
}

protocol DingTalkReading {
    func run(_ operation: DingTalkReadOperation, profile: DingTalkProfile?) throws -> DingTalkCLIResult
    func listProfiles() throws -> [DingTalkProfile]
}

protocol DingTalkTodoAccess: DingTalkReading {
    func createOwnTodo(title: String, dueAt: Date?, priority: Int, profile: DingTalkProfile) throws -> DingTalkCLIResult
}

struct DingTalkCLIClient: DingTalkTodoAccess, DingTalkTodoCompleting, DingTalkTodoMutating {
    func mutateTodo(taskID: String, mode: DingTalkTodoMutationRequest.Mode, patch: DingTalkTodoPatch?, profile: DingTalkProfile) throws -> DingTalkCLIResult {
        guard let executableURL = resolveExecutable() else { throw DingTalkCLIError.notInstalled }
        let command = mode == .update ? "+update" : mode == .complete ? "+complete" : "+reopen"
        var args = ["todo", command, "--task-id", taskID]
        if mode == .update {
            guard let patch, patch.isValid else { throw DingTalkTodoMutationError.invalid }
            if let title = patch.title { args += ["--title", title] }
            if let due = patch.dueAt { args += ["--due", due.ISO8601Format()] }
            if let priority = patch.priority { args += ["--priority", String(priority)] }
        }
        args += ["--profile", profile.id, "--format", "json", "--yes"]
        let output = try run(executableURL, arguments: args)
        return .init(data: Data(output.output.utf8), exitCode: output.status)
    }
    /// Only invoked by the final, explicit completion confirmation.
    func completeTodo(taskID: String, profile: DingTalkProfile) throws -> DingTalkCLIResult {
        guard let executableURL = resolveExecutable() else { throw DingTalkCLIError.notInstalled }
        let output = try run(executableURL, arguments: ["todo", "+complete", "--task-id", taskID, "--profile", profile.argument, "--format", "json", "--yes"])
        return DingTalkCLIResult(data: Data(output.output.utf8), exitCode: output.status)
    }

    func run(_ operation: DingTalkReadOperation, profile: DingTalkProfile? = nil) throws -> DingTalkCLIResult {
        guard let executableURL = resolveExecutable() else { throw DingTalkCLIError.notInstalled }
        let output = try run(executableURL, arguments: operation.arguments(profile: profile))
        let result = DingTalkCLIResult(data: Data(output.output.utf8), exitCode: output.status)
        guard result.exitCode == 0 else { throw DingTalkCLIError.classifying(exitCode: result.exitCode, stderr: output.errorData) }
        return result
    }

    /// Called only after the in-app confirmation sheet's final action.
    func createOwnTodo(title: String, dueAt: Date?, priority: Int, profile: DingTalkProfile) throws -> DingTalkCLIResult {
        guard let executableURL = resolveExecutable() else { throw DingTalkCLIError.notInstalled }
        var arguments = ["todo", "task", "create", "--title", title, "--executors", profile.userID, "--priority", String(priority)]
        if let dueAt { arguments += ["--due", dueAt.ISO8601Format()] }
        arguments += ["--profile", profile.argument, "--format", "json", "--yes"]
        let output = try run(executableURL, arguments: arguments)
        return DingTalkCLIResult(data: Data(output.output.utf8), exitCode: output.status)
    }

    func listProfiles() throws -> [DingTalkProfile] {
        guard let executableURL = resolveExecutable() else { throw DingTalkCLIError.notInstalled }
        let result = try run(executableURL, arguments: ["profile", "list", "--format", "json"])
        guard result.status == 0 else { throw DingTalkCLIError.classifying(exitCode: result.status, stderr: result.errorData) }
        guard result.status == 0, let data = result.output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              object["ok"] as? Bool != false,
              object["outcome"] as? String != "failure" else {
            throw DingTalkCLIError.invalidResponse
        }
        var profiles: [DingTalkProfile] = []
        collectProfiles(in: object, into: &profiles)
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.id).inserted }
    }

    func checkStatus() -> DingTalkCLIStatus {
        guard let executableURL = resolveExecutable() else { return .notInstalled }

        do {
            let version = try run(executableURL, arguments: ["version", "--format", "json"])
            guard version.status == 0 else { return .checkFailed }
            let selectedIDs = AssistantRuntime.preferences.stringArray(forKey: "dingTalkSelectedProfiles") ?? []
            for profile in selectedIDs.isEmpty ? [nil] : selectedIDs.map(Optional.some) {
                var arguments = ["auth", "status", "--format", "json"]
                if let profile { arguments += ["--profile", profile] }
                let auth = try run(executableURL, arguments: arguments)
                guard auth.status == 0, let data = auth.output.data(using: .utf8),
                      Self.isAuthenticated(data, expectedProfileID: profile) else { return .loginRequired }
            }
            return .connected
        } catch {
            return .checkFailed
        }
    }

    static func isAuthenticated(_ data: Data, expectedProfileID: String?) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == true,
              root["authenticated"] as? Bool == true,
              root["token_valid"] as? Bool == true else { return false }
        guard let expectedProfileID else { return true }
        guard let corpID = root["corp_id"] as? String, let userID = root["user_id"] as? String else { return false }
        return "\(corpID):\(userID)" == expectedProfileID
    }

    func resolveExecutable() -> URL? {
        var candidates: [URL] = []
        let fileManager = FileManager.default
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += pathValue.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("dws")
        }
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/dws"),
            URL(fileURLWithPath: "/usr/local/bin/dws"),
            URL(fileURLWithPath: "/usr/bin/dws"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin/dws"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".volta/bin/dws"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/dws")
        ]
        let nvmVersions = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(at: nvmVersions, includingPropertiesForKeys: nil) {
            candidates += versions.map { $0.appendingPathComponent("bin/dws") }
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func collectProfiles(in value: Any, into profiles: inout [DingTalkProfile]) {
        if let object = value as? [String: Any] {
            if let corpID = object["corpId"] as? String,
               let userID = object["userId"] as? String,
               let corpName = object["corpName"] as? String {
                profiles.append(DingTalkProfile(
                    corpID: corpID,
                    userID: userID,
                    corpName: corpName,
                    userName: object["userName"] as? String,
                    isOrgCurrent: object["isOrgCurrent"] as? Bool ?? false
                ))
            }
            for child in object.values { collectProfiles(in: child, into: &profiles) }
        } else if let array = value as? [Any] {
            for child in array { collectProfiles(in: child, into: &profiles) }
        }
    }

    static func processEnvironment(for executableURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TZ"] = TimeZone.current.identifier
        var paths = [executableURL.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let nvmRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: nil) {
            paths += versions.map { $0.appendingPathComponent("bin").path }
        }
        if let existing = environment["PATH"], !existing.isEmpty { paths.append(existing) }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }

    private func run(_ executableURL: URL, arguments: [String]) throws -> (status: Int32, output: String, errorData: Data) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        let environment = Self.processEnvironment(for: executableURL)
        process.environment = environment
        process.standardOutput = pipe
        let errorPipe = Pipe()
        let capturedError = DingTalkErrorBuffer()
        let errorGroup = DispatchGroup()
        process.standardError = errorPipe
        try process.run()
        errorGroup.enter()
        DispatchQueue.global().async {
            defer { errorGroup.leave() }
            capturedError.drain(errorPipe.fileHandleForReading)
        }
        let deadline = DingTalkProcessDeadline()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                deadline.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        if errorGroup.wait(timeout: .now() + 2) == .timedOut { try? errorPipe.fileHandleForReading.close() }
        if deadline.timedOut { throw DingTalkCLIError.timedOut }
        return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "", capturedError.snapshot)
    }
}

private final class DingTalkProcessDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func markTimedOut() { lock.lock(); value = true; lock.unlock() }
}


extension DingTalkCLIError {
    static func classifying(exitCode: Int32, stderr: Data) -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: stderr) as? [String: Any],
              let error = root["error"] as? [String: Any], let category = error["category"] as? String,
              ["auth", "api", "validation", "discovery", "internal"].contains(category) else { return .commandFailed(exitCode: exitCode) }
        // Only the stable category survives. Never display raw server text, tokens or IDs.
        return .classifiedFailure(category: category)
    }
}
private final class DingTalkErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var snapshot: Data { lock.lock(); defer { lock.unlock() }; return data }
    func drain(_ handle: FileHandle) {
        while let bytes = try? handle.read(upToCount: 4_096), !bytes.isEmpty {
            lock.lock()
            if data.count < 65_536 { data.append(bytes.prefix(65_536 - data.count)) }
            lock.unlock()
        }
    }
}
