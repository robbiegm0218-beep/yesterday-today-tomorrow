import Foundation

struct AssistantStageFactRequirement:Codable,Equatable {
    let targetID:UUID
    let expectedStatus:String
    let expectedTitle:String?
    var criterion:AssistantStageFactCriterion {.init(targetID:targetID,expectedStatus:expectedStatus,expectedTitle:expectedTitle)}
}
struct StageExtraFactDraft:Identifiable {
    var id=UUID()
    var targetID=""
    var expectedStatus="any"
    var expectedTitle=""
}
struct AssistantStageFactComponent:Codable,Equatable {
    let targetID:UUID
    let status:String
    let observedTitle:String?
    let observedComplete:Bool?
    let reason:String
    let gaps:[String]
    var label:String {["satisfied":"满足","unsatisfied":"未满足","unknown":"未知"][status] ?? "未知"}
    func validate(requirement:AssistantStageFactRequirement) throws {
        guard targetID==requirement.targetID,["satisfied","unsatisfied","unknown"].contains(status),!reason.isEmpty,reason.count<=500,
              gaps.count<=3,Set(gaps).count==gaps.count,gaps.allSatisfy({["source_unavailable","target_missing","target_invalid","status_mismatch","title_mismatch"].contains($0)}),
              status=="unknown" ? observedTitle==nil && observedComplete==nil && !gaps.isEmpty : observedTitle?.isEmpty==false && (observedTitle?.count ?? 0)<=300 && observedComplete != nil else {throw ProjectUpdateError.invalid("组合条件的逐项结果无效。")}
        if status=="unknown" {guard gaps.count==1,["source_unavailable","target_missing","target_invalid"].contains(gaps[0]) else {throw ProjectUpdateError.invalid("未知条件的原因无效。")}}
        if status != "unknown",let title=observedTitle,let complete=observedComplete {
            let matched=(requirement.expectedStatus=="any" || (requirement.expectedStatus=="complete" ? complete : !complete)) && (requirement.expectedTitle==nil || requirement.expectedTitle==title)
            var expected:[String]=[]
            if (requirement.expectedStatus=="complete" && !complete) || (requirement.expectedStatus=="open" && complete) {expected.append("status_mismatch")}
            if let wanted=requirement.expectedTitle,wanted != title {expected.append("title_mismatch")}
            guard Set(expected)==Set(gaps) else {throw ProjectUpdateError.invalid("组合条件缺口与实际字段不一致。")}
            guard matched == (status=="satisfied") else {throw ProjectUpdateError.invalid("组合条件结论与读取字段不一致。")}
        }
    }
}
extension AssistantStageFactCriterion {
    var requirements:[AssistantStageFactRequirement] {[.init(targetID:targetID,expectedStatus:expectedStatus,expectedTitle:expectedTitle)]+(allOf ?? [])}
}
enum StageCompositeFactPolicy {
    static func status(_ components:[AssistantStageFactComponent])->String {
        if components.contains(where:{$0.status=="unknown"}) {return "unknown"}
        return components.allSatisfy{$0.status=="satisfied"} ? "satisfied" : "unsatisfied"
    }
    static func read(stage:AssistantGoalStage,directory:URL,now:Date)->AssistantStageFactCheck? {
        guard let criterion=stage.factCriterion,criterion.allOf != nil else {return nil}
        // Every condition uses this ONE current file read, never separate snapshots.
        let url=directory.appendingPathComponent("personal-todos.json")
        let todos:[PersonalTodo]?
        if let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=8_000_000,
           let bytes=try? Data(contentsOf:url),bytes.count<=8_000_000,let rows=try? JSONDecoder().decode([PersonalTodo].self,from:bytes),Set(rows.map(\.id)).count==rows.count {todos=rows} else {todos=nil}
        let parts=criterion.requirements.map {rule->AssistantStageFactComponent in
            func unknown(_ code:String,_ reason:String)->AssistantStageFactComponent {.init(targetID:rule.targetID,status:"unknown",observedTitle:nil,observedComplete:nil,reason:reason,gaps:[code])}
            guard let todos else {return unknown("source_unavailable","当前文件无法读取或格式异常，不使用内存或恢复副本。")}
            guard let todo=todos.first(where:{$0.id==rule.targetID}) else {return unknown("target_missing","当前文件未找到精确ID，不用同名项替代。")}
            guard !todo.title.isEmpty,todo.title.count<=300 else {return unknown("target_invalid","原ID记录内容异常，暂不能核对。")}
            var gaps:[String]=[]
            if (rule.expectedStatus=="complete" && !todo.isComplete) || (rule.expectedStatus=="open" && todo.isComplete) {gaps.append("status_mismatch")}
            if let title=rule.expectedTitle,title != todo.title {gaps.append("title_mismatch")}
            return .init(targetID:todo.id,status:gaps.isEmpty ? "satisfied" : "unsatisfied",observedTitle:todo.title,observedComplete:todo.isComplete,reason:gaps.isEmpty ? "当前字段满足此项条件。" : gaps.map{$0=="status_mismatch" ? "状态与期望不一致" : "标题与期望不一致"}.joined(separator:"；"),gaps:gaps)
        }
        let result=status(parts),known=parts.filter{$0.status=="satisfied"}.count,unmet=parts.filter{$0.status=="unsatisfied"}.count,unknown=parts.filter{$0.status=="unknown"}.count
        let reason="共\(parts.count)项：\(known)项满足、\(unmet)项未满足、\(unknown)项未知。"+(result=="satisfied" ? "已配置字段全部满足，其他文字条件仍须人工核对。" : "只有全部字段满足才能确认阶段；不自动修改任何事项。")
        return .init(criterionHash:StageFactPolicy.hash(stage),status:result,checkedAt:now,source:"personal-todos.json",targetID:criterion.targetID,observedTitle:parts.first?.observedTitle,observedComplete:parts.first?.observedComplete,reason:reason,gaps:Array(Set(parts.flatMap(\.gaps))).sorted(),components:parts)
    }
}
