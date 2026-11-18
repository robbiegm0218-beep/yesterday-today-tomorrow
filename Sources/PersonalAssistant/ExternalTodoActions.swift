import SwiftUI

struct ExternalTodoActions: View {
    @EnvironmentObject private var model: AssistantModel
    let task: TaskItem
    let vertical: Bool
    @State private var showingCompletion = false
    @State private var showingEditor = false

    private var buttons: some View {
        Group {
            Button("编辑/改期") { showingEditor = true }.disabled(model.externalTodoCompletionBusy || model.usesDemoData)
            Button("完成") { showingCompletion = true }
                .foregroundStyle(AssistantTheme.accent)
                .disabled(model.externalTodoCompletionBusy || model.usesDemoData)
                .accessibilityLabel("完成钉钉待办：\(task.title)")
            Button("去钉钉处理") { model.openDingTalkTodo(task) }
                .foregroundStyle(AssistantTheme.accent)
                .help(task.sourceURL == nil ? "复制标题并打开钉钉，在待办中搜索处理" : "打开钉钉原事项，处理后刷新工作台")
            Button("隐藏") { model.hideExternalTodo(task) }
                .foregroundStyle(.secondary)
                .help("仅在本机隐藏，可在已隐藏列表恢复")
                .accessibilityLabel("隐藏钉钉待办：\(task.title)")
        }.font(.system(size: 10)).buttonStyle(.plain)
    }

    var body: some View {
        Group {
            if vertical { VStack(spacing: 10) { buttons } }
            else { HStack(spacing: 10) { buttons } }
        }.sheet(isPresented: $showingCompletion) { DingTalkTodoMutationSheet(localID: task.id, title: task.title, mode: .complete).environmentObject(model) }
            .sheet(isPresented: $showingEditor) { DingTalkTodoMutationSheet(localID: task.id, title: task.title, mode: .update).environmentObject(model) }
    }
}

struct HiddenExternalTodosView: View {
    @EnvironmentObject private var model: AssistantModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("仅在本机隐藏，不会完成或删除钉钉原记录；隐藏后不参与优先级、项目统计和 Agent 待办回答。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.hiddenExternalTodos.isEmpty {
                    Text("暂无隐藏的钉钉待办。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(model.hiddenExternalTodos.sorted { $0.hiddenAt > $1.hiddenAt }) { item in
                    HStack {
                        Text(item.title).font(.system(size: 12))
                        Spacer()
                        Button("恢复显示") { model.restoreHiddenExternalTodo(item.id) }
                            .font(.system(size: 11)).buttonStyle(.plain)
                            .foregroundStyle(AssistantTheme.accent)
                            .accessibilityLabel("恢复显示：\(item.title)")
                    }.padding(.vertical, 5)
                }
            }.padding(12)
        } label: {
            Text("已隐藏的钉钉待办（\(model.hiddenExternalTodos.count)）")
                .font(.system(size: 13, weight: .medium))
        }
    }
}
