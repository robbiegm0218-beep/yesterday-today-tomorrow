import Foundation

struct AssistantStageCreatedReference:Codable,Equatable {
    let sourceStageID:UUID
    let actionID:UUID
    let targetID:UUID
    var description:String {"前阶段原创建卡片 "+actionID.uuidString+"；个人待办精确ID "+targetID.uuidString}
}
struct StageCreatedReferenceCandidate:Identifiable {
    let reference:AssistantStageCreatedReference
    let label:String
    var id:UUID {reference.actionID}
}
enum StageCreatedReferencePolicy {
    static func requested(_ text:String)->Bool {
        let clean=text.trimmingCharacters(in:CharacterSet(charactersIn:" 。！!\n"))
        return ["下一阶段用刚创建的那个","下一阶段引用刚创建的待办","下一阶段引用刚创建的那个","下一阶段用刚创建的待办"].contains(clean)
    }
    static func depends(_ index:Int,on source:Int,plan:AssistantGoalStagePlan)->Bool {
        guard index>source,index<plan.stages.count,source>=0 else {return false}
        return plan.stages[index].dependencies.contains(source) || plan.stages[index].dependencies.filter{$0>=0 && $0<index}.contains{depends($0,on:source,plan:plan)}
    }
    static func validate(_ reference:AssistantStageCreatedReference,stage:AssistantGoalStage,index:Int,plan:AssistantGoalStagePlan) throws {
        guard stage.reviewMode=="read_review",stage.actionTool==nil,stage.requiredInput==nil,stage.factCriterion?.allOf==nil,stage.factCriterion?.targetID==reference.targetID,
              let source=plan.stages.firstIndex(where:{$0.id==reference.sourceStageID}),depends(index,on:source,plan:plan),plan.stages[source].isComplete,
              plan.stages[source].actionTool==CreatedTodoReceiptPolicy.operationKind else {throw ProjectUpdateError.invalid("跨阶段引用必须来自已核对的前置创建阶段，且只读核对同一精确目标。")}
    }
    static func candidates(parent:AssistantRun,stageID:UUID,rows:[AssistantRun])->[StageCreatedReferenceCandidate] {
        guard parent.state != .cancelled,let plan=parent.stagePlan,let index=plan.stages.firstIndex(where:{$0.id==stageID}) else {return []}
        return plan.stages.enumerated().flatMap {source,stage->[StageCreatedReferenceCandidate] in
            guard depends(index,on:source,plan:plan),stage.isComplete,stage.actionTool==CreatedTodoReceiptPolicy.operationKind,
                  let child=rows.first(where:{$0.id==stage.childRunID}) else {return []}
            return child.receipts.compactMap {receipt in
                guard receipt.operationKind==CreatedTodoReceiptPolicy.operationKind,receipt.state=="completed",let result=receipt.createdTodo,let target=result.targetID else {return nil}
                return .init(reference:.init(sourceStageID:stage.id,actionID:receipt.actionID,targetID:target),label:"引用第\(source+1)阶段："+(result.observedTitle ?? "原创建事项")+" · "+String(target.uuidString.suffix(8)))
            }
        }
    }
    static func requireCurrent(_ stage:AssistantGoalStage,directory:URL=LocalAssistantPaths.dataDirectory) throws {
        guard stage.createdTargetReference != nil else {return}
        guard let proof=StageFactPolicy.read(stage:stage,directory:directory),proof.status != "unknown" else {throw ProjectUpdateError.invalid("所引用的原创建事项当前无法按精确ID及来源核对；未启动或继续模型请求，不替换同名项、不重新创建。")}
    }
}
