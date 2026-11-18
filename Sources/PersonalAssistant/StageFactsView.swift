import SwiftUI

struct StageFactFieldsView:View {
    @EnvironmentObject private var model:AssistantModel
    @Binding var draft:StageRevisionDraft
    var body:some View {
        DisclosureGroup("可核实的个人待办条件") {
            Toggle("按当前记录核对条件",isOn:$draft.factEnabled)
            if draft.factEnabled {
                Picker("精确目标",selection:$draft.factTargetID) {
                    Text("请选择个人待办").tag("")
                    if !draft.factTargetID.isEmpty,!model.personalTodos.contains(where:{$0.id.uuidString==draft.factTargetID}) {Text("原目标当前不可见 · "+String(draft.factTargetID.suffix(8))).tag(draft.factTargetID)}
                    ForEach(model.personalTodos) {todo in Text(todo.title+" · "+String(todo.id.uuidString.suffix(8))).tag(todo.id.uuidString)}
                }
                .disabled(draft.createdTargetReference != nil)
                Picker("期望状态",selection:$draft.factStatus) {
                    Text("只核对存在").tag("any");Text("未完成").tag("open");Text("已完成").tag("complete")
                }
                TextField("期望标题（留空不核对标题）",text:$draft.factTitle)
                ForEach($draft.extraFacts) {$extra in
                    VStack(alignment:.leading,spacing:4) {
                        Text("同时满足的条件").fontWeight(.medium)
                        Picker("精确目标",selection:$extra.targetID) {
                            Text("请选择个人待办").tag("")
                            if !extra.targetID.isEmpty,!model.personalTodos.contains(where:{$0.id.uuidString==extra.targetID}) {Text("原目标当前不可见 · "+String(extra.targetID.suffix(8))).tag(extra.targetID)}
                            ForEach(model.personalTodos) {todo in Text(todo.title+" · "+String(todo.id.uuidString.suffix(8))).tag(todo.id.uuidString)}
                        }
                        Picker("期望状态",selection:$extra.expectedStatus) {Text("只核对存在").tag("any");Text("未完成").tag("open");Text("已完成").tag("complete")}
                        TextField("期望标题（留空不核对标题）",text:$extra.expectedTitle)
                        Button("移除此条件") {let id=extra.id;draft.extraFacts.removeAll{$0.id==id}}
                    }.padding(.vertical,4)
                }
                if draft.actionTool=="none",draft.createdTargetReference==nil,draft.extraFacts.count<(draft.remoteFactEnabled ? 2 : 3) {
                    Button("添加同时满足的条件（最多4项）") {draft.extraFacts.append(.init())}
                }
                if !draft.extraFacts.isEmpty {Text("全部条件都满足才可确认阶段；任一未知则整体未知。组合条件只读，不自动修改多条待办。")}
                Text("仅核对所选ID、状态和可选标题；其他文字条件仍需人工核对。读取失败或目标消失属于未知。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.font(.caption)
        .onChange(of:draft.factEnabled) {enabled in if !enabled {draft.extraFacts=[]}}
    }
}
struct StageFactResultView:View {
    @EnvironmentObject private var model:AssistantModel
    let parentID:UUID
    let stage:AssistantGoalStage
    var body:some View {
        if let criterion=stage.factCriterion {
            VStack(alignment:.leading,spacing:4) {
                Text("可核实条件："+criterion.description)
                if let check=stage.factCheck {
                    Text("事实复核："+check.label).fontWeight(.medium)
                    Text(check.reason)
                    if let components=check.components {
                        DisclosureGroup("各项条件结果（\(components.count)项）") {
                            ForEach(components,id:\.targetID) {part in
                                Text("个人待办ID "+part.targetID.uuidString+"："+part.label)
                                if let title=part.observedTitle,let complete=part.observedComplete {Text(title+" · "+(complete ? "已完成" : "未完成"))}
                                Text(part.reason)
                            }
                        }
                    }
                    if let title=check.observedTitle,let done=check.observedComplete {Text("读取结果："+title+" · "+(done ? "已完成" : "未完成"))}
                    Text("来源："+check.source+" · 读取时点："+check.checkedAt.formatted(date:.abbreviated,time:.standard))
                    Text("这是该时点的结果；确认阶段完成前会重新读取，结果变化会阻止完成。")
                } else {Text("尚未复核，不能用模型文字替代事实。")}
                if let parent=model.assistantRuns.first(where:{$0.id==parentID}),!stage.isComplete,let child=model.assistantRuns.first(where:{$0.id==stage.childRunID}) {
                    let next=StageNextStepPolicy.decide(stage:stage,child:child,parentState:parent.state)
                    Text("建议下一步："+next.reason).fontWeight(.medium)
                    if let title=next.kind.buttonTitle,let token=model.nextStepToken(parentID:parentID,stageID:stage.id) {
                        Button(title) {model.performStageNextStep(token)}.disabled(model.isSending)
                    }
                    DisclosureGroup("手动复核") {
                        Button("按最新记录复核条件") {model.checkGoalStageFacts(parentID,stageID:stage.id)}.disabled(model.isSending)
                        Text("相同未知结果只做一次引导复核；有新事实后会重新选择建议，不重置模型预算。")
                    }
                }
            }.font(.system(size:10)).padding(6)
        }
    }
}
