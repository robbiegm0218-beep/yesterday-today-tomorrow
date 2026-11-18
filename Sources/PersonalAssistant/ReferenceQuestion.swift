import Foundation

struct ReferenceQuestionPending: Codable, Equatable {
    let runID: UUID
    let originMessageID: UUID
    let originalRequest: String
    let question: String
    let scopeHash: String
}
struct ReferenceQuestionContext {
    let reference: SemanticReferenceContext
    let pending: ReferenceQuestionPending
    var binding: SemanticReferenceResolution? = nil
    var blocked: String? = nil
    var localInterpretation: String? = nil
    var focusOnly = false
    static let name = "resolve_reference_question"
    static var definition: DeepSeekToolDefinition {
        .init(function:.init(name:name,description:"Resolve a qualified reference for the current WHOLE read-only question, preserved verbatim by the application. Use EXACT enum names and 1-based integer position. For 未完成的里面第二个 use mode=state_then_position, position=2, state=open. For 刚才第二个没完成的 with unclear order use mode=unclear_position_state, position=2, state=open. Never invent mode aliases. Original displayed list only. Use unclear_position_state when ordinal/status ordering is not explicit; never silently choose. No business write or remote refresh. A unique match will be read locally and the original question answered; ambiguity asks first and preserves the whole question.",parameters:SemanticReferenceContext.definition.function.parameters))
    }

