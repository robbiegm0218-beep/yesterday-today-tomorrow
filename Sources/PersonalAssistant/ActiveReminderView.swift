import SwiftUI
import AppKit

enum ActiveReminderLabels {
    static func status(_ value: String) -> String {
        ["planned": "已安排，待触发", "submitting": "提交中", "submitted": "已提交系统", "system-record": "系统通知中心有记录", "cancelled": "已取消", "withdrawn": "已撤下", "missed": "已错过，不补发", "failed": "提交失败", "uncertain": "提交结果待核对，未重发"][value] ?? value
    }
}

struct ActiveReminderDetails: View {
    @EnvironmentObject private var model: AssistantModel
    @State private var checking = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { timeline in
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Button(model.reminderConfiguring ? "处理权限中…" : model.proactiveRemindersEnabled ? "关闭主动提醒" : "开启主动提醒") { model.setProactiveRemindersEnabled(!model.proactiveRemindersEnabled) }
                        .disabled(model.reminderConfiguring)
                    Button("系统通知设置") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                }
                Text(model.reminderStatus)
                if let state = try? ActiveReminderStore().state() {
                    let day = DailyPlanSchedulePolicy.dayKey(for: timeline.date)
                    let current = state.records.filter { $0.day == day }
                    let planned = current.filter { $0.status == "planned" }.sorted { $0.fireDate < $1.fireDate }
                    Text("今日已用额度：\(ActiveReminderPolicy.quota(current, day: day))/\(MemoryActionPolicy.reminderLimit(memories: model.memories, relationshipLimit: model.relationshipStage.dailyReminderLimit)) · 待触发：\(planned.count)")
                    if let next = planned.first { Text("下次计划：" + next.fireDate.formatted(date: .omitted, time: .shortened) + " · " + next.source.title) }
                    if let error = state.error { Text(error).foregroundStyle(.red) }
                    HStack {
                        Button(checking ? "核对中…" : "重新核对并重试失败项") { run(retry: true) }
                        Button("测试提醒（占1次额度）") { run(test: true) }
                    }.disabled(!model.proactiveRemindersEnabled || checking || model.reminderConfiguring)
                    Text("日常事项每天最多一次；每版跟进按确认时间提醒一次，改期仍计入当天额度。按亲密度最多5次；超过10分钟不追补，完成或隐藏后撤下。")
                    DisclosureGroup("提醒记录（\(state.history.count)）") {
                        ForEach(state.history.reversed()) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.date.formatted(date: .abbreviated, time: .shortened) + " · " + ActiveReminderLabels.status(event.status))
                                Text(event.title)
                                if let detail = event.detail { Text(detail).foregroundStyle(.secondary) }
                            }.font(.system(size: 10)).padding(.vertical, 5)
                        }
                    }
                } else { Text("提醒记录无法读取，已暂停新增；原文件保留。").foregroundStyle(.red) }
                Text("提醒先在本机安排，到点重核后才提交系统；免打扰期间不提交。系统专注模式等仍可能影响展示，提交成功不代表你已看到。点击通知可打开工作台。")
            }.font(.system(size: 12)).foregroundStyle(AssistantTheme.secondaryText)
        }
    }
    private func run(test: Bool = false, retry: Bool = false) {
        checking = true
        Task { await model.refreshActiveReminders(force: true, test: test, retryFailed: retry); checking = false }
    }
}
