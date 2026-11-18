import Foundation

/// A bounded proposal changes only HOW the current stage is carried out.
/// Target identity, completion criteria, operation capability and dependencies stay local.
struct SemanticStageRevisionPreview: Codable, Equatable, Identifiable {
    var id = UUID()
    let parentID: UUID
    let stageID: UUID
    let parentRevision: Int
    let childRevision: Int?
    let scopeHash: String
    let original: AssistantGoalStage
    let instruction: String
    let reason: String
    var createdAt = Date()
    var status = "pending"
}

enum SemanticStageRevision {
    static let name = "preview_stage_alternative"
    static func requested(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500,
              !["不要换", "不用换", "不换方案", "换个话题", "另外问", "举个例", "如何实现", "怎么实现"].contains(where: text.contains),
              !StageInputRouting.changesGoal(text),
              !["什么意思", "什么是", "为什么", "如果", "例如", "怎么识别"].contains(where: text.contains) else { return false }
        return ["换一种方案", "换个方案", "换种方案", "换一种方法", "换个方法", "换个思路", "换一种思路", "换个做法", "重新设计这个阶段", "重新规划本阶段"].contains(where: text.contains)
    }
    static var definition: DeepSeekToolDefinition {
        .init(function: .init(name: name, description: "Propose only a different execution approach for the SAME stage. Keep original goal, target IDs, operation type, required input, completion criterion and dependencies. No business tools or writes. Do not claim completion or invent evidence. Return a concrete approach, not a promise to prepare a card. If constraints cannot be preserved, explain in plain text instead.", parameters: .init(properties: [
            "instruction": .init(type: "string", description: "Concrete replacement execution instructions, 1-600 characters, constrained by original stage", enumValues: nil),
            "reason": .init(type: "string", description: "Why this approach differs while achieving the same criterion, 1-300 characters", enumValues: nil)
        ], required: ["instruction", "reason"])))
    }
    static func parse(_ calls: [DeepSeekToolCall], original: AssistantGoalStage) throws -> (String, String) {
        struct Arguments: Decodable { let instruction: String; let reason: String }
        guard calls.count == 1, let call = calls.first, call.function.name == name,
              call.function.arguments.utf8.count <= 5000,
              let object = try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8)) as? [String: Any],
              Set(object.keys) == ["instruction", "reason"],
              let args = try? JSONDecoder().decode(Arguments.self, from: Data(call.function.arguments.utf8)) else {
            throw ProjectUpdateError.invalid("模型没有生成有效的阶段替代方案，原方案保留；没有执行操作。")
        }
        let instruction = args.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = args.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, instruction.count <= 600, instruction != original.instruction,
              !reason.isEmpty, reason.count <= 300 else { throw ProjectUpdateError.invalid("替代方案为空、超长或与原内容相同，未生成修订预览。") }
        return (instruction, reason)
    }
    static func target(messages: [AssistantMessage], rows: [AssistantRun], scope: String, now: Date = Date()) throws -> (AssistantRun, AssistantGoalStage) {
        guard let latest = messages.last(where: { !$0.isUser }), now.timeIntervalSince(latest.time) >= 0, now.timeIntervalSince(latest.time) < 86_400 else {
            throw ProjectUpdateError.invalid("当前阶段不明确，请先在目标进度中打开要调整的阶段；没有默认选取旧目标。")
        }
        let candidates = rows.filter { $0.replyIDs.contains(latest.id) || $0.id == latest.stageQuestion?.runID || $0.id == latest.assistantRunID || $0.id == latest.stageRevisionPreview?.parentID }
        let parents = Set(candidates.map { $0.parentRunID ?? $0.id })
        guard parents.count == 1, let parentID = parents.first, let parent = rows.first(where: { $0.id == parentID }), let plan = parent.stagePlan, plan.status == "confirmed" else {
            throw ProjectUpdateError.invalid("没有唯一的当前阶段，请先在目标进度中启动或打开对应阶段；未生成新目标。")
        }
        let stageID = latest.stageRevisionPreview?.stageID ?? candidates.first(where: { $0.parentStageID != nil })?.parentStageID ?? plan.stages.first(where: { !$0.isComplete })?.id
        guard let stageID else { throw ProjectUpdateError.invalid("原目标阶段已经全部完成，不能覆盖已完成结果。") }
        let stage = try StageRevisionPolicy.editable(parent: parent, stageID: stageID, rows: rows, scope: scope)
        return (parent, stage)
    }
    static func draft(_ preview: SemanticStageRevisionPreview, rows: [AssistantRun], scope: String, now: Date = Date()) throws -> StageRevisionDraft {
        guard preview.status == "pending", preview.scopeHash == scope, now.timeIntervalSince(preview.createdAt) >= 0, now.timeIntervalSince(preview.createdAt) < 86_400,
              let parent = rows.first(where: { $0.id == preview.parentID }), parent.revision == preview.parentRevision else {
            throw ProjectUpdateError.invalid("这份替代方案已取消、过期、范围或原目标已有变化，请重新提出；没有覆盖原方案。")
        }
        let stage = try StageRevisionPolicy.editable(parent: parent, stageID: preview.stageID, rows: rows, scope: scope)
        let child = rows.first { $0.id == stage.childRunID }
        guard stage == preview.original, child?.revision == preview.childRevision else { throw ProjectUpdateError.invalid("原阶段已有进展，旧替代方案不能继续使用。") }
        var draft = StageRevisionDraft(parent: parent, stage: stage, child: child)
        draft.instruction = preview.instruction; draft.reason = preview.reason; draft.semanticPreviewID = preview.id
        return draft
    }
}

extension AssistantRunLedger {
    /// Reuses the original stage (or unstarted stage's parent) budget without starting a stage,
    /// clearing its question, invalidating cards, or changing receipts.
    func beginStageInterpretation(parentID: UUID, stageID: UUID, messageID: UUID, scope: String) throws -> AssistantRun {
        guard let parent = rows.first(where: { $0.id == parentID }) else { throw ProjectUpdateError.invalid("原目标不存在。") }
        let stage = try StageRevisionPolicy.editable(parent: parent, stageID: stageID, rows: rows, scope: scope)
        let ownerID = stage.childRunID ?? parentID
        guard let owner = rows.first(where: { $0.id == ownerID }), owner.state != .running, !owner.inFlight,
              owner.budget.maxModelRounds > 0, owner.budget.maxSeconds > 0, owner.budget.maxTotalTokens > 0 else {
            throw ProjectUpdateError.invalid("原阶段预算已耗尽或仍在运行；生成替代方案不会重置预算。")
        }
        try mutateForStageInterpretation(ownerID, messageID: messageID)
        return owner
    }
}
