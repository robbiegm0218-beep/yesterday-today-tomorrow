import AppKit
import Foundation

struct KnowledgeDocument: Identifiable, Codable, Equatable {
    var id: String { urlPath }
    let urlPath: String
    let title: String
    let content: String
    let indexedAt: Date
    let modifiedAt: Date?
    let fileSize: Int64?
}

struct KnowledgeSource: Identifiable, Codable, Equatable {
    var id: String { urlPath }
    let baseName: String
    let title: String
    let urlPath: String
}

struct KnowledgeSearchResult {
    let context: String
    let sources: [KnowledgeSource]
}

struct LocalKnowledgeBase: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var folderPath: String
    var folderBookmark: Data? = nil
    var documents: [KnowledgeDocument] = []
    var lastIndexedAt: Date?
    var isSingleFile: Bool? = nil
}

enum LocalKnowledgeStore {
    private static var fileURL: URL {
        LocalAssistantPaths.dataDirectory.appendingPathComponent("knowledge-bases.json")
    }

    static func load() -> [LocalKnowledgeBase] {
        LocalJSONFileStore.load(from: fileURL, as: [LocalKnowledgeBase].self) ?? []
    }

    static func saveChecked(_ bases: [LocalKnowledgeBase]) throws {
        try LocalJSONFileStore.save(bases, to: fileURL)
    }

    static func save(_ bases: [LocalKnowledgeBase]) {
        do {
            try LocalJSONFileStore.save(bases, to: fileURL)
        } catch {
            NSLog("Could not save local knowledge bases: %@", error.localizedDescription)
        }
    }
}

enum LocalDocumentIndexer {
    static let supportedExtensions: Set<String> = ["md", "markdown", "txt", "docx"]

    enum IndexingError: LocalizedError {
        case authorizationExpired
        case folderUnavailable(String)
        case folderUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .authorizationExpired:
                return "源资料访问授权已失效，请重新连接源资料。原有索引快照仍可搜索。"
            case .folderUnavailable(let path):
                return "找不到资料来源：\(path)。请重新连接源资料。原有索引快照仍可搜索。"
            case .folderUnreadable(let path):
                return "无法读取资料来源：\(path)。请检查访问权限，或重新连接源文件夹。原有索引快照仍可搜索。"
            }
        }
    }

    struct IndexReport {
        let documents: [KnowledgeDocument]
        let skippedFiles: [String]
        let resolvedFolderPath: String
        let refreshedBookmark: Data?
        let bookmarkRefreshFailed: Bool
    }

    static func index(folderPath: String, bookmark: Data? = nil, existing: [KnowledgeDocument] = []) throws -> [KnowledgeDocument] {
        try indexWithReport(folderPath: folderPath, bookmark: bookmark, existing: existing).documents
    }

    static func indexWithReport(folderPath: String, bookmark: Data? = nil, existing: [KnowledgeDocument] = [], singleFile: Bool = false) throws -> IndexReport {
        var folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        var resolvedStaleBookmark = false
        if let bookmark {
            var isStale = false
            do {
                folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
                resolvedStaleBookmark = isStale
            } catch {
                throw IndexingError.authorizationExpired
            }
        }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        if bookmark != nil && !accessed {
            throw IndexingError.authorizationExpired
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue != singleFile else {
            throw IndexingError.folderUnavailable(folder.path)
        }
        guard FileManager.default.isReadableFile(atPath: folder.path) else {
            throw IndexingError.folderUnreadable(folder.path)
        }
        let urls: AnyIterator<URL>
        if singleFile {
            guard supportedExtensions.contains(folder.pathExtension.lowercased()) else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            var selected = [folder].makeIterator()
            urls = AnyIterator { selected.next() }
        } else {
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: folder.path])
            }
            urls = AnyIterator { enumerator.nextObject() as? URL }
        }
        var documents: [KnowledgeDocument] = []
        var skippedFiles: [String] = []
        let oldByPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.urlPath, $0) })
        for url in urls {
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            let modifiedAt = values.contentModificationDate
            let fileSize = values.fileSize.map(Int64.init)
            if let old = oldByPath[url.path], old.modifiedAt == modifiedAt, old.fileSize == fileSize {
                documents.append(old)
                continue
            }
            do {
                let content = try readText(from: url)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                documents.append(KnowledgeDocument(urlPath: url.path, title: url.deletingPathExtension().lastPathComponent, content: String(content.prefix(120_000)), indexedAt: Date(), modifiedAt: modifiedAt, fileSize: fileSize))
            } catch {
                NSLog("Could not index %@: %@", url.lastPathComponent, error.localizedDescription)
                skippedFiles.append(url.lastPathComponent)
                if let old = oldByPath[url.path] { documents.append(old) }
            }
        }
        let refreshedBookmark = resolvedStaleBookmark
            ? try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            : nil
        return IndexReport(
            documents: documents.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            skippedFiles: skippedFiles.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            resolvedFolderPath: folder.path,
            refreshedBookmark: refreshedBookmark,
            bookmarkRefreshFailed: resolvedStaleBookmark && refreshedBookmark == nil
        )
    }

    static func readText(from url: URL) throws -> String {
        if ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        let data = try Data(contentsOf: url)
        let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        return attributed.string
    }
}

