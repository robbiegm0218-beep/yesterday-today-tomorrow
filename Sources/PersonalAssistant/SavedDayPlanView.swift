import SwiftUI

struct DayPlanActionPreview: View {
    @EnvironmentObject private var model: AssistantModel
    let plan: SavedDayPlan
    let expectedRevision: Int
    let action: PendingAssistantAction
    let onSaved: () -> Void
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MemoryPlanPreferenceHints(plan: plan)
            if action.status == .pending && (model.refreshCount == 0 || model.syncError != nil) {
                Text("外部数据未完整读取。当前提案只参考已知内容，保存前请刷新工作台核对。")
                    .foregroundStyle(AssistantTheme.accent)
            }
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(index + 1). \(step.title)").fontWeight(.medium)
                    Text("\(step.plannedTime.isEmpty ? "时间待定" : step.plannedTime) · 预计\(step.durationMinutes)分钟")
                    if !step.preparation.isEmpty { Text("准备：" + step.preparation) }
                    if !step.reason.isEmpty { Text("依据：" + step.reason) }
                }
            }
            if action.status == .pending {
                Button("调整后确认保存") { editing = true }
            }
        }.font(.system(size: 12))
        .sheet(isPresented: $editing) {
            DayPlanEditor(plan: plan) { draft in
                guard model.saveDayPlan(draft, expectedRevision: expectedRevision, actionID: action.id) else { return false }
                onSaved()
                return true
            }
        }
    }
}

struct SavedDayPlanCard: View {
    @EnvironmentObject private var model: AssistantModel
    @State private var editingPlan: SavedDayPlan?
    @State private var history = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日计划").font(.system(size: 15, weight: .semibold))
                Spacer()
                if model.todaySavedPlan != nil { Button("对话调整") { model.requestDayPlanAdjustment() }.font(.system(size: 11)) }
                Button("历史") { history = true }.font(.system(size: 11))
                Button(model.todaySavedPlan == nil ? "手动安排" : "调整") {
                    editingPlan = model.todaySavedPlan ?? SavedDayPlan(day: DailyPlanSchedulePolicy.dayKey(for: Date()), timeZone: TimeZone.current.identifier, steps: [])
                }.font(.system(size: 11))
            }
            Text("执行安排单独保存；勾选安排不会完成原待办，时间不会同步到日历。")
                .font(.system(size: 11)).foregroundStyle(AssistantTheme.secondaryText)
            if let plan = model.todaySavedPlan {
                let hints = model.planChangeHints(for: plan)
                if !hints.isEmpty {
                    DisclosureGroup("发现\(hints.count)项待核对变化") {
                        ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in Text(hint).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                        Button("通过对话建议调整") { model.requestDayPlanAdjustment() }.font(.system(size: 11))
                    }.font(.system(size: 12)).foregroundStyle(AssistantTheme.accent)
                }
                Text("已保存 · 第\(plan.revision)版 · \(plan.steps.filter(\.isDone).count)/\(plan.steps.count)项完成")
                    .font(.system(size: 11)).foregroundStyle(AssistantTheme.secondaryText)
                if plan.steps.isEmpty { Text("今天的计划已清空，可继续添加安排。").font(.system(size: 12)) }
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Button { model.setDayPlanStepDone(step.id, done: !step.isDone) } label: {
                            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.plain).accessibilityLabel(step.isDone ? "恢复这项安排" : "完成这项安排")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(index + 1). \(step.title)").font(.system(size: 13, weight: .medium)).strikethrough(step.isDone)
                            Text("\(step.plannedTime.isEmpty ? "时间待定" : step.plannedTime) · 预计\(step.durationMinutes)分钟 · \(sourceName(step.sourceKind))")
                                .font(.system(size: 11)).foregroundStyle(AssistantTheme.secondaryText)
                            if let origin = step.carriedFrom { Text("衔接自" + origin.day + "的安排；本次勾选独立保存。").font(.system(size: 10)).foregroundStyle(AssistantTheme.secondaryText) }
                            if !step.preparation.isEmpty { Text("准备：" + step.preparation).font(.system(size: 11)) }
                            if !step.reason.isEmpty { Text("依据：" + step.reason).font(.system(size: 11)).foregroundStyle(AssistantTheme.secondaryText) }
                            if step.sourceKind != "note" {
                                if let target = model.matterTargets.first(where: { $0.reference.kind == step.sourceKind && $0.reference.id == step.sourceID }) {
                                    MatterContextButton(target: target)
                                }
                                if let ref = model.dayPlanReferences.first(where: { $0.matches(kind: step.sourceKind, sourceID: step.sourceID) }) {
                                    if String(ref.title.prefix(160)) != step.title || (ref.kind == "event" && ref.time != step.plannedTime) {
                                        Text("源事项已变化，请调整计划后保存。").font(.system(size: 11)).foregroundStyle(AssistantTheme.accent)
                                    }
                                } else {
                                    Text("源事项已完成、隐藏、删除或尚未同步；安排记录保留。").font(.system(size: 11)).foregroundStyle(AssistantTheme.accent)
                                }
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 5)
                }
            } else {
                Text("今天还没有已保存的计划。可以手动安排，或让助手生成后确认保存。")
                    .font(.system(size: 12)).foregroundStyle(AssistantTheme.secondaryText)
                Button("通过对话安排今天") {
                    let request = "帮我安排今天，结合现有日程和待办，先给我可调整的计划，确认后再保存。"
                    model.draft = model.draft.isEmpty ? request : model.draft + "\n" + request
                }.font(.system(size: 12))
            }
            WorkbenchPlanSuggestion()
            DisclosureGroup("回顾昨天与衔接") { DayReviewCard().padding(.top, 8) }
                .font(.system(size: 12))
            if let status = model.dayPlanStatus { Text(status).font(.system(size: 11)).foregroundStyle(AssistantTheme.secondaryText) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .sheet(item: $editingPlan) { initial in
                DayPlanEditor(plan: initial) { draft in model.saveDayPlan(draft, expectedRevision: initial.revision) }
            }
            .sheet(isPresented: $history) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("保存过的计划").font(.title2); Spacer(); Button("完成") { history = false } }
                    Text("最近30条记录，仅查看；每天的计划独立保存，不自动沿用昨天的安排。").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if model.savedDayPlans.isEmpty { Text("还没有保存记录。") }
                            ForEach(model.savedDayPlans.prefix(30)) { plan in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(plan.day) · 第\(plan.revision)版").fontWeight(.semibold)
                                    if let decisions = plan.reviewDecisions, !decisions.isEmpty { Text("已记录\(decisions.count)项回顾决策").font(.caption).foregroundStyle(.secondary) }
                                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                                        Text("\(step.isDone ? "✓" : "○") \(index + 1). \(step.title) · \(step.durationMinutes)分钟")
                                    }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }.padding(24).frame(width: 600, height: 520)
            }
    }
}

