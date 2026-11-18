import Foundation
import Testing
@testable import PersonalAssistant

struct TaskPreferenceRunTests {
    let scope = AssistantRun.digest("task-preference-scope")
    func fixture() -> (AssistantMessage, AssistantRun) {
        var message = AssistantMessage(text: "本任务内详细回复，不要记住", isUser: true)
        var run = AssistantRun(originalMessageID: message.id, requestHash: AssistantRun.digest(message.text), goal: message.text, scopeHash: scope, messageIDs: [message.id])
        run.state = .responded; message.assistantRunID = run.id
        return (message, run)
    }
    func staged() -> (AssistantMessage, AssistantRun, AssistantRun) {
        let (message, base) = fixture()
        var child = base
        var parent = AssistantRun(originalMessageID: UUID(), requestHash: AssistantRun.digest("parent"), goal: "评审准备", scopeHash: scope, messageIDs: [])
        let stage = AssistantGoalStage(title: "核对", instruction: "只读核对", criterion: "人工核对", reviewMode: "read_review", dependencies: [], childRunID: child.id)
        let next = AssistantGoalStage(title: "整理", instruction: "整理", criterion: "人工核对", reviewMode: "read_review", dependencies: [0])
        parent.stagePlan = .init(requestHash: parent.requestHash, stages: [stage,next], status: "confirmed")
        child.parentRunID = parent.id; child.parentStageID = stage.id
        return (message, parent, child)
    }
    @Test func responsePauseAndRestartKeepVerifiedBinding() throws {
        let (message, run) = fixture()
        for status in [AssistantRun.State.responded,.paused,.ready,.awaitingConfirmation,.failed,.blocked] {
            var owner = run; owner.state = status
            var next = AssistantMessage(text: "解释下一步", isUser: true); next.assistantRunID = run.id
            owner.messageIDs.append(next.id)
            let restored = try JSONDecoder().decode([AssistantRun].self, from: JSONEncoder().encode([owner]))
            let state = TaskPreferencePolicy.state(messages: [message,next], runs: restored, currentRunID: owner.id, scopeHash: scope)
            #expect(state.value == "detailed" && state.runID == owner.id)
        }
    }
    @Test func endedRunDoesNotReturnAfterRestartOrExplicitContinuation() throws {
        var (message, run) = fixture(); run.state = .cancelled
        let restored = try JSONDecoder().decode([AssistantRun].self, from: JSONEncoder().encode([run]))
        let next = AssistantMessage(text: "继续本任务", isUser: true)
        let state = TaskPreferencePolicy.state(messages: [message,next], runs: restored, currentRunID: run.id, scopeHash: scope)
        #expect(!state.active && state.expiryReason == "run_ended")
        #expect(state.message?.content.contains("expired") == true)
    }
    @Test func stageCompletionAndParentEndExpireBinding() {
        let (message, base, child) = staged()
        for mode in ["complete", "parent_end", "parent_missing", "child_changed"] {
            var parent = base
            if mode == "complete" { parent.stagePlan!.stages[0].reviewedAt = Date(); parent.stagePlan!.stages[0].reviewNote = "已核对" }
            if mode == "parent_end" { parent.state = .cancelled }
            if mode == "child_changed" { parent.stagePlan!.stages[0].childRunID = UUID() }
            let rows = mode == "parent_missing" ? [child] : [parent,child]
            let state = TaskPreferencePolicy.state(messages: [message], runs: rows, currentRunID: child.id, scopeHash: scope)
            #expect(!state.active)
        }
    }
    @Test func anotherStageNeverInheritsEvenWithExplicitText() {
        let (message, parent, child) = staged()
        var other = child; other.id = UUID(); other.parentStageID = parent.stagePlan!.stages[1].id
        var next = AssistantMessage(text: "继续本任务", isUser: true); next.assistantRunID = other.id
        let state = TaskPreferencePolicy.state(messages: [message,next], runs: [parent,child,other], currentRunID: other.id, scopeHash: scope)
        #expect(!state.active)
    }
    @Test func missingLegacyAlteredOrScopeChangedBindingFailsClosed() {
        let (message, run) = fixture()
        for mode in ["missing", "legacy", "scope", "origin", "hash"] {
            var source = message, owner = run
            if mode == "legacy" { source.assistantRunID = nil }
            if mode == "origin" { owner.messageIDs = [] }
            if mode == "hash" { owner = .init(originalMessageID: message.id, requestHash: AssistantRun.digest("different"), goal: "same name", scopeHash: scope, messageIDs: [message.id]); owner.id = run.id }
            let state = TaskPreferencePolicy.state(messages: [source], runs: mode == "missing" ? [] : [owner], currentRunID: run.id, scopeHash: mode == "scope" ? AssistantRun.digest("other") : scope)
            #expect(!state.active && state.expiryReason == "binding_missing_or_scope_changed")
        }
    }
    @Test func explicitFreeChatMayReferToLiveOriginButNotCancelledOrigin() {
        let (message, run) = fixture()
        let next = AssistantMessage(text: "继续本任务", isUser: true)
        let other = AssistantRun(originalMessageID: next.id, requestHash: AssistantRun.digest(next.text), goal: next.text, scopeHash: scope, messageIDs: [next.id])
        #expect(TaskPreferencePolicy.state(messages: [message,next], runs: [run,other], currentRunID: other.id, scopeHash: scope).active)
        var ended = run; ended.state = .cancelled
        #expect(!TaskPreferencePolicy.state(messages: [message,next], runs: [ended,other], currentRunID: other.id, scopeHash: scope).active)
    }
    @Test func sameRunDoesNotOverrideNegativeOrTaskSwitch() {
        let (message, run) = fixture()
        for text in ["不是同一任务", "换个话题", "取消当前任务"] {
            var next = AssistantMessage(text: text, isUser: true); next.assistantRunID = run.id
            #expect(!TaskPreferencePolicy.state(messages: [message,next], runs: [run], currentRunID: run.id, scopeHash: scope).active)
        }
    }
    @Test func policyIsReadOnlyAndCompletedParentCannotReopenStyle() {
        let (message, base, child) = staged()
        var parent = base
        for index in parent.stagePlan!.stages.indices { parent.stagePlan!.stages[index].reviewedAt = Date(); parent.stagePlan!.stages[index].reviewNote = "完成" }
        let rows = [parent,child], before = rows
        let state = TaskPreferencePolicy.state(messages: [message], runs: rows, currentRunID: child.id, scopeHash: scope)
        #expect(!state.active && rows == before)
        let result = PreferenceContinuationPolicy.make(messages: [message], memories: [], recalled: [], taskState: state)
        #expect(result.message?.content.contains("expired") == true && result.temporaryKinds.isEmpty)
    }

