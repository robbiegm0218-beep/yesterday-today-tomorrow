import SwiftUI

struct DayPlanDifferenceView: View {
    let original: SavedDayPlan
    let proposed: SavedDayPlan
    var body: some View {
        let changes = DayPlanReview.differences(from: original, to: proposed)
        let unchanged = original.steps.filter { proposed.steps.contains($0) }.count
        VStack(alignment: .leading, spacing: 12) {
            MemoryPlanPreferenceHints(plan: proposed)
            Text("\(changes.count)项变化 · \(unchanged)项内容保持 · 已完成安排\(proposed.steps.filter(\.isDone).count)项")
                .font(.system(size: 12, weight: .medium))
            if changes.isEmpty { Text("没有安排变化。").foregroundStyle(.secondary) }
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 6) {
                    Text(change.kind + " · " + change.title).fontWeight(.medium)
                    if let before = change.before { Text("原来：" + before).foregroundStyle(AssistantTheme.secondaryText) }
                    if let after = change.after { Text("调整后：" + after) }
                }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 9))
            }
            let warnings = DayPlanReview.warnings(proposed)
            ForEach(Array(warnings.prefix(10).enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if warnings.count > 10 { Text("另有\(warnings.count - 10)项时间提示，请核对完整安排。").font(.caption) }
            Text("重叠按已填写的时间和预计用时检查；时间留空不代表有空，也不包含尚未同步的日程。").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct DayPlanAdjustmentPreview: View {
    @EnvironmentObject private var model: AssistantModel
    let change: DayPlanAdjustment
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("调整原因：" + change.reason)
            Text("你的原话：" + change.quote).foregroundStyle(AssistantTheme.secondaryText).textSelection(.enabled)
            DayPlanDifferenceView(original: change.original, proposed: change.proposed)
            if let current = model.todaySavedPlan, current != change.original, current.steps != change.proposed.steps {
                Text("当前计划已有新版本；这张旧提案不能覆盖，请重新调整。").foregroundStyle(.orange)
            }
        }.font(.system(size: 12))
    }
}

extension AssistantModel {
    func planChangeHints(for plan: SavedDayPlan) -> [String] {
        var result: [String] = []
        for step in plan.steps where !step.isDone && step.sourceKind != "note" {
            if let ref = dayPlanReferences.first(where: { $0.matches(kind: step.sourceKind, sourceID: step.sourceID) }) {
                if String(ref.title.prefix(160)) != step.title || (ref.kind == "event" && (ref.time != step.plannedTime || min(480, max(1, ref.duration)) != step.durationMinutes)) {
                    result.append("「\(step.title)」的来源内容或日程时间有变化。")
                }
            } else { result.append("「\(step.title)」的来源当前不可用，请核对完成、隐藏或同步状态。") }
        }
        let recent = matterEntries.filter { entry in
            entry.recordedAt > plan.updatedAt && plan.steps.contains { step in
                !step.isDone && step.sourceKind == entry.reference.kind && step.sourceID == entry.reference.id
            }
        }
        if !recent.isEmpty { result.append("关联事项在保存计划后新增了\(recent.count)条进展记录，可核对是否需要调整。") }
        return result
    }
    func requestDayPlanAdjustment() {
        let request = "请结合当前来源和已记录的事项进展，局部调整今天的计划；保留已完成和未受影响的安排，展示前后差异及原因，确认后再保存。"
        draft = draft.isEmpty ? request : draft + "\n" + request
    }
}
