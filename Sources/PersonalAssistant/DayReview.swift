import Foundation

struct DayCarryOrigin: Codable, Equatable {
    let day: String
    let timeZone: String
    let stepID: UUID
}
struct DayReviewHistory: Codable, Equatable {
    let choice: String
    let targetDay: String?
    let reason: String
    let recordedAt: Date
}
struct DayReviewDecision: Codable, Equatable, Identifiable {
    var id: UUID { stepID }
    let stepID: UUID
    let choice: String
    let targetDay: String?
    let reason: String
    let recordedAt: Date
    var appliedDay: String?
    var targetStepID: UUID?
    var history: [DayReviewHistory] = []
}
struct DayReviewInput: Codable, Equatable {
    let stepID: UUID
    let choice: String
    var targetDay: String?
    var plannedTime: String?
    var reason: String?
    enum CodingKeys: String, CodingKey { case choice, reason; case stepID = "step_id"; case targetDay = "target_day"; case plannedTime = "planned_time" }
}
struct DayReviewProposal: Codable, Equatable {
    var id = UUID()
    let original: SavedDayPlan
    let todayOriginal: SavedDayPlan?
    let todayProposed: SavedDayPlan?
    let decisions: [DayReviewDecision]
    let quote: String?
    let sourceMessageID: UUID?
    let targetDay: String
    let timeZone: String
}
struct DayReviewToolArguments: Decodable {
    let sourceDay: String
    let choicesJSON: String
    let quote: String
    enum CodingKeys: String, CodingKey { case quote; case sourceDay = "source_day"; case choicesJSON = "choices_json" }
}

