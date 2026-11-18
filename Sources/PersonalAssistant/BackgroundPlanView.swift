import SwiftUI
import ServiceManagement

struct WorkbenchPlanSuggestion: View {
    @EnvironmentObject private var model: AssistantModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            if let result = try? BackgroundPlanStore().state().result,
               result.plan.day == DailyPlanSchedulePolicy.dayKey(for: timeline.date),
               result.plan.timeZone == TimeZone.current.identifier {
                if model.todaySavedPlan == nil { BackgroundPlanSuggestionCard() }
                else {
                    DisclosureGroup("自动建议（未替换当前计划）") { BackgroundPlanSuggestionCard() }
                        .font(.system(size: 11))
                }
            }
        }
    }
}

struct BackgroundPlanSuggestionCard: View {
    @EnvironmentObject private var model: AssistantModel
    @State private var editing: SavedDayPlan?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            if let state = try? BackgroundPlanStore().state(), let result = state.result,
               result.plan.day == DailyPlanSchedulePolicy.dayKey(for: timeline.date), result.plan.timeZone == TimeZone.current.identifier {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("待确认建议").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if !result.plan.steps.isEmpty && model.todaySavedPlan == nil {
                            Button("核对并采用") { editing = result.plan }.font(.system(size: 11))
                                .disabled(model.refreshCount == 0 || model.isRefreshing || model.syncError != nil)
                        }
                    }
                    Text("生成于 " + result.generatedAt.formatted(date: .omitted, time: .shortened) + " · " + result.sourceLabel)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if result.plan.steps.isEmpty {
                        Text("本次读取没有可安排的未完成事项或后续日程。")
                    } else {
                        DisclosureGroup("查看建议（\(result.plan.steps.count)项）") {
                            ForEach(Array(result.plan.steps.enumerated()), id: \.element.id) { index, step in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(index + 1). \(step.title) · \(step.plannedTime.isEmpty ? "时间待定" : step.plannedTime) · 预计\(step.durationMinutes)分钟")
                                    if !step.preparation.isEmpty { Text("准备：" + step.preparation).foregroundStyle(.secondary) }
                                    if !step.reason.isEmpty { Text("依据：" + step.reason).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                            }
                        }
                    }
                    Text(model.todaySavedPlan == nil ? "建议尚未采用，核对后才保存为今日执行计划。" : "你已有今日计划，后台建议未覆盖原安排。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.font(.system(size: 11)).padding(14)
                    .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }.sheet(item: $editing) { initial in
            DayPlanEditor(plan: initial) { model.saveDayPlan($0, expectedRevision: 0) }
        }
    }
}

struct BackgroundPlanStatusDetails: View {
    @EnvironmentObject private var model: AssistantModel
    @State private var actionInProgress = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { timeline in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(model.backgroundDailyPlanEnabled ? "关闭后台计划" : "启用后台计划") {
                        model.setBackgroundDailyPlanEnabled(!model.backgroundDailyPlanEnabled)
                    }
                    Button("系统后台权限") { SMAppService.openSystemSettingsLoginItems() }
                    Spacer()
                }
                if let state = try? BackgroundPlanStore().state() {
                    Text("执行状态：" + (!model.backgroundDailyPlanEnabled && state.status == "running" ? "已关闭，上次执行未完成" : stateLabel(state.status)))
                    if let date = state.lastAttemptAt { Text("最近尝试：" + date.formatted(date: .abbreviated, time: .shortened)) }
                    if let date = state.lastSuccessAt { Text("最近成功：" + date.formatted(date: .abbreviated, time: .shortened)) }
                    if let error = state.error { Text("失败原因：" + error).foregroundStyle(.red) }
                    if model.backgroundDailyPlanEnabled, let next = BackgroundPlanSchedule.next(state: state, now: timeline.date) {
                        Text("下次检查目标：" + next.formatted(date: .abbreviated, time: .shortened) + "（系统唤醒及5分钟检查可能延后）")
                    }
                    if ["failed", "cancelled"].contains(state.status) && model.backgroundDailyPlanEnabled {
                        Button(actionInProgress ? "检查中…" : "立即重试") {
                            actionInProgress = true
                            Task { await model.runScheduledDailyPlan(retry: true); actionInProgress = false }
                        }.disabled(actionInProgress)
                    }
                    DisclosureGroup("执行记录（\(state.history.count)）") {
                        ForEach(state.history.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + stateLabel(entry.status))
                                Text("触发方式：" + triggerLabel(entry.trigger) + (entry.error.map { " · " + $0 } ?? "")).foregroundStyle(.secondary)
                            }.font(.system(size: 10)).padding(.vertical, 4)
                        }
                    }
                    Text("自动失败当天最多尝试3次，前两次失败分别等5、15分钟；可手动重试。电脑睡眠或关机期间不会执行，恢复后仅补当天计划。")
                } else { Text("执行记录无法读取，已保留原文件并暂停写入。").foregroundStyle(.red) }
            }
        }
    }
    private func triggerLabel(_ value: String) -> String {
        ["launchd": "系统后台", "foreground": "打开应用后补跑", "manual-retry": "手动启用或重试"][value] ?? "其他检查"
    }
    private func stateLabel(_ state: String) -> String {
        ["idle": "尚未执行", "running": "正在生成", "success": "生成成功", "failed": "失败", "interrupted": "进程中断", "cancelled": "已取消"][state] ?? state
    }
}
