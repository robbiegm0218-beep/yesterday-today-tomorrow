import Foundation

enum MemoryExtractionPolicy {
    /// Honor clear, message-level requests to keep information out of long-term memory.
    /// This suppresses only automatic memory extraction; normal model replies still work.
    static func shouldExtract(from userMessage: String) -> Bool {
        let text = userMessage
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "’", with: "'")
        let optOutPhrases = [
            "不要记录记忆", "不要记录这条", "不要记住", "别记住", "不需要记住", "不用记住", "不想让你记住", "不想被记住", "不要记忆", "别记忆",
            "这次别记", "这次不要记", "这件事别记", "这件事不要记", "这件事不需要记",
            "这件事情别记", "这件事情不要记", "这件事情不需要记", "这条别记", "这条不要记",
            "不要把这件事记下来", "不要把这件事情记下来", "不要把这段记下来", "别把这件事记下来", "别把这件事情记下来", "别把这段记下来",
            "记忆里不要", "不要保存到记忆", "别保存到记忆", "不要存进记忆", "不要写进记忆", "别写进记忆",
            "don'tremember", "donotremember", "don'tsavethis", "donotsavethis", "don'tstorethis", "donotstorethis"
        ]
        let temporaryChecks = ["临时体验检查", "仅用于测试", "仅用于验收", "验收口令", "知识库验收", "知识库检索复验", "重启后复验"]
        return !optOutPhrases.contains(where: text.contains) && !temporaryChecks.contains(where: text.contains)
    }
    static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

struct AssistantMemory: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var content: String
    var category: String
    var createdAt: Date = Date()
}

enum LocalMemoryStore {
    private static var fileURL: URL {
        LocalAssistantPaths.dataDirectory.appendingPathComponent("memories.json")
    }

    static func load() -> [AssistantMemory] {
        LocalJSONFileStore.load(from: fileURL, as: [AssistantMemory].self) ?? []
    }

    static func save(_ items: [AssistantMemory]) throws {
        try LocalJSONFileStore.save(items, to: fileURL)
    }
}
