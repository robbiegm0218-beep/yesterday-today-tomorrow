import Foundation
import Testing
@testable import PersonalAssistant

struct ConversationHistoryWindowTests {
    @Test func startupBoundsPresentationWithoutMutatingHistory() {
        for count in [0,1,59,60,61,225,500] {
            let ids = (0..<count).map { _ in UUID() }, before = ids
            let window = ConversationHistoryWindow()
            #expect(window.range(in: ids).count == min(60,count) && ids == before)
        }
    }
    @Test func earlierPagesReachOldestWithoutSkippingOrDuplicating() {
        let ids = (0..<500).map { _ in UUID() }
        var window = ConversationHistoryWindow(); window.recent(in: ids)
        var visited = Set(ids[window.range(in: ids)])
        var previous = window.start(in: ids)
        while window.start(in: ids) > 0 {
            window.earlier(in: ids)
            let current = window.start(in: ids)
            #expect(previous-current == min(60,previous)); previous = current
            visited.formUnion(ids[window.range(in: ids)])
            #expect(window.range(in: ids).count <= ConversationHistoryWindow.maximumVisible)
        }
        #expect(window.range(in: ids) == 0..<120 && visited.count == 500)
        while window.newerCount(in: ids) > 0 {
            let before = window.range(in: ids)
            window.newer(in: ids)
            #expect(window.start(in: ids) > before.lowerBound)
            #expect(window.start(in: ids) <= before.upperBound)
            #expect(window.range(in: ids).count <= ConversationHistoryWindow.maximumVisible)
        }
        #expect(window.range(in: ids) == 440..<500)
    }
    @Test func oldCardRevealUsesExactIDAndMissingTargetDoesNotChangeWindow() {
        let ids = (0..<500).map { _ in UUID() }
        var window = ConversationHistoryWindow(); window.recent(in: ids)
        let found = window.reveal(ids[12], in: ids)
        #expect(found && window.range(in: ids).contains(12))
        let anchor = window.firstVisibleID
        let absent = window.reveal(UUID(), in: ids)
        #expect(!absent && window.firstVisibleID == anchor)
    }
    @Test func incomingReplyKeepsReadingAnchorAndRecentExplicitlyRebounds() {
        var ids = (0..<500).map { _ in UUID() }
        var window = ConversationHistoryWindow(); window.recent(in: ids); window.earlier(in: ids)
        let anchor = window.firstVisibleID; ids.append(UUID())
        #expect(window.firstVisibleID == anchor && window.range(in: ids).count == 120)
        window.recent(in: ids)
        #expect(window.range(in: ids).count == 60)
    }
    @Test func oldCardRevealDoesNotConstructTheEntireTail() {
        let ids = (0..<10_000).map { _ in UUID() }
        var window = ConversationHistoryWindow(); window.recent(in: ids)
        for target in [0, 12, 500, 9_990] {
            let found = window.reveal(ids[target], in: ids)
            #expect(found && window.range(in: ids).contains(target))
            #expect(window.range(in: ids).count <= 120)
        }
    }
    @Test func olderPagePinsBothEndsAcrossIncomingMessagesAndRepeatedNavigation() {
        var ids = (0..<500).map { _ in UUID() }
        var window = ConversationHistoryWindow(); window.recent(in: ids)
        window.earlier(in: ids); window.earlier(in: ids)
        let before = Array(ids[window.range(in: ids)])
        ids.append(contentsOf: (0..<50).map { _ in UUID() })
        #expect(Array(ids[window.range(in: ids)]) == before)
        #expect(window.newerCount(in: ids) == 110)
        for _ in 0..<50 { window.earlier(in: ids) }
        #expect(window.range(in: ids) == 0..<120)
        for _ in 0..<50 { window.newer(in: ids) }
        #expect(window.range(in: ids) == 490..<550)
        #expect(window.newerCount(in: ids) == 0)
    }
    @Test func deletedAnchorAndEmptyHistoryFailSafely() {
        var ids = (0..<80).map { _ in UUID() }
        var window = ConversationHistoryWindow(); window.recent(in: ids)
        ids.removeAll { $0 == window.firstVisibleID }
        #expect(window.range(in: ids).count == 60)
        #expect(window.range(in: []) == 0..<0)
        window.earlier(in: []); #expect(window.firstVisibleID == nil)
    }
}
