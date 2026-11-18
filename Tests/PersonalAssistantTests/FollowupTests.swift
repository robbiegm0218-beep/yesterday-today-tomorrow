import Foundation
import Testing
@testable import PersonalAssistant

private actor FollowupTransport: ActiveNotificationTransport {
    var sent: [String] = []
    var visible: Set<String> = []
    func allowed() -> Bool { true }
    func pendingIDs() -> Set<String> { [] }
    func deliveredIDs() -> Set<String> { visible }
    func submit(id: String, title: String, body: String) { sent.append(id); visible.insert(id) }
    func remove(_ ids: [String]) { visible.subtract(ids) }
}
struct FollowupTests {
    func time(_ hour: Int, _ minute: Int = 0) -> Date { Calendar.current.date(from: .init(year: 2026, month: 10, day: 29, hour: hour, minute: minute))! }
    func rule(due: Date? = nil) -> MatterFollowup {
        .init(reference: .personal(UUID()), title: "发布核对", waitingFor: "小林", criterion: "取得接口清单", nextStep: "核对清单后安排评审", checkAt: due ?? Date().addingTimeInterval(3_600), quote: "等小林给接口清单", sourceMessageID: UUID())
    }
    @Test func rankingReasonDoesNotHideOtherTasksOutsideCandidates() {
        let local = TodoRecord(id: "local", title: "方案", dueAt: nil, importance: .normal, projectName: nil, sourceURL: nil, isComplete: false, isPersonal: true)
        let remote = TodoRecord(id: "dingtalk-org-task", title: "工作", dueAt: nil, importance: .normal, projectName: nil, sourceURL: nil, isComplete: false)
        let plan = DailyPlanComposer().compose(snapshot: .init(events: [], todos: [local, remote], sourceLabel: "合成", usesDemoData: false), now: Date())
        let ranked = plan.applying(.init(orderedTaskIDs: [local.id], reasons: [local.id:"只有这一条，当前没有其他待办"], summary: "", preparations: [:]))
        #expect(ranked.rankedTasks[0].reason == plan.rankedTasks[0].reason)
        #expect(ranked.deferredTasks.count == 1)
    }
    @Test func creationRequiresExistingTargetFutureTimeAndOnePendingPerMatter() throws {
        let first = rule(); let target = MatterTarget(reference: first.reference, title: first.title)
        let saved = try FollowupPolicy.creating(first, among: [], targets: [target])
        #expect(try FollowupPolicy.creating(first, among: saved, targets: [target]) == saved)
        var duplicate = first; duplicate.id = UUID()
        #expect(throws: ProjectUpdateError.self) { _ = try FollowupPolicy.creating(duplicate, among: saved, targets: [target]) }
        #expect(throws: ProjectUpdateError.self) { _ = try FollowupPolicy.creating(first, among: [], targets: []) }
        var past = first; past.checkAt = Date().addingTimeInterval(-1)
        #expect(throws: ProjectUpdateError.self) { _ = try FollowupPolicy.creating(past, among: [], targets: [target]) }
    }
    @Test func feedbackPreservesHistoryRejectsStaleAndNeverChangesSourceTask() throws {
        let original = rule(); let action = UUID()
        let postponed = try FollowupPolicy.responding(id: original.id, revision: 1, action: "postpone", detail: "还没拿到，晚点再看", nextDate: Date().addingTimeInterval(7_200), actionID: action, rules: [original])
        #expect(postponed[0].revision == 2 && postponed[0].status == "pending" && postponed[0].candidateID != original.candidateID)
        #expect(try FollowupPolicy.responding(id: original.id, revision: 1, action: "postpone", detail: "", nextDate: nil, actionID: action, rules: postponed) == postponed)
        #expect(throws: ProjectUpdateError.self) { _ = try FollowupPolicy.responding(id: original.id, revision: 1, action: "resolved", detail: "拿到了", nextDate: nil, actionID: UUID(), rules: postponed) }
        let resolved = try FollowupPolicy.responding(id: original.id, revision: 2, action: "resolved", detail: "接口清单已到", nextDate: nil, actionID: UUID(), rules: postponed)
        #expect(resolved[0].outcomes.count == 2 && resolved[0].status == "resolved")
        #expect(FollowupPolicy.candidates(resolved, eligible: [original.reference]).isEmpty)
        #expect(original.status == "pending")
        let stopped = try FollowupPolicy.responding(id: original.id, revision: 1, action: "stop", detail: "暂时不做", nextDate: nil, actionID: UUID(), rules: [original])
        #expect(stopped[0].status == "stopped")
    }
    @Test func quietHoursShiftToNextAllowedWindow() {
        #expect(FollowupPolicy.deliveryDate(time(8)) == time(9))
        #expect(FollowupPolicy.deliveryDate(time(12, 30)) == time(13))
        #expect(FollowupPolicy.deliveryDate(time(20, 59)) == time(20, 59))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: time(9))!
        #expect(FollowupPolicy.deliveryDate(time(21)) == tomorrow)
    }
    @Test func explicitFollowupReservesSharedQuotaAndNeverRunsEarlyOrReplaysTomorrow() {
        let first = rule(due: time(16, 10)); let item = FollowupPolicy.candidates([first], eligible: [first.reference])[0]
        let general = ActiveReminderCandidate(id: "general", title: "其他事项", body: "提醒", kind: "personal")
        let planned = ActiveReminderPolicy.plan(candidates: [general, item], records: [], limit: 1, now: time(15))
        #expect(planned.count == 1 && planned[0].source.id == item.id && planned[0].fireDate == time(16, 10))
        #expect(!item.eligible(at: time(16, 9)) && item.eligible(at: time(16, 10)))
        let late = ActiveReminderPolicy.plan(candidates: [item], records: [], limit: 4, now: time(16, 21))
        #expect(late.isEmpty)
        #expect(ActiveReminderPolicy.plan(candidates: [item], records: [], limit: 4, now: Calendar.current.date(byAdding: .day, value: 1, to: time(16))!).isEmpty)
    }
    @Test func actualRunnerSubmitsOnceWithdrawsOnFeedbackAndKeepsQuotaAfterPostpone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-followup-run-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActiveReminderStore(directory: directory); try store.setEnabled(true)
        let first = rule(due: time(16, 10)); let items = FollowupPolicy.candidates([first], eligible: [first.reference]); let transport = FollowupTransport(); let runner = ActiveReminderRunner(); let due = time(16, 10)
        _ = await runner.synchronize(store: store, transport: transport, limit: 1, force: true, clock: { due }, fingerprint: { "a" }, load: { .init(candidates: items) })
        _ = await runner.synchronize(store: store, transport: transport, limit: 1, force: true, clock: { due }, fingerprint: { "a" }, load: { .init(candidates: items) })
        #expect(await transport.sent.count == 1)
        _ = await runner.synchronize(store: store, transport: transport, limit: 1, force: true, clock: { due }, fingerprint: { "resolved" }, load: { .init(candidates: []) })
        #expect(await transport.visible.isEmpty)
        #expect(try store.state().history.last?.detail?.contains("原任务状态未自动改变") == true)
        var postponed = first; postponed.revision += 1; postponed.checkAt = time(17)
        let next = FollowupPolicy.candidates([postponed], eligible: [postponed.reference]); let later = time(17)
        _ = await runner.synchronize(store: store, transport: transport, limit: 1, force: true, clock: { later }, fingerprint: { "postponed" }, load: { .init(candidates: next) })
        #expect(await transport.sent.count == 1)
        #expect(ActiveReminderPolicy.quota(try store.state().records, day: DailyPlanSchedulePolicy.dayKey(for: due)) == 1)
    }
    @Test func unavailableSourcesDoNotSupplyFollowupsAndOtherOrganizationHistoryIsNotExposed() {
        let first = rule()
        #expect(FollowupPolicy.candidates([first], eligible: []).isEmpty)
        let context = AssistantChatWorkbenchContext.message(personalTodos: [], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: Date(), followups: [first]).content
        #expect(!context.contains(first.criterion))
    }
    @Test func parserRequiresGroundedFutureFollowupAndFeedbackUsesExistingRevision() throws {
        let todo = PersonalTodo(title: "发布", importance: .normal)
        let targets = MatterContextPolicy.targets(todos: [todo], projects: [], external: [])
        let user = AssistantMessage(text: "跟进发布：等小林给接口清单，拿到后核对，明天查看。", isUser: true)
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        let args: [String: Any] = ["kind":"personal", "target_id":todo.id.uuidString, "waiting_for":"小林", "criterion":"取得接口清单", "next_step":"核对接口清单", "check_at":timestamp, "quote":user.text]
        let call = DeepSeekToolCall(id: "follow", function: .init(name: "create_matter_followup", arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
        let actions = AssistantActionParser.proposals(from: [call], todos: [todo], projects: [], matterTargets: targets, sourceMessage: user)
        guard case let .createFollowup(rule) = try #require(actions.first).operation else { Issue.record("missing followup"); return }
        #expect(rule.reference == .personal(todo.id) && rule.sourceMessageID == user.id)
        #expect(AssistantToolIntent.requestsFollowup("安排跟进，等清单，不要新建待办"))
        #expect(!AssistantToolIntent.requestsFollowup("只查看跟进安排"))
        #expect(AssistantActionParser.proposals(from: [call], todos: [todo], projects: [], matterTargets: [], sourceMessage: user).isEmpty)
        let feedback = AssistantMessage(text: "清单拿到了，这次跟进已解决", isUser: true)
        let payload = try JSONSerialization.data(withJSONObject: ["followup_id":rule.id.uuidString,"action":"resolved","quote":feedback.text])
        let response = DeepSeekToolCall(id: "respond", function: .init(name: "respond_matter_followup", arguments: String(decoding: payload, as: UTF8.self)))
        let parsed = AssistantActionParser.proposals(from: [response], todos: [todo], projects: [], matterTargets: targets, sourceMessage: feedback, followups: [rule])
        guard case let .respondFollowup(id, revision, action, _, _) = try #require(parsed.first).operation else { Issue.record("missing feedback"); return }
        #expect(id == rule.id && revision == 1 && action == "resolved")
    }
    @Test func backupCompatibilityAndCorruptStoreFailClosed() throws {
        let first = rule(); let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-followup-data-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FollowupStore(directory: directory); try store.save([first]); #expect(try store.load() == [first])
        let corrupt = Data("broken".utf8); try corrupt.write(to: store.url)
        #expect(throws: ProjectUpdateError.self) { try store.save([]) }; #expect(try Data(contentsOf: store.url) == corrupt)
        var archive = LocalAssistantDataExport(exportedAt: Date(), profile: .init(name: "QA", personality: "自然", tone: "自然", address: "你", avatar: "warm", relationshipPoints: 0, automaticMemoryEnabled: false), conversation: [], memories: [], projects: [], personalTodos: [], skills: AssistantSkill.defaults, knowledgeBases: [])
        archive.followups = [first]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoded = try LocalAssistantDataManager.decodeImport(encoder.encode(archive)); #expect(decoded.followups?.first?.id == first.id)
        let suite = "yuan-followup-restore-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let restoredRoot = directory.appendingPathComponent("restored")
        try LocalAssistantDataManager.restore(decoded, defaults: defaults, appDataDirectory: restoredRoot)
        #expect(try FollowupStore(directory: restoredRoot).load() == decoded.followups)
        archive.followups = nil; #expect(try LocalAssistantDataManager.decodeImport(encoder.encode(archive)).followups == nil)
    }
}