    static func readQuestion(_ text: String) -> Bool {
        !["换话题","换个话题","另外问"].contains(where:text.contains) &&
        ["谁","负责","什么时候","截止","几号","进展","进度","详情","什么","怎么","下一步","优先级","状态","依据","阻塞","情况","？","?"].contains(where:text.contains)
    }
    static func hasMutation(_ text: String) -> Bool {
        let text = ReferenceExclusion.questionTail(text) ?? text
        return ["标记","改成","改为","修改","更新","删除","创建","新建","添加","重开","恢复为","取消","安排","生成卡片","生成确认卡","提醒我","发送","同步到","完成它","完成这","勾掉"].contains(where:text.contains)
    }
    static func continuationRunID(messages:[AssistantMessage],request:String) -> UUID? {
        guard AssistantConversationFocus.selection(request) != nil else {return nil}
        return messages.last?.referenceQuestionPending?.runID
    }
    static func make(messages:[AssistantMessage],context:AssistantReadContext,scope:String,runID:UUID,now:Date=Date()) -> Self? {
        guard let user=messages.last,user.isUser,messages.count>1 else {return nil}
        let previous=messages[messages.count-2]
        if let pending=previous.referenceQuestionPending, AssistantConversationFocus.selection(user.text) != nil {
            let empty = SemanticReferenceContext(request:pending.originalRequest,rows:[],current:nil,unavailable:true)
            func blocked(_ reason:String) -> Self { .init(reference:empty,pending:pending,blocked:reason) }
            guard pending.runID==runID,pending.scopeHash==scope,
                  let origin=messages.suffix(12).first(where:{$0.id==pending.originMessageID && $0.isUser}),origin.text==pending.originalRequest,
                  now.timeIntervalSince(origin.time)>=0,now.timeIntervalSince(origin.time)<86400,
                  !pending.question.isEmpty,pending.question.count<=400,pending.originalRequest.contains(pending.question),!hasMutation(pending.question),
                  let focus=previous.conversationFocus,focus.isChoice,focus.originMessageID==origin.id else {return blocked("原问题的来源范围、时效或原消息已变化，未继续回答；请重新明确事项与问题。")}
            let targets=MatterContextPolicy.targets(todos:context.todos,projects:context.projects,external:context.external.filter{!$0.isPersonal && !context.hidden.contains($0.id) && WorkbenchArchivePolicy.belongsToSelectedOrganization($0.id,selected:context.selected)})
            guard let options=focus.resolve(messages:messages,targets:targets,selected:context.selected,hidden:context.hidden,now:now,forChoice:true),
                  case let .number(number)=AssistantConversationFocus.selection(user.text),number>0,number<=options.count else {return blocked("请按原澄清列表选择一个有效编号；原ID不可用时不能按同名项替代。")}
            let rows=options.enumerated().map {index,target in SemanticReferenceCandidate(position:index+1,reference:target.reference,title:target.title,localComplete:context.todos.first{.personal($0.id)==target.reference}?.isComplete)}
            let reference=SemanticReferenceContext(request:pending.originalRequest,rows:rows,current:nil,unavailable:false)
            return .init(reference:reference,pending:pending,binding:.init(status:"resolved",candidates:[rows[number-1]],original:rows.map(\.reference),reason:"按原澄清列表的明确编号续接原问题。"))
        }
        if user.text.count<=400,SemanticReferenceContext.needsInterpretation(user.text),
           let reference=SemanticReferenceContext.make(messages:messages,context:context,now:now) {
            let pending=ReferenceQuestionPending(runID:runID,originMessageID:user.id,originalRequest:user.text,question:user.text,scopeHash:scope)
            switch ReferenceExclusion.parse(user.text) {
            case .none: break
            case let .invalid(reason): return .init(reference:reference,pending:pending,blocked:reason,localInterpretation:"original_list_exclusion_invalid")
            case let .plan(plan):
                if hasMutation(user.text) {return .init(reference:reference,pending:pending,blocked:"本句还包含业务修改，请先明确只读问题；未生成或执行操作。",localInterpretation:"original_list_exclusion_mixed_write")}
                return .init(reference:reference,pending:pending,binding:ReferenceExclusion.resolution(plan,reference:reference),localInterpretation:"original_list_exclusion;excluded="+plan.excluded.map(String.init).joined(separator:",")+";included="+(plan.included.map(String.init) ?? "none"),focusOnly:!readQuestion(plan.question))
            }
        }
        guard user.text.count <= 400,readQuestion(user.text),!hasMutation(user.text),SemanticReferenceContext.needsInterpretation(user.text),
              let reference=SemanticReferenceContext.make(messages:messages,context:context,now:now) else {return nil}
        return .init(reference:reference,pending:.init(runID:runID,originMessageID:user.id,originalRequest:user.text,question:user.text,scopeHash:scope))
    }
    func resolve(_ calls:[DeepSeekToolCall]) -> (SemanticReferenceResolution,ReferenceQuestionPending)? {
        guard calls.count==1,let call=calls.first,call.function.name==Self.name,
              reference.request == pending.question, pending.question.count <= 400,
              let resolved=reference.execute(.init(id:call.id,function:.init(name:SemanticReferenceContext.name,arguments:call.function.arguments))).semanticReference else {return nil}
        return (resolved,pending)
    }
    static func answerQuestion(_ original:String) -> String {
        if let tail=ReferenceExclusion.questionTail(original),readQuestion(tail),!hasMutation(tail) {return tail}
        // Remove only a leading already-resolved reference clause, never a question/field.
        if let range=original.rangeOfCharacter(from:CharacterSet(charactersIn:"，,；;")) {
            let prefix=String(original[..<range.lowerBound]),tail=String(original[range.upperBound...]).trimmingCharacters(in:.whitespacesAndNewlines)
            if SemanticReferenceContext.needsInterpretation(prefix),!readQuestion(prefix),readQuestion(tail) {return tail}
        }
        return original
    }
    static func trace(_ calls:[DeepSeekToolCall]) -> String {
        guard calls.count==1,let call=calls.first,let args=(try? JSONSerialization.jsonObject(with:Data(call.function.arguments.utf8))) as? [String:Any] else {return "invalid_tool_batch"}
        return ["mode","position","state"].map {key in key+"="+String(String(describing:args[key] ?? "missing").prefix(60))}.joined(separator:";")
    }
    static func facts(_ resolution:SemanticReferenceResolution,context:AssistantReadContext) -> String? {
        guard resolution.status=="resolved",resolution.candidates.count==1,let row=resolution.candidates.first,
              let data=try? JSONSerialization.data(withJSONObject:["kind":row.reference.kind,"target_id":row.reference.id]) else {return nil}
        let result=context.execute(.init(id:"bound-question-facts",function:.init(name:"read_matter",arguments:String(decoding:data,as:UTF8.self)))).content
        guard let object=(try? JSONSerialization.jsonObject(with:Data(result.utf8))) as? [String:Any],object["error"]==nil,object["target_id"] as? String==row.reference.id else {return nil}
        return result
    }
}
