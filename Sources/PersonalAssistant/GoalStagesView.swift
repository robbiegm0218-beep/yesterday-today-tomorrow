import SwiftUI

struct GoalPlanProposalView:View {
    @EnvironmentObject private var model:AssistantModel
    let messageID:UUID
    let plan:AssistantGoalStagePlan
    private var owner:AssistantRun? {model.assistantRuns.first { $0.stagePlan?.id==plan.id }}
    private var installed:Bool {owner != nil}
    private func dependencyDescription(_ stage:AssistantGoalStage) -> String {
        let dependencies=stage.dependencies.isEmpty ? "无" : stage.dependencies.map { String($0+1) }.joined(separator:"、")
        let review=stage.reviewMode=="confirmed_operation" ? "需\(stage.actionLabel)确认回执并人工核对" : "需人工核对结果"
        return "依赖：\(dependencies) · \(review)"
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("分阶段方案 · "+(owner?.state == .cancelled ? "已结束" : installed ? "已采用" : plan.status=="dismissed" ? "已取消" : "待采用")).font(.system(size:13,weight:.medium))
            ForEach(Array((owner?.stagePlan ?? plan).stages.enumerated()),id:\.element.id) { index,stage in
                VStack(alignment:.leading,spacing:3) {
                    Text("\(index+1). "+stage.title).fontWeight(.medium)
                    Text(stage.instruction)
                    if let required=stage.requiredInput {Text("启动时还需补充："+(required=="todo_title" ? "待办标题" : "选择具体事项（"+(stage.inputTargetKind ?? "")+"）"))}
                    Text("完成条件："+stage.criterion)
                    if let criterion=stage.factCriterion {Text("可核实字段："+criterion.description+"；其余文字条件仍需人工核对。")}
                    Text(dependencyDescription(stage))
                }.font(.system(size:11)).padding(.vertical,3)
            }
            Text("采用仅保存方案，不创建业务任务。最多4阶段；每阶段沿用4轮/6次读取/90秒/64000 token预算；含规划总上限20轮/30次读取/450秒/320000 token（停止调用可能有未知用量）。每阶段手动启动，核对后才能推进。")
                .font(.system(size:10)).foregroundStyle(.secondary)
            if !installed && plan.status=="pending" {
                HStack {
                    Button("采用阶段方案") {model.confirmGoalPlan(messageID)}
                    Button("取消阶段方案") {model.dismissGoalPlan(messageID)}
                }.controlSize(.small).disabled(model.isSending)
            }
        }.padding(12).background(AssistantTheme.inset,in:RoundedRectangle(cornerRadius:9))
    }
}
struct GoalStagesProgressView:View {
    @EnvironmentObject private var model:AssistantModel
    let run:AssistantRun
    @State private var notes:[UUID:String]=[:]
    private func status(_ stage:AssistantGoalStage)->String {
        if stage.isComplete {return "你已核对完成"}
        guard let id=stage.childRunID else {return "待启动"}
        return model.assistantRuns.first(where:{$0.id==id})?.stageQuestion==nil ? "待核对结果" : "待补充信息"
    }
    var body:some View {
        if let plan=run.stagePlan {
            VStack(alignment:.leading,spacing:7) {
                let family=model.assistantRuns.filter {$0.id==run.id || $0.parentRunID==run.id}
                Text("已核对 \(plan.stages.filter(\.isComplete).count)/\(plan.stages.count)阶段 · 累计\(family.reduce(0){$0+$1.modelRequests})轮/\(family.reduce(0){$0+$1.readCalls})次读取")
                    .font(.system(size:10)).foregroundStyle(.secondary)
                if let history=run.stageRevisions,!history.isEmpty {
                    DisclosureGroup("阶段修订记录（\(history.count)/4）") {
                        ForEach(Array(history.enumerated()),id:\.offset) { _,record in
                            Text(record.previous.title+" → "+record.replacement.title+"："+record.reason)
                            Text("原内容："+record.previous.instruction+"；原条件："+record.previous.criterion)
                        }
                    }
                }
                ForEach(Array(plan.stages.enumerated()),id:\.element.id) { index,stage in
                    DisclosureGroup("\(index+1). "+stage.title+" · "+status(stage)) {
                        Text(stage.instruction)
                        Text("完成条件："+stage.criterion)
                        StageFactResultView(parentID:run.id,stage:stage)
                        StageRemoteFactResultView(parentID:run.id,stage:stage)
                        if let reference=stage.createdTargetReference {Text("已明确引用："+reference.description+"；只读核对，不重新创建。")}
                        if !stage.isComplete,stage.actionTool==nil,stage.createdTargetReference==nil,model.canReviseStage(run.id,stageID:stage.id) {
                            let candidates=model.createdStageCandidates(run.id,stageID:stage.id)
                            if !candidates.isEmpty {
                                DisclosureGroup("引用依赖阶段的新建事项") {
                                    ForEach(candidates) {candidate in
                                        Button(candidate.label) {model.beginCreatedStageReference(run.id,stageID:stage.id,actionID:candidate.id)}.disabled(model.isSending)
                                    }
                                    Text("先打开引用预览，确认后才绑定；不会默认选择或启动阶段。")
                                }
                            }
                        }
                        if !stage.isComplete && (stage.factCriterion==nil || StageNextStepPolicy.decide(stage:stage,child:model.assistantRuns.first{$0.id==stage.childRunID},parentState:run.state).kind != .adjust) {
                            Button("修改本阶段") {model.beginStageRevision(run.id,stageID:stage.id)}
                                .disabled(model.isSending || !model.canReviseStage(run.id,stageID:stage.id))
                        }
                        Text("依赖阶段："+(stage.dependencies.isEmpty ? "无" : stage.dependencies.map{String($0+1)}.joined(separator:"、")))
                        if let childID=stage.childRunID, let child=model.assistantRuns.first(where:{$0.id==childID}) {
                            CreatedTodoReceiptView(parentID:run.id,stage:stage,child:child)
                            if child.stageRevisionPending==true {Text("阶段已修订，请沿原预算继续取得新结果。")}
                            Text((child.stageQuestion==nil ? child.state.label : "等待补充信息，原预算保留")+" · 已用\(child.modelRequests)/4轮、\(child.readCalls)/6次读取")
                            if !stage.isComplete {
                                if let question=child.stageQuestion { StageInputQuestionView(question:question) }
                                if stage.remoteFactCriterion==nil && stage.factCriterion==nil && child.canContinue && child.stageQuestion==nil && !(CreatedTodoReceiptPolicy.needsReview(stage) && child.receipts.contains{$0.state=="completed"}) { Button("继续本阶段，保留预算") {model.continueAssistantRun(childID)}.disabled(model.isSending) }
                                if child.state == .cancelled { Button("重试本阶段，保留预算") {model.continueAssistantRun(childID,retryStopped:true)}.disabled(model.isSending) }
                                TextField("满足条件的核对依据（必填，最多500字）",text:Binding(get:{notes[stage.id] ?? ""},set:{notes[stage.id]=$0}))
                                Text("请核对回复、原操作卡片和实际事项。模型回复或已创建待办不代表业务目标完成；此确认只记录你的阶段判断，不完成原任务。")
                                Button("按条件确认本阶段完成") {model.reviewGoalStage(run.id,stageID:stage.id,note:notes[stage.id] ?? "")}
                                    .disabled(model.isSending || model.remoteFactBusy || (stage.remoteFactCriterion != nil && stage.remoteFactCheck?.status != "satisfied") || (CreatedTodoReceiptPolicy.needsReview(stage) && !CreatedTodoReceiptPolicy.reviewable(child)) || (stage.factCriterion != nil && stage.factCheck?.status != "satisfied") || child.stageRevisionPending==true || child.stageQuestion != nil || (notes[stage.id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || ![.ready,.responded].contains(child.state) || child.receipts.contains { ["pending","unverified"].contains($0.state) } || (stage.reviewMode=="confirmed_operation" && !child.receipts.contains { $0.state=="completed" }))
                            } else { Text("你的核对依据："+(stage.reviewNote ?? "")) }
                        } else if stage.remoteFactCriterion==nil {
                            Button("启动第\(index+1)阶段") {model.startGoalStage(run.id,index:index)}
                                .disabled(model.isSending || !stage.dependencies.allSatisfy {plan.stages[$0].isComplete} || plan.stages.contains {$0.childRunID != nil && !$0.isComplete})
                        }
                    }.font(.system(size:10))
                }
            }.padding(8).background(AssistantTheme.inset,in:RoundedRectangle(cornerRadius:8))
        }
    }
}
