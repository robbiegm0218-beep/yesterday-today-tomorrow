import SwiftUI

struct DingTalkTodoMutationPanel: View {
    @EnvironmentObject private var model: AssistantModel
    let localID: String
    let expectedTitle: String
    let mode: DingTalkTodoMutationRequest.Mode
    var request: DingTalkTodoMutationRequest? = nil
    let onVerified: () -> Void
    let onCancel: () -> Void
    @State private var preview: DingTalkTodoMutationTarget?
    @State private var loading = true
    @State private var submitting = false
    @State private var verifyOnly = false
    @State private var submitted: DingTalkTodoMutationRequest?
    @State private var draftID = UUID()
    @State private var title = ""
    @State private var dateEnabled = false
    @State private var due = Date()
    @State private var priorityEnabled = false
    @State private var priority = 20
    @State private var error: String?
    private var editable: Bool { request == nil && mode == .update && !verifyOnly }
    private var currentRequest: DingTalkTodoMutationRequest? {
        if let submitted { return submitted }
        if let request { return request }
        guard let preview else { return nil }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let patch: DingTalkTodoPatch? = mode == .update ? .init(title: cleaned == preview.title ? nil : cleaned,
            dueAt: dateEnabled ? Calendar.current.date(bySetting: .second, value: 0, of: due) : nil, priority: priorityEnabled ? priority : nil) : nil
        return .init(id: draftID, localID: localID, expectedTitle: expectedTitle, mode: mode, patch: patch)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text((submitted?.mode ?? mode).label).font(.headline)
            Text(expectedTitle).font(.body).fixedSize(horizontal: false, vertical: true)
            if loading { ProgressView("正在核对钉钉组织、本人执行身份和最新字段…") }
            if let preview {
                Text("组织：\(preview.profile.corpName)\n执行账号：\(preview.profile.userName ?? "本人")")
                    .font(.caption).foregroundStyle(AssistantTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                if editable {
                    TextField("待办标题", text: $title).textFieldStyle(.roundedBorder).accessibilityLabel("钉钉待办标题")
                    Toggle("设置或更改截止时间", isOn: $dateEnabled)
                    if dateEnabled { DatePicker("新截止时间", selection: $due, displayedComponents: [.date, .hourAndMinute]) }
                    Toggle("更改优先级", isOn: $priorityEnabled)
                    if priorityEnabled {
                        Picker("优先级", selection: $priority) {
                            Text("低").tag(10); Text("普通").tag(20); Text("高").tag(30); Text("紧急").tag(40)
                        }
                    }
                    Text("不勾选则保留原值；暂不支持清除已有截止日期。") .font(.caption).foregroundStyle(AssistantTheme.secondaryText)
                }
                if let currentRequest, currentRequest.isValid {
                    let after = preview.expected(currentRequest)
                    VStack(alignment: .leading, spacing: 5) {
                        if preview.title != after.title { Text("标题：\(preview.title) → \(after.title)") }
                        if preview.dueAt != after.dueAt { Text("截止：\(deadline(preview.dueAt)) → \(deadline(after.dueAt))\(currentRequest.patch?.dateOnly == true ? "（按日期转换为当天23:59:59，本机时间）" : "")") }
                        if preview.priority != after.priority { Text("优先级：\(priorityName(preview.priority)) → \(priorityName(after.priority))") }
                        if preview.isDone != after.isDone { Text("状态：\(preview.isDone ? "已完成" : "未完成") → \(after.isDone ? "已完成" : "未完成")") }
                        if preview.matches(after) { Text("本次字段未变化或钉钉已处于目标状态，不会重复修改。") }
                    }.font(.callout).fixedSize(horizontal: false, vertical: true)
                } else if !loading { Text("请修改至少一个字段后再确认。") .font(.caption).foregroundStyle(AssistantTheme.secondaryText) }
                if verifyOnly { Text("已有本次提交记录，以上为上次核对值；现在只回查结果，不再提交变更。") .font(.caption).foregroundStyle(.orange) }
            }
            Text("最终确认会真实修改钉钉原待办。仅在回查成功后同步工作台，不自动改动已保存计划，也不会完成或新建个人待办。")
                .font(.caption).foregroundStyle(AssistantTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("取消", action: onCancel).disabled(submitting)
                Spacer()
                if preview == nil && !loading { Button("重新核对") { Task { await prepare() } } }
                Button(submitting ? "正在核验…" : verifyOnly ? "只重新核验" : "确认在钉钉执行") { commit() }
                    .buttonStyle(.borderedProminent).disabled(loading || submitting || model.externalTodoCompletionBusy || currentRequest?.isValid != true)
            }
        }.font(.callout).foregroundStyle(AssistantTheme.text)
            .task { await prepare() }
            .interactiveDismissDisabled(submitting)
    }
    private func deadline(_ date: Date?) -> String { date.map { $0.formatted(date: .numeric, time: .shortened) } ?? "未设置" }
    private func priorityName(_ p: Int) -> String { [10:"低",20:"普通",30:"高",40:"紧急"][p] ?? "未知" }
    private func prepare() async {
        loading = true; error = nil
        let selected = model.selectedDingTalkProfileIDs
        do {
            if let request, let receipt = try DingTalkTodoMutationStore().load().first(where: { $0.id == request.id }) {
                guard receipt.request == request, selected.contains(receipt.before.profile.id) else { throw DingTalkTodoMutationError.changed }
                preview = receipt.before; submitted = request; verifyOnly = true
            } else if request == nil, let receipt = try DingTalkTodoMutationStore().load().first(where: { $0.before.localID == localID && $0.state == .submitting }) {
                guard selected.contains(receipt.before.profile.id) else { throw DingTalkTodoMutationError.changed }
                preview = receipt.before; submitted = receipt.request; verifyOnly = true
            } else {
                let target = try await Task.detached(priority: .userInitiated) { try DingTalkTodoMutationService().prepare(localID: localID, expectedTitle: expectedTitle, selected: selected) }.value
                guard selected == model.selectedDingTalkProfileIDs else { throw DingTalkTodoMutationError.changed }
                preview = target; title = target.title; due = target.dueAt ?? Date(); priority = target.priority
            }
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func commit() {
        guard let preview, let request = currentRequest else { return }
        submitted = request; submitting = true; error = nil
        Task {
            do { try await model.mutateExternalTodo(request, preview: preview, verifyOnly: verifyOnly); onVerified() }
            catch {
                self.error = error.localizedDescription
                verifyOnly = ((try? DingTalkTodoMutationStore().load().contains(where: { $0.id == request.id })) == true)
                if !verifyOnly { submitted = nil }
            }
            submitting = false
        }
    }
}
struct DingTalkTodoMutationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let localID: String
    let title: String
    let mode: DingTalkTodoMutationRequest.Mode
    var body: some View {
        DingTalkTodoMutationPanel(localID: localID, expectedTitle: title, mode: mode, onVerified: { dismiss() }, onCancel: { dismiss() })
            .padding(24).frame(width: 560).background(AssistantTheme.canvas)
    }
}
struct CompletedDingTalkTodosView: View {
    @EnvironmentObject private var model: AssistantModel
    @State private var expanded = false
    @State private var editing: DingTalkCompletedTodo?
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { value in expanded = value; if value { Task { await model.loadCompletedExternalTodos() } } })) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("只显示当前所选组织、本人执行的已完成事项；按钉钉返回顺序，最多展示200条。") .font(.caption)
                    Spacer()
                    Button(model.completedExternalLoading ? "读取中…" : "刷新") { Task { await model.loadCompletedExternalTodos() } }.disabled(model.completedExternalLoading || model.selectedDingTalkProfileIDs.isEmpty)
                }
                if let error = model.completedExternalError { Text(error).font(.caption).foregroundStyle(.orange) }
                if model.completedExternalTodos.isEmpty && !model.completedExternalLoading { Text(model.selectedDingTalkProfileIDs.isEmpty ? "请先接入钉钉组织。" : "本次没有可展示的已完成待办。") .font(.caption).foregroundStyle(AssistantTheme.secondaryText) }
                ForEach(model.completedExternalTodos) { todo in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text(todo.title).font(.callout); Text(todo.profile.corpName).font(.caption2).foregroundStyle(AssistantTheme.secondaryText) }
                        Spacer()
                        Button("重新打开") { editing = todo }.disabled(model.externalTodoCompletionBusy)
                    }
                }
                if model.completedExternalTotal > model.completedExternalTodos.count { Text("钉钉返回\(model.completedExternalTotal)条；已隐藏事项不展示，超过200条时请到钉钉查看其余记录。") .font(.caption).foregroundStyle(AssistantTheme.secondaryText) }
            }.padding(12)
        } label: { Text("已完成的钉钉待办").font(.system(size: 13, weight: .medium)) }
            .sheet(item: $editing) { todo in DingTalkTodoMutationSheet(localID: todo.id, title: todo.title, mode: .reopen).environmentObject(model) }
    }
}
