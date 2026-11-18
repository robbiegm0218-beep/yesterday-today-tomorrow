import SwiftUI

struct TodayScheduleSection: View {
    let items: [ScheduleItem]
    let awaitingSnapshot: Bool
    @State private var showingEnded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let active = items.filter { CalendarEventPhase.at(timeline.date, startsAt: $0.startsAt, endsAt: $0.endsAt) != .ended }
            let ended = items.filter { CalendarEventPhase.at(timeline.date, startsAt: $0.startsAt, endsAt: $0.endsAt) == .ended }
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "日程", subtitle: "今天的会议、活动与相关准备")
                if items.isEmpty {
                    Text(awaitingSnapshot ? "尚未取得今天的日程，请刷新后查看。" : "今天暂无日程。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(15)
                        .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    if active.isEmpty {
                        Text("今天的日程均已结束。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else { rows(active, now: timeline.date) }
                    if !ended.isEmpty {
                        DisclosureGroup("已结束日程（\(ended.count)）", isExpanded: $showingEnded) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("按日程结束时间归档，不代表关联待办已完成。")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                rows(ended, now: timeline.date)
                            }.padding(.top, 8)
                        }.font(.system(size: 12, weight: .medium))
                    }
                }
            }
        }
    }

    private func rows(_ events: [ScheduleItem], now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, item in
                ScheduleRow(item: item, phase: CalendarEventPhase.at(now, startsAt: item.startsAt, endsAt: item.endsAt))
                if index < events.count - 1 { Divider().padding(.leading, 96) }
            }
        }.padding(.horizontal, 14)
            .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
