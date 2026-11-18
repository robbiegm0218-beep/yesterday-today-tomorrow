import Foundation

struct AssistantContextSelectionMetric: Codable, Equatable {
    let policy: String
    let sourceMessages: Int
    let selectedMessages: Int
    let omittedOptionalMessages: Int
    let duplicateOptionalMessages: Int
    let omittedUTF8Bytes: Int
}

/// Deliberately narrow. Unknown intent keeps the original business context.
enum AssistantContextSelection {
    static let optionalNames: Set<String> = ["memory_actions", "external_mutation_targets", "remote_research"]
    static func isSocialOnly(_ request: String, hasProtectedContext: Bool) -> Bool {
        guard !hasProtectedContext, request.count <= 40 else { return false }
        let punctuation = CharacterSet(charactersIn: "。！!，,~～.")
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: punctuation).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["你好", "您好", "早上好", "早安", "晚上好", "晚安", "谢谢", "谢谢你", "多谢", "hello", "hi", "thanks", "thank you"].contains(text)
    }
    static let generalConceptPrefix = "只解释通用概念："
    static func isGeneralConceptOnly(_ request: String, hasProtectedContext: Bool) -> Bool {
        guard !hasProtectedContext, request.hasPrefix(generalConceptPrefix) else { return false }
        let body = String(request.dropFirst(generalConceptPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= 200 else { return false }
        // Contradictory/personal/action wording falls back to the original facts.
        let protectedWords = ["我", "我们", "本任务", "这个", "那个", "刚才", "日程", "待办", "项目", "资料", "钉钉", "会议", "提醒", "设置", "记忆", "上面", "之前", "创建", "修改", "删除", "完成", "保存", "更新", "发送", "取消", "安排", "授权", "执行"]
        let english = ["my ", "our ", "previous", "create ", "delete ", "update ", "save ", "send ", "schedule "]
        return !protectedWords.contains(where: body.contains) && !english.contains(where: body.lowercased().contains)
    }
    static func generalWorkbench(now: Date) -> DeepSeekChatMessage {
        .init(role: "system", content: "用户本轮明确只解释通用概念，未附带个人工作台、个人记忆或资料片段。这不表示没有事项/记录，不能判断任何业务状态或声称核实个人来源。只回答本轮通用问题，不主动扩展到个人安排或生成业务提案；转向业务时须重新核对来源。原任务约束与确认回执仍有效。当前时间：" + ISO8601DateFormatter().string(from: now))
    }
    static func socialWorkbench(now: Date) -> DeepSeekChatMessage {
        .init(role: "system", content: "本轮是纯寒暄，未附带工作台业务快照；这不代表没有待办、日程、项目或跟进，也不证明任何事项已完成。不要主动罗列或猜测业务安排。若转向业务问题，须查询或重新提供当前来源，历史答复不能当作当前核实结果。当前时间：" + ISO8601DateFormatter().string(from: now))
    }
    private struct Key: Hashable { let role: String; let content: String }
    static func select(messages: [DeepSeekChatMessage], names: [String], social: Bool, generalConcept: Bool = false) -> (messages: [DeepSeekChatMessage], names: [String], metric: AssistantContextSelectionMetric) {
        // Missing labels cannot establish that a message is optional.
        guard messages.count == names.count else {
            return (messages, names, .init(policy: "unlabelled_full_fallback", sourceMessages: messages.count, selectedMessages: messages.count, omittedOptionalMessages: 0, duplicateOptionalMessages: 0, omittedUTF8Bytes: 0))
        }
        var selected: [DeepSeekChatMessage] = [], labels: [String] = [], seen: Set<Key> = []
        var omitted = 0, duplicates = 0, bytes = 0
        for (message, name) in zip(messages, names) {
            let optional = optionalNames.contains(name) && message.role == "system" && message.toolCalls == nil && message.toolCallID == nil
            if optional && (social || generalConcept) { omitted += 1; bytes += message.content.utf8.count; continue }
            if optional && !seen.insert(.init(role: message.role, content: message.content)).inserted {
                duplicates += 1; bytes += message.content.utf8.count; continue
            }
            selected.append(message); labels.append(name)
        }
        return (selected, labels, .init(policy: social ? "exact_social_allowlist_v1" : generalConcept ? "explicit_general_concept_v1" : "full_business_context", sourceMessages: messages.count, selectedMessages: selected.count, omittedOptionalMessages: omitted, duplicateOptionalMessages: duplicates, omittedUTF8Bytes: bytes))
    }
}
