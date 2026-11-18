import Foundation

struct DingTalkDailyDataSource: DailyDataSource {
    private let client: any DingTalkReading
    private let selectedProfileIDs: () -> Set<String>

    init(client: any DingTalkReading = DingTalkCLIClient(), selectedProfileIDs: @escaping () -> Set<String> = {
        Set(AssistantRuntime.preferences.stringArray(forKey: "dingTalkSelectedProfiles") ?? [])
    }) {
        self.client = client
        self.selectedProfileIDs = selectedProfileIDs
    }

    func loadSnapshot(at date: Date) async throws -> DailyDataSnapshot {
        let selectedIDs = selectedProfileIDs()
        guard !selectedIDs.isEmpty else {
            return DailyDataSnapshot(events: [], todos: [], sourceLabel: "本机个人事项", usesDemoData: false)
        }

        let profiles = try client.listProfiles().filter { selectedIDs.contains($0.id) }
        guard Set(profiles.map(\.id)) == selectedIDs else { throw DingTalkDataSourceError.selectedProfileUnavailable }

        let bounds = dayBounds(for: date)
        var events: [CalendarEvent] = []
        var todos: [TodoRecord] = []
        for profile in profiles {
            events += try loadEvents(for: profile, from: bounds.start, to: bounds.end)
            todos += try loadOpenTodos(for: profile)
        }
        return DailyDataSnapshot(
            events: events,
            todos: todos,
            sourceLabel: "钉钉（\(profiles.map(\.corpName).uniqued().joined(separator: "、"))）",
            usesDemoData: false
        )
    }

    private func loadEvents(for profile: DingTalkProfile, from start: Date, to end: Date) throws -> [CalendarEvent] {
        let result = try client.run(.calendarEvents(start: isoString(start), end: isoString(end)), profile: profile)
        let root = try decodedObject(result)
        let payload = resultObject(root)
        guard payload["hasMore"] as? Bool != true else { throw DingTalkDataSourceError.incompleteCalendar }
        let records = try array(in: payload, keys: ["events"])
        return try records.map { record in
            guard let id = string(record, keys: ["id", "eventId"]),
                  let title = string(record, keys: ["summary", "title"]),
                  let startValue = value(record, keys: ["start", "startTime"]),
                  let endValue = value(record, keys: ["end", "endTime"]),
                  let startsAt = date(startValue),
                  let endsAt = date(endValue), endsAt >= startsAt else { throw DingTalkDataSourceError.invalidResponse }
            let detail = string(record, keys: ["description", "location"]) ?? ""
            let url = string(record, keys: ["url", "link"]).flatMap(URL.init(string:))
            return CalendarEvent(
                id: "dingtalk-\(profile.id)-\(id)",
                title: title,
                startsAt: startsAt,
                endsAt: endsAt,
                detail: detail,
                projectName: nil,
                sourceURL: url
            )
        }
    }

    private func loadOpenTodos(for profile: DingTalkProfile) throws -> [TodoRecord] {
        var records: [TodoRecord] = []
        var seenIDs = Set<String>()
        var page = 1
        while page <= 40 {
            let result = try client.run(.openTodos(page: page, size: 20), profile: profile)
            let root = try decodedObject(result)
            let resultObject = resultObject(root)
            let cards = try array(in: resultObject, keys: ["todoCards", "tasks", "items"])
            let parsed = try cards.map { record in
                guard let id = string(record, keys: ["taskId", "id"]),
                      let title = string(record, keys: ["title", "subject", "name"]) else { throw DingTalkDataSourceError.invalidResponse }
                let dueAt = value(record, keys: ["planFinishTime", "dueTime", "dueAt", "dueDate", "deadline"]).flatMap(date)
                let priority = importance(value(record, keys: ["priority", "priorityLevel"]))
                let owner = string(record, keys: ["executorName", "ownerName"])
                let url = string(record, keys: ["url", "link"]).flatMap(URL.init(string:))
                return TodoRecord(
                    id: "dingtalk-\(profile.id)-\(id)",
                    title: title,
                    dueAt: dueAt,
                    importance: priority,
                    projectName: nil,
                    relatedEventID: nil,
                    sourceURL: url,
                    isComplete: false,
                    owner: owner
                )
            }
            let fresh = parsed.filter { seenIDs.insert($0.id).inserted }
            records += fresh
            let hasMore = resultObject["hasMore"] as? Bool ?? false
            guard hasMore else { break }
            guard !fresh.isEmpty, page < 40 else { throw DingTalkDataSourceError.incompleteTodos }
            page += 1
        }
        return records
    }

    private func decodedObject(_ result: DingTalkCLIResult) throws -> [String: Any] {
        guard result.exitCode == 0,
              let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              object["ok"] as? Bool != false,
              object["success"] as? Bool != false,
              object["error"] == nil,
              object["outcome"] as? String != "partial_success",
              object["outcome"] as? String != "failure" else {
            throw DingTalkDataSourceError.queryFailed
        }
        return object
    }

    private func resultObject(_ root: [String: Any]) -> [String: Any] {
        root["result"] as? [String: Any] ?? root["data"] as? [String: Any] ?? root
    }

    private func array(in object: [String: Any], keys: [String]) throws -> [[String: Any]] {
        for key in keys {
            if let value = object[key] as? [[String: Any]] { return value }
        }
        throw DingTalkDataSourceError.invalidResponse
    }

    private func value(_ object: [String: Any], keys: [String]) -> Any? {
        keys.lazy.compactMap { object[$0] }.first { !($0 is NSNull) }
    }

    private func string(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private func date(_ value: Any) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        if let text = value as? String {
            if let raw = Double(text) {
                guard raw > 0 else { return nil }
                return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
            }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            let local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX")
            local.timeZone = .current
            local.isLenient = false
            for pattern in [
                "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd"
            ] {
                local.dateFormat = pattern
                if let date = local.date(from: text) { return date }
            }
        }
        if let object = value as? [String: Any] {
            for key in ["dateTime", "timestamp", "time", "date", "value"] {
                if let nested = object[key], let parsed = date(nested) { return parsed }
            }
        }
        return nil
    }

    private func importance(_ value: Any?) -> TaskImportance? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.intValue >= 30 ? .high : .normal }
        guard let text = value as? String else { return nil }
        if ["30", "40", "high", "urgent", "紧急", "较高", "高"].contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return .high
        }
        return .normal
    }

    private func dayBounds(for date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: date)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private enum DingTalkDataSourceError: LocalizedError {
    case selectedProfileUnavailable
    case queryFailed
    case invalidResponse
    case incompleteTodos
    case incompleteCalendar

    var errorDescription: String? {
        switch self {
        case .selectedProfileUnavailable:
            "已选的钉钉组织 profile 不可用，请在钉钉接入设置中重新选择。"
        case .queryFailed:
            "钉钉读取失败。请检查 DWS 登录状态和组织授权后重试；未修改钉钉数据。"
        case .invalidResponse:
            "钉钉返回了无法识别的数据，未覆盖上次成功同步的工作台。请刷新重试。"
        case .incompleteTodos:
            "钉钉待办分页未完整返回（分页停滞或达到 40 页上限），已保留上次成功同步的数据。"
        case .incompleteCalendar:
            "当天日程尚有后续分页，当前未完成全部读取；已保留上次成功同步的数据。"
        }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
