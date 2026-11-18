import Foundation

enum DailyPlanSchedulePolicy {
    static let scheduledHour = 9

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func isRefreshDue(now: Date, lastScheduledDay: String?, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour], from: now)
        guard let hour = components.hour, hour >= scheduledHour else { return false }
        return lastScheduledDay != dayKey(for: now, calendar: calendar)
    }
}

enum TaskImportance: Int, Codable, Comparable {
    case low = 1
    case normal = 2
    case high = 3

    static func < (lhs: TaskImportance, rhs: TaskImportance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct CalendarEvent: Identifiable, Codable {
    let id: String
    let title: String
    let startsAt: Date
    let endsAt: Date
    let detail: String
    var projectName: String?
    let sourceURL: URL?
}

struct TodoRecord: Identifiable, Codable {
    let id: String
    let title: String
    let dueAt: Date?
    let importance: TaskImportance?
    var projectName: String?
    var relatedEventID: String?
    let sourceURL: URL?
    let isComplete: Bool
    var isPersonal: Bool = false
    var owner: String? = nil
    var dueText: String? = nil
    var sourceQuote: String? = nil
}

struct DailyDataSnapshot {
    let events: [CalendarEvent]
    let todos: [TodoRecord]
    let sourceLabel: String
    let usesDemoData: Bool

    func includingPersonalTodos(_ personalTodos: [PersonalTodo]) -> DailyDataSnapshot {
        let localRecords = personalTodos.map { todo in
            TodoRecord(
                id: "personal-\(todo.id.uuidString)",
                title: todo.title,
                dueAt: todo.dueAt,
                importance: todo.importance,
                projectName: todo.projectName,
                relatedEventID: nil,
                sourceURL: nil,
                isComplete: todo.isComplete,
                isPersonal: true,
                owner: todo.owner,
                dueText: todo.dueText,
                sourceQuote: todo.sourceQuote
            )
        }
        return DailyDataSnapshot(
            events: events,
            todos: todos + localRecords,
            sourceLabel: sourceLabel,
            usesDemoData: usesDemoData
        )
    }
}

protocol DailyDataSource {
    func loadSnapshot(at date: Date) async throws -> DailyDataSnapshot
}

struct LocalOnlyDailyDataSource: DailyDataSource {
    func loadSnapshot(at date: Date) async throws -> DailyDataSnapshot {
        DailyDataSnapshot(events: [], todos: [], sourceLabel: "本机个人事项", usesDemoData: false)
    }
}

struct PlannedTask: Identifiable {
    let record: TodoRecord
    let dueLabel: String
    let reason: String
    let isOverdue: Bool

    var id: String { record.id }
}

struct DailyPlan {
    let events: [CalendarEvent]
    let todos: [TodoRecord]
    let rankedTasks: [PlannedTask]
    let deferredTasks: [PlannedTask]
    let preparationNotes: [String: String]
    let excludedTaskCount: Int
    let generatedAt: Date
    let sourceLabel: String
    let usesDemoData: Bool

    var priorityTasks: [PlannedTask] { Array(rankedTasks.prefix(3)) }
    var otherTasks: [PlannedTask] { Array(rankedTasks.dropFirst(3)) + deferredTasks }

    func summaryPreservingCoverage(_ generated: String) -> String {
        guard !otherTasks.isEmpty else { return generated }
        return "已列出\(priorityTasks.count)项今日优先事项；另有\(otherTasks.count)项未完成事项可在“其他待办”查看。"
    }

    func applying(_ ranking: DeepSeekPlanRanking, now: Date? = nil) -> DailyPlan {
        let evaluatedAt = now ?? generatedAt
        let byID = Dictionary(uniqueKeysWithValues: rankedTasks.map { ($0.id, $0) })
        var seen = Set<String>()
        var ordered = ranking.orderedTaskIDs.compactMap { id -> PlannedTask? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        let includedIDs = Set(ordered.map(\.id))
        ordered.append(contentsOf: rankedTasks.filter { !includedIDs.contains($0.id) })
        ordered = ordered.map { task in
            let linkedEvent = task.record.relatedEventID.flatMap { id in events.first { $0.id == id } }
            let reason = ScheduleAdvicePolicy.taskReason(fallback: deferredTasks.isEmpty ? (ranking.reasons[task.id].flatMap { $0.isEmpty ? nil : $0 } ?? task.reason) : task.reason, startsAt: linkedEvent?.startsAt, endsAt: linkedEvent?.endsAt, now: evaluatedAt) ?? task.reason
            return PlannedTask(record: task.record, dueLabel: task.dueLabel, reason: reason, isOverdue: task.isOverdue)
        }
        let knownEventIDs = Set(events.filter { $0.startsAt > evaluatedAt }.map(\.id))
        let preparations = (ranking.preparations ?? [:]).reduce(into: [String: String]()) { result, entry in
            let note = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard knownEventIDs.contains(entry.key), !note.isEmpty else { return }
            result[entry.key] = String(note.prefix(180))
        }
        return DailyPlan(
            events: events,
            todos: todos,
            rankedTasks: ordered,
            deferredTasks: deferredTasks,
            preparationNotes: preparations,
            excludedTaskCount: excludedTaskCount,
            generatedAt: generatedAt,
            sourceLabel: sourceLabel,
            usesDemoData: usesDemoData
        )
    }
}

struct DailyPlanComposer {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func compose(snapshot: DailyDataSnapshot, now: Date) -> DailyPlan {
        let today = calendar.startOfDay(for: now)
        let endOfWindow = calendar.date(byAdding: .day, value: 8, to: today) ?? today
        let relevantEvents = snapshot.events
            .filter { calendar.isDate($0.startsAt, inSameDayAs: today) }
            .sorted { $0.startsAt < $1.startsAt }

        let openTasks = snapshot.todos.filter { !$0.isComplete }
        let todayEventIDs = Set(relevantEvents.map(\.id))
        let candidates = openTasks.filter { task in
            if task.isPersonal { return true }
            if let eventID = task.relatedEventID, todayEventIDs.contains(eventID) { return true }
            guard let dueAt = task.dueAt else { return task.importance == .high }
            return dueAt < endOfWindow
        }

        let eventByID = Dictionary(uniqueKeysWithValues: snapshot.events.map { ($0.id, $0) })
        let candidateIDs = Set(candidates.map(\.id))
        let ranked = openTasks.map { task in
            let dueDay = task.dueAt.map { calendar.startOfDay(for: $0) }
            let daysUntilDue = dueDay.flatMap { calendar.dateComponents([.day], from: today, to: $0).day }
            let isOverdue = task.dueAt.map { $0 < today } ?? false
            let linkedEvent = task.relatedEventID.flatMap { eventByID[$0] }
            let isRelatedToToday = linkedEvent.map { calendar.isDate($0.startsAt, inSameDayAs: today) } ?? false

            let dueLabel: String
            let dueScore: Int
            if isOverdue {
                dueLabel = "已逾期"
                dueScore = 10_000 + min(abs(daysUntilDue ?? 0), 365)
            } else if daysUntilDue == 0 {
                dueLabel = "今天到期"
                dueScore = 9_000
            } else if let daysUntilDue, daysUntilDue > 0 {
                dueLabel = daysUntilDue == 1 ? "明天到期" : "\(daysUntilDue) 天后到期"
                dueScore = 8_000 - daysUntilDue * 100
            } else {
                dueLabel = "无截止日期"
                dueScore = 1_000
            }

            let importanceScore = (task.importance?.rawValue ?? 1) * 100
            let eventScore = isRelatedToToday ? 250 : 0
            let score = dueScore + importanceScore + eventScore
            let reason: String
            if isOverdue {
                reason = "已经逾期，建议尽早处理"
            } else if daysUntilDue == 0 {
                reason = isRelatedToToday ? "今天到期，且与今天的\(linkedEvent?.title ?? "日程")相关" : "今天到期，优先留出处理时间"
            } else if isRelatedToToday {
                reason = ScheduleAdvicePolicy.taskReason(fallback: "与今天的\(linkedEvent?.title ?? "日程")相关，建议提前准备", startsAt: linkedEvent?.startsAt, endsAt: linkedEvent?.endsAt, now: now) ?? "关联今日日程"
            } else if dueDay == nil {
                reason = "尚未设置截止日期，可结合今天的安排决定何时推进"
            } else {
                reason = "截止日期在未来一周内，按期限和重要性排序"
            }

            return (score: score, task: PlannedTask(record: task, dueLabel: dueLabel, reason: reason, isOverdue: isOverdue))
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.task.record.title.localizedStandardCompare(rhs.task.record.title) == .orderedAscending
        }
        .map(\.task)

        return DailyPlan(
            events: relevantEvents,
            todos: snapshot.todos,
            rankedTasks: ranked.filter { candidateIDs.contains($0.id) },
            deferredTasks: ranked.filter { !candidateIDs.contains($0.id) },
            preparationNotes: [:],
            excludedTaskCount: openTasks.count - candidates.count,
            generatedAt: now,
            sourceLabel: snapshot.sourceLabel,
            usesDemoData: snapshot.usesDemoData
        )
    }
}


/// Time state only; never changes calendar records or linked todo completion.
enum CalendarEventPhase: String {
    case upcoming = "未开始"
    case ongoing = "进行中"
    case ended = "已结束"

    static func at(_ now: Date, startsAt: Date, endsAt: Date) -> Self {
        if now >= max(startsAt, endsAt) { return .ended }
        return now >= startsAt ? .ongoing : .upcoming
    }
}
