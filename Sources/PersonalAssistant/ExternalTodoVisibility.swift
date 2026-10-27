import Foundation

struct HiddenExternalTodo: Codable, Identifiable {
    let id: String
    let title: String
    let hiddenAt: Date
}

enum ExternalTodoVisibilityStore {
    private static var fileURL: URL {
        LocalAssistantPaths.dataDirectory.appendingPathComponent("hidden-external-todos.json")
    }

    static func load() -> [HiddenExternalTodo] {
        LocalJSONFileStore.load(from: fileURL, as: [HiddenExternalTodo].self) ?? []
    }

    static func save(_ items: [HiddenExternalTodo]) throws {
        try LocalJSONFileStore.save(items, to: fileURL)
    }
}

extension DailyDataSnapshot {
    func excludingHiddenExternalTodos(_ hiddenIDs: Set<String>) -> DailyDataSnapshot {
        DailyDataSnapshot(events: events,
                          todos: todos.filter { $0.isPersonal || !hiddenIDs.contains($0.id) },
                          sourceLabel: sourceLabel, usesDemoData: usesDemoData)
    }
}
