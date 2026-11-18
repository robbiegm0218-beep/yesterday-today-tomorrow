import Foundation

/// Exact-source, memory-only LRU. Limits retained source bytes, not total heap size.
final class BoundedTextCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data: Value] = [:]
    private var order: [Data] = []
    private var bytes = 0
    private var hits = 0, misses = 0
    let maxEntries: Int, maxSourceBytes: Int, maxEntryBytes: Int
    init(maxEntries: Int, maxSourceBytes: Int, maxEntryBytes: Int) {
        self.maxEntries = maxEntries; self.maxSourceBytes = maxSourceBytes; self.maxEntryBytes = maxEntryBytes
    }
    func value(for source: String, make: () -> Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        let key = Data(source.utf8)
        if let cached = values[key] {
            hits += 1; order.removeAll { $0 == key }; order.append(key); return cached
        }
        misses += 1
        let result = make(), cost = key.count
        guard maxEntries > 0, cost <= maxEntryBytes, cost <= maxSourceBytes else { return result }
        while !order.isEmpty && (values.count >= maxEntries || bytes + cost > maxSourceBytes) {
            let key = order.removeFirst(); values.removeValue(forKey: key); bytes -= key.count
        }
        values[key] = result; order.append(key); bytes += cost
        return result
    }
    var statistics: (entries: Int, sourceBytes: Int, hits: Int, misses: Int) {
        lock.lock(); defer { lock.unlock() }; return (values.count, bytes, hits, misses)
    }
}

struct StreamScrollGate {
    private(set) var requestID: UUID?
    private(set) var lastScroll: TimeInterval?
    mutating func reset(requestID: UUID?) { self.requestID = requestID; lastScroll = nil }
    mutating func allow(requestID: UUID?, atBottom: Bool, now: TimeInterval) -> Bool {
        guard let requestID, requestID == self.requestID, atBottom else { return false }
        if let lastScroll, now >= lastScroll && now - lastScroll < 0.1 { return false }
        lastScroll = now; return true
    }
}
