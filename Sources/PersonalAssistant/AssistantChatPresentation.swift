import Foundation

enum AssistantChatProgress: String {
    case preparing, syncing, recalling, requesting, reading, validating, repairing
    var label: String {
        switch self {
        case .preparing: "正在整理这次请求…"
        case .syncing: "正在同步当前事项…"
        case .recalling: "正在查找相关背景…"
        case .requesting: "正在生成回复…"
        case .reading: "正在核对所需资料…"
        case .validating: "正在检查待确认方案…"
        case .repairing: "正在修正方案中的问题…"
        }
    }
}

enum AssistantProposalPresentation {
    static func scope(_ operation: PendingAssistantAction.Operation) -> String {
        switch operation {
        case .saveDayPlan, .adjustDayPlan, .reviewPreviousDay:
            "保存范围：本机执行安排；原待办状态、期限和日历保持独立。"
        case .appendMatterContext:
            "保存范围：本机事项进展；不改变来源任务状态。"
        case .createFollowup, .respondFollowup:
            "保存范围：本机跟进记录；解决跟进不会自动完成来源任务。"
        case .externalTodoMutation:
            "执行范围：钉钉源事项；先回查当前记录，再由你最终确认。"
        default:
            "保存范围：本机个人事项或项目；不写入钉钉或日历。"
        }
    }

    /// Explain only the validated proposal, never reuse unverified claims of
    /// successful writes from the model's free-form tool-call response.
    static func message(for actions: [PendingAssistantAction]) -> String {
        var reasons: [String] = []
        for action in actions {
            let steps: [DayPlanStep]
            switch action.operation {
            case let .saveDayPlan(plan, _): steps = plan.steps
            case let .adjustDayPlan(change): steps = change.proposed.steps.filter { !change.original.steps.contains($0) }
            default: steps = []
            }
            for step in steps {
                let reason = step.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reason.isEmpty { reasons.append("- \(step.title)：\(String(reason.prefix(180)))") }
            }
        }
        let heading = actions.contains { if case .externalTodoMutation = $0.operation { return true }; return false }
            ? "已整理待确认方案，尚未执行。钉钉变更需先核对当前记录，再由你最终确认。"
            : "已整理待确认方案，尚未写入。你可以核对下方内容，确认或取消。"
        return reasons.isEmpty ? heading : heading + "\n\n方案中的安排理由：\n" + reasons.prefix(3).joined(separator: "\n") + (reasons.count > 3 ? "\n其余安排可在计划预览中核对。" : "")
    }
}

/// Reuse the production validators to explain rejected plans; decoding errors
/// stay generic, with no raw payload, server response or credential in the UI.
enum AssistantProposalValidation {
    static func issue(calls: [DeepSeekToolCall], todos: [PersonalTodo], plans: [SavedDayPlan], references: [DayPlanReference], user: AssistantMessage) -> String? {
        guard calls.count == 1, let call = calls.first else { return nil }
        let data = Data(call.function.arguments.utf8)
        do {
            switch call.function.name {
            case "propose_day_plan":
                guard !plans.contains(where: { $0.day == DailyPlanSchedulePolicy.dayKey(for: Date()) }) else { return "今天已有保存的计划，需要基于当前版本局部调整。" }
                guard let normalized = AssistantActionParser.nativeArrayArguments(data, key: "steps", legacyKey: "steps_json"),
                      let object = try JSONSerialization.jsonObject(with: normalized) as? [String: Any], let json = object["steps_json"] as? String else { return "计划步骤格式不完整，需要使用步骤数组。" }
                let plan = try SavedDayPlanPolicy.proposal(json: json, references: references)
                if plan.steps.isEmpty { return "计划没有可核对的步骤，请补充要安排的事项。" }
            case "adjust_day_plan":
                guard let existing = plans.first(where: { $0.day == DailyPlanSchedulePolicy.dayKey(for: Date()) }) else { return "今天尚无保存的计划，无法对旧步骤做局部调整。" }
                guard let normalized = AssistantActionParser.nativeArrayArguments(data, key: "operations", legacyKey: "operations_json") else { return "计划调整格式不完整，需要使用操作数组。" }
                let args = try JSONDecoder().decode(DayPlanAdjustmentArguments.self, from: normalized)
                _ = try DayPlanAdjustmentPolicy.proposal(args, original: existing, references: references, user: user)
            case "reopen_personal_todo":
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = object["todo_id"] as? String,
                      let id = UUID(uuidString: raw), let todo = todos.first(where: { $0.id == id }) else { return "恢复目标ID与当前本机事项不匹配，需要重新核对原事项，不能创建替代任务。" }
                if !todo.isComplete { return "目标个人待办当前已是未完成状态，无需恢复。" }
                return "恢复提案缺少本轮明确请求的原话依据，请重新核对。"
            default: return nil
            }
        } catch let error as DayPlanError { return error.localizedDescription }
        catch { return "方案的字段、类型或必需的原话依据不完整，请核对后重试。" }
        return nil
    }
}