enum DayReviewPolicy {
    static func yesterday(now: Date = Date(), calendar: Calendar = .current) -> String {
        DailyPlanSchedulePolicy.dayKey(for: calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar: calendar)
    }
    static func availableOrigins(plans: [SavedDayPlan], now: Date = Date()) -> [SavedDayPlan] {
        let today = DailyPlanSchedulePolicy.dayKey(for: now), previous = yesterday(now: now)
        return plans.filter { plan in
            plan.day < today && plan.timeZone == TimeZone.current.identifier && (plan.day == previous || (plan.reviewDecisions ?? []).contains { $0.choice == "later" && $0.appliedDay == nil && ($0.targetDay.map { $0 <= today } ?? false) })
        }.sorted { $0.day > $1.day }
    }
    static func validateReview(in plan: SavedDayPlan) throws {
        let decisions = plan.reviewDecisions ?? []
        guard decisions.count <= 20, Set(decisions.map(\.stepID)).count == decisions.count else { throw DayPlanError.invalid("回顾决策重复或超出上限。") }
        for item in decisions {
            guard plan.steps.contains(where: { $0.id == item.stepID && !$0.isDone }), ["today", "later", "skip"].contains(item.choice), item.reason.count <= 500, item.history.count <= 10,
                  item.targetDay.map({ AssistantActionParser.date(from: $0) != nil && $0 > plan.day }) ?? (item.choice == "skip"),
                  (item.appliedDay == nil) == (item.targetStepID == nil),
                  item.appliedDay.map({ AssistantActionParser.date(from: $0) != nil && $0 > plan.day }) ?? true,
                  item.history.allSatisfy({ ["today", "later", "skip"].contains($0.choice) && $0.reason.count <= 500 && ($0.targetDay.map { AssistantActionParser.date(from: $0) != nil } ?? true) }) else {
                throw DayPlanError.invalid("昨日回顾记录无效，原计划保留。")
            }
        }
        for step in plan.steps {
            if let origin = step.carriedFrom {
                guard AssistantActionParser.date(from: origin.day) != nil, origin.day < plan.day, TimeZone(identifier: origin.timeZone) != nil else { throw DayPlanError.invalid("安排衔接来源无效。") }
            }
        }
    }
    static func proposal(origin: SavedDayPlan, today: SavedDayPlan?, inputs: [DayReviewInput], references: [DayPlanReference], quote: String? = nil, sourceMessageID: UUID? = nil, now: Date = Date()) throws -> DayReviewProposal {
        let day = DailyPlanSchedulePolicy.dayKey(for: now), zone = TimeZone.current.identifier
        guard origin.day < day, origin.timeZone == zone, !inputs.isEmpty, inputs.count <= 20,
              Set(inputs.map(\.stepID)).count == inputs.count, today.map({ $0.day == day && $0.timeZone == zone }) ?? true else { throw DayPlanError.invalid("回顾日期、时区或选择已失效，请重新核对。") }
        try SavedDayPlanPolicy.validateShape(origin)
        var target = today ?? SavedDayPlan(day: day, timeZone: zone, steps: [])
        var decisions = origin.reviewDecisions ?? []
        var added = false
        for input in inputs {
            guard let source = origin.steps.first(where: { $0.id == input.stepID && !$0.isDone }), ["today", "later", "skip"].contains(input.choice) else { throw DayPlanError.invalid("只能处理尚未勾选的原安排。") }
            let existing = decisions.first { $0.stepID == source.id }
            guard existing?.appliedDay == nil else { throw DayPlanError.invalid("该安排已经衔接过，不能重复迁入。") }
            let reason = input.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard reason.count <= 500 else { throw DayPlanError.invalid("未完成原因最多500字；未知可留空。") }
            var decision = DayReviewDecision(stepID: source.id, choice: input.choice, targetDay: input.choice == "today" ? day : input.choice == "later" ? input.targetDay : nil, reason: reason, recordedAt: now)
            if let existing {
                decision.history = Array((existing.history + [.init(choice: existing.choice, targetDay: existing.targetDay, reason: existing.reason, recordedAt: existing.recordedAt)]).suffix(10))
            }
            if input.choice == "later" {
                guard let requested = input.targetDay, AssistantActionParser.date(from: requested) != nil, requested > day, source.sourceKind != "event" else { throw DayPlanError.invalid("请选择今天以后的日期；历史日程不自动改期。") }
            }
            if input.choice == "today" {
                guard source.sourceKind != "event" else { throw DayPlanError.invalid("昨日会议不能复制成今天的日程，请另行安排会后行动。") }
                var step = source
                step.id = UUID(); step.isDone = false; step.plannedTime = input.plannedTime ?? ""
                step.reason = String(("衔接" + origin.day + "的未勾选安排" + (reason.isEmpty ? "" : "；原话：" + reason)).prefix(500))
                step.carriedFrom = .init(day: origin.day, timeZone: origin.timeZone, stepID: source.id)
                let duplicate = target.steps.first { candidate in
                    if candidate.carriedFrom == step.carriedFrom { return true }
                    return source.sourceKind != "note" && candidate.sourceKind == source.sourceKind && DayPlanReference(kind: source.sourceKind, id: source.sourceID ?? "", title: "").matches(kind: candidate.sourceKind, sourceID: candidate.sourceID)
                }
                if let duplicate {
                    decision.appliedDay = day; decision.targetStepID = duplicate.id
                } else {
                    let current = try SavedDayPlanPolicy.validated(.init(day: day, timeZone: zone, steps: [step]), references: references, now: now, canonicalize: true).steps[0]
                    target.steps.append(current); decision.appliedDay = day; decision.targetStepID = current.id; added = true
                }
            }
            decisions.removeAll { $0.stepID == source.id }; decisions.append(decision)
        }
        if added { _ = try SavedDayPlanPolicy.validated(target, references: references, now: now, preserving: today) }
        var updatedOrigin = origin; updatedOrigin.reviewDecisions = decisions; try validateReview(in: updatedOrigin)
        return .init(original: origin, todayOriginal: today, todayProposed: added ? target : nil, decisions: decisions, quote: quote, sourceMessageID: sourceMessageID, targetDay: day, timeZone: zone)
    }
    static func saving(_ proposal: DayReviewProposal, among plans: [SavedDayPlan], references: [DayPlanReference], now: Date = Date()) throws -> [SavedDayPlan] {
        let currentOrigin = plans.first { $0.day == proposal.original.day }
        if currentOrigin?.reviewActionID == proposal.id { return plans }
        guard proposal.targetDay == DailyPlanSchedulePolicy.dayKey(for: now), proposal.timeZone == TimeZone.current.identifier,
              currentOrigin == proposal.original, plans.first(where: { $0.day == proposal.targetDay }) == proposal.todayOriginal else { throw DayPlanError.invalid("日期、原回顾或今日计划已有变化，请重新预览，避免覆盖。") }
        var result = plans
        if let target = proposal.todayProposed {
            result = try SavedDayPlanPolicy.saving(target, among: result, expectedRevision: proposal.todayOriginal?.revision ?? 0, references: references, actionID: proposal.id, now: now)
        }
        guard let index = result.firstIndex(where: { $0.day == proposal.original.day }) else { throw DayPlanError.invalid("原计划已不存在。") }
        result[index].reviewDecisions = proposal.decisions; result[index].reviewActionID = proposal.id
        try validateReview(in: result[index])
        return result.sorted { $0.day > $1.day }
    }
}
