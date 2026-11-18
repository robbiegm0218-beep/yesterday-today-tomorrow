import SwiftUI

struct MeetingActionResolutionView: View {
    @EnvironmentObject private var model: AssistantModel
    let action: ExtractedMeetingAction
    let source: String
    let sourceTitle: String
    let sourceURL: URL?
    @State private var target = "choose"
    @State private var projectName = ""
    @State private var error: String?

    var body: some View {
        let evidence = try? MeetingActionEvidence.make(action: action, source: source, title: sourceTitle, url: sourceURL)
        let existing = evidence.flatMap { MeetingFollowupPolicy.existing(for: $0, todos: model.personalTodos) }
        let candidates = MeetingFollowupPolicy.candidates(for: action, todos: model.personalTodos)
        VStack(alignment: .leading, spacing: 8) {
            if let existing {
                Label("已关联：\(existing.title) · \(existing.isComplete ? "已完成" : "未完成")", systemImage: "link")
                    .font(.system(size: 11)).foregroundStyle(AssistantTheme.accent)
                Text("同一来源依据已保存，不会重复创建；当前任务状态以工作台为准。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                if !candidates.isEmpty {
                    Text("可能重复（仅按标题相似推荐，请核对）：")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(AssistantTheme.accent)
                    ForEach(candidates.prefix(5)) { todo in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("• \(todo.title) · \(todo.isComplete ? "已完成" : "未完成")" + (todo.projectName.map { " · " + $0 } ?? ""))
                            Text([todo.owner.map { "负责人：" + $0 }, todo.dueAt.map { "截止：" + $0.formatted(date: .abbreviated, time: .omitted) }, todo.dueText.map { "原期限：" + $0 }].compactMap { $0 }.joined(separator: " · "))
                            if let quote = todo.meetingEvidence?.last?.quote ?? todo.sourceQuote {
                                Text("已有依据：" + quote).lineLimit(3)
                            } else { Text("已有待办尚无纪要来源，可先核对任务内容。") }
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Picker("处理方式", selection: $target) {
                    Text("请选择处理方式").tag("choose")
                    Text(candidates.isEmpty ? "新建本地待办" : "确认是不同事项，仍新建").tag("new")
                    ForEach(targetTodos(candidates)) { todo in
                        Text("关联：" + todo.title + (todo.isComplete ? "（已完成）" : "" )).tag(todo.id.uuidString)
                    }
                }.font(.system(size: 11))
                if target == "new" {
                    Picker("关联项目", selection: $projectName) {
                        Text("不关联项目").tag("")
                        ForEach(model.projects) { project in Text(project.name).tag(project.name) }
                    }.font(.system(size: 11))
                } else if target != "choose" {
                    Text("只追加这条纪要来源，不更改已有标题、截止日期、项目或完成状态。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack {
                    Button(target == "new" ? "确认新建本地待办" : "确认关联已有待办") {
                        guard let evidence else { error = "原文依据已变化，请重新提取。"; return }
                        error = model.saveMeetingFollowup(action: action, evidence: evidence,
                            targetID: target == "new" ? nil : UUID(uuidString: target),
                            projectName: target == "new" && !projectName.isEmpty ? projectName : nil)
                    }.disabled(target == "choose" || evidence == nil)
                    if let error { Text(error).font(.system(size: 10)).foregroundStyle(.red) }
                }
            }
        }.padding(10).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 8))
    }

    private func targetTodos(_ candidates: [PersonalTodo]) -> [PersonalTodo] {
        let candidateIDs = Set(candidates.map(\.id))
        return candidates + model.personalTodos.filter { !candidateIDs.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }
}

struct MeetingEvidenceList: View {
    let todo: PersonalTodo
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let sources = todo.meetingEvidence, !sources.isEmpty {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(source.sourceTitle).font(.system(size: 11, weight: .medium))
                            Spacer()
                            if let url = source.sourceURL { Link("打开原文", destination: url).font(.system(size: 10)) }
                        }
                        Text(source.quote).font(.system(size: 11)).textSelection(.enabled)
                        Text([source.owner.isEmpty ? nil : "核对负责人：" + source.owner,
                              source.dueText.isEmpty ? nil : "核对期限：" + source.dueText,
                              "记录于 " + source.recordedAt.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(10).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                }
            } else if let quote = todo.sourceQuote {
                Text("历史纪要摘录：" + quote).font(.system(size: 11)).textSelection(.enabled)
                Text("旧记录没有原文链接及提取时间，不补造来源。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

struct MeetingFollowupSection: View {
    @EnvironmentObject private var model: AssistantModel
    let onEdit: (PersonalTodo) -> Void
    @State private var expanded = false

    var body: some View {
        let todos = model.personalTodos.filter { !($0.meetingEvidence ?? []).isEmpty || $0.sourceQuote != nil }
        if !todos.isEmpty {
            DisclosureGroup("会后跟进（\(todos.filter { !$0.isComplete }.count) 项未完成）", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("同一待办集中显示所有纪要来源；完成状态与今日优先级一致。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach(todos.sorted { !$0.isComplete && $1.isComplete }) { todo in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(todo.title).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(todo.isComplete ? "已完成" : "未完成").font(.system(size: 10)).foregroundStyle(.secondary)
                                Button("编辑待办") { onEdit(todo) }.font(.system(size: 10))
                            }
                            if let name = todo.projectName {
                                Text("项目：" + name).font(.system(size: 10)).foregroundStyle(AssistantTheme.accent)
                                if let project = model.projects.first(where: { $0.name == name || ($0.previousNames ?? []).contains(name) }) {
                                    Text("项目进展：" + project.progressNote + (project.nextStep.map { " · 下一步：" + $0 } ?? ""))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            DisclosureGroup("纪要来源（\(todo.meetingEvidence?.count ?? 1)）") { MeetingEvidenceList(todo: todo).padding(.top, 6) }
                                .font(.system(size: 11))
                        }.padding(12).background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(.top, 9)
            }.font(.system(size: 14, weight: .semibold))
        }
    }
}
