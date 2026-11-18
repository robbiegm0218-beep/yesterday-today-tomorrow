import SwiftUI

struct StageRevisionView:View {
    @EnvironmentObject private var model:AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State var draft:StageRevisionDraft
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:12) {
            Text("修改本阶段").font(.title2)
            Text("原内容："+draft.original.instruction).font(.caption).foregroundStyle(.secondary)
            if draft.semanticPreviewID != nil {
                Text("目标与阶段不变：" + draft.title).font(.headline)
                Text("完成条件保留：" + draft.criterion)
                Text("操作类型保留：" + draft.original.actionLabel)
                Text("只修改下面的执行做法；原依赖、必要信息与精确目标保持不变。").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("阶段标题（最多100字）",text:$draft.title)
            }
            Text("阶段内容（最多600字）").font(.caption)
            TextEditor(text:$draft.instruction).frame(height:90).border(Color.secondary.opacity(0.2))
            if draft.semanticPreviewID == nil {
            TextField("完成条件（最多300字）",text:$draft.criterion)
            Picker("操作类型",selection:$draft.actionTool) {
                Text("只读核对").tag("none")
                Text("创建个人待办").tag("create_personal_todo")
                Text("修改个人待办").tag("update_personal_todo")
                Text("完成个人待办").tag("complete_personal_todo")
                Text("重开个人待办").tag("reopen_personal_todo")
            }
            .disabled(draft.createdTargetReference != nil || !draft.extraFacts.isEmpty || draft.remoteFactEnabled)
            Picker("启动时仍缺的信息",selection:$draft.requiredInput) {
                Text("无需补充").tag("none")
                if draft.actionTool=="create_personal_todo" {Text("待办标题").tag("todo_title")}
                Text("选择具体事项").tag("target_choice")
            }
            if draft.requiredInput=="target_choice" {
                Picker("候选来源",selection:$draft.inputTargetKind) {
                    Text("个人待办").tag("personal")
                    if draft.actionTool=="none" {Text("钉钉待办").tag("external");Text("项目").tag("project");Text("当前可见来源").tag("any")}
                }
            }
            if let reference=draft.createdTargetReference {
                Text("明确引用："+reference.description+"。本批引用仅支持只读；先取消引用才能改变操作类型。")
                    .font(.caption)
                Button("取消跨阶段引用") {draft.createdTargetReference=nil;draft.factEnabled=false;draft.factTargetID="";draft.factTitle="";draft.factStatus="any"}
            }
            StageFactFieldsView(draft:$draft)
            StageRemoteFactFieldsView(draft:$draft)
            }
            TextField("修改原因（必填，最多500字）",text:$draft.reason)
            Text("确认后旧问题和未执行卡片失效；依赖和已用预算保留。不会启动阶段或修改业务数据。旧结果不能用于完成修订后的阶段；已完成或结果未知的操作须先核对。")
                .font(.caption).foregroundStyle(.secondary)
            if let status=model.runStatus {Text(status).font(.caption).foregroundStyle(.red)}
            HStack {
                Button("取消") {dismiss()}
                Spacer()
                Button("确认修订，稍后继续") {if model.applyStageRevision(draft) {dismiss()}}
                    .disabled(model.isSending || draft.reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(20) }.frame(width:620,height:680)
        .onChange(of:draft.actionTool) {value in
            if value != "create_personal_todo",draft.requiredInput=="todo_title" {draft.requiredInput="none"}
            if value != "none" {draft.inputTargetKind="personal"}
        }
    }
}

struct SemanticStageRevisionCard: View {
    @EnvironmentObject private var model: AssistantModel
    let preview: SemanticStageRevisionPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("阶段替代方案 · " + (preview.status == "applied" ? "已采用" : preview.status == "dismissed" ? "已放弃" : "待核对"))
            Text(preview.original.title).font(.headline)
            Text("原做法：" + preview.original.instruction)
            Text("新做法：" + preview.instruction)
            Text("完成条件保留：" + preview.original.criterion)
            Text("调整依据：" + preview.reason)
            if preview.status == "pending" {
                HStack {
                    Button("核对修订方案") { model.openStageAlternative(preview.id) }
                    Button("放弃此方案") { model.dismissStageAlternative(preview.id) }
                }.disabled(model.isSending)
            }
            Text("确认只保存修订，不启动阶段或执行业务操作；原预算保留。").foregroundStyle(.secondary)
        }.font(.caption).padding(12).background(Color.secondary.opacity(0.08)).cornerRadius(10)
    }
}
