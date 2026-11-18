import Foundation
import Testing
@testable import PersonalAssistant

struct AssistantContextRecallTests {
    private func thread(_ first: String, _ current: String) -> [AssistantMessage] {
        [.init(text: first, isUser: true), .init(text: "你想核对哪一方面？", isUser: false), .init(text: current, isUser: true)]
    }
    @Test func relevantMemoryBeyondPrefixAndCharacterBudget() {
        let junk = (0..<60).map { AssistantMemory(content: "无关旅行素材\($0)", category: "个人偏好") }
        let relevant = AssistantMemory(content: "蓝鲸工程验收负责人为林晨", category: "项目背景")
        let context = AssistantReadContext(memories: junk + [relevant])
        let recalled = AssistantContextRecall.make(messages: [.init(text: "蓝鲸工程的验收负责人是谁？", isUser: true)], context: context)
        #expect(recalled.memories.map(\.id).contains(relevant.id))
        #expect(recalled.metrics.memoryScanned == 61 && recalled.metrics.memoryCharacters <= 5000)
        #expect(!recalled.memoryContext.contains("无关旅行"))
    }
    @Test func pronounUsesLatestUserEntityAndRecallsConfirmedProgress() {
        let project = AssistantProject(name: "蓝鲸工程", progressNote: "等待联调", status: "受阻")
        let entry = MatterContextEntry(reference: .project(project.id), category: "阻塞", content: "等待林晨提供字段", quote: "林晨还没给字段", sourceMessageID: nil, recordedAt: Date())
        let context = AssistantReadContext(projects: [project], entries: [entry], memories: [.init(content: "蓝鲸工程的负责人是林晨", category: "项目背景")])
        let recalled = AssistantContextRecall.make(messages: thread("看一下蓝鲸工程", "它的阻塞是什么？"), context: context)
        #expect(recalled.candidates.map(\.reference) == [.project(project.id)] && !recalled.requiresClarification)
        #expect(recalled.matterContext.content.contains("等待林晨提供字段") && recalled.memoryContext.contains("林晨"))
    }
    @Test func explicitTopicSwitchAndStaleOrUnmentionedHistoryDoNotInheritFocus() {
        let project = AssistantProject(name: "蓝鲸工程", progressNote: "")
        let context = AssistantReadContext(projects: [project])
        for prompt in ["换个话题，那个周末怎么过？", "介绍一下黑洞", "不聊蓝鲸工程了，换个话题，介绍量子纠缠"] {
            let recalled = AssistantContextRecall.make(messages: thread("看一下蓝鲸工程", prompt), context: context)
            #expect(recalled.candidates.isEmpty)
        }
        var old = thread("看一下蓝鲸工程", "它的状态呢？")
        old[0].time = Date().addingTimeInterval(-90_000)
        #expect(AssistantContextRecall.make(messages: old, context: context).candidates.isEmpty)
        let interrupted: [AssistantMessage] = [.init(text: "看看蓝鲸工程", isUser: true), .init(text: "明天的天气怎样", isUser: true), .init(text: "它的风险呢", isUser: true)]
        #expect(AssistantContextRecall.make(messages: interrupted, context: context).candidates.isEmpty)
    }
    @Test func duplicateTitlesAndAmbiguousAliasesRequireClarification() {
        let local = PersonalTodo(title: "接口评审", importance: .normal)
        let remote = TodoRecord(id: "dingtalk-org:user-a", title: "接口评审", dueAt: nil, importance: .normal, sourceURL: nil, isComplete: false)
        let context = AssistantReadContext(todos: [local], external: [remote], selected: ["org:user"])
        let recalled = AssistantContextRecall.make(messages: thread("看看接口评审", "把刚才那个完成"), context: context)
        #expect(recalled.requiresClarification && recalled.candidates.count == 2 && recalled.focusReferences.isEmpty)
        let selected = AssistantContextRecall.make(messages: thread("看看接口评审", "我指的是钉钉的那个项目"), context: context)
        #expect(selected.candidates.map(\.reference) == [.init(kind: "external", id: remote.id)] && !selected.requiresClarification)
        let a = AssistantProject(name: "新蓝鲸", progressNote: "", previousNames: ["旧海盐"])
        let b = AssistantProject(name: "新海豚", progressNote: "", previousNames: ["旧海盐"])
        let alias = AssistantContextRecall.make(messages: [.init(text: "旧海盐的状态？", isUser: true)], context: .init(projects: [a,b]))
        #expect(alias.requiresClarification)
    }
    @Test func explicitIDAndSourceDisambiguationNeverMergeNames() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        let b = PersonalTodo(title: "接口评审", importance: .normal)
        let recalled = AssistantContextRecall.make(messages: [.init(text: "查看事项 " + a.id.uuidString, isUser: true)], context: .init(todos: [a,b]))
        #expect(recalled.candidates.map(\.reference) == [.personal(a.id)] && !recalled.requiresClarification)
    }
    @Test func hiddenAndUnselectedExternalContextCannotReappearThroughHistory() {
        let todo = TodoRecord(id: "dingtalk-org:user-a", title: "蓝鲸部署", dueAt: nil, importance: .normal, sourceURL: nil, isComplete: false)
        for context in [AssistantReadContext(external: [todo], selected: []), .init(external: [todo], selected: ["org:user"], hidden: [todo.id])] {
            let recalled = AssistantContextRecall.make(messages: thread("看看蓝鲸部署", "它的进展？"), context: context)
            #expect(recalled.candidates.isEmpty && !recalled.matterContext.content.contains(todo.id))
        }
    }
    @Test func conflictingMemoriesAreSelectedTogetherWithoutAssumingNewestWins() {
        let old = AssistantMemory(content: "蓝鲸工程偏好早上评审", category: "个人偏好")
        let new = AssistantMemory(content: "蓝鲸工程偏好下午评审", category: "个人偏好", conflictsWithMemoryID: old.id)
        let recalled = AssistantContextRecall.make(messages: [.init(text: "蓝鲸工程什么时候评审比较合适？", isUser: true)], context: .init(memories: [old] + (0..<40).map { .init(content: "旅行\($0)", category: "个人偏好") } + [new]))
        #expect(Set(recalled.memories.map(\.id)) == [old.id, new.id])
        #expect(recalled.memoryContext.contains("可能冲突") && recalled.matterContext.content.contains("不能因记录较新"))
    }
    @Test func knownProjectAliasRetriesWhenOriginalQueryHasNoMatches() {
        let project = AssistantProject(name: "OrionLaunch", progressNote: "", previousNames: ["LegacyCedar"])
        let document = KnowledgeDocument(urlPath: "/synthetic/cedar.md", title: "LegacyCedar", content: "LegacyCedar launch code CEDAR_47", indexedAt: Date(), modifiedAt: nil, fileSize: nil)
        let context = AssistantReadContext(projects: [project], bases: [.init(name: "合成库", folderPath: "/synthetic", documents: [document])])
        let recalled = AssistantContextRecall.make(messages: [.init(text: "OrionLaunch", isUser: true)], context: context)
        #expect(recalled.attemptedQueries.count >= 2 && recalled.attemptedQueries.count <= 3)
        #expect(recalled.knowledge.sources.map(\.id) == [document.urlPath] && recalled.knowledge.context.contains("CEDAR_47"))
        #expect(recalled.candidates.map(\.reference) == [.project(project.id)])
        #expect(recalled.matterContext.content.contains("saved_names_of_same_project_id") && recalled.matterContext.content.contains("LegacyCedar"))
    }
    @Test func noMemoryMatchIsNotClaimedToMeanNoSavedMemories() {
        let recalled = AssistantContextRecall.make(messages: [.init(text: "解释量子纠缠", isUser: true)], context: .init(memories: [.init(content: "偏好海边慢跑", category: "个人偏好")]))
        #expect(recalled.memories.isEmpty && recalled.metrics.memoryScanned == 1)
        #expect(recalled.matterContext.content.contains("relevance_ranked_subset_not_complete"))
    }
    @Test func thirtySyntheticMultiTurnRecallFixturesHaveExpectedEvidence() {
        let cases = RecallEvaluationFixtures.cases()
        #expect(cases.count == 30 && Set(cases.map(\.id)).count == 30)
        for item in cases {
            let recalled = AssistantContextRecall.make(messages: item.messages, context: item.context)
            if item.group == "ambiguous_matter" { #expect(recalled.requiresClarification, Comment(rawValue: item.id)) }
            else if item.group == "conflicting_memories" { #expect(recalled.memories.count == 2, Comment(rawValue: item.id)) }
            else { #expect((recalled.memoryContext + recalled.knowledge.context).contains(item.expected), Comment(rawValue: item.id)) }
            if item.group == "topic_switch" { #expect(recalled.candidates.isEmpty && !recalled.memoryContext.contains("OldTopic")) }
            #expect(recalled.metrics.memoryCharacters <= 5000 && recalled.attemptedQueries.count <= 3)
        }
    }
    @Test func explicitComparisonRetainsBothIdentitiesWithoutBlocking() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        let b = PersonalTodo(title: "接口评审", importance: .normal)
        let recalled = AssistantContextRecall.make(messages: [.init(text: "比较两个接口评审", isUser: true)], context: .init(todos: [a,b]))
        #expect(recalled.candidates.count == 2 && !recalled.requiresClarification)
    }
    @Test func cancelledRecallDoesNotReturnAUsableContext() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AssistantContextRecall.makeAsync(messages: [.init(text: "查询", isUser: true)], context: .init())
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request returned recall") }
        catch is CancellationError { }
    }

    @Test func sharedOldNameDoesNotExpandAUniqueCurrentProjectQuery() {
        let a = AssistantProject(name: "AquilaLaunch", progressNote: "", previousNames: ["LegacyShared"])
        let b = AssistantProject(name: "LyraLaunch", progressNote: "", previousNames: ["LegacyShared"])
        let doc = KnowledgeDocument(urlPath: "/synthetic/shared.md", title: "LegacyShared", content: "LegacyShared token UNSCOPED", indexedAt: Date(), modifiedAt: nil, fileSize: nil)
        let recalled = AssistantContextRecall.make(messages: [.init(text: "AquilaLaunch", isUser: true)], context: .init(projects: [a,b], bases: [.init(name: "合成库", folderPath: "/synthetic", documents: [doc])]))
        #expect(recalled.candidates.map(\.reference) == [.project(a.id)] && !recalled.requiresClarification)
        #expect(recalled.knowledge.sources.isEmpty && !recalled.attemptedQueries.contains(where: { $0.contains("LegacyShared") }))
    }

    @Test func personalWorkingPreferenceCanApplyToAnExplicitTaskWithoutItsName() {
        let todo = PersonalTodo(title: "接口评审准备", importance: .normal)
        let preference = AssistantMemory(content: "用户下午更适合安排专注任务", category: "个人偏好")
        let unrelated = AssistantMemory(content: "其他项目下午发布", category: "项目背景")
        let recall = AssistantContextRecall.make(messages: [.init(text: "安排接口评审准备，需要专注", isUser: true)], context: .init(todos: [todo], memories: [preference,unrelated]))
        #expect(recall.memories.map(\.id).contains(preference.id) && !recall.memories.map(\.id).contains(unrelated.id))
    }

}
