import Foundation

/// Presentation only. Never trims the model's conversation or stored history.
struct ConversationHistoryWindow {
    static let pageSize = 60
    static let maximumVisible = 120
    private(set) var firstVisibleID: UUID?
    private var lastVisibleID: UUID?

    func range(in ids: [UUID]) -> Range<Int> {
        let first = firstVisibleID.flatMap { ids.firstIndex(of: $0) } ?? max(0, ids.count - Self.pageSize)
        let end = lastVisibleID.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? ids.count
        // Deleted/reordered anchors must still produce a valid bounded range.
        let lower = min(first, end)
        return lower..<min(end, lower + Self.maximumVisible)
    }
    func start(in ids: [UUID]) -> Int { range(in: ids).lowerBound }
    func newerCount(in ids: [UUID]) -> Int { ids.count - range(in: ids).upperBound }
    mutating func recent(in ids: [UUID]) {
        firstVisibleID = ids.dropFirst(max(0, ids.count - Self.pageSize)).first
        lastVisibleID = nil
    }
    @discardableResult mutating func earlier(in ids: [UUID]) -> UUID? {
        guard !ids.isEmpty else { recent(in: []); return nil }
        let first = max(0, start(in: ids) - Self.pageSize)
        select(first..<min(ids.count, first + Self.maximumVisible), in: ids)
        return firstVisibleID
    }
    @discardableResult mutating func newer(in ids: [UUID]) -> UUID? {
        guard !ids.isEmpty else { recent(in: []); return nil }
        let first = min(max(0, ids.count - Self.pageSize), start(in: ids) + Self.pageSize)
        if first + Self.maximumVisible >= ids.count { recent(in: ids) }
        else { select(first..<min(ids.count, first + Self.maximumVisible), in: ids) }
        return firstVisibleID
    }
    @discardableResult mutating func reveal(_ id: UUID, in ids: [UUID]) -> Bool {
        guard let target = ids.firstIndex(of: id) else { return false }
        if !range(in: ids).contains(target) {
            let first = max(0, target - Self.pageSize / 2)
            select(first..<min(ids.count, first + Self.maximumVisible), in: ids)
        }
        return true
    }
    private mutating func select(_ range: Range<Int>, in ids: [UUID]) {
        firstVisibleID = range.first.map { ids[$0] }
        // Pin both ends on older pages, including when new messages arrive.
        lastVisibleID = range.last.map { ids[$0] }
    }
}
