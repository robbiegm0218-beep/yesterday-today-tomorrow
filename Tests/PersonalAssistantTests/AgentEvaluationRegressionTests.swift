import Foundation
import Testing
@testable import PersonalAssistant

struct AgentEvaluationRegressionTests {
    @Test func completionQuestionAndReadOnlyStatusAreNeverForcedWrites() {
        for text in ["这个任务完成了吗？", "刚才勾选的步骤完成，原任务也完成了吗？只核对状态，不修改。", "这件待办做完了吗？"] {
            #expect(AssistantToolIntent.declinesWriteTools(in: text))
            #expect(AssistantToolIntent.forcedToolName(for: text, enabledSkillIDs: ["todo-priority"]) == nil)
        }
        #expect(AssistantToolIntent.forcedToolName(for: "将个人待办标记完成", enabledSkillIDs: ["todo-priority"]) == "complete_personal_todo")
        #expect(AssistantToolIntent.shouldEnforceProposal("如果将任务标题改为终审会怎样？", tool: "update_personal_todo", groundedTargetCount: 1, external: false) == false)
        #expect(AssistantToolIntent.shouldEnforceProposal("帮我解释将任务标题改为终审会怎样？", tool: "update_personal_todo", groundedTargetCount: 1, external: false) == false)
        #expect(AssistantToolIntent.shouldEnforceProposal("帮我安排今天，如果下午已过就不要安排过去时刻", tool: "propose_day_plan", groundedTargetCount: 1, external: false))
        #expect(AssistantToolIntent.requestsDayPlan("帮我安排今天剩下的时间，不要安排过去时刻"))
        #expect(!AssistantToolIntent.requestsDayPlan("不要安排今天，只给建议"))
        #expect(!AssistantToolIntent.requestsTodoReopen("这个任务完成后还能恢复吗？"))
        #expect(AssistantToolIntent.requestsDayReview("今天只继续昨天第一项，第二项先不决定"))
        #expect(!AssistantToolIntent.requestsDayReview("只读回顾昨天，今天先别安排"))
    }
    @Test func reopeningRequiresCompletedLocalTargetAndVerbatimCurrentAuthorization() throws {
        var todo = PersonalTodo(title: "接口评审", importance: .normal); todo.isComplete = true
        let user = AssistantMessage(text: "恢复刚才那个个人待办为未完成", isUser: true)
        func proposals(_ quote: String, todos: [PersonalTodo] = [], source: AssistantMessage? = nil) throws -> [PendingAssistantAction] {
            let args = try JSONSerialization.data(withJSONObject: ["todo_id": todo.id.uuidString, "quote": quote])
            return AssistantActionParser.proposals(from: [.init(id: "r", function: .init(name: "reopen_personal_todo", arguments: String(decoding: args, as: UTF8.self)))], todos: todos, projects: [], sourceMessage: source)
        }
        let valid = try proposals(user.text, todos: [todo], source: user)
        #expect(valid.count == 1)
        let roundtrip = try JSONDecoder().decode([PendingAssistantAction].self, from: JSONEncoder().encode(valid))
        if case let .reopenTodo(id) = roundtrip.first?.operation { #expect(id == todo.id) } else { Issue.record("Wrong operation") }
        #expect(try proposals("没有说过的授权", todos: [todo], source: user).isEmpty)
        #expect(try proposals(user.text, todos: [], source: user).isEmpty)
        let external = AssistantMessage(text: "将钉钉待办重新打开", isUser: true)
        #expect(try proposals(external.text, todos: [todo], source: external).isEmpty)
        todo.isComplete = false
        #expect(try proposals(user.text, todos: [todo], source: user).isEmpty)
    }
    @Test func followupUsesOnlyNewExactTargetEvidenceWithoutResolvingAnything() {
        let now = Date(); let ref = MatterReference.personal(UUID())
        var rule = MatterFollowup(reference: ref, title: "接口评审", waitingFor: "小林", criterion: "收到字段确认", nextStep: "核对字段", checkAt: now, quote: "原话", sourceMessageID: nil)
        rule.updatedAt = now.addingTimeInterval(-600)
        let new = FollowupPolicy.Observation(reference: ref, excerpt: "小林已回复 REPLY_48", source: "已关联消息", date: now.addingTimeInterval(-1))
        let future = FollowupPolicy.Observation(reference: ref, excerpt: "未来不可用", source: "消息", date: now.addingTimeInterval(100))
        let wrong = FollowupPolicy.Observation(reference: .personal(UUID()), excerpt: "其他事项", source: "消息", date: now)
        let result = FollowupPolicy.candidates([rule], eligible: [ref], observations: [new,future,wrong], now: now)
        #expect(result.first?.body.contains("REPLY_48") == true && result.first?.body.contains("未来不可用") == false)
        #expect(result.first?.body.contains("是否满足") == true && rule.status == "pending")
        #expect(FollowupPolicy.candidates([rule], eligible: [], observations: [new], now: now).isEmpty)
        let old = FollowupPolicy.Observation(reference: ref, excerpt: "旧内容", source: "消息", date: rule.updatedAt.addingTimeInterval(-1))
        #expect(FollowupPolicy.candidates([rule], eligible: [ref], observations: [old], now: now).first?.body.contains("没有取得可验证") == true)
    }
}
