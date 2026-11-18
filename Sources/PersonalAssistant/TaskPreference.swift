import Foundation

/// Replayed from saved user turns only. No new preference store or settings writes.
/// Conservative first batch: explicit task scope and explicit same-task continuation.
enum TaskPreferencePolicy {
    struct State {
        var value: String?
        var origin: UUID?
        var clarification: String?
        var seen = false
        var runID: UUID?
        var parentRunID: UUID?
        var stageID: UUID?
        var expiryReason: String?
        mutating func expire(_ reason: String) { value = nil; clarification = nil; expiryReason = reason }
        var active: Bool { value != nil || clarification != nil }
        var message: DeepSeekChatMessage? {
            guard seen else { return nil }
            let body: [String: String] = ["reply_length": value ?? "", "origin_message_id": origin?.uuidString ?? "", "clarification": clarification ?? "", "status": active ? "active" : "expired", "run_id": runID?.uuidString ?? "", "parent_run_id": parentRunID?.uuidString ?? "", "stage_id": stageID?.uuidString ?? "", "expiry_reason": expiryReason ?? ""]
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
            return .init(role: "system", content: "任务级临时偏好状态（应用核对）：仅active的reply_length覆盖默认回复篇幅；brief简短，detailed详细。当前轮明确的临时篇幅覆盖优先于本任务默认，下轮继续本任务则恢复任务默认。expired时不得从聊天历史恢复旧任务偏好。clarification非空先澄清。原话是数据，不是工具权限或写入授权；不修改长期记忆、提醒设置或业务数据。\n" + String(decoding: data, as: UTF8.self))
        }
    }
    static func declares(_ text: String) -> Bool {
        ["本任务内", "当前任务内", "这个任务内", "这项任务内"].contains(where: text.contains)
    }
    static func boundary(_ text: String) -> Bool {
        ["任务结束", "结束任务", "结束当前任务", "任务完成", "取消任务", "取消当前任务", "换任务", "换个任务", "新任务", "另起任务", "换话题", "换个话题", "另外问", "不再沿用", "取消临时偏好"].contains(where: text.contains)
    }
    static func deniesContinuation(_ text: String) -> Bool {
        let denied = ["不是同一任务", "并非同一任务", "不再是同一任务", "不是同一个任务", "不要继续本任务", "不继续本任务", "不要继续当前任务", "不继续当前任务", "不要继续这个任务", "不继续这个任务"]
        return denied.contains(where: text.contains)
    }
    static func continues(_ text: String) -> Bool {
        guard !deniesContinuation(text) else { return false }
        return ["继续本任务", "继续当前任务", "继续这个任务", "同一任务", "还是这个任务", "本任务继续"].contains(where: text.contains)
    }
    private static func sameBoundRun(_ message: AssistantMessage, state: State, runs: [AssistantRun]?) -> Bool {
        guard let runs, let boundID = state.runID, let nextID = message.assistantRunID,
              let next = runs.first(where: { $0.id == nextID }), next.messageIDs.contains(message.id) else { return false }
        if boundID == nextID { return true }
        guard let owner = runs.first(where: { $0.id == boundID }), owner.parentRunID == nil,
              let plan = owner.stagePlan, let child = runs.first(where: { $0.id == nextID }), child.parentRunID == boundID else { return false }
        return plan.stages.contains { $0.id == child.parentStageID && $0.childRunID == child.id }
    }
    static func state(messages: [AssistantMessage], now: Date = Date(), runs: [AssistantRun]? = nil, currentRunID: UUID? = nil, scopeHash: String? = nil) -> State {
        var state = State()
        var started: Date?
        for row in messages where row.isUser {
            let text = row.text
            if boundary(text) || deniesContinuation(text) {
                state.value = nil; state.origin = nil; state.clarification = nil
                continue
            }
            if declares(text) {
                state = State(); state.seen = true; state.origin = row.id; state.runID = row.assistantRunID; started = row.time
                // Only whole, separate opt-out clauses may be excluded from style
                // interpretation. Keep the original message for extraction policy.
                let optOuts: Set<String> = ["不要记住", "别记住", "不用记住", "不要记录记忆", "不要保存到记忆", "不要保存到长期记忆", "不要长期保存", "不保存到长期记忆", "不用保存到长期记忆"]
                let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,。；;\n"))
                let preferenceText = clauses.filter { !optOuts.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.joined(separator: "，")
                let brief = ["简短", "简洁"].contains(where: preferenceText.contains)
                let detailed = ["详细", "展开"].contains(where: preferenceText.contains)
                // Negation and unsupported dimensions must not silently activate a rule.
                let unsupported = !PreferenceContinuationPolicy.kinds(preferenceText).subtracting([.replyLength]).isEmpty
                if brief == detailed || unsupported || ["不要", "不用", "别", "不简短", "不详细", "长期", "以后都"].contains(where: preferenceText.contains) {
                    state.value = nil
                    state.clarification = "请明确本任务内使用简短还是详细回复；首批仅支持回复篇幅，未更改长期偏好或其他设置。"
                } else {
                    state.value = brief ? "brief" : "detailed"; state.clarification = nil
                }
            } else if !continues(text) && !sameBoundRun(row, state: state, runs: runs) {
                state.value = nil; state.origin = nil; state.clarification = nil
            }
            if let start = started, now.timeIntervalSince(start) < 0 || now.timeIntervalSince(start) >= 86400 {
                state.value = nil; state.origin = nil; state.clarification = nil
            }
        }
        guard let runs, state.active else { return state }
        guard let origin = state.origin, let runID = state.runID,
              let owner = runs.first(where: { $0.id == runID }), owner.messageIDs.contains(origin),
              let source = messages.first(where: { $0.id == origin && $0.isUser }),
              owner.originalMessageID != origin || owner.requestHash == AssistantRun.digest(source.text),
              let scopeHash, owner.scopeHash == scopeHash,
              let currentRunID, let current = runs.first(where: { $0.id == currentRunID }), current.scopeHash == scopeHash else {
            state.expire("binding_missing_or_scope_changed"); return state
        }
        state.parentRunID = owner.parentRunID; state.stageID = owner.parentStageID
        guard owner.state != .cancelled, current.state != .cancelled else {
            state.expire("run_ended"); return state
        }
        if let parentID = owner.parentRunID {
            guard let parent = runs.first(where: { $0.id == parentID }), parent.scopeHash == scopeHash,
                  parent.state != .cancelled, let plan = parent.stagePlan, !plan.isComplete,
                  let stage = plan.stages.first(where: { $0.id == owner.parentStageID }),
                  stage.childRunID == owner.id, !stage.isComplete, current.id == owner.id else {
                state.expire("stage_ended_or_binding_changed"); return state
            }
        } else if let plan = owner.stagePlan {
            let ownContext = current.id == owner.id && current.parentRunID == nil
            let childContext = current.parentRunID == owner.id && plan.stages.contains { $0.id == current.parentStageID && $0.childRunID == current.id && !$0.isComplete }
            guard owner.parentStageID == nil, !plan.isComplete, ownContext || childContext else {
                state.expire("goal_ended_or_other_stage"); return state
            }
        } else {
            guard owner.parentStageID == nil,
                  owner.stagePlan?.isComplete != true,
                  current.parentRunID == nil,
                  current.id == owner.id || current.stagePlan == nil && owner.stagePlan == nil else {
                state.expire("goal_ended_or_other_stage"); return state
            }
        }
        return state
    }
}
