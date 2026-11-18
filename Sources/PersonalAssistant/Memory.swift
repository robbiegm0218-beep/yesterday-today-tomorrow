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
            "不要记录记忆", "不要记录这条", "不要记录这次", "不要记录本次", "不要记录本轮", "别记录这次", "别记录本次", "这次不记录", "本轮不记录", "不要记住", "别记住", "不需要记住", "不用记住", "不想让你记住", "不想被记住", "不要记忆", "别记忆",
            "这次别记", "这次不要记", "这件事别记", "这件事不要记", "这件事不需要记",
            "这件事情别记", "这件事情不要记", "这件事情不需要记", "这条别记", "这条不要记",
            "不要把这件事记下来", "不要把这件事情记下来", "不要把这段记下来", "别把这件事记下来", "别把这件事情记下来", "别把这段记下来",
            "记忆里不要", "不要保存到记忆", "别保存到记忆", "不要存进记忆", "不要写进记忆", "别写进记忆",
            "don'tremember", "donotremember", "don'tsavethis", "donotsavethis", "don'tstorethis", "donotstorethis"
        ]
        let temporaryChecks = ["临时体验检查", "仅用于测试", "仅用于验收", "验收口令", "知识库验收", "知识库检索复验", "重启后复验"]
        return !TaskPreferencePolicy.declares(userMessage) && !optOutPhrases.contains(where: text.contains) && !temporaryChecks.contains(where: text.contains) &&
            PreferenceContinuationPolicy.temporaryKinds(userMessage).isEmpty && !PreferenceContinuationPolicy.pureReference(userMessage)
    }
    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
        var result = String(folded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        while let last = result.last, "。！!？?；;，,".contains(last) { result.removeLast() }
        return result
    }
}

struct AssistantMemory: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var content: String
    var category: String
    var createdAt: Date = Date()
    // Optional fields preserve compatibility with existing files and backups.
    var updatedAt: Date?
    var sourceType: String?
    var evidence: [MemoryEvidence]?
    var revisions: [MemoryRevision]?
    var conflictsWithMemoryID: UUID?
    var actionPreferences: [MemoryActionPreference]? = nil

    var contextDescription: String {
        let caution = conflictsWithMemoryID == nil ? "" : "（与另一条记忆可能冲突，先向用户核对，不自行判定旧事实失效）"
        return "[\(category)] \(content)\(caution)"
    }
}

struct MemoryEvidence: Codable, Equatable {
    let messageID: UUID
    let quote: String
    let recordedAt: Date
}

struct MemoryRevision: Codable, Equatable {
    let content: String
    let changedAt: Date
}

enum MemoryEvolution {
    struct Result {
        let memories: [AssistantMemory]
        let added: Int
        let enriched: Int
    }

    static func apply(_ candidates: [ExtractedMemory], to existing: [AssistantMemory], source: AssistantMessage, now: Date = Date()) -> Result {
        guard source.isUser, MemoryExtractionPolicy.shouldExtract(from: source.text) else {
            return Result(memories: existing, added: 0, enriched: 0)
        }
        var memories = existing
        var added = 0
        var enrichedIDs = Set<UUID>()
        for candidate in candidates.prefix(3) {
            let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = candidate.sourceQuote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty, content.count <= 500,
                  ["个人偏好", "重要人物", "项目背景"].contains(candidate.category),
                  !quote.isEmpty, quote.count <= 400, source.text.contains(quote) else { continue }
            let evidence = MemoryEvidence(messageID: source.id, quote: quote, recordedAt: now)
            let exact = memories.firstIndex { MemoryExtractionPolicy.normalized($0.content) == MemoryExtractionPolicy.normalized(content) }
            let matchID = candidate.matchesMemoryID.flatMap(UUID.init(uuidString:))
            // Do not recreate a semantic target deleted while extraction was in flight.
            if let matchID, !memories.contains(where: { $0.id == matchID }) { continue }
            if exact == nil, candidate.conflictsWithMemoryID == nil,
               let matchID, memories.contains(where: { $0.id == matchID && $0.sourceType == "手动编辑" }) { continue }
            let semantic = candidate.conflictsWithMemoryID == nil ? matchID.flatMap { id in memories.firstIndex { $0.id == id && $0.category == candidate.category && $0.sourceType != "手动编辑" && $0.conflictsWithMemoryID == nil } } : nil
            if let index = exact ?? semantic {
                var sources = memories[index].evidence ?? []
                guard !sources.contains(where: { $0.messageID == source.id && $0.quote == quote }) else { continue }
                sources.append(evidence)
                memories[index].evidence = Array(sources.suffix(10))
                memories[index].updatedAt = now
                // Keep the original content, ID, category and manual edit history.
                enrichedIDs.insert(memories[index].id)
                continue
            }
            let conflictID = candidate.conflictsWithMemoryID.flatMap(UUID.init(uuidString:)).flatMap { id in
                memories.first(where: { $0.id == id && $0.category == candidate.category })?.id
            }
            memories.insert(AssistantMemory(content: content, category: candidate.category,
                createdAt: now, updatedAt: now, sourceType: "自动提取", evidence: [evidence],
                conflictsWithMemoryID: conflictID), at: 0)
            added += 1
        }
        return Result(memories: memories, added: added, enriched: enrichedIDs.count)
    }
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
