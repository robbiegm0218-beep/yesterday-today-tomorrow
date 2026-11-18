import Foundation

struct DingTalkTodoChatTarget: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let organization: String
    let isComplete: Bool
}
enum DingTalkTodoMutationIntent {
    static func requested(_ text: String) -> Bool {
        guard !AssistantToolIntent.declinesWriteTools(in: text), !["怎么", "如何", "是否能", "能不能", "能否"].contains(where: text.hasPrefix) else { return false }
        return ["修改", "改成", "改为", "改到", "改期", "调整", "设置截止", "设置优先级", "延期", "提前", "帮我完成", "标记完成", "标记为完成", "设为完成", "完成待办", "重开", "重新打开", "恢复为未完成", "设为未完成", "改为未完成", "标记为未完成", "取消完成"].contains(where: text.contains)
    }
    static func wantsReopen(_ text: String) -> Bool { ["重开", "重新打开", "恢复为未完成", "设为未完成", "改为未完成", "标记为未完成", "取消完成"].contains(where: text.contains) }
    static func prefersExternal(_ text: String, targets: [DingTalkTodoChatTarget], personal: [PersonalTodo]) -> Bool {
        guard requested(text) else { return false }
        if text.contains("钉钉") { return true }
        return targets.contains { target in text.contains(target.title) && !personal.contains(where: { $0.title == target.title }) }
    }
}
struct DingTalkTodoMutationArguments: Decodable {
    let targetID: String
    let operation: String
    let title: String?
    let dueDate: String?
    let dueAt: String?
    let priority: Int?
    let quote: String
    enum CodingKeys: String, CodingKey { case operation, title, priority, quote; case targetID = "target_id", dueDate = "due_date", dueAt = "due_at" }
}
enum DingTalkTodoMutationParser {
    static func proposal(_ args: DingTalkTodoMutationArguments, user: AssistantMessage, targets: [DingTalkTodoChatTarget], personal: [PersonalTodo]) -> PendingAssistantAction? {
        guard user.isUser, DingTalkTodoMutationIntent.requested(user.text), args.quote.count >= 2, args.quote.count <= 1_000, user.text.contains(args.quote),
              let target = targets.first(where: { $0.id == args.targetID }), let mode = DingTalkTodoMutationRequest.Mode(rawValue: args.operation) else { return nil }
        let sameNames = targets.filter { $0.title == target.title }
        guard sameNames.count == 1 || user.text.contains(target.id) || (user.text.contains(target.organization) && sameNames.filter { $0.organization == target.organization }.count == 1) else { return nil }
        guard user.text.contains("钉钉") || !personal.contains(where: { $0.title == target.title }) else { return nil }
        if mode == .reopen && !DingTalkTodoMutationIntent.wantsReopen(user.text) { return nil }
        if mode == .complete && (DingTalkTodoMutationIntent.wantsReopen(user.text) || !user.text.contains("完成")) { return nil }
        var patch: DingTalkTodoPatch?
        if mode == .update {
            guard !(args.dueAt != nil && args.dueDate != nil) else { return nil }
            if let title = args.title, !user.text.contains(title) { return nil }
            if let priority = args.priority {
                let words = [10:["低"], 20:["普通", "一般", "正常"], 30:["高", "重要"], 40:["紧急", "最高", "P0"]]
                guard (words[priority] ?? []).contains(where: user.text.contains) else { return nil }
            }
            if args.dueDate != nil || args.dueAt != nil {
                guard ["截止", "到期", "改期", "改到", "延期", "提前", "期限"].contains(where: user.text.contains) else { return nil }
            }
            var due: Date?
            if let date = args.dueDate {
                guard let day = AssistantActionParser.date(from: date), let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: day) else { return nil }
                due = end
            }
            if let stamp = args.dueAt { guard let parsed = ISO8601DateFormatter().date(from: stamp) else { return nil }; due = parsed }
            patch = .init(title: args.title, dueAt: due, priority: args.priority, dateOnly: args.dueDate != nil)
        } else if args.title != nil || args.dueDate != nil || args.dueAt != nil || args.priority != nil { return nil }
        let request = DingTalkTodoMutationRequest(localID: target.id, expectedTitle: target.title, mode: mode, patch: patch, quote: args.quote)
        guard request.isValid else { return nil }
        return .init(id: request.id, summary: "\(mode.label)：\(target.title) · \(target.organization)；核对服务端后再确认", operation: .externalTodoMutation(request: request))
    }
}
