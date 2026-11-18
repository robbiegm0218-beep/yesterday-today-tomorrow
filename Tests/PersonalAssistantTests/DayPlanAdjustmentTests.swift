import Foundation
import Testing
@testable import PersonalAssistant

struct DayPlanAdjustmentTests {
    private func plan(_ steps: [DayPlanStep]) -> SavedDayPlan {
        .init(day: DailyPlanSchedulePolicy.dayKey(for: Date()), timeZone: TimeZone.current.identifier, revision: 3, steps: steps)
    }
    private func proposal(_ json: String, original: SavedDayPlan, refs: [DayPlanReference] = []) throws -> DayPlanAdjustment {
        try DayPlanAdjustmentPolicy.proposal(.init(operationsJSON: json, reason: "用户调整今天的安排", quote: "调整今天的安排"), original: original, references: refs, user: .init(text: "调整今天的安排，确认后保存", isUser: true))
    }
    @Test func patchPreservesCompletedAndUnrelatedStepsEvenWhenTheirSourceDisappears() throws {
        let done = DayPlanStep(title: "已完成工作", sourceKind: "personal", sourceID: UUID().uuidString, isDone: true)
        let other = DayPlanStep(title: "等回复的原事项", sourceKind: "external", sourceID: "dingtalk-org-unavailable")
        let changing = DayPlanStep(title: "整理方案", plannedTime: "14:00", durationMinutes: 60)
        let original = plan([done, other, changing])
        let change = try proposal("[{\"action\":\"update\",\"step_id\":\"\(changing.id)\",\"plannedTime\":\"15:00\"}]", original: original)
        #expect(change.proposed.steps[0] == done)
        #expect(change.proposed.steps[1] == other)
        #expect(change.proposed.steps[2].id == changing.id && change.proposed.steps[2].plannedTime == "15:00")
        let saved = try SavedDayPlanPolicy.saving(change.proposed, among: [original], expectedRevision: 3, references: [], actionID: UUID())
        #expect(saved[0].steps[0].isDone && saved[0].steps[1] == other && saved[0].revision == 4)
    }
    @Test func completedUnknownDuplicateTargetsAndNoOpsAreRejected() throws {
        let done = DayPlanStep(title: "完成", isDone: true)
        let open = DayPlanStep(title: "方案")
        let original = plan([done, open])
        for action in ["remove", "move", "update"] {
            #expect(throws: DayPlanError.self) { _ = try proposal("[{\"action\":\"\(action)\",\"step_id\":\"\(done.id)\"}]", original: original) }
        }
        #expect(throws: DayPlanError.self) { _ = try proposal("[{\"action\":\"remove\",\"step_id\":\"\(UUID())\"}]", original: original) }
        #expect(throws: DayPlanError.self) { _ = try proposal("[{\"action\":\"update\",\"step_id\":\"\(open.id)\"}]", original: original) }
        #expect(throws: DayPlanError.self) { _ = try proposal("[{\"action\":\"update\",\"step_id\":\"\(open.id)\",\"plannedTime\":\"15:00\"},{\"action\":\"remove\",\"step_id\":\"\(open.id)\"}]", original: original) }
    }
    @Test func urgentInsertionCannotPrependOrDisplaceCompletedHistory() throws {
        let done = DayPlanStep(title: "已经完成", isDone: true)
        let open = DayPlanStep(title: "未完成")
        let original = plan([done, open])
        #expect(throws: DayPlanError.self) {
            _ = try proposal("[{\"action\":\"add\",\"after_step_id\":\"\",\"step\":{\"title\":\"紧急事项\"}}]", original: original)
        }
        let change = try proposal("[{\"action\":\"add\",\"after_step_id\":\"\(done.id)\",\"step\":{\"title\":\"紧急事项\"}}]", original: original)
        #expect(change.proposed.steps.first == done && change.proposed.steps[1].title == "紧急事项")
        var invalid = change.proposed
        invalid.steps.swapAt(0, 1)
        let forged = DayPlanAdjustment(original: original, proposed: invalid, reason: "紧急", quote: "调整", sourceMessageID: UUID())
        #expect(throws: DayPlanError.self) { try DayPlanAdjustmentPolicy.validateConfirmation(forged, current: original) }
    }

    @Test func addRemoveMoveHaveExplicitAnchorsAndPreserveIdentities() throws {
        let a = DayPlanStep(title: "A"), b = DayPlanStep(title: "B"), c = DayPlanStep(title: "C")
        let original = plan([a, b, c])
        let change = try proposal("[{\"action\":\"remove\",\"step_id\":\"\(b.id)\"},{\"action\":\"move\",\"step_id\":\"\(c.id)\",\"after_step_id\":\"\"},{\"action\":\"add\",\"after_step_id\":\"\(a.id)\",\"step\":{\"title\":\"紧急工作\",\"plannedTime\":\"16:00\",\"durationMinutes\":30}}]", original: original)
        #expect(change.proposed.steps.map(\.title) == ["C", "A", "紧急工作"])
        #expect(change.proposed.steps[0].id == c.id && change.proposed.steps[1] == a)
        #expect(original.steps.count == 3)
        #expect(throws: DayPlanError.self) { _ = try proposal("[{\"action\":\"move\",\"step_id\":\"\(a.id)\",\"after_step_id\":\"\(a.id)\"}]", original: original) }
    }
    @Test func changedCalendarTimeIsAuthoritativeAndNewSourceChangeBlocksConfirmationSave() throws {
        let event = DayPlanStep(title: "评审", sourceKind: "event", sourceID: "event", plannedTime: "14:00", durationMinutes: 30)
        let original = plan([event])
        let latest = DayPlanReference(kind: "event", id: "event", title: "评审", time: "15:00", duration: 60)
        let change = try proposal("[{\"action\":\"update\",\"step_id\":\"\(event.id)\",\"plannedTime\":\"09:00\"}]", original: original, refs: [latest])
        #expect(change.proposed.steps[0].plannedTime == "15:00" && change.proposed.steps[0].durationMinutes == 60)
        let durationChanged = DayPlanReference(kind: "event", id: "event", title: "评审", time: "15:00", duration: 90)
        #expect(throws: DayPlanError.self) { _ = try SavedDayPlanPolicy.saving(change.proposed, among: [original], expectedRevision: original.revision, references: [durationChanged]) }
        let changedAgain = DayPlanReference(kind: "event", id: "event", title: "评审", time: "16:00", duration: 60)
        #expect(throws: DayPlanError.self) { _ = try SavedDayPlanPolicy.saving(change.proposed, among: [original], expectedRevision: original.revision, references: [changedAgain]) }
        #expect(throws: DayPlanError.self) { _ = try SavedDayPlanPolicy.saving(change.proposed, among: [original], expectedRevision: original.revision, references: []) }
    }
    @Test func newCheckboxOrRevisionCannotBeOverwrittenAndManualSaveClearsActionReceipt() throws {
        let a = DayPlanStep(title: "A")
        let original = plan([a])
        let change = try proposal("[{\"action\":\"update\",\"step_id\":\"\(a.id)\",\"plannedTime\":\"15:00\"}]", original: original)
        var newer = original; newer.steps[0].isDone = true; newer.revision += 1
        #expect(throws: DayPlanError.self) { try DayPlanAdjustmentPolicy.validateConfirmation(change, current: newer) }
        #expect(throws: DayPlanError.self) { try DayPlanAdjustmentPolicy.validateConfirmation(change, current: nil) }
        let actionID = UUID()
        let saved = try SavedDayPlanPolicy.saving(change.proposed, among: [original], expectedRevision: 3, references: [], actionID: actionID)
        #expect(try SavedDayPlanPolicy.saving(change.proposed, among: saved, expectedRevision: 3, references: [], actionID: actionID) == saved)
        let manual = try SavedDayPlanPolicy.saving(saved[0], among: saved, expectedRevision: 4, references: [])
        #expect(manual[0].sourceActionID == nil)
        #expect(throws: DayPlanError.self) { _ = try SavedDayPlanPolicy.saving(change.proposed, among: manual, expectedRevision: 3, references: [], actionID: actionID) }
    }
    @Test func differencesAndOverlapWarningsDoNotTreatInsertedStepsAsEditsToUnchangedContent() throws {
        let a = DayPlanStep(title: "A", plannedTime: "14:00", durationMinutes: 60)
        let original = plan([a])
        let change = try proposal("[{\"action\":\"add\",\"after_step_id\":\"\",\"step\":{\"title\":\"紧急工作\",\"plannedTime\":\"14:30\",\"durationMinutes\":60}}]", original: original)
        let diff = DayPlanReview.differences(from: original, to: change.proposed)
        #expect(diff.count == 1 && diff[0].kind == "新增")
        #expect(DayPlanReview.warnings(change.proposed).count == 1)
        #expect(change.proposed.steps[1] == a)
    }
    @Test func parserRejectsWholePlanReplacementAndUngroundedPatch() throws {
        let a = DayPlanStep(title: "A")
        let original = plan([a])
        let replacement = DeepSeekToolCall(id: "replace", function: .init(name: "propose_day_plan", arguments: #"{"steps_json":"[{\"title\":\"new\"}]"}"#))
        #expect(AssistantActionParser.proposals(from: [replacement], todos: [], projects: [], plans: [original]).isEmpty)
        func call(quote: String) throws -> DeepSeekToolCall {
            let ops = "[{\"action\":\"update\",\"step_id\":\"\(a.id)\",\"plannedTime\":\"15:00\"}]"
            let data = try JSONSerialization.data(withJSONObject: ["operations_json":ops,"reason":"用户调整时间","quote":quote])
            return .init(id: "patch", function: .init(name: "adjust_day_plan", arguments: String(decoding: data, as: UTF8.self)))
        }
        let user = AssistantMessage(text: "调整今天的计划，把A改到15:00", isUser: true)
        let actions = AssistantActionParser.proposals(from: [try call(quote: "把A改到15:00")], todos: [], projects: [], plans: [original], sourceMessage: user)
        #expect(actions.count == 1 && actions[0].status == .pending)
        #expect(AssistantActionParser.proposals(from: [try call(quote: "并不存在的原话")], todos: [], projects: [], plans: [original], sourceMessage: user).isEmpty)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        #expect(throws: DayPlanError.self) { _ = try DayPlanAdjustmentPolicy.proposal(.init(operationsJSON: "[]", reason: "调整", quote: "调整"), original: original, references: [], user: user, now: tomorrow) }
    }
    @Test func adjustmentSurvivesConversationBackupRoundTripWithoutMutatingBaseline() throws {
        let original = plan([DayPlanStep(title: "A")])
        let change = try proposal("[{\"action\":\"add\",\"step\":{\"title\":\"紧急任务\"}}]", original: original)
        let pending = PendingAssistantAction(summary: "调整", operation: .adjustDayPlan(change: change))
        let decoded = try JSONDecoder().decode(PendingAssistantAction.self, from: JSONEncoder().encode(pending))
        guard case let .adjustDayPlan(restored) = decoded.operation else { Issue.record("Wrong operation"); return }
        #expect(restored == change && restored.original == original)
    }
    @Test func existingMatterCannotSilentlyBecomeUnlinkedNote() throws {
        let existing=DayPlanReference(kind:"personal",id:UUID().uuidString,title:"紧急验证")
        let original=plan([DayPlanStep(title:"其他安排")])
        #expect(throws:DayPlanError.self) {try proposal("[{\"action\":\"add\",\"step\":{\"title\":\"紧急验证\"}}]",original:original,refs:[existing])}
        let change=try proposal("[{\"action\":\"add\",\"step\":{\"title\":\"紧急验证\",\"sourceKind\":\"personal\",\"sourceID\":\"\(existing.id)\"}}]",original:original,refs:[existing])
        #expect(change.proposed.steps.last?.sourceID==existing.id)
    }

    @Test func explicitlyRequestedSourceMustActuallyBeAddedToPlan() throws {
        let step=DayPlanStep(title:"其他安排"),urgent=DayPlanReference(kind:"personal",id:UUID().uuidString,title:"紧急验证")
        let original=plan([step]),user=AssistantMessage(text:"新增「紧急验证」到今日计划",isUser:true)
        let args=DayPlanAdjustmentArguments(operationsJSON:"[{\"action\":\"update\",\"step_id\":\"\(step.id)\",\"plannedTime\":\"15:00\"}]",reason:"为紧急验证腾位置",quote:"新增「紧急验证」到今日计划")
        #expect(throws:DayPlanError.self){try DayPlanAdjustmentPolicy.proposal(args,original:original,references:[urgent],user:user)}
    }

}
