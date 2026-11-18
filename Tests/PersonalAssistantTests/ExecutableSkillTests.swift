import Foundation
import Testing
@testable import PersonalAssistant

struct ExecutableSkillTests {
    let now = Date()
    func action(_ title: String = "核对字段", quote: String = "小李负责核对字段，周五反馈。") -> ExtractedMeetingAction {
        .init(title: title, owner: "小李", dueText: "周五", sourceQuote: quote, confidence: "高")
    }
    func run() throws -> SkillRun {
        var run = SkillRun(skillID: "minutes-actions", startedAt: now, updatedAt: now)
        run.meetingProposals = try SkillRunPolicy.meetingProposals([action()], source: "会议决定：小李负责核对字段，周五反馈。", title: "合成会议")
        run.selectedEvidenceIDs = run.meetingProposals.map(\.id); run.status = .committing; run.completedSteps = 4
        return run
    }
    @Test func onlyTwoReviewedBuiltInsAreExecutable() {
        #expect(ExecutableSkillDefinition.all.count == 2)
        #expect(ExecutableSkillDefinition.find("custom-test") == nil)
        #expect(ExecutableSkillDefinition.all.allSatisfy { $0.steps.count == 5 && !$0.boundary.isEmpty && !$0.recovery.isEmpty })
    }
    @Test func backgroundWorkersAndAcceptanceProcessesDoNotRecoverAnActiveForegroundRun() {
        #expect(SkillRunPolicy.shouldRecoverOnLaunch(arguments: ["app"]))
        #expect(SkillRunPolicy.shouldRecoverOnLaunch(arguments: ["app", "-psn_123"]))
        for flag in ["--daily-plan-worker", "--verify-executable-skills", "--verify-day-review", "--background-qa-register", "--background-qa-unregister"] {
            #expect(!SkillRunPolicy.shouldRecoverOnLaunch(arguments: ["app", flag]))
        }
    }
    @Test func extractionRequiresAllOriginalQuotesAndDeduplicatesSameEvidence() throws {
        let source = "会议决定：小李负责核对字段，周五反馈。"
        let proposals = try SkillRunPolicy.meetingProposals([action(), action()], source: source, title: "合成")
        #expect(proposals.count == 1 && proposals[0].evidence.quote == action().sourceQuote)
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.meetingProposals([action(), action(quote: "原文没有的安排")], source: source, title: "合成") }
    }
    @Test func confirmationCreatesOnceAndReadbackRequiresEverySelectedEvidence() throws {
        let run = try run()
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.verify(run, plans: [], todos: []) }
        let saved = try SkillRunPolicy.meetingResult(run, among: [])
        #expect(saved.count == 1 && saved[0].meetingEvidence?.count == 1)
        let again = try SkillRunPolicy.meetingResult(run, among: saved)
        #expect(again == saved)
        #expect(try SkillRunPolicy.verify(run, plans: [], todos: saved).contains("1项"))
    }
    @Test func linkPreservesExistingTitleDeadlineAndCompletedStatus() throws {
        var run = try run()
        let existing = PersonalTodo(title: "用户改过的名称", dueAt: now, importance: .high, projectName: "已有项目", isComplete: true)
        run.links = [run.meetingProposals[0].id: existing.id]
        let result = try SkillRunPolicy.meetingResult(run, among: [existing])
        #expect(result.count == 1 && result[0].id == existing.id && result[0].isComplete)
        #expect(result[0].title == existing.title && result[0].dueAt == existing.dueAt && result[0].projectName == existing.projectName)
        #expect(try SkillRunPolicy.verify(run, plans: [], todos: result).contains("已回查"))
    }
    @Test func missingLinkAndConflictingExistingSourcePreventSaving() throws {
        var run = try run(); run.links = [run.meetingProposals[0].id: UUID()]
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.meetingResult(run, among: []) }
        let saved = try SkillRunPolicy.meetingResult(try self.run(), among: [])
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.meetingResult(run, among: saved) }
    }
    @Test func invalidSelectionsAndUnconfirmedStagesNeverCreateTasks() throws {
        var original = try run(); original.status = .awaitingConfirmation
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.meetingResult(original, among: []) }
        var foreign = try run(); foreign.selectedEvidenceIDs = ["foreign"]
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.meetingResult(foreign, among: []) }
        var empty = try run(); empty.selectedEvidenceIDs = []
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.meetingResult(empty, among: []) }
    }
    @Test func partialMissingEvidenceDoesNotPassVerification() throws {
        var run = try run()
        let other = try SkillRunPolicy.meetingProposals([action("复核报告", quote: "小王负责复核报告。")], source: "小王负责复核报告。", title: "第二部分")
        run.meetingProposals += other; run.selectedEvidenceIDs += other.map(\.id)
        let onlyFirst = try SkillRunPolicy.meetingResult(try self.run(), among: [])
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.verify(run, plans: [], todos: onlyFirst) }
        #expect(try SkillRunPolicy.meetingResult(run, among: onlyFirst).count == 2)
    }
    @Test func recoveryStopsPreparationAndOnlyReconcilesInterruptedCommit() throws {
        var preparing = try run(); preparing.status = .running
        let committing = try run()
        var ready = try run(); ready.status = .awaitingConfirmation
        let recovered = SkillRunPolicy.recovered([preparing, committing, ready])
        #expect(recovered[0].status == .failed && recovered[1].status == .verificationNeeded && recovered[2].status == .awaitingConfirmation)
        #expect(recovered[1].selectedEvidenceIDs == committing.selectedEvidenceIDs)
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.meetingResult(recovered[1], among: []) }
    }
    @Test func dailyPlanCompletionRequiresPersistedActionReceipt() throws {
        let draft = SavedDayPlan(day: DailyPlanSchedulePolicy.dayKey(for: now), timeZone: TimeZone.current.identifier, steps: [.init(title: "合成安排")])
        let action = PendingAssistantAction(summary: "合成提案", operation: .saveDayPlan(plan: draft, expectedRevision: 0))
        var run = SkillRun(skillID: "daily-planning", startedAt: now, updatedAt: now); run.action = action; run.status = .committing
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.verify(run, plans: [draft], todos: []) }
        var saved = draft; saved.sourceActionID = action.id; saved.revision = 1
        #expect(try SkillRunPolicy.verify(run, plans: [saved], todos: []).contains("第1版"))
    }
    @Test func toolOutsideSkillBoundaryCannotEnterJournal() throws {
        var run = SkillRun(skillID: "daily-planning", startedAt: now, updatedAt: now)
        run.action = .init(summary: "越界", operation: .createTodo(title: "越界", dueAt: nil, importance: .normal, projectName: nil))
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.validate([run]) }
        var wrong = SkillRun(skillID: "custom-test", startedAt: now, updatedAt: now)
        wrong.status = .awaitingConfirmation
        #expect(throws: ProjectUpdateError.self) { try SkillRunPolicy.validate([wrong]) }
    }
    @Test func journalRoundTripRetainsPendingResultWithoutFullSourceAndCorruptionBlocks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-skill-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SkillRunStore(directory: directory); var run = try run(); run.status = .awaitingConfirmation
        try store.save([run]); let loaded = try store.load()
        #expect(loaded.count == 1 && loaded[0].meetingProposals[0].evidence == run.meetingProposals[0].evidence)
        #expect(try String(contentsOf: store.fileURL).contains("meetingProposals"))
        try Data("broken".utf8).write(to: store.fileURL)
        // First write has no recovery copy; unreadable history must not reset to empty.
        #expect(throws: ProjectUpdateError.self) { try store.load() }
    }
    @Test func backupSupportsOldMissingHistoryAndRejectsUnknownExecutableSkills() throws {
        let profile = LocalAssistantDataExport.Profile(name: "合成", personality: "温柔陪伴型", tone: "简洁直接", address: "你", avatar: "warm", relationshipPoints: 0, automaticMemoryEnabled: true)
        var archive = LocalAssistantDataExport(exportedAt: now, profile: profile, conversation: [], memories: [], projects: [], personalTodos: [], skills: [], knowledgeBases: [])
        #expect(try LocalAssistantDataManager.decodeImport(JSONEncoder().encode(archive)).skillRuns == nil)
        archive.skillRuns = [try run()]
        #expect(try LocalAssistantDataManager.decodeImport(JSONEncoder().encode(archive)).skillRuns?.count == 1)
        archive.skillRuns = [SkillRun(skillID: "unreviewed", startedAt: now, updatedAt: now)]
        #expect(throws: ProjectUpdateError.self) { try LocalAssistantDataManager.decodeImport(JSONEncoder().encode(archive)) }
    }
}
