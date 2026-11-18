import Foundation

/// Local heuristic, not the provider's tokenizer or a claim about its context limit.
struct AssistantInputPolicy: Equatable {
    var maximumEstimatedInputTokens = 49_152
    var maximumRequestBytes = 196_608
    var outputReserve = 8_192
    static let standard = Self()
    func accepts(bytes: Int) -> Bool {
        bytes >= 0 && maximumEstimatedInputTokens > 0 && maximumRequestBytes > 0 && outputReserve > 0
            && bytes <= maximumRequestBytes && Self.estimate(bytes: bytes) <= maximumEstimatedInputTokens
    }
    func outputLimit(bytes: Int, remainingTokens: Int, requested: Int) -> Int? {
        guard accepts(bytes: bytes), requested > 0 else { return nil }
        let input = Self.estimate(bytes: bytes)
        guard remainingTokens > input else { return nil }
        return min(outputReserve, requested, remainingTokens - input)
    }
    static func estimate(bytes: Int) -> Int { bytes / 3 + (bytes % 3 == 0 ? 0 : 1) }
}

struct AssistantInputBudgetError: LocalizedError {
    var remainingTokens: Int? = nil
    var errorDescription: String? {
        if remainingTokens != nil { return "原运行剩余额度不足以容纳本次输入估算和输出预留，这次请求尚未发送。原消息、精确ID、确认卡和回执均保留，没有截断关键依据或重置原预算；请缩小范围后继续。" }
        return
        "本轮输入超过本机上下文预算，尚未向模型发送这次请求。原消息、精确ID、确认卡和回执均已保留，没有自动截断依据。请拆分长材料；若要用新问题继续，可在开头写“仅以本条为准：”，明确不引用此前聊天。当前事实、任务约束和回执仍会核对。"
    }
}

struct AssistantInputModuleMetric: Codable, Equatable {
    let name: String
    var messageCount: Int
    var characters: Int
    var utf8Bytes: Int
    var estimatedTokens: Int
    let retention: String
}

struct AssistantInputAudit: Codable, Equatable {
    let estimator: String
    let characters: Int
    let utf8Bytes: Int
    let estimatedTokens: Int
    let modules: [AssistantInputModuleMetric]

    static func make(messages: [DeepSeekChatMessage], names: [String]) -> Self {
        var modules: [AssistantInputModuleMetric] = []
        for (index, message) in messages.enumerated() {
            let name = index < names.count ? names[index] : "protected_task_context"
            let bytes = message.content.utf8.count
            if let at = modules.firstIndex(where: { $0.name == name }) {
                modules[at].messageCount += 1; modules[at].characters += message.content.count
                modules[at].utf8Bytes += bytes
                modules[at].estimatedTokens = AssistantInputPolicy.estimate(bytes: modules[at].utf8Bytes)
            } else {
                modules.append(.init(name: name, messageCount: 1, characters: message.content.count, utf8Bytes: bytes,
                                     estimatedTokens: AssistantInputPolicy.estimate(bytes: bytes), retention: "preserved_without_trimming"))
            }
        }
        let characters = modules.reduce(0) { $0 + $1.characters }, bytes = modules.reduce(0) { $0 + $1.utf8Bytes }
        return .init(estimator: "utf8_bytes_divided_by_3_ceil_v1_not_tokenizer", characters: characters, utf8Bytes: bytes,
                     estimatedTokens: AssistantInputPolicy.estimate(bytes: bytes), modules: modules)
    }
}

/// Numbers and fixed labels only; never records request text, schema, IDs or credentials.
struct AssistantRequestInputMetric: Codable, Equatable, Identifiable {
    var id = UUID()
    var state: String
    let requestBytes: Int
    let estimatedInputTokens: Int
    let maximumEstimatedInputTokens: Int
    let maximumRequestBytes: Int
    let outputReserve: Int
    var remainingRunTokens: Int?
    var effectiveOutputTokens: Int?
    var actualPromptTokens: Int?
    var estimateMinusActual: Int? { actualPromptTokens.map { estimatedInputTokens - $0 } }
    // Computed properties need explicit encoding to retain the comparison in diagnostics.
    enum CodingKeys: String, CodingKey {
        case id, state, requestBytes, estimatedInputTokens, maximumEstimatedInputTokens, maximumRequestBytes, outputReserve, actualPromptTokens, estimateMinusActual, remainingRunTokens, effectiveOutputTokens
    }
    init(state: String, bytes: Int, policy: AssistantInputPolicy) {
        self.state = state; requestBytes = bytes; estimatedInputTokens = AssistantInputPolicy.estimate(bytes: bytes)
        maximumEstimatedInputTokens = policy.maximumEstimatedInputTokens; maximumRequestBytes = policy.maximumRequestBytes; outputReserve = policy.outputReserve
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); state = try c.decode(String.self, forKey: .state)
        requestBytes = try c.decode(Int.self, forKey: .requestBytes); estimatedInputTokens = try c.decode(Int.self, forKey: .estimatedInputTokens)
        maximumEstimatedInputTokens = try c.decode(Int.self, forKey: .maximumEstimatedInputTokens); maximumRequestBytes = try c.decode(Int.self, forKey: .maximumRequestBytes)
        remainingRunTokens = try c.decodeIfPresent(Int.self, forKey: .remainingRunTokens); effectiveOutputTokens = try c.decodeIfPresent(Int.self, forKey: .effectiveOutputTokens)
        outputReserve = try c.decode(Int.self, forKey: .outputReserve); actualPromptTokens = try c.decodeIfPresent(Int.self, forKey: .actualPromptTokens)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(state, forKey: .state); try c.encode(requestBytes, forKey: .requestBytes)
        try c.encode(estimatedInputTokens, forKey: .estimatedInputTokens); try c.encode(maximumEstimatedInputTokens, forKey: .maximumEstimatedInputTokens)
        try c.encode(maximumRequestBytes, forKey: .maximumRequestBytes); try c.encode(outputReserve, forKey: .outputReserve)
        try c.encodeIfPresent(remainingRunTokens, forKey: .remainingRunTokens); try c.encodeIfPresent(effectiveOutputTokens, forKey: .effectiveOutputTokens)
        try c.encodeIfPresent(actualPromptTokens, forKey: .actualPromptTokens); try c.encodeIfPresent(estimateMinusActual, forKey: .estimateMinusActual)
    }
}

/// Explicit recovery only. All authoritative system/task contexts are assembled separately.
enum AssistantInputHistory {
    static let freshRequestPrefix = "仅以本条为准："
    static func recent(_ messages: [AssistantMessage]) -> ArraySlice<AssistantMessage> {
        let recent = messages.suffix(40)
        if let boundary = recent.lastIndex(where: { $0.isUser && $0.text.hasPrefix(freshRequestPrefix) }) {
            return recent[boundary...]
        }
        return recent
    }
    static func selectionName(_ messages: [AssistantMessage]) -> String {
        let selected = recent(messages)
        guard selected.first?.isUser == true, selected.first?.text.hasPrefix(freshRequestPrefix) == true else { return "recent_40" }
        return selected.count == 1 ? "explicit_current_request_only" : "explicit_history_boundary"
    }
}
