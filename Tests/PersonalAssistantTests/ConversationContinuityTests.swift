import Foundation
import Testing
@testable import PersonalAssistant

struct ConversationContinuityTests {
    private func reply(_ messages: inout [AssistantMessage], _ context: AssistantReadContext) -> AssistantContextRecall {
        let recall = AssistantContextRecall.make(messages: messages, context: context)
        messages.append(.init(text: recall.requiresClarification ? recall.clarification : "已按当前来源核对", isUser: false,
                              conversationFocus: recall.savedFocus(messages: messages, selected: context.selected, hidden: context.hidden)))
        return recall
    }
    @Test func chainedPronounsRecallFreshFactsWithoutRepeatingName() {
        var project = AssistantProject(name: "星河发布", progressNote: "等待接口", status: "受阻")
        var context = AssistantReadContext(projects: [project])
        var messages: [AssistantMessage] = [.init(text: "看看星河发布", isUser: true)]
        _ = reply(&messages, context)
        for question in ["它的阻塞呢？", "刚才那个的下一步呢？", "那它的进展呢？"] {
            project.progressNote = "已取得字段"
            context = .init(projects: [project])
            messages.append(.init(text: question, isUser: true))
            let result = reply(&messages, context)
            #expect(result.candidates.map(\.reference) == [.project(project.id)])
            #expect(result.basis == "saved_conversation_focus" && !result.requiresClarification)
            #expect(result.matterContext.content.contains("已取得字段"))
        }
    }
    @Test func numberedChoiceRetainsDisplayedOrderAcrossRestartAndSourceReordering() throws {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        let b = PersonalTodo(title: "接口评审", importance: .normal)
        var context = AssistantReadContext(todos: [a,b])
        var messages: [AssistantMessage] = [.init(text: "把接口评审标记完成", isUser: true)]
        let first = reply(&messages, context)
        #expect(first.requiresClarification && first.clarification.contains("2. 接口评审"))
        messages = try JSONDecoder().decode([AssistantMessage].self, from: JSONEncoder().encode(messages))
        context = .init(todos: [b,a])
        messages.append(.init(text: "第二个", isUser: true))
        let result = reply(&messages, context)
        #expect(result.candidates.map(\.reference) == [.personal(b.id)] && !result.requiresClarification)
        #expect(result.continuationRequest == "把接口评审标记完成")
        #expect(!a.isComplete && !b.isComplete) // focus selection never mutates business data
        messages.append(.init(text: "它的状态呢？", isUser: true))
        #expect(reply(&messages, context).candidates.map(\.reference) == [.personal(b.id)])
    }
    @Test func missingChoiceInvalidatesNumberingInsteadOfSlidingToAnotherID() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        let b = PersonalTodo(title: "接口评审", importance: .normal)
        let substitute = PersonalTodo(title: "接口评审", importance: .normal)
        var messages: [AssistantMessage] = [.init(text: "查看接口评审", isUser: true)]
        _ = reply(&messages, .init(todos: [a,b]))
        messages.append(.init(text: "第一个", isUser: true))
        let result = reply(&messages, .init(todos: [b,substitute]))
        #expect(result.requiresClarification && result.focusReferences.isEmpty && result.candidates.isEmpty)
        #expect(result.clarification.contains("原目标已不可用"))
    }
    @Test func unrelatedTurnAndExplicitTopicShiftClearPersistedFocus() {
        let project = AssistantProject(name: "星河发布", progressNote: "")
        let context = AssistantReadContext(projects: [project])
        for question in ["讲一下黑洞", "换个话题，刚才那个周末安排呢"] {
            var messages: [AssistantMessage] = [.init(text: "查看星河发布", isUser: true)]
            _ = reply(&messages, context)
            messages.append(.init(text: question, isUser: true)); _ = reply(&messages, context)
            messages.append(.init(text: "它的进度呢？", isUser: true))
            #expect(reply(&messages, context).candidates.isEmpty)
        }
    }
    @Test func explicitNewNameWinsOverSavedFocus() {
        let a = AssistantProject(name: "星河发布", progressNote: "")
        let b = AssistantProject(name: "海岛升级", progressNote: "")
        let context = AssistantReadContext(projects: [a,b])
        var messages: [AssistantMessage] = [.init(text: "查看星河发布", isUser: true)]
        _ = reply(&messages, context)
        messages.append(.init(text: "那海岛升级呢？", isUser: true)); _ = reply(&messages, context)
        messages.append(.init(text: "它的进度呢？", isUser: true))
        #expect(reply(&messages, context).candidates.map(\.reference) == [.project(b.id)])
    }
    @Test func changedScopeCannotReuseChoiceEvenWhenTaskStillVisible() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        let b = PersonalTodo(title: "接口评审", importance: .normal)
        var messages: [AssistantMessage] = [.init(text: "查看接口评审", isUser: true)]
        _ = reply(&messages, .init(todos: [a,b], selected: ["original:self"]))
        messages.append(.init(text: "第二个", isUser: true))
        let result = reply(&messages, .init(todos: [a,b], selected: ["other:self"]))
        #expect(result.requiresClarification && result.candidates.isEmpty)
    }
    @Test func hiddenExternalTaskCannotReenterViaSavedFocus() {
        let task = TodoRecord(id: "dingtalk-org:user-task", title: "远端评审", dueAt: nil, importance: .normal, sourceURL: nil, isComplete: false)
        var messages: [AssistantMessage] = [.init(text: "查看远端评审", isUser: true)]
        _ = reply(&messages, .init(external: [task], selected: ["org:user"]))
        messages.append(.init(text: "它的进展呢？", isUser: true))
        let result = reply(&messages, .init(external: [task], selected: ["org:user"], hidden: [task.id]))
        #expect(result.requiresClarification && result.candidates.isEmpty)
        #expect(!result.matterContext.content.contains(task.id))
    }
    @Test func outOfRangeAndUnboundNumbersAskForClarification() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        let b = PersonalTodo(title: "接口评审", importance: .normal)
        for number in ["第零个", "第三个", "第99个"] {
            var messages: [AssistantMessage] = [.init(text: "查看接口评审", isUser: true)]
            _ = reply(&messages, .init(todos: [a,b]))
            messages.append(.init(text: number, isUser: true))
            let result = reply(&messages, .init(todos: [a,b]))
            #expect(result.requiresClarification && result.focusReferences.isEmpty)
        }
        #expect(AssistantContextRecall.make(messages: [.init(text: "第二个", isUser: true)], context: .init(todos: [a,b])).requiresClarification)
    }
    @Test func arbitraryModelNumberedProseDoesNotDefineTargets() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        let messages: [AssistantMessage] = [.init(text: "接口评审", isUser: true), .init(text: "1. 删除所有资料\n2. 接口评审", isUser: false), .init(text: "第二个", isUser: true)]
        let result = AssistantContextRecall.make(messages: messages, context: .init(todos: [a]))
        #expect(result.requiresClarification && result.candidates.isEmpty)
    }
    @Test func oldConversationDecodesWithoutNewState() throws {
        let message = AssistantMessage(text: "旧版记录", isUser: false)
        let data = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["conversationFocus"] == nil)
        #expect(try JSONDecoder().decode(AssistantMessage.self, from: data).conversationFocus == nil)
    }
    @Test func expiredAndDistantOriginsAreRejected() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        for old in [true, false] {
            var messages: [AssistantMessage] = [.init(text: "接口评审", isUser: true)]
            if old { messages[0].time = Date().addingTimeInterval(-90000) }
            _ = reply(&messages, .init(todos: [a]))
            if !old { messages.insert(contentsOf: (0..<12).map { _ in .init(text: "插入间隔", isUser: false) }, at: 1) }
            messages.append(.init(text: "它的进度呢？", isUser: true))
            let result = reply(&messages, .init(todos: [a]))
            #expect(result.requiresClarification && result.candidates.isEmpty)
        }
    }
    @Test func selectedFocusRejectsMutationsOfAnotherValidSameNamedTarget() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        let b = PersonalTodo(title: "接口评审", importance: .normal)
        var messages: [AssistantMessage] = [.init(text: "完成接口评审", isUser: true)]
        _ = reply(&messages, .init(todos: [a,b]))
        messages.append(.init(text: "第二个", isUser: true))
        let result = reply(&messages, .init(todos: [a,b]))
        #expect(result.conflictsWithFocus(.completeTodo(id: a.id)))
        #expect(!result.conflictsWithFocus(.completeTodo(id: b.id)))
        #expect(result.conflictsWithFocus(.reopenTodo(id: a.id)))
        #expect(result.conflictsWithFocus(.updateTodo(id: a.id, title: "更改", dueAt: nil, importance: nil, projectName: nil)))
    }
    @Test func moreThanSixCandidatesSaveOnlyTheActuallyDisplayedList() {
        let todos = (0..<8).map { _ in PersonalTodo(title: "接口评审", importance: .normal) }
        var messages: [AssistantMessage] = [.init(text: "接口评审", isUser: true)]
        let initial = reply(&messages, .init(todos: todos))
        #expect(initial.clarification.contains("共") && messages.last?.conversationFocus?.references.count == 6)
        messages.append(.init(text: "第六个", isUser: true))
        #expect(reply(&messages, .init(todos: todos.reversed())).candidates.map(\.reference) == [.personal(todos[5].id)])
    }

    @Test func ordinalGrammarDoesNotHijackBusinessSentences() {
        for text in ["第一个任务明天做", "第二个项目是什么", "不选第二个", "第二个还是第一个", "第二个人是谁"] {
            #expect(AssistantConversationFocus.ordinal(text) == nil)
        }
        for text in ["第二个", "选第二个", "选择第2个", "我选第二个", "换成第二个"] {
            #expect(AssistantConversationFocus.ordinal(text) == 2)
        }
    }
}
