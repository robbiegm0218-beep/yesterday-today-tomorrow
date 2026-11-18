import SwiftUI

enum WorkbenchArchiveState: String {
    case completed = "已完成", hidden = "已隐藏（仅本机）"
}

struct WorkbenchArchiveView: View {
    @EnvironmentObject private var model: AssistantModel
    let state: WorkbenchArchiveState
    var source: WorkbenchTaskSource = .all
    var query = ""
    @State private var reopening: DingTalkCompletedTodo?
    private func matches(_ title: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || title.localizedCaseInsensitiveContains(term)
    }
    private var personal: [PersonalTodo] {
        model.personalTodos.filter { $0.isComplete && matches($0.title) }.sorted { $0.createdAt > $1.createdAt }
    }
    private var external: [DingTalkCompletedTodo] {
        model.completedExternalTodos.filter { model.selectedDingTalkProfileIDs.contains($0.profile.id) && matches($0.title) }
    }
    private var hidden: [HiddenExternalTodo] {
        model.hiddenExternalTodos.filter {
            WorkbenchArchivePolicy.belongsToSelectedOrganization($0.id, selected: model.selectedDingTalkProfileIDs) && matches($0.title)
        }.sorted { $0.hiddenAt > $1.hiddenAt }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state == .completed {
                if source != .local {
                    HStack {
                        Text("钉钉完成记录按最近查询展示，最多200项。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.completedExternalLoading ? "读取中…" : "刷新钉钉") { Task { await model.loadCompletedExternalTodos() } }
                            .disabled(model.completedExternalLoading || model.selectedDingTalkProfileIDs.isEmpty)
                    }
                    if let error = model.completedExternalError { Text(error).font(.caption).foregroundStyle(.orange) }
                    if model.selectedDingTalkProfileIDs.isEmpty { Text("尚未选择钉钉组织。").font(.caption).foregroundStyle(.secondary) }
                }
                if source != .external {
                    ForEach(personal) { task in
                        ArchivedMatterRow(target: .init(reference: .personal(task.id), title: task.title), state: .completed,
                                          detail: "个人" + (task.projectName.map { " · " + $0 } ?? "")) {
                            Button("恢复事项") { model.reopenPersonalTodoFromWorkbench(task.id) }
                        }
                    }
                }
                if source != .local {
                    ForEach(external) { task in
                        ArchivedMatterRow(target: .init(reference: .init(kind: "external", id: task.id), title: task.title), state: .completed,
                                          detail: "钉钉 · " + task.profile.corpName) {
                            Button("重新打开…") { reopening = task }.disabled(model.externalTodoCompletionBusy)
                        }
                    }
                    if model.completedExternalTotal > model.completedExternalTodos.count {
                        Text("部分记录未展示；可到钉钉查看其余完成事项。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if (source == .external || personal.isEmpty) && (source == .local || external.isEmpty) && !model.completedExternalLoading {
                    Text("当前范围没有匹配的已完成事项。").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("仅显示当前所选组织的本机隐藏记录；隐藏不代表源事项已完成或删除。").font(.caption).foregroundStyle(.secondary)
                if hidden.isEmpty { Text("当前范围没有匹配的隐藏事项。").font(.callout).foregroundStyle(.secondary) }
                ForEach(hidden) { task in
                    ArchivedMatterRow(target: .init(reference: .init(kind: "external", id: task.id), title: task.title), state: .hidden,
                                      detail: "钉钉 · 隐藏于 " + task.hiddenAt.formatted(date: .abbreviated, time: .omitted)) {
                        Button("恢复显示") { model.restoreHiddenExternalTodo(task.id) }
                    }
                }
            }
        }.task(id: model.selectedDingTalkProfileIDs.sorted().joined(separator: "|") + source.rawValue + state.rawValue) {
            if state == .completed && source != .local && !model.selectedDingTalkProfileIDs.isEmpty {
                await model.loadCompletedExternalTodos()
            }
        }.sheet(item: $reopening) { task in
            DingTalkTodoMutationSheet(localID: task.id, title: task.title, mode: .reopen)
        }
    }
}

enum WorkbenchArchivePolicy {
    static func belongsToSelectedOrganization(_ id: String, selected: Set<String>) -> Bool {
        selected.contains { id.hasPrefix("dingtalk-" + $0 + "-") }
    }
}

private struct ArchivedMatterRow<Actions: View>: View {
    let target: MatterTarget
    let state: WorkbenchArchiveState
    let detail: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(target.title, systemImage: state == .completed ? "checkmark.circle" : "eye.slash")
                .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(state.rawValue + " · " + detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                MatterContextButton(target: target, archiveState: state)
                Spacer()
                actions()
            }.font(.system(size: 11)).buttonStyle(.plain)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
