import Foundation

struct DingTalkCompletedTodo: Identifiable {
    let id: String
    let title: String
    let profile: DingTalkProfile
}
extension DingTalkTodoMutationService {
    func completed(selected: Set<String>) throws -> (items: [DingTalkCompletedTodo], total: Int) {
        let profiles = try client.listProfiles().filter { selected.contains($0.id) }
        guard !selected.isEmpty, Set(profiles.map(\.id)) == selected else { throw DingTalkTodoMutationError.changed }
        var items: [DingTalkCompletedTodo] = []
        for profile in profiles {
            let root = try DingTalkJSON.decode(client.run(.ownCompletedTodos, profile: profile))
            guard let data = root["data"] as? [String: Any], data["complete"] as? Bool == true,
                  let todos = data["todos"] as? [[String: Any]], data["count"] as? Int == todos.count else { throw DingTalkContentError.incomplete }
            for todo in todos {
                guard let id = todo["taskId"] as? String, !id.isEmpty, let title = todo["subject"] as? String, !title.isEmpty else { throw DingTalkTodoMutationError.invalid }
                items.append(.init(id: "dingtalk-\(profile.id)-\(id)", title: title, profile: profile))
            }
        }
        guard Set(items.map(\.id)).count == items.count else { throw DingTalkContentError.incomplete }
        return (Array(items.prefix(200)), items.count)
    }
}
extension DailyDataSnapshot {
    func applyingVerifiedExternalTodo(_ target: DingTalkTodoMutationTarget) -> DailyDataSnapshot {
        let original = todos.first { $0.id == target.localID && !$0.isPersonal }
        let importance: TaskImportance = target.priority >= 30 ? .high : target.priority == 10 ? .low : .normal
        let record = TodoRecord(id: target.localID, title: target.title, dueAt: target.dueAt, importance: importance, projectName: original?.projectName,
            relatedEventID: original?.relatedEventID, sourceURL: original?.sourceURL, isComplete: target.isDone, isPersonal: false, owner: original?.owner)
        return .init(events: events, todos: todos.filter { $0.id != target.localID } + [record], sourceLabel: sourceLabel, usesDemoData: usesDemoData)
    }
}
