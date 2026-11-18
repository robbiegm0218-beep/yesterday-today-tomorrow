import Foundation
import Testing
@testable import PersonalAssistant

struct ConversationCorrectionTests {
    private func answer(_ messages: inout [AssistantMessage], _ context: AssistantReadContext) -> AssistantContextRecall {
        let result = AssistantContextRecall.make(messages: messages, context: context)
        messages.append(.init(text: result.requiresClarification ? result.clarification : result.correctionAcknowledgement ?? "只读合成回复", isUser: false,
                              conversationFocus: result.savedFocus(messages: messages, selected: context.selected, hidden: context.hidden)))
        return result
    }
    private func selected(_ todos: [PersonalTodo]) -> [AssistantMessage] {
        var messages: [AssistantMessage] = [.init(text: "完成接口评审", isUser: true)]
        _ = answer(&messages, .init(todos: todos))
        messages.append(.init(text: "第二个", isUser: true)); _ = answer(&messages, .init(todos: todos))
        return messages
    }
    @Test func reselectFirstAfterRestartPreservesOriginalDisplayedOrder() throws {
        let a = PersonalTodo(title: "接口评审", importance: .normal), b = PersonalTodo(title: "接口评审", importance: .normal)
        var messages = try JSONDecoder().decode([AssistantMessage].self, from: JSONEncoder().encode(selected([a,b])))
        messages.append(.init(text: "换成第一个", isUser: true))
        let result = answer(&messages, .init(todos: [b,a]))
        #expect(result.candidates.map(\.reference) == [.personal(a.id)] && !result.requiresClarification)
        #expect(result.isFocusCorrection && result.continuationRequest == nil && result.correctionAcknowledgement != nil)
        #expect(messages.last?.conversationFocus?.choiceReferences == [.personal(a.id), .personal(b.id)])
        #expect(result.conflictsWithFocus(.completeTodo(id: b.id)))
        #expect(!result.conflictsWithFocus(.completeTodo(id: a.id)))
    }
    @Test func explicitCorrectionDoesNotRepeatOldBusinessInstructionOnNextPronoun() {
        let a = PersonalTodo(title: "接口评审", importance: .normal), b = PersonalTodo(title: "接口评审", importance: .normal)
        var messages = selected([a,b]); messages.append(.init(text: "不是第二个，是第一个", isUser: true))
        let correction = answer(&messages, .init(todos: [a,b]))
        #expect(correction.correctionAcknowledgement?.contains("已有卡片状态保持") == true)
        messages.append(.init(text: "它的进度呢？", isUser: true))
        let next = answer(&messages, .init(todos: [a,b]))
        #expect(next.candidates.map(\.reference) == [.personal(a.id)] && next.continuationRequest == nil)
        #expect(!next.matterContext.content.contains("完成接口评审"))
    }
    @Test func anotherRequiresOneUnselectedAlternative() {
        let todos = (0..<3).map { _ in PersonalTodo(title: "接口评审", importance: .normal) }
        for count in [2,3] {
            var messages = selected(Array(todos.prefix(count))); messages.append(.init(text: "换成另一个", isUser: true))
            let result = answer(&messages, .init(todos: todos))
            if count == 2 { #expect(result.candidates.map(\.reference) == [.personal(todos[0].id)] && !result.requiresClarification) }
            else { #expect(result.requiresClarification && Set(result.candidates.map(\.reference)) == [.personal(todos[0].id), .personal(todos[2].id)]) }
        }
    }
    @Test func cannotInferAnotherBeforeInitialSelection() {
        let todos = (0..<2).map { _ in PersonalTodo(title: "接口评审", importance: .normal) }
        var messages: [AssistantMessage] = [.init(text: "接口评审", isUser: true)]; _ = answer(&messages, .init(todos: todos))
        messages.append(.init(text: "换成另一个", isUser: true))
        #expect(answer(&messages, .init(todos: todos)).requiresClarification)
    }
    @Test func uniqueCompletionQualifierUsesLoadedLocalFields() {
        var a = PersonalTodo(title: "接口评审", importance: .normal)
        let b = PersonalTodo(title: "接口评审", importance: .normal)
        var messages = selected([a,b]); a.isComplete = true
        messages.append(.init(text: "刚才那个已完成的", isUser: true))
        let result = answer(&messages, .init(todos: [a,b]))
        #expect(result.candidates.map(\.reference) == [.personal(a.id)] && result.isFocusCorrection)
        #expect(result.correctionAcknowledgement != nil && result.continuationRequest == nil)
        #expect(!b.isComplete)
    }
    @Test func completionQualifierCanResolveInitialChoiceWithOriginalIntent() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        var b = PersonalTodo(title: "接口评审", importance: .normal); b.isComplete = true
        var messages: [AssistantMessage] = [.init(text: "查看接口评审", isUser: true)]; _ = answer(&messages, .init(todos: [a,b]))
        messages.append(.init(text: "选未完成的那个", isUser: true))
        let result = answer(&messages, .init(todos: [a,b]))
        #expect(result.candidates.map(\.reference) == [.personal(a.id)] && !result.isFocusCorrection)
        #expect(result.continuationRequest == "查看接口评审")
    }
    @Test func severalMatchingStatesAskAndEstablishNewVisibleNumbering() {
        let todos = (0..<3).map { _ in PersonalTodo(title: "接口评审", importance: .normal) }
        var messages = selected(todos); messages.append(.init(text: "换成未完成的那个", isUser: true))
        let first = answer(&messages, .init(todos: todos))
        #expect(first.requiresClarification && first.correctionAcknowledgement == nil)
        messages.append(.init(text: "第一个", isUser: true))
        let next = answer(&messages, .init(todos: todos.reversed()))
        #expect(next.candidates.map(\.reference) == [.personal(todos[0].id)])
        #expect(next.continuationRequest == nil && next.correctionAcknowledgement != nil)
        #expect(messages.last?.conversationFocus?.discussionOnly == true)
    }
    @Test func noMatchingStateDoesNotChooseACompletedTaskInstead() {
        var a = PersonalTodo(title: "接口评审", importance: .normal), b = PersonalTodo(title: "接口评审", importance: .normal)
        a.isComplete = true; b.isComplete = true
        var messages = selected([a,b]); messages.append(.init(text: "换成未完成的那个", isUser: true))
        let result = answer(&messages, .init(todos: [a,b]))
        #expect(result.requiresClarification && result.focusReferences.isEmpty)
    }
    @Test func mixedRemoteOrProjectListsCannotBeFilteredAsFreshBooleanFacts() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        let remote = TodoRecord(id: "dingtalk-org:user-a", title: "接口评审", dueAt: nil, importance: .normal, sourceURL: nil, isComplete: false)
        let context = AssistantReadContext(todos: [a], external: [remote], selected: ["org:user"])
        var messages: [AssistantMessage] = [.init(text: "接口评审", isUser: true)]; _ = answer(&messages, context)
        messages.append(.init(text: "选未完成的那个", isUser: true))
        let result = answer(&messages, context)
        #expect(result.requiresClarification && result.clarification.contains("只支持"))
    }
    @Test func removedAlternativeInvalidatesOldNumbersEvenIfSelectedItemStillExists() {
        let todos = (0..<3).map { _ in PersonalTodo(title: "接口评审", importance: .normal) }
        var messages = selected(todos); messages.append(.init(text: "换成第一个", isUser: true))
        let result = answer(&messages, .init(todos: Array(todos.suffix(2))))
        #expect(result.requiresClarification && result.candidates.isEmpty)
    }
    @Test func changedScopeAndExpiredListsBlockCorrections() {
        let todos = (0..<2).map { _ in PersonalTodo(title: "接口评审", importance: .normal) }
        for stale in [true,false] {
            var messages = selected(todos)
            if stale { for i in messages.indices { messages[i].time = Date().addingTimeInterval(-90000) } }
            messages.append(.init(text: "换成第一个", isUser: true))
            let context = AssistantReadContext(todos: todos, selected: stale ? [] : ["different:self"])
            #expect(answer(&messages, context).requiresClarification)
        }
    }
    @Test func oldBuild64SingleFocusWithoutAlternativesDoesNotInventList() {
        let a = PersonalTodo(title: "接口评审", importance: .normal)
        let user = AssistantMessage(text: "查看接口评审", isUser: true)
        let reply = AssistantMessage(text: "已回复", isUser: false, conversationFocus: .init(references: [.personal(a.id)], isChoice: false, originMessageID: user.id, selected: [], hidden: []))
        let result = AssistantContextRecall.make(messages: [user,reply,.init(text: "换成第一个", isUser: true)], context: .init(todos: [a]))
        #expect(result.requiresClarification)
    }
    @Test func explicitNewEntityClearsOldAlternativesAndTopicShiftDoesNotSelect() {
        let todos = (0..<2).map { _ in PersonalTodo(title: "接口评审", importance: .normal) }
        let new = PersonalTodo(title: "发布准备", importance: .normal)
        var messages = selected(todos); messages.append(.init(text: "查看发布准备", isUser: true)); _ = answer(&messages, .init(todos: todos + [new]))
        #expect(messages.last?.conversationFocus?.choiceReferences == nil)
        messages.append(.init(text: "换个话题，刚才第一个", isUser: true))
        #expect(answer(&messages, .init(todos: todos + [new])).candidates.isEmpty)
    }
    @Test func anchoredSelectionDoesNotInterpretNegationAlternativesOrWriteSentences() {
        for text in ["不要换成第一个", "不是第二个", "第一个还是第二个", "换成第一个并完成", "未完成的那个明天做", "假设换成另一个", "不选未完成的那个"] {
            #expect(AssistantConversationFocus.selection(text) == nil)
        }
        for text in ["换成第一个", "不是这个，是第一个", "不是第二个，是第一个", "刚才第一个", "我说的是第一个"] {
            #expect(AssistantConversationFocus.selection(text) == .number(1))
        }
    }
}
