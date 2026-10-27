import Foundation
import Testing
@testable import PersonalAssistant

struct DingTalkWorkflowTests {
    private let now = Date(timeIntervalSince1970: 1_793_016_000)
    private let profile = DingTalkProfile(corpID: "synthetic-corp", userID: "synthetic-user", corpName: "验收组织", userName: nil, isOrgCurrent: true)

    @Test func connectionRequiresValidTokenAndTheExplicitSelectedOrganization() {
        let valid = Data(#"{"success":true,"authenticated":true,"token_valid":true,"corp_id":"corp","user_id":"17350149253572987"}"#.utf8)
        #expect(DingTalkCLIClient.isAuthenticated(valid, expectedProfileID: "corp:17350149253572987"))
        #expect(!DingTalkCLIClient.isAuthenticated(valid, expectedProfileID: "other:17350149253572987"))
        #expect(!DingTalkCLIClient.isAuthenticated(Data(#"{"success":true,"authenticated":true,"token_valid":false}"#.utf8), expectedProfileID: nil))
        #expect(!DingTalkCLIClient.isAuthenticated(Data(#"{"success":true,"authenticated":false,"token_valid":true}"#.utf8), expectedProfileID: nil))
    }

    @Test func projectAssociationResolvesUniqueNamesWithoutChangingPersonalChoices() {
        let projects = [AssistantProject(name: "青杉", progressNote: "评审中"), AssistantProject(name: "CRM", progressNote: "开发中")]
        let snapshot = DailyDataSnapshot(events: [event("event", title: "青杉方案评审")], todos: [
            todo("work", title: "青杉评审材料"),
            todo("ambiguous", title: "青杉和 CRM 对接"),
            todo("substring", title: "CRMS 模块排查"),
            todo("personal", title: "青杉评审材料", project: "CRM", personal: true)
        ], sourceLabel: "验收组织", usesDemoData: false)
        let linked = DailyProjectAssociation.apply(to: snapshot, projects: projects, now: now)
        #expect(linked.events.first?.projectName == "青杉")
        #expect(linked.todos[0].projectName == "青杉")
        #expect(linked.todos[0].relatedEventID == "event")
        #expect(linked.todos[1].projectName == nil)
        #expect(linked.todos[2].projectName == nil)
        #expect(linked.todos[3].projectName == "CRM")
        #expect(snapshot.todos[0].projectName == nil)

        let plan = DailyPlanComposer().compose(snapshot: linked, now: now)
        #expect(plan.priorityTasks.contains { $0.id == "work" })
        #expect(plan.otherTasks.contains { $0.id == "ambiguous" })
        #expect(Set(plan.priorityTasks.map(\.id) + plan.otherTasks.map(\.id)).count == 4)
    }

    @Test func duplicateProjectNamesOrMultipleMeetingsDoNotInventAnAssociation() {
        let snapshot = DailyDataSnapshot(events: [event("one", title: "CRM评审"), event("two", title: "CRM周会")], todos: [todo("work", title: "CRM材料")], sourceLabel: "测试", usesDemoData: false)
        let linked = DailyProjectAssociation.apply(to: snapshot, projects: [AssistantProject(name: "crm", progressNote: "")], now: now)
        #expect(linked.todos[0].projectName == "crm")
        #expect(linked.todos[0].relatedEventID == nil)
        let ambiguous = DailyProjectAssociation.apply(to: snapshot, projects: [AssistantProject(name: "CRM", progressNote: ""), AssistantProject(name: "crm", progressNote: "")], now: now)
        #expect(ambiguous.events.allSatisfy { $0.projectName == nil })
        let removed = DailyProjectAssociation.apply(to: snapshot, projects: [], now: now)
        #expect(removed.todos[0].projectName == nil)
    }

    @Test func nonPriorityWorkTasksRemainVisibleAfterAIRanking() throws {
        let tasks = [todo("due", title: "到期事项", due: now), todo("undated", title: "无截止日期"), todo("future", title: "远期事项", due: now.addingTimeInterval(30 * 86_400))]
        let plan = DailyPlanComposer().compose(snapshot: .init(events: [], todos: tasks, sourceLabel: "测试", usesDemoData: false), now: now)
        let ranking = try JSONDecoder().decode(DeepSeekPlanRanking.self, from: Data(#"{"ordered_task_ids":["due"],"reasons":{},"summary":"处理到期事项"}"#.utf8))
        let ranked = plan.applying(ranking)
        #expect(ranked.priorityTasks.map(\.id) == ["due"])
        #expect(Set(ranked.otherTasks.map(\.id)) == ["undated", "future"])
    }

    @Test func paginatedReadDeduplicatesCardsAndKeepsMissingDeadlinesUnset() async throws {
        let client = FixtureDingTalkClient(profile: profile, pages: [
            1: #"{"success":true,"result":{"hasMore":true,"todoCards":[{"taskId":"one","subject":"事项一","dueTime":0}]}}"#,
            2: #"{"success":true,"result":{"hasMore":false,"todoCards":[{"taskId":"one","subject":"事项一","dueTime":0},{"taskId":"two","subject":"事项二","dueTime":null}]}}"#
        ])
        let snapshot = try await source(client).loadSnapshot(at: now)
        #expect(snapshot.todos.count == 2)
        #expect(snapshot.todos.allSatisfy { $0.dueAt == nil })
        #expect(client.requestedPages == [1, 2])
        #expect(client.profilesUsed.allSatisfy { $0 == profile.id })
    }

    @Test func repeatedPageAndMalformedEnvelopesFailInsteadOfPretendingSyncIsComplete() async {
        let page = #"{"success":true,"result":{"hasMore":true,"todoCards":[{"taskId":"same","subject":"事项"}]}}"#
        let repeated = FixtureDingTalkClient(profile: profile, pages: [1: page, 2: page])
        await #expect(throws: (any Error).self) { try await source(repeated).loadSnapshot(at: now) }
        #expect(repeated.requestedPages == [1, 2])
        for response in [#"{"success":false,"result":{"todoCards":[]}}"#, #"{"success":true,"result":{"renamedField":[]}}"#] {
            let broken = FixtureDingTalkClient(profile: profile, pages: [1: response])
            await #expect(throws: (any Error).self) { try await source(broken).loadSnapshot(at: now) }
        }
    }

    private func source(_ client: FixtureDingTalkClient) -> DingTalkDailyDataSource {
        DingTalkDailyDataSource(client: client, selectedProfileIDs: { [profile.id] })
    }

    private func event(_ id: String, title: String) -> CalendarEvent {
        CalendarEvent(id: id, title: title, startsAt: now, endsAt: now.addingTimeInterval(3600), detail: "", projectName: nil, sourceURL: nil)
    }

    private func todo(_ id: String, title: String, due: Date? = nil, project: String? = nil, personal: Bool = false) -> TodoRecord {
        TodoRecord(id: id, title: title, dueAt: due, importance: .normal, projectName: project, relatedEventID: nil, sourceURL: nil, isComplete: false, isPersonal: personal)
    }
}

private final class FixtureDingTalkClient: DingTalkReading {
    let profile: DingTalkProfile
    let pages: [Int: String]
    var requestedPages: [Int] = []
    var profilesUsed: [String] = []

    init(profile: DingTalkProfile, pages: [Int: String]) {
        self.profile = profile
        self.pages = pages
    }

    func listProfiles() throws -> [DingTalkProfile] { [profile] }

    func run(_ operation: DingTalkReadOperation, profile: DingTalkProfile?) throws -> DingTalkCLIResult {
        profilesUsed.append(profile?.id ?? "missing")
        switch operation {
        case .calendarEvents:
            return DingTalkCLIResult(data: Data(#"{"success":true,"result":{"events":[],"hasMore":false}}"#.utf8), exitCode: 0)
        case let .openTodos(page, _):
            requestedPages.append(page)
            guard let fixture = pages[page] else { throw DingTalkCLIError.invalidResponse }
            return DingTalkCLIResult(data: Data(fixture.utf8), exitCode: 0)
        default:
            throw DingTalkCLIError.invalidResponse
        }
    }
}
