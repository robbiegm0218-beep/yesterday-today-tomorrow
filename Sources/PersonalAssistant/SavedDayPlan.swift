import Foundation

struct DayPlanStep: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var sourceKind: String = "note"
    var sourceID: String?
    var plannedTime: String = ""
    var durationMinutes: Int = 30
    var preparation: String = ""
    var reason: String = ""
    var isDone = false
    var carriedFrom: DayCarryOrigin? = nil
}

struct SavedDayPlan: Identifiable, Codable, Equatable {
    var id: String { day }
    var day: String
    var timeZone: String
    var revision = 0
    var updatedAt = Date()
    var steps: [DayPlanStep]
    var sourceActionID: UUID?
    var reviewDecisions: [DayReviewDecision]? = nil
    var reviewActionID: UUID? = nil
}

struct DayPlanReference {
    let kind: String
    let id: String
    let title: String
    var time: String = ""
    var duration: Int = 30

    func matches(kind: String, sourceID: String?) -> Bool {
        guard self.kind == kind, let sourceID else { return false }
        if kind == "personal", let a = UUID(uuidString: id), let b = UUID(uuidString: sourceID) { return a == b }
        return id == sourceID
    }
}

enum SavedDayPlanPolicy {
    static func preservingProgress(in draft: SavedDayPlan, from old: SavedDayPlan?) -> SavedDayPlan {
        guard let old else { return draft }
        var result = draft
        var used = Set<UUID>()
        for index in result.steps.indices {
            let step = result.steps[index]
            let matches = old.steps.filter { previous in
                guard !used.contains(previous.id), previous.sourceKind == step.sourceKind else { return false }
                if step.sourceKind != "note" { return previous.sourceID == step.sourceID }
                return previous.title == step.title
            }
            let previous = matches.count == 1 ? matches.first : matches.first { $0.plannedTime == step.plannedTime }
            if let previous {
                result.steps[index].id = previous.id
                result.steps[index].isDone = previous.isDone
                used.insert(previous.id)
            }
        }
        return result
    }

    struct Input: Decodable {
        let title: String
        var sourceKind: String?
        var sourceID: String?
        var plannedTime: String?
        var durationMinutes: Int?
        var preparation: String?
        var reason: String?
    }

    static func proposal(json: String, references: [DayPlanReference], now: Date = Date()) throws -> SavedDayPlan {
        guard json.utf8.count <= 30_000 else { throw DayPlanError.invalid("计划内容过长。") }
        let inputs = try JSONDecoder().decode([Input].self, from: Data(json.utf8))
        let steps = inputs.map { value in
            DayPlanStep(title: value.title, sourceKind: value.sourceKind ?? "note", sourceID: value.sourceID,
                plannedTime: value.plannedTime ?? "", durationMinutes: value.durationMinutes ?? 30,
                preparation: value.preparation ?? "", reason: value.reason ?? "")
        }
        return try validated(SavedDayPlan(day: DailyPlanSchedulePolicy.dayKey(for: now), timeZone: TimeZone.current.identifier, steps: steps), references: references, now: now, canonicalize: true)
    }

    static func validateShape(_ plan: SavedDayPlan) throws {
        try DayReviewPolicy.validateReview(in: plan)
        guard AssistantActionParser.date(from: plan.day) != nil, TimeZone(identifier: plan.timeZone) != nil,
              (0..<1_000_000).contains(plan.revision), plan.steps.count <= 20,
              Set(plan.steps.map(\.id)).count == plan.steps.count else { throw DayPlanError.invalid("计划日期或条目无效，最多20项。") }
        var sources = Set<String>()
        for step in plan.steps {
            guard !step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, step.title.count <= 160,
                  ["note", "personal", "external", "event"].contains(step.sourceKind),
                  (step.sourceID?.count ?? 0) <= 1_000, (1...480).contains(step.durationMinutes),
                  step.preparation.count <= 500, step.reason.count <= 500,
                  step.plannedTime.isEmpty || validTime(step.plannedTime) else { throw DayPlanError.invalid("请检查标题、时间和预计用时（1–480分钟）。") }
            if step.sourceKind != "note" {
                guard let id = step.sourceID, !id.isEmpty else { throw DayPlanError.invalid("来源事项缺失，请调整计划。") }
                let canonicalID = step.sourceKind == "personal" ? UUID(uuidString: id)?.uuidString ?? id : id
                guard sources.insert(step.sourceKind + ":" + canonicalID).inserted else { throw DayPlanError.invalid("来源事项重复，请调整计划。") }
            } else if step.sourceID != nil { throw DayPlanError.invalid("独立安排不应关联来源ID。") }
        }
    }

    static func validated(_ plan: SavedDayPlan, references: [DayPlanReference], now: Date = Date(), canonicalize: Bool = false, preserving baseline: SavedDayPlan? = nil) throws -> SavedDayPlan {
        try validateShape(plan)
        guard plan.day == DailyPlanSchedulePolicy.dayKey(for: now), plan.timeZone == TimeZone.current.identifier else { throw DayPlanError.invalid("日期或时区已变化，请重新安排今天。") }
        var result = plan
        for index in result.steps.indices where result.steps[index].sourceKind != "note" {
            if baseline?.steps.contains(result.steps[index]) == true { continue }
            guard let reference = references.first(where: { $0.matches(kind: result.steps[index].sourceKind, sourceID: result.steps[index].sourceID) }) else {
                throw DayPlanError.invalid("来源事项已完成、隐藏、删除或尚未同步。请移除该项，或改为独立安排后保存。")
            }
            if !canonicalize, (result.steps[index].title != String(reference.title.prefix(160)) || (reference.kind == "event" && (result.steps[index].plannedTime != reference.time || result.steps[index].durationMinutes != min(480, max(1, reference.duration))))) {
                throw DayPlanError.invalid("源事项标题或日程时间已变化，请重新打开调整页核对后保存。")
            }
            result.steps[index].title = String(reference.title.prefix(160))
            result.steps[index].sourceID = reference.id
            if reference.kind == "event" {
                result.steps[index].plannedTime = reference.time
                result.steps[index].durationMinutes = min(480, max(1, reference.duration))
            }
        }
        return result
    }

    static func saving(_ draft: SavedDayPlan, among plans: [SavedDayPlan], expectedRevision: Int, references: [DayPlanReference], actionID: UUID? = nil, now: Date = Date()) throws -> [SavedDayPlan] {
        let existing = plans.first { $0.day == draft.day }
        if let actionID, existing?.sourceActionID == actionID { return plans }
        guard (0..<999_999).contains(expectedRevision), (existing?.revision ?? 0) == expectedRevision else { throw DayPlanError.invalid("计划已在别处更新，请重新打开最新版本，避免覆盖。") }
        var plan = try validated(draft, references: references, now: now, preserving: existing)
        plan.revision = expectedRevision + 1
        plan.updatedAt = now
        plan.sourceActionID = actionID
        return ([plan] + plans.filter { $0.day != plan.day }).sorted { $0.day > $1.day }
    }

    static func validTime(_ value: String) -> Bool {
        guard value.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 && parts[0] < 24 && parts[1] < 60
    }
}

enum DayPlanError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

enum LocalDayPlanStore {
    private static var url: URL { LocalAssistantPaths.dataDirectory.appendingPathComponent("saved-day-plans.json") }
    static func load() -> [SavedDayPlan] { (LocalJSONFileStore.load(from: url, as: [SavedDayPlan].self) ?? []).sorted { $0.day > $1.day } }
    static func save(_ plans: [SavedDayPlan]) throws { try LocalJSONFileStore.save(plans, to: url) }
}
