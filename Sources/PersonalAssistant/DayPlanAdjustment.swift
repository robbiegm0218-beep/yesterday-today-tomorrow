import Foundation

struct DayPlanAdjustment: Codable, Equatable {
    let original: SavedDayPlan
    let proposed: SavedDayPlan
    let reason: String
    let quote: String
    let sourceMessageID: UUID
}

struct DayPlanAdjustmentArguments: Decodable {
    let operationsJSON: String
    let reason: String
    let quote: String
    enum CodingKeys: String, CodingKey { case reason, quote; case operationsJSON = "operations_json" }
}

enum DayPlanAdjustmentPolicy {
    struct Operation: Decodable {
        let action: String
        let stepID: UUID?
        let afterStepID: String?
        let step: SavedDayPlanPolicy.Input?
        let title: String?
        let plannedTime: String?
        let durationMinutes: Int?
        let preparation: String?
        let reason: String?
        enum CodingKeys: String, CodingKey {
            case action, step, title, plannedTime, durationMinutes, preparation, reason
            case stepID = "step_id"
            case afterStepID = "after_step_id"
        }
    }
    static func proposal(_ args: DayPlanAdjustmentArguments, original: SavedDayPlan, references: [DayPlanReference], user: AssistantMessage, now: Date = Date()) throws -> DayPlanAdjustment {
        let quote = args.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = args.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard user.isUser, quote.count >= 2, quote.count <= 1_000, user.text.contains(quote), !reason.isEmpty, reason.count <= 500,
              args.operationsJSON.utf8.count <= 30_000 else { throw DayPlanError.invalid("调整缺少本轮原话或原因，未保存。") }
        let operations = try JSONDecoder().decode([Operation].self, from: Data(args.operationsJSON.utf8))
        guard !operations.isEmpty, operations.count <= 20 else { throw DayPlanError.invalid("每次调整需包含1–20项操作。") }
        var draft = original
        var touched = Set<UUID>()
        for op in operations {
            switch op.action {
            case "add":
                guard op.stepID == nil, let input = op.step else { throw DayPlanError.invalid("新增安排参数不完整。") }
                let proposed = DayPlanStep(title: input.title, sourceKind: input.sourceKind ?? "note", sourceID: input.sourceID, plannedTime: input.plannedTime ?? "", durationMinutes: input.durationMinutes ?? 30, preparation: input.preparation ?? "", reason: input.reason ?? "")
                if proposed.sourceKind=="note", references.contains(where:{$0.title==proposed.title}) {
                    throw DayPlanError.invalid("新增安排与现有来源事项同名，请使用其真实sourceKind和sourceID；多个同名事项先澄清，不要转成独立笔记。")
                }
                let canonical = try SavedDayPlanPolicy.validated(.init(day: original.day, timeZone: original.timeZone, steps: [proposed]), references: references, now: now, canonicalize: true).steps[0]
                try insert(canonical, after: op.afterStepID, into: &draft.steps)
            case "update", "remove", "move":
                guard let id = op.stepID, original.steps.contains(where: { $0.id == id }), touched.insert(id).inserted,
                      let index = draft.steps.firstIndex(where: { $0.id == id }), !draft.steps[index].isDone else {
                    throw DayPlanError.invalid("调整目标不存在、重复或已经完成；已完成安排保留。")
                }
                if op.action == "remove" { draft.steps.remove(at: index); continue }
                if op.action == "move" {
                    guard op.afterStepID != id.uuidString else { throw DayPlanError.invalid("不能把安排移到自身之后。") }
                    let step = draft.steps.remove(at: index)
                    try insert(step, after: op.afterStepID, into: &draft.steps)
                    continue
                }
                var step = draft.steps[index]
                if let value = op.title {
                    guard step.sourceKind == "note" || value == step.title else { throw DayPlanError.invalid("关联事项名称须以来源为准。") }
                    step.title = value
                }
                if let value = op.plannedTime { step.plannedTime = value }
                if let value = op.durationMinutes { step.durationMinutes = value }
                if let value = op.preparation { step.preparation = value }
                if let value = op.reason { step.reason = value }
                let canonical = try SavedDayPlanPolicy.validated(.init(day: original.day, timeZone: original.timeZone, steps: [step]), references: references, now: now, canonicalize: true).steps[0]
                draft.steps[index] = canonical
            default: throw DayPlanError.invalid("不支持的计划调整操作。")
            }
        }
        if ["新增","加入"].contains(where:user.text.contains) {
            let requested=references.filter { ref in
                !original.steps.contains{ref.matches(kind:$0.sourceKind,sourceID:$0.sourceID)} &&
                ["「"+ref.title+"」","“"+ref.title+"”","\""+ref.title+"\""].contains(where:user.text.contains)
            }
            for ref in requested where !draft.steps.contains(where:{ref.matches(kind:$0.sourceKind,sourceID:$0.sourceID)}) {
                throw DayPlanError.invalid("本轮明确要求新增的事项「"+ref.title+"」尚未按原来源ID纳入计划；不能只挪动其他安排后声称已安排。请把该事项加入未完成部分，保留已完成历史。")
            }
        }
        try validateCompletedPrefix(original: original, proposed: draft)
        guard draft.steps != original.steps else { throw DayPlanError.invalid("没有实际变化，原计划保留。") }
        _ = try SavedDayPlanPolicy.validated(draft, references: references, now: now, preserving: original)
        return .init(original: original, proposed: draft, reason: reason, quote: quote, sourceMessageID: user.id)
    }
    private static func insert(_ step: DayPlanStep, after anchor: String?, into steps: inout [DayPlanStep]) throws {
        guard let anchor else { steps.append(step); return }
        if anchor.isEmpty { steps.insert(step, at: 0); return }
        guard let id = UUID(uuidString: anchor), let index = steps.firstIndex(where: { $0.id == id }) else { throw DayPlanError.invalid("调整位置所引用的安排不存在。") }
        steps.insert(step, at: index + 1)
    }
    private static func validateCompletedPrefix(original: SavedDayPlan, proposed: SavedDayPlan) throws {
        let completed = Array(original.steps.prefix(while: { $0.isDone }))
        guard Array(proposed.steps.prefix(completed.count)) == completed else {
            throw DayPlanError.invalid("开头已完成的安排须保留原位；新增紧急事项应插在这段已完成安排之后。")
        }
    }
    static func validateConfirmation(_ change: DayPlanAdjustment, current: SavedDayPlan?) throws {
        guard current == change.original else { throw DayPlanError.invalid("计划已有新版本或勾选变化，请重新生成调整，避免覆盖。") }
        try validateCompletedPrefix(original: change.original, proposed: change.proposed)
        for step in change.original.steps where step.isDone {
            guard change.proposed.steps.first(where: { $0.id == step.id }) == step else { throw DayPlanError.invalid("不能通过自动调整修改或移除已完成安排。") }
        }
    }
}

