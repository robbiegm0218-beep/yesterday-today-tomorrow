import Foundation

struct AssistantProject: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var dueAt: Date?
    var progressNote: String
    var updatedAt: Date = Date()
}

enum LocalProjectStore {
    private static var fileURL: URL {
        LocalAssistantPaths.dataDirectory.appendingPathComponent("projects.json")
    }

    static func load() -> [AssistantProject] {
        LocalJSONFileStore.load(from: fileURL, as: [AssistantProject].self) ?? []
    }

    static func save(_ projects: [AssistantProject]) throws {
        try LocalJSONFileStore.save(projects, to: fileURL)
    }
}
