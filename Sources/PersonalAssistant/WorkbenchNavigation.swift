import SwiftUI

enum WorkbenchSection: String, CaseIterable, Identifiable {
    case today = "今天", tasks = "事项", projects = "项目"
    var id: String { rawValue }
}

enum WorkbenchTaskFilter: String, CaseIterable, Identifiable {
    case open = "未完成", completed = "已完成", hidden = "已隐藏", followups = "跟进", meetings = "会后行动"
    var id: String { rawValue }
}

enum WorkbenchTaskSource: String, CaseIterable, Identifiable {
    case all = "全部来源", local = "个人", external = "钉钉"
    var id: String { rawValue }
}

enum WorkbenchSource: String, CaseIterable, Identifiable {
    case local = "本地资料", research = "消息与组织知识库", documents = "钉钉文档", minutes = "钉钉听记", localMinutes = "导入或粘贴会议纪要"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .local: "添加文档、管理文件夹与查看索引"
        case .research: "检索历史消息、浏览知识库、关联事项与检查变化"
        case .documents: "搜索钉钉文档，查看来源"
        case .minutes: "查看会议听记，核对并整理行动项"
        case .localMinutes: "从本地文件或原文整理会后行动，关联已有事项"
        }
    }
}

enum WorkbenchTaskPolicy {
    static func visible(priority: [TaskItem], other: [TaskItem], query: String, source: WorkbenchTaskSource = .all) -> [TaskItem] {
        var seen = Set<String>()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (priority + other).filter { task in
            guard seen.insert(task.id).inserted else { return false }
            guard source == .all || (source == .local ? task.isPersonal : !task.isPersonal) else { return false }
            return term.isEmpty || [task.title, task.owner ?? "", task.projectName ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }
}

struct WorkbenchSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    let select: (WorkbenchSource) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("查找资料").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
            }
            Text("选择查找范围，找到的来源可用于理解和推进事项。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(WorkbenchSource.allCases) { source in
                Button { select(source) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.rawValue).font(.headline)
                            Text(source.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
        }.padding(24).frame(width: 500)
            .foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
    }
}

struct WorkbenchLocalSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("本地资料").font(.headline); Spacer(); Button("完成") { dismiss() } }.padding()
            KnowledgeBaseView()
        }.frame(width: 650, height: 600)
    }
}
