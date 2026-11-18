import SwiftUI

struct StageRemoteFactFieldsView:View {
    @EnvironmentObject private var model:AssistantModel
    @Binding var draft:StageRevisionDraft
    @State private var selection=""
    var body:some View {
        if draft.actionTool=="none",draft.createdTargetReference==nil {
            DisclosureGroup("可核实的钉钉待办条件（1项，只读）") {
                Toggle("核对原组织中的精确任务",isOn:$draft.remoteFactEnabled).disabled(!draft.remoteFactEnabled && draft.factEnabled && draft.extraFacts.count>=3)
                if draft.remoteFactEnabled {
                    Picker("组织与精确任务",selection:$selection) {
                        Text("请选择已授权组织中的任务").tag("")
                        if !selection.isEmpty,!model.remoteStageFactOptions.contains(where:{$0.id==selection}) {Text("已绑定任务当前未列出 · "+String(draft.remoteTaskID.suffix(8))).tag(selection)}
                        ForEach(model.remoteStageFactOptions) {option in Text(option.label).tag(option.id)}
                    }
                    Picker("远端期望状态",selection:$draft.remoteStatus) {Text("只核对存在").tag("any");Text("未完成").tag("open");Text("已完成").tag("complete")}
                    TextField("远端期望标题（留空不核对标题）",text:$draft.remoteTitle)
                    Text("仅覆盖所选组织的这一个精确任务。未列出不代表删除；实时读取失败保持未知。与本地条件合计最多4项，全部满足后仍需人工确认。")
                }
            }.font(.caption)
            .onAppear {if draft.remoteFactEnabled {selection=draft.remoteTargetID}}
            .onChange(of:selection) {value in
                if let option=model.remoteStageFactOptions.first(where:{$0.id==value}) {draft.remoteProfileID=option.profileID;draft.remoteTaskID=option.taskID}
                else if value.isEmpty {draft.remoteProfileID="";draft.remoteTaskID=""}
            }
        }
    }
}
struct StageRemoteFactResultView:View {
    @EnvironmentObject private var model:AssistantModel
    let parentID:UUID
    let stage:AssistantGoalStage
    var body:some View {
        if let rule=stage.remoteFactCriterion {
            VStack(alignment:.leading,spacing:4) {
                Text("远端条件："+rule.description)
                Text("整体字段复核："+(["satisfied":"全部满足","unsatisfied":"未全部满足","unknown":"存在未知"][StageRemoteFactPolicy.combinedStatus(stage)] ?? "未知"))
                if let check=stage.remoteFactCheck {
                    Text("远端复核："+(["satisfied":"满足","unsatisfied":"未满足","unknown":"未知"][check.status] ?? "未知"))
                    if let title=check.observedTitle,let complete=check.observedComplete {Text(title+" · "+(complete ? "已完成" : "未完成"))}
                    Text(check.reason)
                    Text("来源：原组织单任务实时读取 · "+check.checkedAt.formatted(date:.abbreviated,time:.standard))
                } else {Text("尚无当前远端核对；旧工作台快照不能作为满足证据。")}
                Text("这是读取时点的结果；确认阶段时会再次实时读取，旧快照不能直接完成阶段。")
                Text("仅覆盖原组织的这个任务；本地与远端为先后读取，并非跨系统原子快照。只有所有配置字段满足，才可经再次读取后人工确认阶段。")
                if !stage.isComplete {
                    if model.remoteFactBusy,model.remoteFactStageID==stage.id {
                        Text("正在实时核对，计入原读取/时间预算，不调用模型。")
                        Button("停止本次核对") {model.cancelRemoteFactCheck()}
                    } else {Button("实时核对条件，不修改事项") {model.checkRemoteGoalStage(parentID,stageID:stage.id)}.disabled(model.isSending || model.remoteFactBusy)}
                }
            }.font(.system(size:10)).padding(6)
        }
    }
}
