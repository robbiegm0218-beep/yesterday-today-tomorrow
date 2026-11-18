import Foundation

/// Serial, bounded auxiliary work. Cancellation also invalidates results from
/// transports that ignore cancellation; no job is persisted or automatically retried.
@MainActor
final class AutomaticMemoryQueue {
    private struct Job {
        let id: UUID
        let extract: () async throws -> [ExtractedMemory]
        let apply: ([ExtractedMemory]) -> Void
        let failed: () -> Void
    }
    private var jobs: [Job] = []
    private var activeID: UUID?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let onBusy: (Bool) -> Void
    let limit: Int
    var pendingCount: Int { jobs.count + (activeID == nil ? 0 : 1) }

    init(limit: Int = 8, onBusy: @escaping (Bool) -> Void = { _ in }) {
        self.limit = max(1, limit); self.onBusy = onBusy
    }

    @discardableResult
    func enqueue(id: UUID, extract: @escaping () async throws -> [ExtractedMemory], apply: @escaping ([ExtractedMemory]) -> Void, failed: @escaping () -> Void) -> Bool {
        if activeID == id || jobs.contains(where: { $0.id == id }) { return true }
        guard pendingCount < limit else { return false }
        jobs.append(.init(id: id, extract: extract, apply: apply, failed: failed))
        onBusy(true); startNext()
        return true
    }

    func cancelAll() {
        generation = UUID(); jobs.removeAll(); activeID = nil
        task?.cancel(); task = nil; onBusy(false)
    }

    private func startNext() {
        guard activeID == nil, !jobs.isEmpty else { return }
        let job = jobs.removeFirst(), epoch = generation
        activeID = job.id
        task = Task { [weak self] in
            do {
                let result = try await job.extract()
                guard let self, self.generation == epoch, !Task.isCancelled else { return }
                job.apply(result)
            } catch {
                guard let self, self.generation == epoch, !Task.isCancelled else { return }
                job.failed()
            }
            guard let self, self.generation == epoch else { return }
            self.activeID = nil; self.task = nil
            if self.jobs.isEmpty { self.onBusy(false) } else { self.startNext() }
        }
    }
}
