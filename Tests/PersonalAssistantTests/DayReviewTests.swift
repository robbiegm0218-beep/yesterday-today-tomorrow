import Foundation
import Testing
@testable import PersonalAssistant

struct DayReviewTests {
    let now = Date()
    var today: String { DailyPlanSchedulePolicy.dayKey(for: now) }
    var yesterday: String { DayReviewPolicy.yesterday(now: now) }
    func origin(_ steps: [DayPlanStep]) -> SavedDayPlan { .init(day: yesterday, timeZone: TimeZone.current.identifier, revision: 2, steps: steps) }
    func current(_ steps: [DayPlanStep]) -> SavedDayPlan { .init(day: today, timeZone: TimeZone.current.identifier, revision: 3, steps: steps) }
    @Test func confirmedCarryPreservesTodayAndHistoricalCheckboxesAndClearsYesterdayClock() throws {
        let done = DayPlanStep(title: "昨日已勾选", isDone: true)
        let open = DayPlanStep(title: "昨日未做", plannedTime: "10:00", durationMinutes: 45, reason: "今天到期")
        let source = origin([done, open]); let existing = DayPlanStep(title: "今天安排", plannedTime: "15:00", isDone: true); let current = current([existing])
        let proposal = try DayReviewPolicy.proposal(origin: source, today: current, inputs: [.init(stepID: open.id, choice: "today")], references: [], now: now)
        let target = try #require(proposal.todayProposed)
        #expect(target.steps[0] == existing && target.steps[1].plannedTime.isEmpty)
        #expect(target.steps[1].carriedFrom == .init(day: source.day, timeZone: source.timeZone, stepID: open.id))
        #expect(!target.steps[1].isDone && target.steps[1].id != open.id && !target.steps[1].reason.contains("今天到期"))
        let saved = try DayReviewPolicy.saving(proposal, among: [source, current], references: [], now: now)
        #expect(saved.first { $0.day == today }?.revision == 4)
        #expect(saved.first { $0.day == yesterday }?.steps == source.steps)
        #expect(try DayReviewPolicy.saving(proposal, among: saved, references: [], now: now) == saved)
        let recorded = try #require(saved.first { $0.day == yesterday })
        #expect(throws: DayPlanError.self) { _ = try DayReviewPolicy.proposal(origin: recorded, today: saved.first { $0.day == today }, inputs: [.init(stepID: open.id, choice: "today")], references: [], now: now) }
    }
    @Test func sameSourceAlreadyInTodayLinksWithoutAddingOrOverwritingProgress() throws {
        let id = UUID().uuidString
        let sourceStep = DayPlanStep(title: "旧名", sourceKind: "personal", sourceID: id)
        let existing = DayPlanStep(title: "新名", sourceKind: "personal", sourceID: id, plannedTime: "14:00", isDone: true)
        let source = origin([sourceStep]); let current = current([existing])
        let proposal = try DayReviewPolicy.proposal(origin: source, today: current, inputs: [.init(stepID: sourceStep.id, choice: "today")], references: [], now: now)
        #expect(proposal.todayProposed == nil && proposal.decisions[0].targetStepID == existing.id)
        let result = try DayReviewPolicy.saving(proposal, among: [source, current], references: [], now: now)
        #expect(result.first { $0.day == today } == current)
    }
    @Test func deferralOnlySavesDecisionAndBecomesReviewableOnTargetDay() throws {
        let step = DayPlanStep(title: "稍后安排")
        let source = origin([step]); let nextDate = Calendar.current.date(byAdding: .day, value: 1, to: now)!; let nextDay = DailyPlanSchedulePolicy.dayKey(for: nextDate)
        let proposal = try DayReviewPolicy.proposal(origin: source, today: nil, inputs: [.init(stepID: step.id, choice: "later", targetDay: nextDay, reason: "等待回复")], references: [], now: now)
        let saved = try DayReviewPolicy.saving(proposal, among: [source], references: [], now: now)
        #expect(saved.count == 1 && proposal.todayProposed == nil)
        #expect(DayReviewPolicy.availableOrigins(plans: saved, now: nextDate).first?.day == source.day)
        let carried = try DayReviewPolicy.proposal(origin: saved[0], today: nil, inputs: [.init(stepID: step.id, choice: "today")], references: [], now: nextDate)
        #expect(carried.decisions[0].history.first?.choice == "later")
        #expect(carried.todayProposed?.day == nextDay)
    }
    @Test func skipDoesNotCompleteDeleteOrCreateTaskAndUnselectedStepsRemainUndecided() throws {
        let first = DayPlanStep(title: "不用安排"), other = DayPlanStep(title: "仍待决定")
        let source = origin([first, other]); let proposal = try DayReviewPolicy.proposal(origin: source, today: nil, inputs: [.init(stepID: first.id, choice: "skip")], references: [], now: now)
        let saved = try DayReviewPolicy.saving(proposal, among: [source], references: [], now: now)
        #expect(saved.count == 1 && saved[0].steps == source.steps && saved[0].reviewDecisions?.count == 1)
        #expect(saved[0].reviewDecisions?.first?.targetDay == nil)
    }
    @Test func checkedStepsHistoricalEventsMissingSourcesAndDuplicateInputsAreRejected() throws {
        let done = DayPlanStep(title: "勾选", isDone: true), event = DayPlanStep(title: "昨日会议", sourceKind: "event", sourceID: "event")
        let task = DayPlanStep(title: "原任务", sourceKind: "personal", sourceID: UUID().uuidString)
        let source = origin([done, event, task])
        for id in [done.id, event.id, task.id, UUID()] {
            #expect(throws: DayPlanError.self) { _ = try DayReviewPolicy.proposal(origin: source, today: nil, inputs: [.init(stepID: id, choice: "today")], references: [], now: now) }
        }
        #expect(throws: DayPlanError.self) { _ = try DayReviewPolicy.proposal(origin: source, today: nil, inputs: [.init(stepID: task.id, choice: "skip"), .init(stepID: task.id, choice: "skip")], references: [], now: now) }
    }
    @Test func confirmationDetectsTodayCheckboxSourceAndDayChangesWithoutWriting() throws {
        let id = UUID().uuidString, step = DayPlanStep(title: "原任务", sourceKind: "personal", sourceID: UUID().uuidString)
        let source = origin([step]); let existing = current([.init(title: "今日安排")]); let ref = DayPlanReference(kind: "personal", id: step.sourceID!, title: "当前标题")
        let proposal = try DayReviewPolicy.proposal(origin: source, today: existing, inputs: [.init(stepID: step.id, choice: "today")], references: [ref], now: now)
        var newer = existing; newer.steps[0].isDone = true; newer.revision += 1
        #expect(throws: DayPlanError.self) { _ = try DayReviewPolicy.saving(proposal, among: [source, newer], references: [ref], now: now) }
        #expect(throws: DayPlanError.self) { _ = try DayReviewPolicy.saving(proposal, among: [source, existing], references: [], now: now) }
        let changed = DayPlanReference(kind: "personal", id: id, title: "另一个任务")
        #expect(throws: DayPlanError.self) { _ = try DayReviewPolicy.saving(proposal, among: [source, existing], references: [changed], now: now) }
        #expect(throws: DayPlanError.self) { _ = try DayReviewPolicy.saving(proposal, among: [source, existing], references: [ref], now: now.addingTimeInterval(172_800)) }
    }
    @Test func unavailableYesterdayIsNotReplacedByOlderHistoryAndDifferentTimezoneDoesNotCarry() throws {
        let oldDay = DailyPlanSchedulePolicy.dayKey(for: Calendar.current.date(byAdding: .day, value: -3, to: now)!)
        let old = SavedDayPlan(day: oldDay, timeZone: TimeZone.current.identifier, steps: [.init(title: "三天前")])
        #expect(DayReviewPolicy.availableOrigins(plans: [old], now: now).isEmpty)
        var foreign = origin([.init(title: "其他时区")]); foreign.timeZone = TimeZone.current.identifier == "UTC" ? "Asia/Tokyo" : "UTC"
        #expect(throws: DayPlanError.self) { _ = try DayReviewPolicy.proposal(origin: foreign, today: nil, inputs: [.init(stepID: foreign.steps[0].id, choice: "today")], references: [], now: now) }
        let context = AssistantChatWorkbenchContext.message(personalTodos: [], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: now, reviewPlans: [old]).content
        #expect(!context.contains("三天前"))
    }
    @Test func chatReviewUsesCurrentSourceStatusWithoutInventingYesterdayCompletionDate() {
        let todo = PersonalTodo(title: "原任务", importance: .normal, isComplete: true)
        let source = origin([.init(title: todo.title, sourceKind: "personal", sourceID: todo.id.uuidString)])
        let context = AssistantChatWorkbenchContext.message(personalTodos: [todo], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: now, reviewPlans: [source]).content
        #expect(context.contains("原任务当前已完成，完成时间未知"))
        #expect(context.contains("previousDayPlan"))
        #expect(!AssistantToolIntent.requestsDayReview("只回顾昨天做了什么"))
        #expect(AssistantToolIntent.requestsDayReview("把昨天的方案安排今天继续"))
    }
    @Test func reviewAndCarryProvenanceSurviveBackupAndMalformedRecordsAreRejected() throws {
        let step = DayPlanStep(title: "继续方案"), source = origin([.init(title: "记录")])
        let original = origin([step]); let proposal = try DayReviewPolicy.proposal(origin: original, today: nil, inputs: [.init(stepID: step.id, choice: "today")], references: [], now: now)
        let saved = try DayReviewPolicy.saving(proposal, among: [original], references: [], now: now)
        var archive = LocalAssistantDataExport(exportedAt: now, profile: .init(name: "QA", personality: "自然", tone: "自然", address: "你", avatar: "warm", relationshipPoints: 0, automaticMemoryEnabled: false), conversation: [], memories: [], projects: [], personalTodos: [], skills: AssistantSkill.defaults, knowledgeBases: [], savedDayPlans: saved)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoded = try LocalAssistantDataManager.decodeImport(encoder.encode(archive))
        #expect(decoded.savedDayPlans?.first?.steps.first?.carriedFrom?.stepID == step.id)
        var malformed = source; malformed.reviewDecisions = [.init(stepID: UUID(), choice: "skip", targetDay: nil, reason: "", recordedAt: now)]; archive.savedDayPlans = [malformed]
        #expect(throws: DayPlanError.self) { _ = try LocalAssistantDataManager.decodeImport(encoder.encode(archive)) }
    }
    @Test func parserRejectsInventedReasonsAndReadOnlyReviewButKeepsPendingConfirmation() throws {
        let step = DayPlanStep(title: "方案"); let source = origin([step])
        let user = AssistantMessage(text: "昨天的方案今天继续，未完成原因未知", isUser: true)
        func call(reason: String, quote: String) throws -> DeepSeekToolCall {
            let choices = try JSONSerialization.data(withJSONObject: [["step_id":step.id.uuidString, "choice":"today", "reason":reason]])
            let args = try JSONSerialization.data(withJSONObject: ["source_day":source.day, "choices_json":String(decoding: choices, as: UTF8.self), "quote":quote])
            return .init(id: "review", function: .init(name: "review_previous_day", arguments: String(decoding: args, as: UTF8.self)))
        }
        let valid = try call(reason: "", quote: "昨天的方案今天继续")
        let parsed = AssistantActionParser.proposals(from: [valid], todos: [], projects: [], plans: [source], sourceMessage: user)
        #expect(parsed.count == 1 && parsed[0].status == .pending)
        #expect(AssistantActionParser.proposals(from: [try call(reason: "因为懒", quote: user.text)], todos: [], projects: [], plans: [source], sourceMessage: user).isEmpty)
        #expect(AssistantActionParser.proposals(from: [try call(reason: "", quote: "未说过的内容")], todos: [], projects: [], plans: [source], sourceMessage: user).isEmpty)
        let readonly = AssistantMessage(text: "只回顾昨天的方案，不要保存", isUser: true)
        #expect(AssistantActionParser.proposals(from: [valid], todos: [], projects: [], plans: [source], sourceMessage: readonly).isEmpty)
    }

}
