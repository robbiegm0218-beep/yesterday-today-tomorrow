import Foundation

enum AssistantStreamUpdate: Equatable {
    case text(String)
    case reset
}

enum DeepSeekStreamError: LocalizedError {
    case malformed, incomplete, limit, truncated
    var errorDescription: String? {
        switch self {
        case .malformed: "模型流式回复格式异常，本轮未保存回复或执行操作。"
        case .incomplete: "模型回复中断，尚未完整接收；未保存片段或执行操作，请重试。"
        case .limit: "本轮流式回复达到大小或用量上限，未保存片段或执行操作。"
        case .truncated: "模型未完整生成回复，未保存片段或执行操作，请缩小请求后重试。"
        }
    }
}

/// Incremental UTF-8/SSE framing. Tool arguments remain private until BOTH a
/// matching finish_reason and [DONE], then pass through the existing validator.
struct DeepSeekStreamAccumulator {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct Tool: Decodable {
                    struct Function: Decodable { let name: String?; let arguments: String? }
                    let index: Int; let id: String?; let type: String?; let function: Function?
                }
                let content: String?
                let toolCalls: [Tool]?
                enum CodingKeys: String, CodingKey { case content; case toolCalls = "tool_calls" }
            }
            let index: Int
            let delta: Delta
            let finishReason: String?
            enum CodingKeys: String, CodingKey { case index, delta; case finishReason = "finish_reason" }
        }
        let choices: [Choice]
        let model: String?
    }
    private struct Tool { var id = ""; var name = ""; var arguments = "" }
    private var line = Data(), eventLines: [String] = []
    private var bytes = 0, eventBytes = 0, events = 0
    private var tools: [Int: Tool] = [:]
    private var finishReason: String?
    private(set) var done = false
    private(set) var text = ""
    private(set) var usage: DeepSeekTokenUsage?
    private(set) var model = "deepseek-flash"
    let tokenLimit: Int
    init(tokenLimit: Int = 64_000) { self.tokenLimit = max(1, tokenLimit) }

    mutating func consume(_ byte: UInt8) throws -> AssistantStreamUpdate? {
        guard !done else { throw DeepSeekStreamError.malformed }
        bytes += 1
        guard bytes <= 2_000_000 else { throw DeepSeekStreamError.limit }
        if byte != 10 {
            line.append(byte)
            guard line.count <= 128_000 else { throw DeepSeekStreamError.limit }
            return nil
        }
        return try consumeLine()
    }

    private mutating func consumeLine() throws -> AssistantStreamUpdate? {
        if line.last == 13 { line.removeLast() }
        guard let value = String(data: line, encoding: .utf8) else { throw DeepSeekStreamError.malformed }
        line.removeAll(keepingCapacity: true)
        if value.isEmpty {
            guard !eventLines.isEmpty else { return nil }
            let event = eventLines.joined(separator: "\n")
            eventLines.removeAll(keepingCapacity: true); eventBytes = 0
            return try consumeEvent(event)
        }
        if value.hasPrefix("data:") {
            let data = String(value.dropFirst(5)).drop(while: { $0 == " " })
            eventBytes += data.utf8.count
            guard eventBytes <= 128_000, eventLines.count < 100 else { throw DeepSeekStreamError.limit }
            eventLines.append(String(data))
        }
        return nil // comments / SSE metadata are not model content
    }

    private mutating func consumeEvent(_ event: String) throws -> AssistantStreamUpdate? {
        events += 1
        guard events <= 20_000 else { throw DeepSeekStreamError.limit }
        if event == "[DONE]" {
            guard let finishReason, ["stop", "tool_calls"].contains(finishReason) else { throw DeepSeekStreamError.incomplete }
            guard (finishReason == "tool_calls") == !tools.isEmpty else { throw DeepSeekStreamError.malformed }
            done = true; return nil
        }
        let data = Data(event.utf8)
        let chunk: Chunk
        do { chunk = try JSONDecoder().decode(Chunk.self, from: data) }
        catch { throw DeepSeekStreamError.malformed }
        if let value = chunk.model { guard value.count <= 80 else { throw DeepSeekStreamError.limit }; model = value }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = object["usage"] as? [String: Any] {
            usage = (try? JSONSerialization.data(withJSONObject: raw)).flatMap { try? JSONDecoder().decode(DeepSeekTokenUsage.self, from: $0) }.flatMap { value in
                [value.promptTokens, value.completionTokens, value.totalTokens].allSatisfy { (0...10_000_000).contains($0) } ? value : nil
            }
            if let usage, usage.totalTokens >= tokenLimit { throw DeepSeekStreamError.limit }
        }
        guard chunk.choices.count <= 1 else { throw DeepSeekStreamError.malformed }
        guard let choice = chunk.choices.first else { return nil } // final usage-only event
        guard choice.index == 0, finishReason == nil else { throw DeepSeekStreamError.malformed }
        if let reason = choice.finishReason {
            guard ["stop", "tool_calls"].contains(reason) else { throw DeepSeekStreamError.truncated }
            finishReason = reason
        }
        if let fragment = choice.delta.content {
            text += fragment
            guard text.utf8.count <= 128_000 else { throw DeepSeekStreamError.limit }
        }
        if let fragments = choice.delta.toolCalls, !fragments.isEmpty {
            guard fragments.count <= 8 else { throw DeepSeekStreamError.limit }
            for fragment in fragments {
                guard (0..<8).contains(fragment.index), fragment.type == nil || fragment.type == "function" else { throw DeepSeekStreamError.malformed }
                var tool = tools[fragment.index] ?? Tool()
                if let id = fragment.id {
                    guard tool.id.isEmpty || tool.id == id else { throw DeepSeekStreamError.malformed }
                    tool.id = id
                }
                if let name = fragment.function?.name { tool.name += name }
                if let args = fragment.function?.arguments { tool.arguments += args }
                guard tool.id.count <= 200, tool.name.count <= 100, tool.arguments.utf8.count <= 16_000 else { throw DeepSeekStreamError.limit }
                tools[fragment.index] = tool
            }
            return .reset
        }
        return tools.isEmpty && choice.delta.content != nil ? .text(text) : nil
    }

    mutating func finish() throws -> (text: String?, calls: [DeepSeekToolCall]) {
        // Permit the sentinel's final event to end exactly at EOF.
        if !line.isEmpty { _ = try consumeLine() }
        if !eventLines.isEmpty { _ = try consumeEvent(eventLines.joined(separator: "\n")); eventLines = [] }
        guard done, finishReason != nil else { throw DeepSeekStreamError.incomplete }
        guard tools.keys.sorted() == Array(0..<tools.count) else { throw DeepSeekStreamError.malformed }
        let calls = try tools.keys.sorted().map { index -> DeepSeekToolCall in
            let tool = tools[index]!
            guard !tool.id.isEmpty, !tool.name.isEmpty else { throw DeepSeekStreamError.malformed }
            return .init(id: tool.id, function: .init(name: tool.name, arguments: tool.arguments))
        }
        guard Set(calls.map(\.id)).count == calls.count, !text.isEmpty || !calls.isEmpty else { throw DeepSeekStreamError.malformed }
        return (text.isEmpty ? nil : text, calls)
    }
}
