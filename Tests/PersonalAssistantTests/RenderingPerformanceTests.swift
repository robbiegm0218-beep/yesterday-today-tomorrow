import Foundation
import Testing
@testable import PersonalAssistant

struct RenderingPerformanceTests {
    @Test func exactSourceCacheDoesNotReturnPreviousEditedText() {
        let cache = BoundedTextCache<String>(maxEntries: 2, maxSourceBytes: 100, maxEntryBytes: 100)
        #expect(cache.value(for: "A") { "original" } == "original")
        #expect(cache.value(for: "A") { "wrong" } == "original")
        #expect(cache.value(for: "B") { "edited" } == "edited")
        #expect(cache.statistics.hits == 1)
    }
    @Test func leastRecentlyUsedEvictionAndUnicodeSourceByteLimit() {
        let cache = BoundedTextCache<String>(maxEntries: 2, maxSourceBytes: 6, maxEntryBytes: 6)
        _ = cache.value(for: "中") { "one" }; _ = cache.value(for: "文") { "two" }
        _ = cache.value(for: "中") { "unused" }
        _ = cache.value(for: "字") { "three" }
        #expect(cache.statistics.entries == 2 && cache.statistics.sourceBytes == 6)
        #expect(cache.value(for: "中") { "wrong" } == "one")
        #expect(cache.value(for: "文") { "rebuilt" } == "rebuilt")
    }
    @Test func oversizedStreamOrDisabledCacheNeverRetained() {
        let cache = BoundedTextCache<Int>(maxEntries: 2, maxSourceBytes: 8, maxEntryBytes: 3)
        #expect(cache.value(for: "too large") { 1 } == 1)
        #expect(cache.value(for: "too large") { 2 } == 2)
        #expect(cache.statistics.entries == 0)
        let disabled = BoundedTextCache<Int>(maxEntries: 0, maxSourceBytes: 8, maxEntryBytes: 8)
        _ = disabled.value(for: "a") { 1 }; #expect(disabled.statistics.entries == 0)
    }
    @Test func cachedMarkdownMatchesFreshParsingForEditedAndIncompleteBlocks() {
        for text in ["## 标题\n- **重点**\n  继续说明\n> 引用", "1. 原文\n2. 新文", "```swift\nlet a = 1", "```swift\nlet a = 1\n```\n新段落", "中文🙂 **强调**\n\n---", "## 新标题\n- 改过的内容"] {
            #expect(AssistantRichText.blocks(text) == AssistantRichText.parseBlocks(text))
            #expect(AssistantRichText.blocks(text) == AssistantRichText.parseBlocks(text))
        }
        #expect(AssistantRichText.blocks("## 原标题") != AssistantRichText.blocks("## 新标题"))
    }
    @Test func inlineFormattingLinksAndUnicodeMatchUncachedOutput() {
        for text in ["**重点**与*斜体*", "[资料](https://example.com)", "中文🙂 `代码`", "**尚未闭合", "正文\n换行"] {
            let expected = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
            #expect(AssistantRichText.inline(text) == expected)
        }
    }
    @Test func rapidStreamScrollIsBoundedAndResetsForNewRequest() {
        var gate = StreamScrollGate(); let first = UUID(), second = UUID()
        gate.reset(requestID: first)
        let allowed1 = gate.allow(requestID: first, atBottom: true, now: 1); #expect(allowed1)
        let allowed2 = gate.allow(requestID: first, atBottom: true, now: 1.01); #expect(!allowed2)
        let allowed3 = gate.allow(requestID: first, atBottom: true, now: 1.11); #expect(allowed3)
        gate.reset(requestID: second)
        let allowed4 = gate.allow(requestID: first, atBottom: true, now: 1.12); #expect(!allowed4)
        let allowed5 = gate.allow(requestID: second, atBottom: true, now: 1.12); #expect(allowed5)
        gate.reset(requestID: nil)
        let allowed6 = gate.allow(requestID: second, atBottom: true, now: 2); #expect(!allowed6)
    }
    @Test func browsingOldHistoryNeverGrantsStreamScroll() {
        var gate = StreamScrollGate(); let id = UUID(); gate.reset(requestID: id)
        let allowed7 = gate.allow(requestID: id, atBottom: false, now: 1); #expect(!allowed7)
        let allowed8 = gate.allow(requestID: id, atBottom: true, now: 1.01); #expect(allowed8)
        let allowed9 = gate.allow(requestID: id, atBottom: false, now: 5); #expect(!allowed9)
    }

    @Test func canonicallyEquivalentUnicodeStillKeepsExactSourceBytes() {
        let cache = BoundedTextCache<Data>(maxEntries: 4, maxSourceBytes: 100, maxEntryBytes: 100)
        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        #expect(composed == decomposed)
        #expect(cache.value(for: composed) { Data(composed.utf8) } == Data(composed.utf8))
        #expect(cache.value(for: decomposed) { Data(decomposed.utf8) } == Data(decomposed.utf8))
        #expect(cache.statistics.entries == 2)
    }
}
