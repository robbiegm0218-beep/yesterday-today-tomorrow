import Foundation
import Testing
@testable import PersonalAssistant

@MainActor
private final class MemoryGate {
    var started: [Int] = []
    var waiters: [Int: CheckedContinuation<[ExtractedMemory], Never>] = [:]
    func extract(_ id: Int) async -> [ExtractedMemory] {
        started.append(id)
        return await withCheckedContinuation { waiters[id] = $0 }
    }
    func release(_ id: Int) { waiters.removeValue(forKey: id)?.resume(returning: []) }
}

@MainActor
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<2000 {
        if condition() { return }
        await Task.yield()
    }
    #expect(condition())
}

@Suite(.serialized)
@MainActor struct ChatExperienceTests {
    @Test func memoryQueueSerializesSourcesAndReturnsBeforeExtractionFinishes() async {
        let gate = MemoryGate(); var applied: [Int] = [], busy: [Bool] = []
        let queue = AutomaticMemoryQueue(onBusy: { busy.append($0) })
        let first = UUID()
        #expect(queue.enqueue(id: first, extract: { await gate.extract(1) }, apply: { _ in applied.append(1) }, failed: {}))
        #expect(queue.enqueue(id: first, extract: { Issue.record("Duplicate source ran"); return [] }, apply: { _ in }, failed: {}))
        let secondAccepted = queue.enqueue(id: UUID(), extract: { #expect(applied == [1]); return await gate.extract(2) }, apply: { _ in applied.append(2) }, failed: {})
        #expect(secondAccepted)
        await eventually { gate.started == [1] }
        #expect(queue.pendingCount == 2 && applied.isEmpty)
        // New user work can run while extraction is suspended.
        var foregroundCompleted = false
        Task { foregroundCompleted = true }
        await eventually { foregroundCompleted }
        #expect(gate.started == [1] && applied.isEmpty)
        gate.release(1); await eventually { gate.started == [1,2] }
        gate.release(2); await eventually { queue.pendingCount == 0 }
        #expect(applied == [1,2] && busy.last == false)
    }

    @Test func disableOrManualEditDiscardsLateResultWithoutCancellingNewGeneration() async {
        let gate = MemoryGate(); var applied: [Int] = [], failures = 0
        let queue = AutomaticMemoryQueue()
        queue.enqueue(id: UUID(), extract: { await gate.extract(1) }, apply: { _ in applied.append(1) }, failed: { failures += 1 })
        queue.enqueue(id: UUID(), extract: { Issue.record("Cancelled queued source ran"); return [] }, apply: { _ in applied.append(2) }, failed: {})
        await eventually { gate.started == [1] }
        queue.cancelAll()
        #expect(queue.pendingCount == 0)
        queue.enqueue(id: UUID(), extract: { await gate.extract(3) }, apply: { _ in applied.append(3) }, failed: {})
        await eventually { gate.started == [1,3] }
        gate.release(1)
        for _ in 0..<10 { await Task.yield() }
        #expect(applied.isEmpty && queue.pendingCount == 1 && failures == 0)
        gate.release(3); await eventually { queue.pendingCount == 0 }
        #expect(applied == [3])
    }

    @Test func boundedQueueAndFailureDoNotBlockFollowingSource() async {
        let gate = MemoryGate(); var failures = 0, applied = 0
        let queue = AutomaticMemoryQueue(limit: 2)
        queue.enqueue(id: UUID(), extract: { _ = await gate.extract(1); throw URLError(.timedOut) }, apply: { _ in Issue.record("Failed result applied") }, failed: { failures += 1 })
        queue.enqueue(id: UUID(), extract: { [] }, apply: { _ in applied += 1 }, failed: {})
        #expect(!queue.enqueue(id: UUID(), extract: { [] }, apply: { _ in }, failed: {}))
        await eventually { gate.started == [1] }; gate.release(1)
        await eventually { queue.pendingCount == 0 }
        #expect(failures == 1 && applied == 1)
    }

    @Test func perTurnMemoryOptOutDoesNotEnqueueAnotherExtraction() {
        for request in ["只读核对当前状态，不修改。不要记录这次查询。", "不要记录本轮对话", "别记录这次", "本轮不记录"] {
            #expect(!MemoryExtractionPolicy.shouldExtract(from: request))
        }
        #expect(MemoryExtractionPolicy.shouldExtract(from: "请记住我长期偏好下午安排专注任务"))
    }

    @Test func planExplanationUsesValidatedReasonsAndKeepsSourceStatesIndependent() {
        let plan = SavedDayPlan(day: "2026-11-06", timeZone: "Asia/Shanghai", steps: [.init(title: "评审准备", plannedTime: "14:00", reason: "下午适合专注，提前整理问题清单")])
        let action = PendingAssistantAction(summary: "保存今日计划", operation: .saveDayPlan(plan: plan, expectedRevision: 0))
        let message = AssistantProposalPresentation.message(for: [action])
        #expect(message.contains("下午适合专注") && message.contains("尚未写入"))
        #expect(AssistantProposalPresentation.scope(action.operation).contains("原待办状态"))
        #expect(!message.contains("已保存"))
    }

    @Test func validationReportsDuplicateSourceInsteadOfRequestingUnneededContext() throws {
        let todo = PersonalTodo(title: "评审准备", importance: .normal)
        let row: [String: Any] = ["title": todo.title, "sourceKind": "personal", "sourceID": todo.id.uuidString]
        let data = try JSONSerialization.data(withJSONObject: ["steps": [row,row]])
        let call = DeepSeekToolCall(id: "invalid", function: .init(name: "propose_day_plan", arguments: String(decoding: data, as: UTF8.self)))
        let issue = AssistantProposalValidation.issue(calls: [call], todos: [todo], plans: [], references: [.init(kind: "personal", id: todo.id.uuidString, title: todo.title, time: "", duration: 30)], user: .init(text: "安排今天", isUser: true))
        #expect(issue?.contains("重复") == true)
    }
}
