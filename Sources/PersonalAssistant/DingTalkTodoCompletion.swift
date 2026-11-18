import Foundation

protocol DingTalkTodoCompleting: DingTalkReading {
    func completeTodo(taskID: String, profile: DingTalkProfile) throws -> DingTalkCLIResult
}

struct DingTalkTodoCompletionTarget: Equatable {
    let localID: String
    let taskID: String
    let title: String
    let profile: DingTalkProfile
    let modifiedTime: Double
    let isDone: Bool
}

enum DingTalkTodoCompletionError: LocalizedError {
    case invalidTarget, changed, notExecutor, unverified
    var errorDescription: String? {
        switch self {
        case .invalidTarget: "无法核对该待办及所属组织，请刷新后重新打开。"
        case .changed: "待办或接入组织已变化，请关闭后重新核对再确认。"
        case .notExecutor: "未能证明你是该待办的执行人，请到钉钉处理。"
        case .unverified: "完成请求的结果尚未核验。请点击“重新核验”，不会重复提交；也可到钉钉查看。"
        }
    }
}

struct DingTalkTodoCompletionService {
    let client: any DingTalkTodoCompleting
    init(client: any DingTalkTodoCompleting = DingTalkCLIClient()) { self.client = client }

    // Prefixes are built from actual selected profiles; never split task IDs on '-'.
    func prepare(localID: String, expectedTitle: String, selectedIDs: Set<String>) throws -> DingTalkTodoCompletionTarget {
        let matches = try client.listProfiles().filter { selectedIDs.contains($0.id) && localID.hasPrefix("dingtalk-\($0.id)-") }
        guard matches.count == 1, let profile = matches.first else { throw DingTalkTodoCompletionError.invalidTarget }
        let taskID = String(localID.dropFirst("dingtalk-\(profile.id)-".count))
        guard !taskID.isEmpty else { throw DingTalkTodoCompletionError.invalidTarget }
        let target = try detail(localID: localID, taskID: taskID, profile: profile)
        guard target.title == expectedTitle else { throw DingTalkTodoCompletionError.changed }
        if !target.isDone { try verifyExecutor(target) }
        return target
    }

    /// Final UI confirmation is required. Read again before writing to reject stale previews.
    func completeConfirmed(_ target: DingTalkTodoCompletionTarget, selectedIDs: Set<String>) throws -> DingTalkTodoCompletionTarget {
        guard selectedIDs.contains(target.profile.id), try client.listProfiles().contains(target.profile) else { throw DingTalkTodoCompletionError.changed }
        let latest = try detail(localID: target.localID, taskID: target.taskID, profile: target.profile)
        guard latest.title == target.title else { throw DingTalkTodoCompletionError.changed }
        if latest.isDone { return latest }
        guard !target.isDone, latest.modifiedTime == target.modifiedTime else { throw DingTalkTodoCompletionError.changed }
        try verifyExecutor(latest)
        // No automatic replay after a timeout or an ambiguous response.
        do { _ = try DingTalkJSON.decode(client.completeTodo(taskID: target.taskID, profile: target.profile)) }
        catch { throw DingTalkTodoCompletionError.unverified }
        return try verifyCompleted(target, selectedIDs: selectedIDs)
    }

    func verifyCompleted(_ target: DingTalkTodoCompletionTarget, selectedIDs: Set<String>) throws -> DingTalkTodoCompletionTarget {
        guard selectedIDs.contains(target.profile.id) else { throw DingTalkTodoCompletionError.changed }
        do {
            let latest = try detail(localID: target.localID, taskID: target.taskID, profile: target.profile)
            guard latest.isDone else { throw DingTalkTodoCompletionError.unverified }
            return latest
        } catch { throw DingTalkTodoCompletionError.unverified }
    }

    private func detail(localID: String, taskID: String, profile: DingTalkProfile) throws -> DingTalkTodoCompletionTarget {
        let root = try DingTalkJSON.decode(client.run(.todoDetails(id: taskID), profile: profile))
        guard let result = root["result"] as? [String: Any], let detail = result["todoDetailModel"] as? [String: Any],
              detail["taskId"] as? String == taskID, let title = detail["subject"] as? String, !title.isEmpty,
              let done = detail["isDone"] as? Bool, let modified = detail["modifiedTime"] as? NSNumber else { throw DingTalkTodoCompletionError.invalidTarget }
        return .init(localID: localID, taskID: taskID, title: title, profile: profile, modifiedTime: modified.doubleValue, isDone: done)
    }

    private func verifyExecutor(_ target: DingTalkTodoCompletionTarget) throws {
        // Org employee IDs can differ from the internal Todo identity. Prove
        // membership using the authenticated executor-scoped collection.
        let root = try DingTalkJSON.decode(client.run(.ownOpenTodos, profile: target.profile))
        guard let data = root["data"] as? [String: Any], data["complete"] as? Bool == true,
              let todos = data["todos"] as? [[String: Any]], data["count"] as? Int == todos.count,
              todos.filter({ $0["taskId"] as? String == target.taskID }).count == 1 else { throw DingTalkTodoCompletionError.notExecutor }
    }
}

extension DailyDataSnapshot {
    func completingExternalTodo(_ id: String) -> DailyDataSnapshot {
        let updated = todos.map { todo -> TodoRecord in
            guard !todo.isPersonal, todo.id == id else { return todo }
            return TodoRecord(id: todo.id, title: todo.title, dueAt: todo.dueAt, importance: todo.importance,
                projectName: todo.projectName, relatedEventID: todo.relatedEventID, sourceURL: todo.sourceURL,
                isComplete: true, isPersonal: false, owner: todo.owner, dueText: todo.dueText, sourceQuote: todo.sourceQuote)
        }
        return .init(events: events, todos: updated, sourceLabel: sourceLabel, usesDemoData: usesDemoData)
    }
}
