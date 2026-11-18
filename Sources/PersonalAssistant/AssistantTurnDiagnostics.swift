import Foundation

struct DeepSeekTokenUsage: Codable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens"
    }
}

struct AssistantTurnDiagnostic: Codable, Identifiable {
    var id = UUID()
    var startedAt = Date()
    var outcome = "interrupted"
    var model = "deepseek-flash"
    var elapsedMilliseconds = 0
    var streaming: Bool?
    var firstPreviewMilliseconds: Int?
    var responseMilliseconds: Int?
    var historySelection: String?
    var excludedHistoryMessageCount: Int?
    var contextSelection: AssistantContextSelectionMetric?
    var inputAudit: AssistantInputAudit?
    var inputRequests: [AssistantRequestInputMetric]?
    var contextCharacters = 0
    var retrievedSourceCount = 0
    var modelRounds: Int?
    var readToolCallCount: Int?
    var stopReason: String?
    var toolCallCount = 0
    var referenceQuestionInterpretation: String?
    var proposalEnforced: Bool?
    var proposalRepairCount: Int?
    var proposedActionCount = 0
    var rejectionReason: String?
    var timeoutPhase:String?
    var receivedStreamBytes:Int?
    var errorCategory: String?
    var sourceSyncFailed = false
    var usageScope = "primary_chat_only"
    var recallMilliseconds: Int?
    var recall: AssistantRecallMetrics?
    var usage: DeepSeekTokenUsage?

    static func category(for error: Error) -> String {
        if error is AssistantInputBudgetError { return "input_budget" }
        if error is CancellationError { return "cancelled" }
        if let value = error as? DeepSeekRequestError {
            switch value {
            case .timedOut,.streamTimedOut: return "timeout"
            case let .server(status, _):
                if status == 401 || status == 403 { return "authentication_or_permission" }
                if status == 429 { return "rate_limit" }
                return status >= 500 ? "provider_unavailable" : "provider_request"
            default: return "response_format"
            }
        }
        if error is DeepSeekStreamError { return "stream_incomplete_or_invalid" }
        if error is URLError { return "network" }
        if error is DecodingError { return "response_format" }
        return "unknown"
    }
}

struct AssistantTurnDiagnosticStore {
    var directory = LocalAssistantPaths.dataDirectory
    var url: URL { directory.appendingPathComponent("chat-turn-diagnostics.json") }
    func load() throws -> [AssistantTurnDiagnostic] {
        guard FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) else { return [] }
        guard let rows = LocalJSONFileStore.load(from: url, as: [AssistantTurnDiagnostic].self) else {
            throw ProjectUpdateError.invalid("对话诊断无法读取，保留原文件。")
        }
        return rows
    }
    func append(_ row: AssistantTurnDiagnostic) throws {
        var rows = try load(); rows.append(row)
        try LocalJSONFileStore.save(Array(rows.suffix(100)), to: url)
    }
}
