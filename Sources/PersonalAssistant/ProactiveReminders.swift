import Foundation
import UserNotifications

struct ReminderSlotPlan: Equatable {
    let slotIndex: Int
    let fireDate: Date
    let item: String
}

@MainActor
enum ReminderScheduleTransaction {
    static func install(
        identifiers: [String],
        add: @MainActor (String) async throws -> Void,
        rollback: @MainActor ([String]) -> Void
    ) async throws {
        do {
            for identifier in identifiers {
                try await add(identifier)
            }
        } catch {
            rollback(identifiers)
            throw error
        }
    }
}

enum ReminderSchedulePolicy {
    static let slots: [(hour: Int, minute: Int)] = [(9, 15), (11, 15), (13, 10), (16, 30), (20, 15)]

    static func isAllowedTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return false }
        let minutes = hour * 60 + minute
        return (minutes >= 540 && minutes < 750) || (minutes >= 780 && minutes < 1_260)
    }

    static func plan(items: [String], limit: Int, consumedSlots: Set<Int>, now: Date, calendar: Calendar = .current) -> [ReminderSlotPlan] {
        let validConsumedSlots = Set(consumedSlots.filter { slots.indices.contains($0) })
        let remainingLimit = max(0, min(limit, 5) - validConsumedSlots.count)
        guard remainingLimit > 0, !items.isEmpty else { return [] }
        let futureSlots = slots.enumerated().compactMap { index, slot -> (Int, Date)? in
            guard let date = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: now),
                  date > now,
                  isAllowedTime(date, calendar: calendar) else { return nil }
            return (index, date)
        }
        return Array(zip(futureSlots, items).prefix(remainingLimit)).map { slot, item in
            ReminderSlotPlan(slotIndex: slot.0, fireDate: slot.1, item: item)
        }
    }
}

@MainActor
enum ProactiveReminderScheduler {
    private static let identifierPrefix = "yuan-daily-reminder-"

    static func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func cancelTodayReminders() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ReminderSchedulePolicy.slots.indices.map { identifierPrefix + String($0) })
    }

    static func cancelAllAssistantNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    static func scheduleToday(items: [String], limit: Int, assistantName: String, now: Date = Date()) async throws -> Int {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ReminderSchedulePolicy.slots.indices.map { identifierPrefix + String($0) })
        let calendar = Calendar.current
        let dayKey = Self.dayKey(for: now)
        let previousSlots = UserDefaults.standard.string(forKey: "scheduledReminderDay") == dayKey
            ? Set(UserDefaults.standard.array(forKey: "scheduledReminderSlots") as? [Int] ?? [])
            : Set<Int>()
        let consumedSlots = Set(previousSlots.filter { index in
            guard ReminderSchedulePolicy.slots.indices.contains(index),
                  let date = calendar.date(bySettingHour: ReminderSchedulePolicy.slots[index].hour, minute: ReminderSchedulePolicy.slots[index].minute, second: 0, of: now) else { return false }
            return date <= now
        })
        guard !items.isEmpty else {
            saveScheduledSlots(consumedSlots, dayKey: dayKey)
            return 0
        }
        let planned = ReminderSchedulePolicy.plan(items: items, limit: limit, consumedSlots: consumedSlots, now: now, calendar: calendar)
        let requests = planned.map { reminder -> UNNotificationRequest in
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            components.second = 0
            let content = UNMutableNotificationContent()
            content.title = "\(assistantName)的今日提醒"
            content.body = reminder.item
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: identifierPrefix + String(reminder.slotIndex), content: content, trigger: trigger)
            return request
        }
        let requestsByID = Dictionary(uniqueKeysWithValues: requests.map { ($0.identifier, $0) })
        let identifiers = requests.map(\.identifier)
        try await ReminderScheduleTransaction.install(
            identifiers: identifiers,
            add: { identifier in
                guard let request = requestsByID[identifier] else { return }
                try await center.add(request)
            },
            rollback: { identifiers in
                center.removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        )
        saveScheduledSlots(consumedSlots.union(planned.map(\.slotIndex)), dayKey: dayKey)
        return planned.count
    }

    private static func saveScheduledSlots(_ indices: Set<Int>, dayKey: String) {
        UserDefaults.standard.set(dayKey, forKey: "scheduledReminderDay")
        UserDefaults.standard.set(Array(indices), forKey: "scheduledReminderSlots")
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