enum LocalKnowledgeSearch {
    static func recommendations(for projectName: String, bases: [LocalKnowledgeBase], limit: Int = 3) -> [KnowledgeSource] {
        let result = search(for: projectName, bases: bases)
        return Array(result.sources.prefix(limit))
    }

    static func search(for query: String, bases: [LocalKnowledgeBase]) -> KnowledgeSearchResult {
        let terms = Set(tokenize(query))
        guard !terms.isEmpty else { return KnowledgeSearchResult(context: "", sources: []) }
        let documents = bases.flatMap { base in base.documents.map { (base, $0) } }
        guard !documents.isEmpty else { return KnowledgeSearchResult(context: "", sources: []) }
        let documentAnalyses = documents.map { entry in
            (tokenCount: tokenCount(in: entry.1.content), frequencies: termFrequencies(in: entry.1.content, terms: terms))
        }
        let averageDocumentLength = max(1, Double(documentAnalyses.map(\.tokenCount).reduce(0, +)) / Double(documentAnalyses.count))
        let idf = Dictionary(uniqueKeysWithValues: terms.map { term in
            let documentFrequency = documentAnalyses.filter { $0.frequencies[term, default: 0] > 0 }.count
            return (term, log(1 + (Double(documents.count - documentFrequency) + 0.5) / (Double(documentFrequency) + 0.5)))
        })

        let matches = documents.enumerated().compactMap { index, entry -> (String, Double, KnowledgeSource)? in
            let (base, document) = entry
            let titleScore = terms.reduce(0.0) { score, term in
                score + (document.title.localizedCaseInsensitiveContains(term) ? (idf[term] ?? 0) * 2.5 : 0)
            }
            let analysis = documentAnalyses[index]
            let bodyScore = bm25Score(frequencies: analysis.frequencies, tokenCount: analysis.tokenCount, terms: terms, idf: idf, averageLength: averageDocumentLength)
            let (excerptScore, excerpt) = bestExcerpt(from: document.content, terms: terms, idf: idf, averageLength: averageDocumentLength)
            let score = titleScore + bodyScore + excerptScore * 0.35
            guard score > 0 else { return nil }
            return ("知识库「\(base.name)」· \(document.title)：\(excerpt)", score, KnowledgeSource(baseName: base.name, title: document.title, urlPath: document.urlPath))
        }
        let topMatches = matches.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.2.title.localizedStandardCompare($1.2.title) == .orderedAscending
        }.prefix(4)
        return KnowledgeSearchResult(context: topMatches.map { $0.0 }.joined(separator: "\n"), sources: topMatches.map { $0.2 })
    }

    private static func tokenize(_ text: String) -> [String] {
        let chunks = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var terms = chunks.filter { $0.count > 1 }
        for chunk in chunks where chunk.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            let characters = Array(chunk)
            guard characters.count > 1 else { continue }
            for index in 0..<(characters.count - 1) {
                terms.append(String(characters[index...index + 1]))
            }
        }
        return terms
    }

    private static func tokenCount(in text: String) -> Int {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.reduce(0) { count, chunk in
            let baseCount = chunk.count > 1 ? 1 : 0
            let containsChinese = chunk.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            return count + baseCount + (containsChinese ? max(0, chunk.count - 1) : 0)
        }
    }

    private static func termFrequencies(in text: String, terms: Set<String>) -> [String: Int] {
        tokenize(text).reduce(into: [:]) { frequencies, token in
            guard terms.contains(token) else { return }
            frequencies[token, default: 0] += 1
        }
    }

    private static func bm25Score(frequencies: [String: Int], tokenCount: Int, terms: Set<String>, idf: [String: Double], averageLength: Double) -> Double {
        let k1 = 1.2
        let b = 0.75
        let lengthNormalization = k1 * (1 - b + b * Double(tokenCount) / averageLength)
        return terms.reduce(0.0) { score, term in
            let frequency = Double(frequencies[term, default: 0])
            guard frequency > 0 else { return score }
            return score + (idf[term] ?? 0) * frequency * (k1 + 1) / (frequency + lengthNormalization)
        }
    }

    private static func bestExcerpt(from content: String, terms: Set<String>, idf: [String: Double], averageLength: Double) -> (Double, String) {
        let paragraphs = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var bestScore = 0.0
        var bestIndex = 0
        for (index, paragraph) in paragraphs.enumerated() {
            let score = bm25Score(
                frequencies: termFrequencies(in: paragraph, terms: terms),
                tokenCount: tokenCount(in: paragraph),
                terms: terms,
                idf: idf,
                averageLength: averageLength
            )
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        let lowerIndex = max(0, bestIndex - 1)
        let upperIndex = min(paragraphs.count - 1, bestIndex + 1)
        let bestParagraph = paragraphs.isEmpty ? content : paragraphs[lowerIndex...upperIndex].joined(separator: "\n")
        let firstMatch = terms.compactMap { bestParagraph.range(of: $0, options: .caseInsensitive)?.lowerBound }.min() ?? bestParagraph.startIndex
        let start = bestParagraph.index(firstMatch, offsetBy: -min(240, bestParagraph.distance(from: bestParagraph.startIndex, to: firstMatch)), limitedBy: bestParagraph.startIndex) ?? bestParagraph.startIndex
        let end = bestParagraph.index(start, offsetBy: 700, limitedBy: bestParagraph.endIndex) ?? bestParagraph.endIndex
        return (bestScore, String(bestParagraph[start..<end]))
    }
}
