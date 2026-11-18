import SwiftUI

struct MatterContextButton: View {
    let target: MatterTarget
    var archiveState: WorkbenchArchiveState? = nil
    @State private var showing = false
    var body: some View {
        Button("事项详情") { showing = true }
            .font(.system(size: 10)).buttonStyle(.plain)
            .accessibilityLabel("查看「\(target.title)」的事项详情")
            .sheet(isPresented: $showing) { MatterContextView(target: target, archiveState: archiveState) }
    }
}

struct ProjectRelatedMatters: View {
    @EnvironmentObject private var model: AssistantModel
    let project: AssistantProject
    private func belongs(_ name: String?) -> Bool {
        MatterContextPolicy.confirmedProject(named: name, projects: model.projects)?.id == project.id
    }
    var body: some View {
        DisclosureGroup("关联事项") {
            ForEach(model.personalTodos.filter { belongs($0.projectName) }) { task in
                HStack {
                    Text(task.title + (task.isComplete ? " · 已完成" : " · 未完成")).font(.caption)
                    Spacer()
                    MatterContextButton(target: .init(reference: .personal(task.id), title: task.title))
                }.padding(.vertical, 4)
            }
            ForEach((model.skillSnapshot?.todos ?? []).filter { !$0.isPersonal && belongs($0.projectName) }) { task in
                HStack {
                    Text(task.title + " · 钉钉").font(.caption)
                    Spacer()
                    MatterContextButton(target: .init(reference: .init(kind: "external", id: task.id), title: task.title))
                }.padding(.vertical, 4)
            }
        }.font(.system(size: 13))
    }
}

