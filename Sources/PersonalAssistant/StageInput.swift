import Foundation

struct AssistantStageChoice:Codable,Equatable,Identifiable {
    let reference:MatterReference
    let title:String
    var detail:String? = nil
    static func make(_ target:MatterTarget,todos:[PersonalTodo],projects:[AssistantProject],external:[TodoRecord])->Self {
        var details:[String]=[]
        if let todo=todos.first(where:{target.reference == .personal($0.id)}) {
            details.append(todo.isComplete ? "已完成" : "未完成")
            if let name=todo.projectName,!name.isEmpty {details.append("项目："+String(name.prefix(60)))}
            if let owner=todo.owner,!owner.isEmpty {details.append("负责人："+String(owner.prefix(60)))}
            if let due=todo.dueAt {details.append("期限："+DailyPlanSchedulePolicy.dayKey(for:due))}
        } else if let project=projects.first(where:{target.reference == .project($0.id)}) {
            details.append(String((project.status ?? "状态未提供").prefix(60)))
        } else if let todo=external.first(where:{target.reference.kind=="external" && $0.id==target.reference.id}) {
            details.append(todo.isComplete ? "已完成（快照）" : "未完成（快照）")
        }
        return .init(reference:target.reference,title:String(target.title.prefix(300)),detail:details.isEmpty ? nil : String(details.joined(separator:"；").prefix(300)))
    }
    var id:String {reference.kind+":"+reference.id}
    var label:String {title+"（"+reference.sourceLabel+"，ID尾号"+reference.id.suffix(8)+"）"+(detail.map{" · "+$0} ?? "")}
}
struct AssistantStageQuestion:Codable,Equatable,Identifiable {
    var id=UUID()
    let runID:UUID
    let purpose:String
    let question:String
    let choices:[AssistantStageChoice]
    func validate() throws {
        guard !["密钥","api key","apikey","token","令牌","密码"].contains(where:question.lowercased().contains),["target_choice","missing_details"].contains(purpose), !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, question.count<=600,
              choices.count<=8, Set(choices.map(\.id)).count==choices.count,
              choices.allSatisfy({$0.reference.isValid && !$0.title.isEmpty && $0.title.count<=300 && ($0.detail?.count ?? 0)<=300}),
              purpose=="target_choice" ? !choices.isEmpty : choices.isEmpty else {throw ProjectUpdateError.invalid("阶段补充问题格式无效。")}
    }
    var displayText:String {
        question+(choices.isEmpty ? "" : "\n"+choices.enumerated().map {"\($0.offset+1). \($0.element.label)"}.joined(separator:"\n"))+"\n可直接回复或在问题卡片补充；沿本阶段继续，原预算保留，写入仍须确认。"
    }
    func answer(_ input:String, targets:[MatterTarget]) throws -> (String,MatterReference?) {
        let clean=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !clean.isEmpty,clean.count<=1500 else {throw ProjectUpdateError.invalid("补充内容须为1—1500字，未发送到模型。")}
        guard !StageInputRouting.changesGoal(clean) else {throw ProjectUpdateError.invalid("这条内容涉及修改阶段目标或操作类型，当前阶段不会按旧方案继续执行。请先核对并重新规划；未重置预算或写入。")}
        if purpose=="missing_details" {return(clean,nil)}
        let text=clean.trimmingCharacters(in:CharacterSet(charactersIn:"。！!，, "))
        let numerals=["一","二","三","四","五","六","七","八"]
        var matches:[AssistantStageChoice]=[]
        for (i,c) in choices.enumerated() {
            let n=i+1,cn=numerals[i]
            let names=["\(n)","第\(n)个","第\(n)项","第\(cn)个","第\(cn)项","选\(n)","选第\(cn)个","选择第\(cn)个","我指的是第\(cn)个","是第\(cn)个","就是第\(cn)个"]
            if names.contains(text) || text==c.title || text.localizedCaseInsensitiveContains(c.reference.id) {matches.append(c)}
        }
        if matches.isEmpty {
            let kind=text.contains("钉钉") ? "external" : text.contains("个人") || text.contains("本机") ? "personal" : text.contains("项目") ? "project" : ""
            if !kind.isEmpty {matches=choices.filter{$0.reference.kind==kind}}
        }
        guard matches.count==1, let choice=matches.first else {throw ProjectUpdateError.invalid("请明确选择列出的一个编号、精确ID或唯一来源；没有默认选第一项。")}
        guard let current=targets.first(where:{$0.reference==choice.reference}) else {throw ProjectUpdateError.invalid("所选事项已删除、隐藏或不在当前来源中，请重新核对。")}
        return("用户针对原问题明确选择：kind=\(choice.reference.kind)，target_id=\(choice.reference.id)，当前标题：\(current.title)。原回复：\(clean)",choice.reference)
    }
}
struct AssistantStageSupplement:Codable,Equatable {
    let questionID:UUID
    let messageID:UUID
    let text:String
    let selected:MatterReference?
}
enum StageInputRouting {
    enum Decision:Equatable {case ordinary;case answer(UUID);case blocked(String)}
    static func changesGoal(_ text:String)->Bool {
        ["换个目标","改目标","修改阶段目标","更改阶段目标","阶段目标改","这个阶段改成","这个阶段改为","取消这个阶段","结束这个阶段"].contains(where:text.contains)
    }
    static func decide(text:String,messages:[AssistantMessage],runs:[AssistantRun])->Decision {
        let clean=text.trimmingCharacters(in:.whitespacesAndNewlines)
        if ["换个话题","先不管这个","新问题","另外问","另起目标","独立问题"].contains(where:clean.contains) || ["你好","谢谢","好的","明白了","知道了","晚安"].contains(clean) {return .ordinary}
        let active=runs.filter {r in r.parentRunID != nil && r.stageQuestion != nil && r.state != .cancelled && runs.contains {p in p.id==r.parentRunID && p.state != .cancelled && p.stagePlan?.stages.contains(where:{$0.childRunID==r.id && !$0.isComplete})==true}}
        if let latest=messages.last(where:{!$0.isUser}), let q=latest.stageQuestion {
            if (clean.contains("？") || clean.contains("?")) && !["补充","本阶段","这个阶段","你的问题","第一个","第二个"].contains(where:clean.contains) {return .ordinary}
            guard active.contains(where:{$0.id==q.runID && $0.stageQuestion?.id==q.id}) else {return .blocked("原阶段或这张提问已经结束、处理或失效，不能把简短回复当作新目标继续旧操作。若要开始新任务，请明确说明新请求。")}
            if changesGoal(clean) {return .blocked("这条内容涉及更改阶段目标。请先结束旧目标并重新确认阶段方案；已有记录和已执行结果保留，不会按旧指令继续执行。")}
            return .answer(q.runID)
        }
        if ["补充本阶段","补充这个阶段","继续本阶段"].contains(where:clean.contains) {
            if active.count==1 {return .answer(active[0].id)}
            if active.count>1 {return .blocked("有多个阶段等待补充，请在对应问题卡片中回答，不能默认选择第一项。")}
        }
        return .ordinary
    }
}
enum StageQuestionTool {
    static let name="request_stage_input"
    static var definition:DeepSeekToolDefinition {
        typealias P=DeepSeekToolDefinition.Parameters.Property
        let target=P(type:"object",description:"Exact authorized existing matter; no guessed IDs",enumValues:nil,properties:["kind":P(type:"string",description:"Source kind",enumValues:["personal","external","project"]),"target_id":P(type:"string",description:"Exact known ID",enumValues:nil)],required:["kind","target_id"])
        return .init(function:.init(name:name,description:"Pause this stage to ask for REQUIRED missing information or an ambiguous target. Use this instead of an unstructured question. Does not execute, complete, replan, expand tools or reset budget. Choices must be known current targets; local todo write stages accept personal targets only. Ask only necessary data, never credentials/Key/token, and do not ask optional due dates when user said none. User's answer will resume this SAME stage. Do not combine with write proposals.",parameters:.init(properties:["purpose":P(type:"string",description:"Clarification type",enumValues:["target_choice","missing_details"]),"question":P(type:"string",description:"One concise necessary question,1-600 chars",enumValues:nil),"candidates":P(type:"array",description:"1-8 exact targets for target_choice; [] for missing_details",enumValues:nil,items:target)],required:["purpose","question","candidates"])))
    }
    static func initial(stage:AssistantGoalStage,run:AssistantRun,targets:[MatterTarget],todos:[PersonalTodo],projects:[AssistantProject],external:[TodoRecord])->AssistantStageQuestion? {
        guard (run.modelRequests==0 || run.stageRevisionPending==true),(run.stageSupplements ?? []).isEmpty else {return nil}
        if stage.requiredInput=="todo_title" {
            return .init(runID:run.id,purpose:"missing_details",question:"这条个人待办的标题是什么？其他已明确的信息沿用原阶段，不需要重述整个目标。",choices:[])
        }
        if stage.requiredInput=="target_choice" {
            let known=targets.filter {stage.instruction.localizedCaseInsensitiveContains($0.reference.id)}
            if known.count==1 {return nil}
            let matches=targets.filter {stage.inputTargetKind=="any" || $0.reference.kind==stage.inputTargetKind}
            guard !matches.isEmpty,matches.count<=8 else {return .init(runID:run.id,purpose:"missing_details",question:"当前候选为空或超过8项，请补充要核对事项的明确标题或已知ID，先缩小本阶段范围。",choices:[])}
            return .init(runID:run.id,purpose:"target_choice",question:"本阶段需要明确核对哪一项，请从当前候选中选择：",choices:matches.map{AssistantStageChoice.make($0,todos:todos,projects:projects,external:external)})
        }
        return nil
    }
    static func legacyQuestion(_ text:String,run:AssistantRun)->AssistantStageQuestion? {
        let clean=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard run.parentRunID != nil,!clean.isEmpty,clean.count<=600,
              ["请告诉","请补充","请提供","需要你提供","标题是什么","想叫什么","请选择","哪一个","哪一条"].contains(where:clean.contains),
              !["已经创建","已创建","已经完成","已完成","操作成功"].contains(where:clean.contains) else {return nil}
        let q=AssistantStageQuestion(runID:run.id,purpose:"missing_details",question:clean,choices:[])
        guard (try? q.validate()) != nil else {return nil};return q
    }
    static func make(_ call:DeepSeekToolCall,runID:UUID,targets:[MatterTarget],details:[MatterReference:AssistantStageChoice]=[:])->AssistantReadResult {
        do {
            guard Set(targets.map(\.reference)).count==targets.count,call.function.arguments.utf8.count<=6000,let a=try JSONSerialization.jsonObject(with:Data(call.function.arguments.utf8)) as? [String:Any],Set(a.keys)==["purpose","question","candidates"],
                  let purpose=a["purpose"] as? String,let text=a["question"] as? String,let raw=a["candidates"] as? [[String:Any]],
                  !["密钥","api key","apikey","token","令牌","密码"].contains(where:text.lowercased().contains) else {throw DingTalkContentError.invalidResponse}
            let choices=try raw.map {r->AssistantStageChoice in
                guard Set(r.keys)==["kind","target_id"],let kind=r["kind"] as? String,let id=r["target_id"] as? String,let target=targets.first(where:{$0.reference == .init(kind:kind,id:id)}) else {throw DingTalkContentError.invalidResponse}
                return details[target.reference] ?? .init(reference:target.reference,title:String(target.title.prefix(300)))
            }
            let q=AssistantStageQuestion(runID:runID,purpose:purpose,question:text,choices:choices);try q.validate()
            return .init(content:"{\"state\":\"awaiting_stage_input\",\"writes_executed\":0}",stageQuestion:q)
        } catch {return .init(content:"{\"error\":\"invalid_stage_question\",\"hint\":\"Ask one required question, use exact current candidate IDs and no credentials; correct within remaining budget.\"}")}
    }
}
