import Foundation
import Testing
@testable import PersonalAssistant

struct TaskPreferenceTests {
    func thread(_ texts: [String]) -> [AssistantMessage] { texts.map { .init(text: $0, isUser: true) } }
    @Test func explicitScopeContinuesAndSurvivesSerialization() throws {
        let rows = thread(["本任务内请简短回复", "继续本任务，解释原因", "继续当前任务，下一步呢"])
        let restored = try JSONDecoder().decode([AssistantMessage].self, from: JSONEncoder().encode(rows))
        let state = TaskPreferencePolicy.state(messages: restored)
        #expect(state.value == "brief" && state.origin == rows.first?.id)
        #expect(!MemoryExtractionPolicy.shouldExtract(from: rows[0].text))
    }
    @Test func boundariesNeverResurrectOldRule() {
        for boundary in ["结束当前任务", "取消当前任务", "换个任务", "新任务", "换个话题", "另起任务", "另外问一下", "解释另一个项目", "继续"] {
            let state = TaskPreferencePolicy.state(messages: thread(["本任务内详细回复", boundary, "继续本任务"]))
            #expect(!state.active && state.seen)
            #expect(state.message?.content.contains("expired") == true)
        }
    }
    @Test func conflictRequiresExplicitNewDeclaration() {
        let rows = thread(["本任务内简短又详细回复", "继续本任务"])
        #expect(TaskPreferencePolicy.state(messages: rows).clarification != nil)
        #expect(TaskPreferencePolicy.state(messages: rows + thread(["本任务内详细回复"])).value == "detailed")
    }
    @Test func unsupportedOrNegatedRulesDoNotActivate() {
        for text in ["本任务内不要详细回复", "本任务内简短回复并调整提醒次数", "本任务内安排在下午", "本任务内以后都简短回复"] {
            let state = TaskPreferencePolicy.state(messages: thread([text]))
            #expect(state.value == nil && state.clarification != nil)
            #expect(!MemoryExtractionPolicy.shouldExtract(from: text))
        }
    }
    @Test func expiredFutureAndMissingHistory() {
        var rows = thread(["本任务内简短回复", "继续本任务"])
        rows[0].time = Date().addingTimeInterval(-86401)
        #expect(!TaskPreferencePolicy.state(messages: rows).active)
        rows[0].time = Date().addingTimeInterval(60)
        #expect(!TaskPreferencePolicy.state(messages: rows).active)
        #expect(!TaskPreferencePolicy.state(messages: []).active)
        #expect(!TaskPreferencePolicy.state(messages: thread(["继续本任务"])).active)
    }
    @Test func currentTurnOverrideDoesNotReplaceTaskRule() {
        let rows = thread(["本任务内简短回复", "继续本任务，这次详细回答"])
        let result = PreferenceContinuationPolicy.make(messages: rows, memories: [], recalled: [])
        #expect(result.temporaryKinds == [.replyLength] && result.message?.content.contains("brief") == true)
        #expect(TaskPreferencePolicy.state(messages: rows + thread(["继续本任务"])).value == "brief")
    }
    @Test func activeScopeOverridesSavedDefaultWithoutMutation() {
        let memory = AssistantMemory(content: "简短", category: "个人偏好", actionPreferences: [.init(kind: .replyLength, value: "brief", end: nil, confirmedAt: Date())])
        let rows = thread(["本任务内详细回复", "继续本任务，按之前的偏好回复"])
        let result = PreferenceContinuationPolicy.make(messages: rows, memories: [memory], recalled: [memory])
        #expect(result.selected.isEmpty && result.clarification == nil)
        #expect(result.message?.content.contains("detailed") == true)
        #expect(memory.actionPreferences?.first?.value == "brief")
    }

    @Test func negatedSameTaskNeverContinuesOrResurrects() throws {
        for negative in ["不是同一任务", "这不是同一任务", "并非同一任务", "不再是同一任务", "不是同一个任务", "不要继续本任务", "不继续当前任务", "不要继续这个任务", "继续本任务，但不是同一任务"] {
            let rows = thread(["本任务内详细回复", negative, "继续本任务"])
            let restored = try JSONDecoder().decode([AssistantMessage].self, from: JSONEncoder().encode(rows))
            #expect(!TaskPreferencePolicy.continues(negative))
            #expect(!TaskPreferencePolicy.state(messages: restored).active)
        }
    }
    @Test func independentMemoryOptOutKeepsExplicitTaskStyle() {
        for optOut in ["不要记住", "别记住", "不用记住", "不要记录记忆", "不要保存到记忆", "不要保存到长期记忆", "不要长期保存", "不保存到长期记忆", "不用保存到长期记忆"] {
            let text = "本任务内详细回复，" + optOut
            let rows = thread([text, "继续本任务"])
            #expect(TaskPreferencePolicy.state(messages: rows).value == "detailed")
            #expect(!MemoryExtractionPolicy.shouldExtract(from: text))
            #expect(PreferenceContinuationPolicy.make(messages: rows, memories: [], recalled: []).clarification == nil)
        }
    }
    @Test func optOutCannotHideNegatedConflictingOrPermanentStyle() {
        for text in ["本任务内不要详细回复，不要记住", "本任务内简短又详细回复，不要记住", "本任务内详细回复，不要记住，以后都简短", "本任务内详细回复，不要记住但要简短", "本任务内详细回复并不要记住", "本任务内详细回复，不要保存到长期记忆并调整提醒次数"] {
            let state = TaskPreferencePolicy.state(messages: thread([text]))
            #expect(state.value == nil && state.clarification != nil)
            #expect(!MemoryExtractionPolicy.shouldExtract(from: text))
        }
    }
    @Test func newDeclarationAfterDeniedContinuationBindsNewOrigin() {
        let rows = thread(["本任务内详细回复", "不是同一任务", "本任务内简短回复，不要记住", "继续本任务"])
        let state = TaskPreferencePolicy.state(messages: rows)
        #expect(state.value == "brief" && state.origin == rows[2].id)
    }
}
