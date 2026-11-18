import SwiftUI

struct DingTalkTodoCompletionSheet: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    let task: TaskItem
    @State private var target: DingTalkTodoCompletionTarget?
    @State private var loading = true
    @State private var submitting = false
    @State private var verifyOnly = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("完成钉钉待办").font(.title2.weight(.semibold))
            Text(task.title).font(.body).textSelection(.enabled).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            if loading { ProgressView("正在核对组织、执行人和最新状态…") }
            if let target {
                Text("组织：\(target.profile.corpName)\n执行账号：\(target.profile.userName ?? "本人")")
                    .font(.callout).foregroundStyle(AssistantTheme.secondaryText).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                Text(target.isDone ? "钉钉中已经完成，可直接同步工作台，不会重复提交。" : "确认后会将这条钉钉原待办标记为完成，并回查结果。这不是仅在本机隐藏；已保存的今日计划不会自动勾选。")
                    .font(.callout).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled).lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("取消") { dismiss() }.disabled(submitting)
                Spacer()
                if target == nil && !loading {
                    Button("重新读取") { Task { await prepare() } }
                }
                if let target {
                    Button(submitting ? "正在核验…" : (verifyOnly ? "重新核验" : (target.isDone ? "同步已完成状态" : "确认在钉钉完成"))) {
                        submitting = true
                        error = nil
                        Task {
                            do {
                                try await model.finishExternalTodo(target, verifyOnly: verifyOnly || target.isDone)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                                if let issue = error as? DingTalkTodoCompletionError, case .unverified = issue { verifyOnly = true }
                            }
                            submitting = false
                        }
                    }.buttonStyle(.borderedProminent).disabled(submitting || model.externalTodoCompletionBusy)
                }
            }
        }.padding(24).frame(width: 480).foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
            .interactiveDismissDisabled(submitting)
            .task { await prepare() }
    }

    private func prepare() async {
        loading = true; error = nil; target = nil
        do { target = try await model.prepareExternalTodoCompletion(task) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}
