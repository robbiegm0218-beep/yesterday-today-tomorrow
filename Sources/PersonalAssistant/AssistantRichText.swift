import SwiftUI

/// Render Markdown blocks individually so headings, lists and paragraphs keep
/// their hierarchy instead of flattening into one long inline-only Text.
struct AssistantRichText: View {
    let text: String

    enum Block: Equatable {
        case paragraph(String)
        case heading(String, Int)
        case item(String, String, Int)
        case quote(String)
        case code(String, String)
        case divider
    }

    private static let blockCache = BoundedTextCache<[Block]>(maxEntries: 256, maxSourceBytes: 1_048_576, maxEntryBytes: 32_768)
    private static let inlineCache = BoundedTextCache<AttributedString>(maxEntries: 512, maxSourceBytes: 1_048_576, maxEntryBytes: 16_384)
    static func inline(_ value: String) -> AttributedString {
        inlineCache.value(for: value) {
            (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        }
    }
    static func blocks(_ text: String) -> [Block] { blockCache.value(for: text) { parseBlocks(text) } }
    static var cacheStatistics: [String: Int] {
        let block = blockCache.statistics, inline = inlineCache.statistics
        return ["blockEntries": block.entries, "blockSourceBytes": block.sourceBytes, "blockHits": block.hits, "blockMisses": block.misses, "inlineEntries": inline.entries, "inlineSourceBytes": inline.sourceBytes, "inlineHits": inline.hits, "inlineMisses": inline.misses]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.top, index == 0 ? 0 : Self.spacing(before: block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(AssistantTheme.text)
        .tint(AssistantTheme.accent)
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case let .paragraph(value):
            Text(Self.inline(value)).font(.system(size: 15)).lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        case let .heading(value, level):
            Text(Self.inline(value)).font(.system(size: level == 1 ? 21 : (level == 2 ? 18 : 16), weight: .semibold))
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        case let .item(value, marker, depth):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(marker).font(.system(size: 14)).foregroundStyle(AssistantTheme.secondaryText)
                    .frame(minWidth: 15, alignment: .trailing)
                Text(Self.inline(value)).font(.system(size: 15)).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(min(depth, 4)) * 16)
        case let .quote(value):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(AssistantTheme.border).frame(width: 3)
                Text(Self.inline(value)).font(.system(size: 14)).foregroundStyle(AssistantTheme.secondaryText)
                    .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }.fixedSize(horizontal: false, vertical: true)
        case let .code(value, language):
            VStack(alignment: .leading, spacing: 10) {
                if !language.isEmpty {
                    Text(language).font(.system(size: 11, weight: .medium)).foregroundStyle(AssistantTheme.secondaryText)
                }
                ScrollView(.horizontal) {
                    Text(verbatim: value).font(.system(size: 13, design: .monospaced)).lineSpacing(4)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 10))
        case .divider:
            Rectangle().fill(AssistantTheme.border).frame(height: 1).padding(.vertical, 4)
        }
    }

    private static func spacing(before block: Block) -> CGFloat {
        switch block {
        case .heading: 22
        case .item: 7
        case .paragraph, .quote, .code, .divider: 14
        }
    }

    static func parseBlocks(_ text: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        var language = ""
        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        let ordered = try? NSRegularExpression(pattern: "^([0-9]+)[.)、]\\s+(.+)$")
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("```") {
                flush()
                if let content = code {
                    result.append(.code(content.joined(separator: "\n"), language))
                    code = nil
                } else {
                    code = []
                    language = String(value.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if code != nil { code?.append(line); continue }
            if value.isEmpty { flush(); continue }
            if ["---", "***", "___"].contains(value) { flush(); result.append(.divider); continue }
            let hashes = value.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), value.dropFirst(hashes).first == " " {
                flush()
                result.append(.heading(String(value.dropFirst(hashes + 1)), hashes))
                continue
            }
            if value.hasPrefix("**"), value.hasSuffix("**"), value.count <= 70,
               !value.dropFirst(2).dropLast(2).contains("**") {
                flush(); result.append(.heading(String(value.dropFirst(2).dropLast(2)), 3)); continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if ["- ", "* ", "+ ", "• "].contains(where: { value.hasPrefix($0) }) {
                flush(); result.append(.item(String(value.dropFirst(2)), "•", indent)); continue
            }
            let ns = value as NSString
            if let match = ordered?.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) {
                flush()
                result.append(.item(ns.substring(with: match.range(at: 2)), ns.substring(with: match.range(at: 1)) + ".", indent))
                continue
            }
            if value.hasPrefix(">") {
                flush(); result.append(.quote(String(value.dropFirst()).trimmingCharacters(in: .whitespaces))); continue
            }
            if line.first == " " || line.first == "\t", case let .item(previous, marker, depth)? = result.last {
                result[result.count - 1] = .item(previous + "\n" + value, marker, depth)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        if let content = code { result.append(.code(content.joined(separator: "\n"), language)) }
        return result
    }
}
