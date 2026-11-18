import Foundation
import Testing
@testable import PersonalAssistant

struct TodoConfirmationTests {
    @Test func completionCommandsDoNotDependOnTaskNoun() {
        for text in ["优先候选把星河原型状态变更为完成","没弹出卡片，你直接标记完成","标记为已完成","请把星河标记完成","把待办改为已完成"] { #expect(TodoConfirmationPolicy.completionCommand(text)) }
        for text in ["不要标记完成","标记完成是什么意思？","如何标记完成","这个已经完成","钉钉待办标记完成","项目设为完成","把待办标题改为完成","标记完成按钮在哪里"] { #expect(!TodoConfirmationPolicy.completionCommand(text)) }
    }
    private func legacy(_ last: String) -> [AssistantMessage] {
        [.init(text:"优先候选把星河原型状态变更为完成",isUser:true),.init(text:"如果是v1_星河原型修改完善，我生成确认卡",isUser:false),.init(text:"是本地这个",isUser:true),.init(text:"你一句话确认我就生成卡片",isUser:false),.init(text:"对",isUser:true),.init(text:"我先打出确认卡",isUser:false),.init(text:last,isUser:true)]
    }
    @Test func legacyAcknowledgementsRecoverUserInstructionNotAssistantPromise() throws {
        let messages = legacy("没弹出卡片，你直接标记完成")
        let value = try #require(TodoConfirmationPolicy.make(messages:messages,scope:"scope"))
        #expect(value.originMessageID == messages[0].id && value.localOnly && value.priorityOnly)
        #expect(value.originalRequest == messages[0].text)
        #expect(TodoConfirmationPolicy.make(messages:legacy("对"),scope:"scope") != nil)
        let noUser: [AssistantMessage] = [.init(text:"聊工作",isUser:true),.init(text:"我生成完成卡片",isUser:false),.init(text:"对",isUser:true)]
        #expect(TodoConfirmationPolicy.make(messages:noUser,scope:"scope") == nil)
    }
    @Test func topicChangeNegationAndReadOnlyDoNotResumeOldCompletion() {
        for text in ["换个话题聊周末","不要完成","只查看状态"] { #expect(TodoConfirmationPolicy.make(messages:legacy(text),scope:"scope") == nil) }
        var messages = legacy("对"); messages.insert(.init(text:"介绍黑洞",isUser:true),at:messages.count-1)
        #expect(TodoConfirmationPolicy.make(messages:messages,scope:"scope") == nil)
    }
    @Test func scopeOrExpiryCannotFallBackToLegacyRecovery() throws {
        var messages = legacy("对"); let value = try #require(TodoConfirmationPolicy.make(messages:messages,scope:"old"))
        messages[messages.count-2].todoConfirmationRequest = value
        #expect(TodoConfirmationPolicy.make(messages:messages,scope:"new") == nil)
        #expect(TodoConfirmationPolicy.blockedContinuation(messages:messages,scope:"new"))
        #expect(TodoConfirmationPolicy.make(messages:messages,scope:"old",now:Date().addingTimeInterval(90000)) == nil)
    }
    @Test func storedBindingSurvivesRestartWithoutTitleRemapping() throws {
        var messages = legacy("对"); var value = try #require(TodoConfirmationPolicy.make(messages:messages,scope:"scope"));let target = UUID();value.boundTargetID = target
        messages[messages.count-2].todoConfirmationRequest = value
        messages = try JSONDecoder().decode([AssistantMessage].self,from:JSONEncoder().encode(messages))
        #expect(TodoConfirmationPolicy.make(messages:messages,scope:"scope")?.boundTargetID == target)
    }
    @Test func cancelledOrDiscussionOnlyChoiceDoesNotReplayCompletion() throws {
        var messages = legacy("对"); let value = try #require(TodoConfirmationPolicy.make(messages:messages,scope:"scope"))
        messages[messages.count-2].todoConfirmationRequest = value
        var action = PendingAssistantAction(summary:"完成旧事项",operation:.completeTodo(id:UUID()));action.status = .dismissed
        var boundValue = value; boundValue.boundTargetID = UUID()
        action.operation = .completeTodo(id:boundValue.boundTargetID!)
        messages[messages.count-2].todoConfirmationRequest = boundValue
        messages[messages.count-2].pendingActions = [action]
        #expect(TodoConfirmationPolicy.make(messages:messages,scope:"scope") == nil)
        var blocked = messages
        blocked.append(.init(text:"原操作已取消",isUser:false,todoConfirmationRequest:boundValue));blocked.append(.init(text:"对",isUser:true))
        #expect(TodoConfirmationPolicy.make(messages:blocked,scope:"scope") == nil)
        messages[messages.count-2].pendingActions = nil
        messages[messages.count-2].conversationFocus = .init(references:[.personal(UUID())],isChoice:false,originMessageID:messages[0].id,selected:[],hidden:[],discussionOnly:true)
        #expect(TodoConfirmationPolicy.make(messages:messages,scope:"scope") == nil)
    }
    private func lookup(_ todos: [PersonalTodo], query: String, local: Bool = true, priority: Bool = false, external: [TodoRecord] = []) -> AssistantReadResult {
        let origin = AssistantMessage(text:"星河状态变更为完成",isUser:true)
        var context = AssistantReadContext(todos:todos,external:external,selected:["org:user"])
        context.todoConfirmationRequest = .init(originMessageID:origin.id,originalRequest:origin.text,scopeHash:"scope",localOnly:local,priorityOnly:priority)
        let data = try! JSONSerialization.data(withJSONObject:["query":query,"state":"all"])
        return context.execute(.init(id:"lookup",function:.init(name:"find_matter",arguments:String(decoding:data,as:UTF8.self))))
    }
    @Test func priorityLookupDoesNotConfuseCompletedHistoryWithOpenTask() {
        let a = PersonalTodo(title:"v1_星河原型修改完善",importance:.high);var b = PersonalTodo(title:"继续星河原型方案设计",importance:.normal);b.isComplete = true
        let result = lookup([a,b],query:"星河原型",priority:true).todoConfirmationLookup
        #expect(result?.binding?.id == a.id && result?.binding?.complete == false)
    }
    @Test func ambiguousAndMissingTargetsDoNotProduceBinding() {
        let rows = (0..<2).map { _ in PersonalTodo(title:"星河评审",importance:.normal) }
        #expect(lookup(rows,query:"星河").todoConfirmationLookup?.binding == nil)
        #expect(lookup(rows,query:"不存在").todoConfirmationLookup?.matchedCount == 0)
        #expect(lookup(rows,query:"星河").todoConfirmationLookup?.clarification.contains("第几个") == true)
    }
    @Test func mixedSourcesRequireLocalChoiceAndCompletedTargetIsNotReopened() {
        var a = PersonalTodo(title:"星河评审",importance:.normal);a.isComplete = true
        let remote = TodoRecord(id:"dingtalk-org:user-a",title:a.title,dueAt:nil,importance:.normal,sourceURL:nil,isComplete:false)
        #expect(lookup([a],query:"星河",local:false,external:[remote]).todoConfirmationLookup?.binding == nil)
        #expect(lookup([a],query:"星河",local:true,external:[remote]).todoConfirmationLookup?.binding?.complete == true)
    }
    @Test func knownLocalCompletionAvoidsRemoteRefreshWithoutBreakingRemoteDiscovery() {
        let local = "请把本地待办接口评审标记完成"
        #expect(!TodoConfirmationPolicy.shouldRefreshExternal(local,messages:[.init(text:local,isUser:true)],scope:"scope"))
        let retry = "没弹出卡片，你直接标记完成"
        #expect(!TodoConfirmationPolicy.shouldRefreshExternal(retry,messages:legacy(retry),scope:"scope"))
        for text in ["修改钉钉待办期限","把待办改期到明天"] {
            #expect(TodoConfirmationPolicy.shouldRefreshExternal(text,messages:[.init(text:text,isUser:true)],scope:"scope"))
        }
    }
    @Test func existingPendingCardIsNotConfirmedByChatAcknowledgement() {
        let id = UUID(), action = PendingAssistantAction(summary:"完成",operation:.completeTodo(id:id))
        let messages = [AssistantMessage(text:"确认卡",isUser:false,pendingActions:[action])]
        #expect(TodoConfirmationPolicy.pendingCard(messages:messages,target:id))
        #expect(!TodoConfirmationPolicy.pendingCard(messages:messages,target:UUID()))
        #expect(messages[0].pendingActions?[0].status == .pending)
    }
}