struct DayPlanDifference: Identifiable {
    let id: UUID
    let title: String
    let kind: String
    let before: String?
    let after: String?
}

enum DayPlanReview {
    static func description(_ step: DayPlanStep, position: Int) -> String {
        "第\(position + 1)项 · \(step.title) · \(["note": "独立安排", "personal": "本地待办", "external": "外部待办", "event": "源日程"][step.sourceKind] ?? "来源未知") · \(step.plannedTime.isEmpty ? "时间待定" : step.plannedTime) · \(step.durationMinutes)分钟" +
        (step.preparation.isEmpty ? "" : " · 准备：" + step.preparation) + (step.reason.isEmpty ? "" : " · 依据：" + step.reason) + (step.isDone ? " · 已完成" : "")
    }
    static func differences(from old: SavedDayPlan, to new: SavedDayPlan) -> [DayPlanDifference] {
        var result: [DayPlanDifference] = []
        for (index, step) in old.steps.enumerated() {
            guard let newIndex = new.steps.firstIndex(where: { $0.id == step.id }) else {
                result.append(.init(id: step.id, title: step.title, kind: "移除", before: description(step, position: index), after: nil)); continue
            }
            let next = new.steps[newIndex]
            // Position shifts caused solely by inserting/removing other steps are not content changes.
            let oldPeers = old.steps.filter { item in new.steps.contains { $0.id == item.id } }.map(\.id)
            let newPeers = new.steps.filter { item in old.steps.contains { $0.id == item.id } }.map(\.id)
            let moved = oldPeers.firstIndex(of: step.id) != newPeers.firstIndex(of: step.id)
            if step != next || moved {
                result.append(.init(id: step.id, title: step.title, kind: step != next ? "调整" : "顺序变化", before: description(step, position: index), after: description(next, position: newIndex)))
            }
        }
        for (index, step) in new.steps.enumerated() where !old.steps.contains(where: { $0.id == step.id }) {
            result.append(.init(id: step.id, title: step.title, kind: "新增", before: nil, after: description(step, position: index)))
        }
        return result
    }
    static func warnings(_ plan: SavedDayPlan) -> [String] {
        var result: [String] = []
        let timed = plan.steps.filter { !$0.isDone && SavedDayPlanPolicy.validTime($0.plannedTime) }
        func minutes(_ step: DayPlanStep) -> Int { let parts = step.plannedTime.split(separator: ":").compactMap { Int($0) }; return parts[0] * 60 + parts[1] }
        for (index, a) in timed.enumerated() {
            if minutes(a) + a.durationMinutes > 1_440 { result.append("「\(a.title)」的预计用时跨到次日，请核对。") }
            for b in timed.dropFirst(index + 1) where max(minutes(a), minutes(b)) < min(minutes(a) + a.durationMinutes, minutes(b) + b.durationMinutes) {
                result.append("「\(a.title)」与「\(b.title)」的时间重叠，请核对。")
            }
        }
        return result
    }
}
