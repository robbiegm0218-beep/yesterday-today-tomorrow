import Foundation

enum AssistantFactTime {
    // Clock facts are rendered from source fields. Generated prose must not
    // introduce a second, potentially contradictory clock representation.
    static func containsClockClaim(_ text: String) -> Bool {
        text.range(of: #"(?<!\d)\d{1,2}[:：]\d{2}(?!\d)|[0-9一二三四五六七八九十两]+[点时]|上午|下午|凌晨|中午|傍晚"#, options: .regularExpression) != nil
    }

    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func freshness(lastSync: Date?, failed: Bool, syncing: Bool, now: Date, calendar: Calendar = .current) -> String {
        guard let lastSync else { return "尚未同步，无法确认外部日程与待办" }
        if failed { return "刷新失败，仅有上次同步数据" }
        if !calendar.isDate(lastSync, inSameDayAs: now) { return "跨日旧快照，无法确认今天的外部安排" }
        if syncing { return "正在刷新，当前为上次同步数据" }
        if now.timeIntervalSince(lastSync) > 900 { return "超过15分钟未同步，外部事项可能已变化" }
        return "最近同步快照"
    }
}
