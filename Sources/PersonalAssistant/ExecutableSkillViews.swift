import SwiftUI

struct SkillRunnerInput: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    let definition: ExecutableSkillDefinition
    @State private var input = ""
    @State private var title = "会议纪要"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("执行“\(definition.name)”").font(.title2.weight(.semibold))
            Text("输入：" + definition.input).font(.callout)
            if definition.id == "minutes-actions" {
                TextField("纪要来源标题", text: $title).textFieldStyle(.roundedBorder)
                Text("粘贴纪要全文；执行时发送到已配置的模型，仅在执行记录保留行动摘录。未知负责人和时间须在确认前核对。")
                    .font(.caption).foregroundStyle(AssistantTheme.secondaryText)
            } else { Text("可补充今天的重点、已确认的空闲时间或调整要求；留空时结合当前事项生成建议。") .font(.caption).foregroundStyle(AssistantTheme.secondaryText) }
            TextEditor(text: $input).frame(height: 160).font(.body)
                .accessibilityLabel(definition.id == "minutes-actions" ? "技能纪要输入" : "技能规划要求")
                .padding(8).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 8))
            Text("边界：" + definition.boundary).font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("步骤：" + definition.steps.joined(separator: " → ")).font(.caption).fixedSize(horizontal: false, vertical: true)
            Text(definition.recovery).font(.caption).foregroundStyle(AssistantTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let status = model.skillStatus { Text(status).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button("开始准备，确认前不保存事项") {
                    let count = model.skillRuns.count, oldFirst = model.skillRuns.first?.id
                    model.startExecutableSkill(definition.id, input: input, title: title)
                    if model.skillRuns.count > count || model.skillRuns.first?.id != oldFirst { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(model.isExecutingSkill || model.isSending || (definition.id == "minutes-actions" && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(24).frame(width: 570).foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
    }
}

struct SkillRunHistory: View {
    @EnvironmentObject private var model: AssistantModel
    let onOpen: (SkillRun) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("技能执行记录").font(.headline)
            if model.skillRuns.isEmpty { Text("执行型技能会在这里显示步骤、待确认结果和回查证据。普通对话和旧纪要入口不补造执行记录。") .font(.caption).foregroundStyle(AssistantTheme.secondaryText) }
            ForEach(model.skillRuns) { run in
                Button { onOpen(run) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(ExecutableSkillDefinition.find(run.skillID)?.name ?? run.skillID).fontWeight(.medium); Spacer(); Text(run.status.label) }
                        Text("\(run.completedSteps)/5步 · " + run.startedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(AssistantTheme.secondaryText)
                        if let result = run.resultSummary { Text(result) }
                        if let error = run.error { Text(error).foregroundStyle(.orange) }
                    }.font(.caption).fixedSize(horizontal: false, vertical: true).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityLabel("查看执行：" + (ExecutableSkillDefinition.find(run.skillID)?.name ?? run.skillID) + "，" + run.status.label)
            }
        }
    }
}

struct SkillRunDetail: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    let runID: UUID
    @State private var selected = Set<String>()
    @State private var linkSelections: [String: String] = [:]
    @State private var retryDefinition: ExecutableSkillDefinition?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("技能执行详情").font(.title2.weight(.semibold)); Spacer(); Button("关闭") { dismiss() } }
            if let run = model.skillRuns.first(where: { $0.id == runID }), let definition = ExecutableSkillDefinition.find(run.skillID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(definition.name + " · " + run.status.label).font(.headline)
                        Text(run.sourceSummary).font(.caption).foregroundStyle(AssistantTheme.secondaryText)
                        ForEach(Array(definition.steps.enumerated()), id: \.offset) { index, step in
                            Label(step, systemImage: index < run.completedSteps ? "checkmark.circle.fill" : (index == run.completedSteps && run.status == .running ? "hourglass" : "circle"))
                                .font(.callout).foregroundStyle(index < run.completedSteps ? AssistantTheme.accent : AssistantTheme.secondaryText)
                        }
                        if let action = run.action {
                            Text(action.summary).font(.headline)
                            switch action.operation {
                            case .saveDayPlan(let plan, _):
                                MemoryPlanPreferenceHints(plan: plan)
                                ForEach(plan.steps) { step in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(step.title) · \(step.plannedTime.isEmpty ? "时间待定" : step.plannedTime) · \(step.durationMinutes)分钟")
                                        if !step.reason.isEmpty { Text("依据：" + step.reason).foregroundStyle(AssistantTheme.secondaryText) }
                                        if !step.preparation.isEmpty { Text("准备：" + step.preparation) }
                                    }.font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            case .adjustDayPlan(let change): DayPlanDifferenceView(original: change.original, proposed: change.proposed)
                            default: Text("该工具不在技能边界内，不能执行。")
                            }
                        }
                        ForEach(run.meetingProposals) { proposal in
                            VStack(alignment: .leading, spacing: 8) {
                                if run.status == .awaitingConfirmation {
                                    Toggle(proposal.title, isOn: Binding(get: { selected.contains(proposal.id) }, set: { if $0 { selected.insert(proposal.id) } else { selected.remove(proposal.id) } }))
                                    if let existing = MeetingFollowupPolicy.existing(for: proposal.evidence, todos: model.personalTodos) { Text("已有关联：" + existing.title + "；再次确认不会重复创建。") .font(.caption).foregroundStyle(AssistantTheme.accent) }
                                    if selected.contains(proposal.id) {
                                        Picker("保存方式", selection: Binding(get: { linkSelections[proposal.id] ?? "" }, set: { linkSelections[proposal.id] = $0 })) {
                                            Text("新建本机待办（自动防重复）").tag("")
                                            ForEach(Array(model.personalTodos.prefix(200))) { todo in Text("关联：" + todo.title + (todo.isComplete ? "（已完成）" : "")).tag(todo.id.uuidString) }
                                        }.font(.caption)
                                        Text("关联候选最多显示200项；选择已有待办只追加来源，不改变完成状态。") .font(.caption2).foregroundStyle(AssistantTheme.secondaryText)
                                    }
                                } else { Text(proposal.title).fontWeight(.medium) }
                                Text("负责人：\(proposal.evidence.owner.isEmpty ? "待核对" : proposal.evidence.owner) · 截止描述：\(proposal.evidence.dueText.isEmpty ? "未提供" : proposal.evidence.dueText)") .font(.caption)
                                Text("原文：" + proposal.evidence.quote).font(.caption).foregroundStyle(AssistantTheme.secondaryText).textSelection(.enabled)
                            }.fixedSize(horizontal: false, vertical: true).padding(12).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 9))
                        }
                        if let summary = run.resultSummary { Text(summary).foregroundStyle(AssistantTheme.accent) }
                        if let error = run.error { Text(error).foregroundStyle(.orange) }
                        Text(definition.boundary).font(.caption)
                        Text(definition.recovery).font(.caption).foregroundStyle(AssistantTheme.secondaryText)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if [.running, .awaitingConfirmation].contains(run.status) { Button("取消本次执行") { model.cancelSkillRun(run.id) } }
                    if [.failed, .cancelled, .verificationNeeded].contains(run.status) { Button("重新准备（重新输入）") { retryDefinition = definition }.disabled(model.isExecutingSkill || model.isSending) }
                    Spacer()
                    if run.status == .verificationNeeded { Button("只回查，不重复保存") { model.verifySkillRun(run.id) } }
                    if run.status == .awaitingConfirmation {
                        Button(run.skillID == "daily-planning" ? "确认保存本机计划" : "确认创建或关联所选本机待办") {
                            let links = linkSelections.reduce(into: [String: UUID]()) { result, pair in if let id = UUID(uuidString: pair.value) { result[pair.key] = id } }
                            model.confirmSkillRun(run.id, selected: selected, links: links)
                        }.buttonStyle(.borderedProminent).disabled(model.isExecutingSkill || (run.skillID == "minutes-actions" && selected.isEmpty))
                    }
                }
            } else { Text("执行记录已不在列表中，请返回技能页。") }
            if let status = model.skillStatus { Text(status).font(.caption).foregroundStyle(.orange) }
        }.padding(24).frame(width: 650, height: 630).foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
            .sheet(item: $retryDefinition) { definition in SkillRunnerInput(definition: definition).environmentObject(model) }
    }
}
