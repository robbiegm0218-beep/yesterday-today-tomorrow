import SwiftUI
import UserNotifications

struct ScheduledActivitiesView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var notificationPermission = "读取中"
    @State private var pendingTimes: [Date] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("定时任务").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("刷新状态") { Task { await refreshStatus() } }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("查看助手的自动安排与提醒状态")
                .font(.system(size: 13)).foregroundStyle(AssistantTheme.secondaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    taskCard(title: "每日计划", icon: "sun.max", status: model.backgroundDailyPlanEnabled ? "已配置" : "未启用") {
                        Text("计划时间：每天 \(DailyPlanSchedulePolicy.scheduledHour):00（本机时区）")
                        Text("汇总日程、待办和项目进度，结果在工作台查看。")
                        Text(model.backgroundDailyPlanStatus)
                        BackgroundPlanStatusDetails()
                    }
                    taskCard(title: "主动提醒", icon: "bell", status: model.proactiveRemindersEnabled ? "已开启" : "未启用") {
                        Text("结合亲密度与个人偏好，每天最多 \(MemoryActionPolicy.reminderLimit(memories: model.memories, relationshipLimit: model.relationshipStage.dailyReminderLimit)) 次，上限5次。")
                        Text("日常提醒时段：" + ReminderSchedulePolicy.slots.map { String(format: "%02d:%02d", $0.hour, $0.minute) }.joined(separator: "、"))
                        Text("事项跟进按确认时间核对，与日常提醒共用额度。")
                        Text("免打扰：21:00–次日09:00、12:30–13:00。")
                        Text("系统通知权限：\(notificationPermission)")
                        Text("系统待发送提醒：\(pendingTimes.count) 条")
                        if let next = pendingTimes.first {
                            Text("下一条：" + next.formatted(date: .abbreviated, time: .shortened))
                        }
                        ActiveReminderDetails()
                    }
                    Text("后台计划保存建议，核对后可采用；不会覆盖已有今日计划。主动提醒需要单独开启并获得系统通知许可。")
                        .font(.system(size: 12)).foregroundStyle(AssistantTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(24).frame(width: 600, height: 580)
        .foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
        .task {
            while !Task.isCancelled {
                await refreshStatus()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func taskCard<Content: View>(title: String, icon: String, status: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(status).font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(AssistantTheme.selection, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 7, content: content)
                .font(.system(size: 12)).foregroundStyle(AssistantTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AssistantTheme.border.opacity(0.5), lineWidth: 1))
    }

    @MainActor
    private func refreshStatus() async {
        model.refreshDailyPlanAgentStatus()
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: notificationPermission = "尚未申请"
        case .denied: notificationPermission = "未允许"
        case .authorized: notificationPermission = "已允许"
        case .provisional: notificationPermission = "临时允许"
        @unknown default: notificationPermission = "未知"
        }
        let requests = await center.pendingNotificationRequests()
        pendingTimes = requests.filter { $0.identifier.hasPrefix("yuan-daily-reminder-") || $0.identifier.hasPrefix(ActiveReminderPolicy.prefix) }
            .compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }.sorted()
    }
}
