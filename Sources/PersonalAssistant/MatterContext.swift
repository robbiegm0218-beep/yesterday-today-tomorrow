import Foundation

struct MatterReference: Codable, Hashable {
    let kind: String
    let id: String
    static func personal(_ id: UUID) -> Self { .init(kind: "personal", id: id.uuidString) }
    static func project(_ id: UUID) -> Self { .init(kind: "project", id: id.uuidString) }
    static func task(_ task: TaskItem) -> Self {
        if task.isPersonal, let id = UUID(uuidString: String(task.id.dropFirst("personal-".count))) { return .personal(id) }
        return .init(kind: "external", id: task.id)
    }
    var sourceLabel: String { ["personal": "本地待办", "external": "钉钉待办", "project": "本地项目"][kind] ?? "未知来源" }
    var isValid: Bool {
        if kind == "external" { return id.hasPrefix("dingtalk-") && id.count <= 1_000 }
        return ["personal", "project"].contains(kind) && UUID(uuidString: id)?.uuidString == id
    }
}

struct MatterTarget: Identifiable, Equatable, Encodable {
    var id: String { reference.kind + ":" + reference.id }
    let reference: MatterReference
    let title: String
}

struct MatterContextEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    let reference: MatterReference
    let category: String
    let content: String
    let quote: String
    let sourceMessageID: UUID?
    let recordedAt: Date
}

enum MatterContextPolicy {
    static let categories = ["进展", "阻塞", "等待", "决策", "补充", "更正"]
    static func validate(_ entries: [MatterContextEntry]) throws {
        guard entries.count <= 5_000, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ $0.reference.isValid && categories.contains($0.category) &&
                  !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.content.count <= 1_000 &&
                  !$0.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.quote.count <= 1_000 && $0.recordedAt.timeIntervalSince1970.isFinite }) else {
            throw ProjectUpdateError.invalid("事项记录无效或超出上限；原记录保留。")
        }
    }
    static func appending(_ entry: MatterContextEntry, expectedRevision: Int, entries: [MatterContextEntry], targets: [MatterTarget]) throws -> [MatterContextEntry] {
        try validate(entries)
        if let existing = entries.first(where: { $0.id == entry.id }) {
            guard existing == entry else { throw ProjectUpdateError.invalid("操作标识冲突，请重新生成记录。") }
            return entries
        }
        guard targets.contains(where: { $0.reference == entry.reference }) else { throw ProjectUpdateError.invalid("原事项已删除、隐藏或不在当前来源中；请刷新核对，不会新建替代事项。") }
        let previous = entries.filter { $0.reference == entry.reference }
        guard previous.count == expectedRevision else { throw ProjectUpdateError.invalid("该事项已有新的记录，请查看最新进展后重新确认。") }
        guard !previous.contains(where: { $0.category == entry.category && $0.content == entry.content && $0.quote == entry.quote }) else {
            throw ProjectUpdateError.invalid("相同记录已经保存，没有重复追加。")
        }
        let result = entries + [entry]
        try validate(result)
        return result
    }
    static func targets(todos: [PersonalTodo], projects: [AssistantProject], external: [TodoRecord]) -> [MatterTarget] {
        todos.map { .init(reference: .personal($0.id), title: $0.title) } +
        projects.map { .init(reference: .project($0.id), title: $0.name) } +
        external.filter { !$0.isPersonal }.map { .init(reference: .init(kind: "external", id: $0.id), title: $0.title) }
    }
    static func confirmedProject(named name: String?, projects: [AssistantProject]) -> AssistantProject? {
        guard let name else { return nil }
        let matches = projects.filter { ([$0.name] + ($0.previousNames ?? [])).contains { ProjectUpdatePolicy.nameKey($0) == ProjectUpdatePolicy.nameKey(name) } }
        return matches.count == 1 ? matches.first : nil
    }
}

struct MatterContextStore {
    var directory = LocalAssistantPaths.dataDirectory
    var url: URL { directory.appendingPathComponent("matter-context.json") }
    func load() throws -> [MatterContextEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let entries = try JSONDecoder().decode([MatterContextEntry].self, from: Data(contentsOf: url))
            try MatterContextPolicy.validate(entries)
            return entries
        } catch { throw ProjectUpdateError.invalid("事项记录无法读取，已暂停保存；原文件保留，请检查本机资料。") }
    }
    func save(_ entries: [MatterContextEntry]) throws {
        _ = try load() // Never overwrite unreadable evidence with an empty fallback.
        try MatterContextPolicy.validate(entries)
        try LocalJSONFileStore.save(entries, to: url)
    }
}

struct MatterContextToolArguments: Decodable {
    let kind: String
    let targetID: String
    let category: String
    let content: String
    let quote: String
    enum CodingKeys: String, CodingKey { case kind, category, content, quote; case targetID = "target_id" }
}