struct MatterContextView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    let target: MatterTarget
    var archiveState: WorkbenchArchiveState? = nil
    @State private var category = "进展"
    @State private var draft = ""
    @State private var error: String?
    @State private var baselineRevision = 0
    private var entries: [MatterContextEntry] { model.matterEntries.filter { $0.reference == target.reference }.sorted { $0.recordedAt > $1.recordedAt } }
    private var todo: PersonalTodo? { model.personalTodos.first { MatterReference.personal($0.id) == target.reference } }
    private var project: AssistantProject? {
        if target.reference.kind == "project" { return model.projects.first { MatterReference.project($0.id) == target.reference } }
        // Only explicit local task association; inferred title resemblance is not evidence.
        return MatterContextPolicy.confirmedProject(named: todo?.projectName, projects: model.projects)
    }
    private var planItems: [(String, DayPlanStep)] {
        model.savedDayPlans.sorted { $0.day > $1.day }.flatMap { plan in
            plan.steps.filter { $0.sourceKind == target.reference.kind && $0.sourceID == target.reference.id }.map { (plan.day, $0) }
        }
    }
    private var allowsFollowupCreation: Bool {
        guard archiveState == nil, todo?.isComplete != true, project?.status != "已完成",
              model.matterTargets.contains(where: { $0.reference == target.reference }) else { return false }
        if target.reference.kind == "external" {
            return model.skillSnapshot?.todos.first(where: { $0.id == target.reference.id })?.isComplete == false
        }
        return true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("事项详情").font(.system(size: 21, weight: .semibold))
                    Text(target.reference.sourceLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.matterTargets.first { $0.reference == target.reference }?.title ?? target.title).font(.system(size: 13)).textSelection(.enabled)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("这里保存你确认的进展和决策。历史记录保留当时信息；原待办、项目和钉钉状态单独维护。")
                        .font(.system(size: 12)).foregroundStyle(AssistantTheme.secondaryText)
                    if archiveState == .hidden {
                        Text("此事项仅在本机隐藏，源完成状态尚未核对；可以查看历史，恢复显示后再安排新跟进。").font(.caption).foregroundStyle(.secondary)
                    } else if archiveState == .completed && target.reference.kind == "external" {
                        Text("已完成（最近钉钉查询）；期限等未返回字段不作推断。").font(.caption)
                    } else if !model.matterTargets.contains(where: { $0.reference == target.reference }) {
                        Text("原事项暂不可用，仅保留历史；刷新来源后再核对。").foregroundStyle(.orange)
                    }
                    if let todo {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("状态：" + (todo.isComplete ? "已完成" : "未完成"))
                            Text(todo.dueAt.map { "截止：" + $0.formatted(date: .abbreviated, time: .omitted) } ?? "未设置截止日期")
                            if let owner = todo.owner { Text("负责人：" + owner) }
                            if let name = todo.projectName { Text("项目：" + name) }
                        }.font(.system(size: 12))
                    } else if target.reference.kind == "external", archiveState == nil {
                        if let task = model.skillSnapshot?.todos.first(where: { $0.id == target.reference.id }) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("源状态：" + (task.isComplete ? "已完成" : "未完成") + "（最近同步记录）")
                                Text(task.dueAt.map { "截止：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "未提供截止时间")
                                if let owner = task.owner { Text("负责人：" + owner) }
                                if let name = task.projectName { Text("项目：" + name) }
                            }.font(.system(size: 12))
                        } else { Text("当前源状态不可用，刷新后核对；这里不推断事项已完成。").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let project {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("关联项目：" + project.name).fontWeight(.medium)
                            Text("当前进展：" + (project.progressNote.isEmpty ? "未提供" : project.progressNote))
                            if let value = project.nextStep { Text("下一步：" + value) }
                            if let value = project.blocker { Text("项目阻塞：" + value) }
                            if let value = project.waitingFor { Text("等待：" + value) }
                            Text("项目更新：" + project.updatedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }.font(.system(size: 12))
                    }
                    if let project, target.reference.kind == "project" {
                        ProjectRelatedMatters(project: project)
                    }
                    FollowupSection(target: target, allowsCreation: allowsFollowupCreation)
                    DingTalkEvidenceSection(target: target)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("补充一条记录").font(.system(size: 13, weight: .semibold))
                        Picker("类型", selection: $category) { ForEach(MatterContextPolicy.categories, id: \.self) { Text($0).tag($0) } }
                        TextEditor(text: $draft).frame(minHeight: 70).padding(5)
                            .background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("事项记录内容")
                        HStack {
                            Text("\(draft.count)/1000字；更正会追加记录，保留原有依据。").font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button("确认保存记录") { save() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 1_000 || archiveState == .hidden || !model.matterTargets.contains { $0.reference == target.reference })
                        }
                        if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                    }
                    Divider()
                    Text("跟进记录（\(entries.count)）").font(.system(size: 13, weight: .semibold))
                    if entries.isEmpty { Text("还没有跟进记录。你也可以在对话中交代这件事的新进展，核对卡片后保存。").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.category + " · " + entry.recordedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(entry.content).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            DisclosureGroup(entry.sourceMessageID == nil ? "手动记录原文" : "对话原话依据") {
                                Text(entry.quote).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }.font(.system(size: 11))
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let todo, !(todo.meetingEvidence ?? []).isEmpty || todo.sourceQuote != nil {
                        DisclosureGroup("会议来源") { MeetingEvidenceList(todo: todo) }.font(.system(size: 13))
                    }
                    if !planItems.isEmpty {
                        DisclosureGroup("关联的执行安排（\(planItems.count)）") {
                            ForEach(Array(planItems.prefix(30).enumerated()), id: \.offset) { _, value in
                                Text(value.0 + " · " + value.1.title + " · " + (value.1.isDone ? "安排已勾选" : "安排未勾选"))
                                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
                            }
                            Text("仅按事项ID关联，安排勾选不代表原待办完成；最多展示最近30项。").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.font(.system(size: 13))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 600, height: 640)
            .foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
            .onAppear {
                do { model.matterEntries = try MatterContextStore().load(); baselineRevision = entries.count }
                catch { self.error = error.localizedDescription }
            }
    }
    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = MatterContextEntry(reference: target.reference, category: category, content: text, quote: text, sourceMessageID: nil, recordedAt: Date())
        do {
            try model.saveMatterEntry(entry, expectedRevision: baselineRevision)
            baselineRevision = entries.count; draft = ""; error = nil
        } catch {
            self.error = error.localizedDescription
            if let current = try? MatterContextStore().load() { model.matterEntries = current; baselineRevision = entries.count }
        }
    }
}
