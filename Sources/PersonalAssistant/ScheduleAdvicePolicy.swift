import Foundation

/// Re-evaluated from source timestamps, without model calls or task mutations.
enum ScheduleAdvicePolicy {
    static func summary(fallback: String, windows: [(startsAt: Date, endsAt: Date)], now: Date) -> String {
        let states = windows.map { CalendarEventPhase.at(now, startsAt: $0.startsAt, endsAt: $0.endsAt) }
        let ended = states.filter { $0 == .ended }.count
        let ongoing = states.filter { $0 == .ongoing }.count
        let upcoming = states.filter { $0 == .upcoming }.count
        guard ended > 0 || ongoing > 0 else { return fallback }
        var parts: [String] = []
        if ended > 0 { parts.append("\(ended)项日程已结束") }
        if ongoing > 0 { parts.append("\(ongoing)项正在进行") }
        if upcoming > 0 { parts.append("\(upcoming)项尚未开始") }
        return parts.joined(separator: "，") + "。待办优先级见下方；日程结束不表示待办完成。"
    }

    static func taskReason(fallback: String?, startsAt: Date?, endsAt: Date?, now: Date) -> String? {
        guard let startsAt, let endsAt else { return fallback }
        switch CalendarEventPhase.at(now, startsAt: startsAt, endsAt: endsAt) {
        case .upcoming: return fallback
        case .ongoing: return "关联日程正在进行；这条待办仍未完成，请按实际进度处理。"
        case .ended: return "关联日程已结束；这条待办仍未完成，请按实际进度继续处理。"
        }
    }
}
