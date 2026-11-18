import Foundation

struct AssistantProject: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var dueAt: Date?
    var progressNote: String
    var updatedAt: Date = Date()
    var nextStep: String?
    var blocker: String?
    var waitingFor: String?
    var status: String?
    var progressUpdatedAt: Date?
    var previousNames: [String]?
    var lastActionID: UUID?
}

enum ProjectUpdatePolicy {
    static let statuses = ["推进中", "受阻", "等待回复", "已完成"]
    static func nameKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func validate(_ project: AssistantProject) throws {
        guard !nameKey(project.name).isEmpty, project.name.count <= 100, project.progressNote.count <= 1_000,
              [project.nextStep, project.blocker, project.waitingFor].allSatisfy({ ($0?.count ?? 0) <= 500 }),
              project.status.map({ statuses.contains($0) }) ?? true,
              (project.previousNames?.count ?? 0) <= 50, project.previousNames?.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) ?? true else {
            throw ProjectUpdateError.invalid("请检查项目名称、状态及跟进内容长度；名称最多100字，进展1000字，其他说明500字。")
        }
    }
    static func saving(_ candidate: AssistantProject, among projects: [AssistantProject], expectedUpdatedAt: Date?, actionID: UUID? = nil, now: Date = Date()) throws -> [AssistantProject] {
        let existing = projects.first { $0.id == candidate.id }
        if let actionID, existing?.lastActionID == actionID { return projects }
        guard existing?.updatedAt == expectedUpdatedAt else { throw ProjectUpdateError.invalid("项目已更新或删除，请重新打开最新项目后再保存，避免覆盖。") }
        var updated = candidate
        updated.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.progressNote = candidate.progressNote.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.nextStep = cleaned(candidate.nextStep)
        updated.blocker = cleaned(candidate.blocker)
        updated.waitingFor = cleaned(candidate.waitingFor)
        updated.status = cleaned(candidate.status)
        var names = existing?.previousNames ?? []
        if let existing, nameKey(existing.name) != nameKey(updated.name), !names.contains(existing.name) { names.append(existing.name) }
        updated.previousNames = names.isEmpty ? nil : names
        try validate(updated)
        let allNames = Set(([updated.name] + names).map(nameKey))
        let oldClaims = Set(existing.map { ([$0.name] + ($0.previousNames ?? [])).map(nameKey) } ?? [])
        let addedClaims = allNames.subtracting(oldClaims)
        guard !projects.contains(where: { other in other.id != updated.id && !addedClaims.isDisjoint(with: ([other.name] + (other.previousNames ?? [])).map(nameKey)) }) else {
            throw ProjectUpdateError.invalid("名称与已有项目或其旧名称重复，请编辑现有项目，不要重复创建。")
        }
        let progressChanged = existing == nil || existing?.progressNote != updated.progressNote || existing?.nextStep != updated.nextStep || existing?.blocker != updated.blocker || existing?.waitingFor != updated.waitingFor || existing?.status != updated.status
        let hasProgress = !updated.progressNote.isEmpty || updated.nextStep != nil || updated.blocker != nil || updated.waitingFor != nil || updated.status != nil
        updated.progressUpdatedAt = existing == nil && !hasProgress ? nil : (progressChanged ? now : existing?.progressUpdatedAt)
        updated.updatedAt = now
        updated.lastActionID = actionID ?? existing?.lastActionID
        return ([updated] + projects.filter { $0.id != updated.id }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

enum ProjectUpdateError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
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
