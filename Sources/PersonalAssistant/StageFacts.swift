import Foundation

struct AssistantStageFactCriterion:Codable,Equatable {
    let targetID:UUID
    let expectedStatus:String
    let expectedTitle:String?
    var allOf:[AssistantStageFactRequirement]? = nil
    func validate() throws {
        if let allOf {
            guard (1...3).contains(allOf.count),Set([targetID]+allOf.map(\.targetID)).count==allOf.count+1 else {throw ProjectUpdateError.invalid("组合条件最多4个不同的个人待办ID，不能重复或冲突。")}
            for rule in allOf {try rule.criterion.validate()}
        }
        guard ["any","open","complete"].contains(expectedStatus),expectedTitle.map({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count<=300}) ?? true else {throw ProjectUpdateError.invalid("事实条件只支持个人待办的精确ID、存在/未完成/已完成和最多300字的标题。")}
    }
    var description:String {
        let state=["any":"存在","open":"未完成","complete":"已完成"][expectedStatus] ?? "未知"
        return "个人待办ID "+targetID.uuidString+"；期望："+state+(expectedTitle.map{"；标题："+$0} ?? "")+(allOf.map{"；且同时满足："+$0.map{$0.criterion.description}.joined(separator:"；且")} ?? "")
    }
}
struct AssistantStageFactCheck:Codable,Equatable {
    let criterionHash:String
    let status:String
    let checkedAt:Date
    let source:String
    let targetID:UUID
    let observedTitle:String?
    let observedComplete:Bool?
    let reason:String
    var gaps:[String]? = nil
    var components:[AssistantStageFactComponent]? = nil
    var label:String {["satisfied":"满足","unsatisfied":"未满足","unknown":"未知"][status] ?? "未知"}
    func validate(stage:AssistantGoalStage) throws {
        guard let criterion=stage.factCriterion,criterionHash==StageFactPolicy.hash(stage),targetID==criterion.targetID,
              ["satisfied","unsatisfied","unknown"].contains(status),source=="personal-todos.json",checkedAt.timeIntervalSince1970.isFinite,
              !reason.isEmpty,reason.count<=500,(observedTitle?.count ?? 0)<=300,
              components != nil || status=="unknown" || (observedTitle != nil && observedComplete != nil) else {throw ProjectUpdateError.invalid("阶段事实复核归属、条件版本或结果无效。")}
        if let gaps {guard gaps.count<=(criterion.allOf==nil ? 3 : 5),Set(gaps).count==gaps.count,gaps.allSatisfy({["source_unavailable","target_missing","target_invalid","status_mismatch","title_mismatch"].contains($0)}) else {throw ProjectUpdateError.invalid("事实缺口代码无效。")}}
        if let components {
            guard criterion.allOf != nil,components.count==criterion.requirements.count,components.map(\.targetID)==criterion.requirements.map(\.targetID),status==StageCompositeFactPolicy.status(components),observedTitle==components.first?.observedTitle,observedComplete==components.first?.observedComplete,Set(gaps ?? [])==Set(components.flatMap(\.gaps)) else {throw ProjectUpdateError.invalid("组合条件总结果与逐项读取不一致。")}
            for (part,rule) in zip(components,criterion.requirements) {try part.validate(requirement:rule)}
            return
        }
        guard criterion.allOf==nil else {throw ProjectUpdateError.invalid("组合条件缺少逐项核对结果。")}
        if status != "unknown",let complete=observedComplete,let title=observedTitle {
            let matches=(criterion.expectedStatus=="any" || (criterion.expectedStatus=="complete" ? complete : !complete)) && (criterion.expectedTitle==nil || criterion.expectedTitle==title)
            guard (status=="satisfied")==matches else {throw ProjectUpdateError.invalid("复核结论与实际读取字段不一致。")}
        }
    }
}
enum StageFactPolicy {
    static func hash(_ stage:AssistantGoalStage)->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let reference=stage.createdTargetReference.map{String(decoding:(try? encoder.encode($0)) ?? Data(),as:UTF8.self)} ?? ""
        return AssistantRun.digest(stage.id.uuidString+stage.instruction+stage.criterion+String(decoding:(try? encoder.encode(stage.factCriterion)) ?? Data(),as:UTF8.self)+reference)
    }
    static func read(stage:AssistantGoalStage,directory:URL=LocalAssistantPaths.dataDirectory,now:Date=Date())->AssistantStageFactCheck? {
        guard let criterion=stage.factCriterion else {return nil}
        if criterion.allOf != nil {return StageCompositeFactPolicy.read(stage:stage,directory:directory,now:now)}
        func result(_ status:String,_ reason:String,_ todo:PersonalTodo?=nil,gaps:[String]=[])->AssistantStageFactCheck {
            .init(criterionHash:hash(stage),status:status,checkedAt:now,source:"personal-todos.json",targetID:criterion.targetID,observedTitle:todo?.title,observedComplete:todo?.isComplete,reason:reason,gaps:gaps)
        }
        let url=directory.appendingPathComponent("personal-todos.json")
        // Do not substitute an in-memory or recovery snapshot for a fresh read.
        guard let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=8_000_000,
              let data=try? Data(contentsOf:url),data.count<=8_000_000,
              let todos=try? JSONDecoder().decode([PersonalTodo].self,from:data),Set(todos.map(\.id)).count==todos.count else {
            return result("unknown","当前个人待办文件缺失、无法读取或格式异常；未使用旧回复、内存或恢复副本判定满足。",gaps:["source_unavailable"])
        }
        guard let todo=todos.first(where:{$0.id==criterion.targetID}) else {return result("unknown","当前文件未能定位该精确ID，不按同名事项替代，也不推断已完成。",gaps:["target_missing"])}
        if let reference=stage.createdTargetReference {
            guard todo.id==reference.targetID,todo.sourceActionID==reference.actionID,todos.filter({$0.sourceActionID==reference.actionID}).count==1 else {return result("unknown","引用的原ID与创建来源不一致或操作标记重复；不按同名项改绑，不重新创建。",gaps:["target_invalid"])}
        }
        guard !todo.title.isEmpty,todo.title.count<=300 else {return result("unknown","该精确ID内容异常，暂不能核对。",gaps:["target_invalid"])}
        var gaps:[String]=[],codes:[String]=[]
        if criterion.expectedStatus=="open",todo.isComplete {gaps.append("期望未完成，当前已完成");codes.append("status_mismatch")}
        if criterion.expectedStatus=="complete",!todo.isComplete {gaps.append("期望已完成，当前未完成");codes.append("status_mismatch")}
        if let title=criterion.expectedTitle,title != todo.title {gaps.append("标题与期望不一致");codes.append("title_mismatch")}
        return result(gaps.isEmpty ? "satisfied" : "unsatisfied",gaps.isEmpty ? "当前记录满足已配置的结构化字段；其他文字条件仍须人工核对，不自动完成阶段或原事项。" : gaps.joined(separator:"；"),todo,gaps:codes)
    }
}
extension AssistantRunLedger {
    @discardableResult func checkStageFacts(parentID:UUID,stageID:UUID,scope:String,directory:URL=LocalAssistantPaths.dataDirectory,selectedRecheck:Bool=false) throws ->AssistantStageFactCheck {
            var result:AssistantStageFactCheck?
            try stageTransaction { rows in
                guard let p=rows.firstIndex(where:{$0.id==parentID}),rows[p].scopeHash==scope,rows[p].state != .cancelled,
                      let i=rows[p].stagePlan?.stages.firstIndex(where:{$0.id==stageID}),rows[p].stagePlan?.stages[i].isComplete==false,
                      let childID=rows[p].stagePlan?.stages[i].childRunID,let child=rows.first(where:{$0.id==childID}),child.state != .running,child.state != .cancelled,!child.inFlight,
                      let checked=StageFactPolicy.read(stage:rows[p].stagePlan!.stages[i],directory:directory) else {throw ProjectUpdateError.invalid("阶段尚未启动、正在执行、已结束、范围变化或未配置事实条件，未复核。")}
                var stage=rows[p].stagePlan!.stages[i]
                let old=stage.nextStep,newSignature=StageNextStepPolicy.signature(checked)
                let same=(old?.proofSignature ?? stage.factCheck.map(StageNextStepPolicy.signature))==newSignature
                stage.factCheck=checked
                let attempts=same ? min(1,(old?.rechecks ?? 0)+(selectedRecheck ? 1 : 0)) : 0
                stage.nextStep = .init(kind:.query,reason:"待选择",proofSignature:newSignature,rechecks:attempts,clarificationUsed:old?.clarificationUsed ?? false,verifiedReceiptIDs:child.receipts.filter{$0.state=="completed"}.map(\.actionID))
                stage.nextStep=StageNextStepPolicy.decide(stage:stage,child:child,parentState:rows[p].state)
                rows[p].stagePlan!.stages[i]=stage;rows[p].revision+=1;rows[p].updatedAt=Date();result=checked
            }
            return result!
    }
}
