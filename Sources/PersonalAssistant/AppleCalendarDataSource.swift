import EventKit
import Foundation

enum AppleCalendarAccessError: LocalizedError {
    case denied

    var errorDescription: String? {
        "没有 Apple 日历读取权限。请在 macOS 系统设置的隐私与安全性中允许予安访问日历，然后重试。"
    }
}

@MainActor
final class AppleCalendarDataSource: DailyDataSource {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await store.requestFullAccessToEvents()
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(to: .event) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    func loadSnapshot(at date: Date) async throws -> DailyDataSnapshot {
        let status = EKEventStore.authorizationStatus(for: .event)
        let canRead: Bool
        if #available(macOS 14.0, *) {
            canRead = status == .fullAccess || status == .authorized
        } else {
            canRead = status == .authorized
        }
        guard canRead else {
            return DailyDataSnapshot(events: [], todos: [], sourceLabel: "Apple 日历（尚未授权）", usesDemoData: false)
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let eventNotes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let detail = eventNotes.isEmpty ? event.calendar.title : eventNotes
                return CalendarEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "未命名日程",
                    startsAt: event.startDate,
                    endsAt: event.endDate,
                    detail: String(detail.prefix(1_000)),
                    projectName: nil,
                    sourceURL: nil
                )
            }
        return DailyDataSnapshot(events: events, todos: [], sourceLabel: "Apple 日历", usesDemoData: false)
    }
}
