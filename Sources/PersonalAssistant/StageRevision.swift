import Foundation

struct AssistantStageRevisionRecord:Codable,Equatable {
    let previous:AssistantGoalStage
    let replacement:AssistantGoalStage
    let reason:String
    let at:Date
    let previousQuestion:AssistantStageQuestion?
    let previousSupplements:[AssistantStageSupplement]
}
struct StageRevisionDraft:Identifiable {
    let id=UUID()
    let parentID:UUID
    let stageID:UUID
    let expectedRevision:Int
    let expectedChildRevision:Int?
    let original:AssistantGoalStage
    var title:String
    var instruction:String
    var criterion:String
    var actionTool:String
    var requiredInput:String
    var inputTargetKind:String
    var createdTargetReference:AssistantStageCreatedReference? = nil
    var extraFacts:[StageExtraFactDraft]=[]
    var remoteFactEnabled=false
    var remoteProfileID=""
    var remoteTaskID=""
    var remoteStatus="complete"
    var remoteTitle=""
    var remoteTargetID:String {"dingtalk-"+remoteProfileID+"-"+remoteTaskID}
    var factEnabled=false
    var factTargetID=""
    var factStatus="any"
    var factTitle=""
    var semanticPreviewID:UUID? = nil
    var reason=""
    init(parent:AssistantRun,stage:AssistantGoalStage,child:AssistantRun?=nil) {
        parentID=parent.id;stageID=stage.id;expectedRevision=parent.revision;expectedChildRevision=child?.revision;original=stage
        remoteFactEnabled=stage.remoteFactCriterion != nil;remoteProfileID=stage.remoteFactCriterion?.profileID ?? "";remoteTaskID=stage.remoteFactCriterion?.taskID ?? "";remoteStatus=stage.remoteFactCriterion?.expectedStatus ?? "complete";remoteTitle=stage.remoteFactCriterion?.expectedTitle ?? ""
        createdTargetReference=stage.createdTargetReference
        title=stage.title;instruction=stage.instruction;criterion=stage.criterion
        extraFacts=(stage.factCriterion?.allOf ?? []).map{StageExtraFactDraft(targetID:$0.targetID.uuidString,expectedStatus:$0.expectedStatus,expectedTitle:$0.expectedTitle ?? "")}
        factEnabled=stage.factCriterion != nil;factTargetID=stage.factCriterion?.targetID.uuidString ?? "";factStatus=stage.factCriterion?.expectedStatus ?? "any";factTitle=stage.factCriterion?.expectedTitle ?? ""
        actionTool=stage.actionTool ?? "none";requiredInput=stage.requiredInput ?? "none";inputTargetKind=stage.inputTargetKind ?? "personal"
    }
    var replacement:AssistantGoalStage {
        var row=AssistantGoalStage(title:title.trimmingCharacters(in:.whitespacesAndNewlines),instruction:instruction.trimmingCharacters(in:.whitespacesAndNewlines),criterion:criterion.trimmingCharacters(in:.whitespacesAndNewlines),reviewMode:actionTool=="none" ? "read_review" : "confirmed_operation",dependencies:original.dependencies,actionTool:actionTool=="none" ? nil : actionTool,requiredInput:requiredInput=="none" ? nil : requiredInput,inputTargetKind:requiredInput=="target_choice" ? inputTargetKind : nil)
        if factEnabled,let id=UUID(uuidString:factTargetID) {row.factCriterion = .init(targetID:id,expectedStatus:factStatus,expectedTitle:factTitle.isEmpty ? nil : factTitle,allOf:extraFacts.isEmpty ? nil : extraFacts.compactMap{row in guard let id=UUID(uuidString:row.targetID) else {return nil};return .init(targetID:id,expectedStatus:row.expectedStatus,expectedTitle:row.expectedTitle.isEmpty ? nil : row.expectedTitle)})}
        if remoteFactEnabled {row.remoteFactCriterion = .init(profileID:remoteProfileID,taskID:remoteTaskID,expectedStatus:remoteStatus,expectedTitle:remoteTitle.isEmpty ? nil : remoteTitle)}
        row.createdTargetReference=createdTargetReference
        row.id=stageID;row.childRunID=original.childRunID;return row
    }
}
enum StageRevisionPolicy {
    static func editable(parent:AssistantRun,stageID:UUID,rows:[AssistantRun],scope:String) throws -> AssistantGoalStage {
        guard parent.parentRunID==nil,parent.state != .cancelled,parent.scopeHash==scope,let plan=parent.stagePlan,let index=plan.stages.firstIndex(where:{$0.id==stageID}),!plan.stages[index].isComplete,(parent.stageRevisions?.count ?? 0)<4 else {throw ProjectUpdateError.invalid("阶段已完成、目标已结束、范围改变或修订已达4次；原记录保留。")}
        func depends(_ i:Int,on target:Int)->Bool {plan.stages[i].dependencies.contains(target) || plan.stages[i].dependencies.contains{depends($0,on:target)}}
        guard !plan.stages.indices.contains(where:{$0 != index && depends($0,on:index) && plan.stages[$0].childRunID != nil}) else {throw ProjectUpdateError.invalid("后续依赖阶段已经启动，不能覆盖前置条件；请核对已有结果后另建方案。")}
        if let id=plan.stages[index].childRunID {
            guard let child=rows.first(where:{$0.id==id}),child.state != .running,!child.inFlight,child.state != .cancelled,
                  !child.receipts.contains(where:{["completed","unverified"].contains($0.state)}) else {throw ProjectUpdateError.invalid("请先暂停阶段并核对已执行或未知操作结果；不能通过修订覆盖回执。")}
        }
        return plan.stages[index]
    }
    static func request(_ stage:AssistantGoalStage,index:Int)->String {
        let reference=stage.createdTargetReference.map{"本阶段明确引用："+$0.description+"。只能只读核对这条原创建事项，不能默认同名项，也不重新创建。"} ?? ""
        return "执行已采用目标的第\(index+1)阶段「\(stage.title)」。本阶段内容：\(stage.instruction)。完成条件：\(stage.criterion)。只处理当前阶段，不自动推进后续阶段；需要写入时必须生成原确认卡片，不得声称已经执行或自动完成目标。"+reference
    }
    static func fieldCorrection(_ text:String)->(String,String)? {
        for (phrase,key) in [("这个阶段的标题改成","title"),("本阶段标题改为","title"),("这个阶段的完成条件改成","criterion"),("这个阶段的内容改成","instruction")] {
            guard text.hasPrefix(phrase) else {continue}
            let value=String(text.dropFirst(phrase.count)).trimmingCharacters(in:CharacterSet(charactersIn:" ：:「」“”\"。\n"))
            if !value.isEmpty {return(key,value)}
        };return nil
    }
}
extension AssistantRunLedger {
    func reviseStage(_ draft:StageRevisionDraft,scope:String) throws {
        try stageTransaction { rows in
            guard let p=rows.firstIndex(where:{$0.id==draft.parentID}),rows[p].revision==draft.expectedRevision else {throw ProjectUpdateError.invalid("阶段方案已有新版本，请重新打开修改，未覆盖原方案。")}
            let original=try StageRevisionPolicy.editable(parent:rows[p],stageID:draft.stageID,rows:rows,scope:scope)
            guard original==draft.original,let i=rows[p].stagePlan?.stages.firstIndex(where:{$0.id==draft.stageID}) else {throw ProjectUpdateError.invalid("修改所基于的阶段已变化。")}
            let currentChild=original.childRunID.flatMap{id in rows.first{$0.id==id}}
            guard currentChild?.revision==draft.expectedChildRevision else {throw ProjectUpdateError.invalid("阶段运行已有新进展，请重新打开修改预览。")}
            guard draft.extraFacts.count<=3,draft.extraFacts.allSatisfy({UUID(uuidString:$0.targetID) != nil}) else {throw ProjectUpdateError.invalid("请逐项明确选择目标，组合条件最多4个不同ID，未默认选择或丢弃空项。")}
            guard !draft.factEnabled || UUID(uuidString:draft.factTargetID) != nil else {throw ProjectUpdateError.invalid("请明确选择要核对的个人待办，不能默认选择第一项。")}
            let reason=draft.reason.trimmingCharacters(in:.whitespacesAndNewlines),replacement=draft.replacement
            guard !reason.isEmpty,reason.count<=500,replacement != original else {throw ProjectUpdateError.invalid("请填写1—500字修改原因，并作出实际变化。")}
            var plan=rows[p].stagePlan!;plan.stages[i]=replacement;try plan.validate()
            let c=original.childRunID.flatMap { id in rows.firstIndex{$0.id==id} }
            let history=AssistantStageRevisionRecord(previous:original,replacement:replacement,reason:reason,at:Date(),previousQuestion:c.flatMap{rows[$0].stageQuestion},previousSupplements:c.map{rows[$0].stageSupplements ?? []} ?? [])
            rows[p].stageRevisions=(rows[p].stageRevisions ?? [])+[history];rows[p].stagePlan=plan;rows[p].revision+=1;rows[p].updatedAt=Date();rows[p].checkpoint="阶段已修订，旧卡片失效；保留预算，等待手动继续和新结果"
            if let c {
                let superseded=rows[c].receipts.filter{$0.state=="pending"}.map(\.actionID)
                rows[c].supersededActionIDs=(rows[c].supersededActionIDs ?? [])+superseded
                for j in rows[c].receipts.indices where rows[c].receipts[j].state=="pending" {rows[c].receipts[j].state="dismissed"}
                rows[c].stageQuestion=nil;rows[c].stageSupplements=nil;rows[c].stageRevisionPending=true
                rows[c].state = .paused;rows[c].revision+=1;rows[c].updatedAt=Date();rows[c].checkpoint="阶段已修订，旧结果不能用于完成；原预算保留，等待手动继续"
            }
        }
    }
}