struct DayPlanEditor: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State var plan: SavedDayPlan
    let onSave: (SavedDayPlan) -> Bool
    @State private var error = ""
    @State private var original: SavedDayPlan?
    @State private var reviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(reviewing ? "核对计划变化" : "调整今日计划").font(.system(size: 21, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }
                if reviewing { Button("返回编辑") { reviewing = false } }
                Button(reviewing ? "确认保存计划" : "预览调整") {
                    do {
                        try SavedDayPlanPolicy.validateShape(plan)
                        if !reviewing { reviewing = true; error = "" }
                        else if onSave(plan) { dismiss() } else { error = model.dayPlanStatus ?? "未保存。" }
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
            Text("\(plan.day) · 时间是个人安排意向，用时是估计值。请核对日程冲突；不会创建或修改源待办/日历。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if reviewing {
                        DayPlanDifferenceView(original: original ?? plan, proposed: plan)
                    } else {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("\(index + 1). \(sourceName(step.sourceKind))").fontWeight(.medium)
                                Spacer()
                                Button { plan.steps.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).accessibilityLabel("上移安排")
                                Button { plan.steps.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == plan.steps.count - 1).accessibilityLabel("下移安排")
                                Button("移除") { plan.steps.remove(at: index) }
                            }
                            TextField("安排内容", text: $plan.steps[index].title).disabled(step.sourceKind != "note").accessibilityLabel("安排内容")
                            if step.sourceKind == "event" {
                                Text("源日程时间：" + (model.dayPlanReferences.first { $0.matches(kind: "event", sourceID: step.sourceID) }?.time ?? step.plannedTime))
                            } else {
                                TextField("安排时间 HH:mm（可留空）", text: $plan.steps[index].plannedTime)
                            }
                            HStack {
                                Text("预计用时")
                                TextField("分钟", value: $plan.steps[index].durationMinutes, format: .number).frame(width: 70)
                                Text("分钟")
                            }
                            TextField("提前准备什么（可选）", text: $plan.steps[index].preparation, axis: .vertical).lineLimit(1...4)
                            TextField("安排依据（可选）", text: $plan.steps[index].reason, axis: .vertical).lineLimit(1...4)
                            if step.sourceKind != "note" {
                                Button("改为独立安排（不再关联源事项）") {
                                    plan.steps[index].sourceKind = "note"
                                    plan.steps[index].sourceID = nil
                                }
                            }
                        }.font(.system(size: 12)).textFieldStyle(.roundedBorder).padding(14)
                            .background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button("添加一项独立安排") { plan.steps.append(DayPlanStep(title: "")) }.disabled(plan.steps.count >= 20)
                    }
                }
            }
        }.padding(24).frame(width: 660, height: 580)
            .foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
        .onAppear {
            if original == nil { original = plan }
            for index in plan.steps.indices where !plan.steps[index].isDone && plan.steps[index].sourceKind != "note" {
                if let ref = model.dayPlanReferences.first(where: { $0.matches(kind: plan.steps[index].sourceKind, sourceID: plan.steps[index].sourceID) }) {
                    plan.steps[index].title = String(ref.title.prefix(160))
                    if ref.kind == "event" { plan.steps[index].plannedTime = ref.time; plan.steps[index].durationMinutes = min(480, max(1, ref.duration)) }
                }
            }
        }
    }
}

private func sourceName(_ kind: String) -> String {
    switch kind { case "personal": "本地待办"; case "external": "外部待办"; case "event": "源日程"; default: "独立安排" }
}