    @Test func parentTaskPreferenceAppliesToItsOwnLiveChildOnly() {
        let (_, base, initialChild) = staged()
        var child = initialChild
        var parent = base
        var declaration = AssistantMessage(text: "本任务内详细回复", isUser: true); declaration.assistantRunID = parent.id
        parent = AssistantRun(originalMessageID: declaration.id, requestHash: AssistantRun.digest(declaration.text), goal: declaration.text, scopeHash: scope, messageIDs: [declaration.id])
        parent.id = base.id; parent.stagePlan = .init(requestHash: parent.requestHash, stages: base.stagePlan!.stages, status: "confirmed")
        var next = AssistantMessage(text: "核对当前阶段", isUser: true); next.assistantRunID = child.id
        child.messageIDs.append(next.id)
        let state = TaskPreferencePolicy.state(messages: [declaration,next], runs: [parent,child], currentRunID: child.id, scopeHash: scope)
        #expect(state.active && state.runID == parent.id && state.stageID == nil)
        var other = child; other.parentRunID = UUID()
        #expect(!TaskPreferencePolicy.state(messages: [declaration,next], runs: [parent,other], currentRunID: other.id, scopeHash: scope).active)
        parent.stagePlan!.stages[0].reviewedAt = Date(); parent.stagePlan!.stages[0].reviewNote = "已核对"
        #expect(!TaskPreferencePolicy.state(messages: [declaration,next], runs: [parent,child], currentRunID: child.id, scopeHash: scope).active)
    }

    @Test func scopeRestorationRetainsLiveOriginButNeverEndedOrigin() throws {
        let (message, run) = fixture()
        let next = AssistantMessage(text: "继续本任务", isUser: true)
        let other = AssistantRun(originalMessageID: next.id, requestHash: AssistantRun.digest(next.text), goal: next.text, scopeHash: scope, messageIDs: [next.id])
        let before = [run,other]
        #expect(!TaskPreferencePolicy.state(messages: [message,next], runs: before, currentRunID: other.id, scopeHash: AssistantRun.digest("changed")).active)
        #expect(TaskPreferencePolicy.state(messages: [message,next], runs: before, currentRunID: other.id, scopeHash: scope).active)
        var ended = run; ended.state = .cancelled
        let restored = try JSONDecoder().decode([AssistantRun].self, from: JSONEncoder().encode([ended,other]))
        #expect(!TaskPreferencePolicy.state(messages: [message,next], runs: restored, currentRunID: other.id, scopeHash: scope).active)
        #expect(before == [run,other])
    }
    @Test func staleImplicitRunTagCannotPreservePreference() {
        let (message, run) = fixture()
        var next = AssistantMessage(text: "解释另一份材料", isUser: true); next.assistantRunID = run.id
        #expect(!TaskPreferencePolicy.state(messages: [message,next], runs: [run], currentRunID: run.id, scopeHash: scope).active)
        var verified = run; verified.messageIDs.append(next.id)
        #expect(TaskPreferencePolicy.state(messages: [message,next], runs: [verified], currentRunID: run.id, scopeHash: scope).active)
    }
}
