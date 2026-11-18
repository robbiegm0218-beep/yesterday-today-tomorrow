import Foundation

/// Associations are derived from the current snapshot. They never modify a
/// DingTalk record or overwrite a personal task's explicit project choice.
enum DailyProjectAssociation {
    static func apply(to snapshot: DailyDataSnapshot, projects: [AssistantProject], now: Date, calendar: Calendar = .current) -> DailyDataSnapshot {
        let groups = Dictionary(grouping: projects, by: { normalized($0.name) })
        let uniqueProjects = groups.values.compactMap { $0.count == 1 ? $0.first : nil }

        func match(_ text: String) -> String? {
            let text = normalized(text)
            let matches = uniqueProjects.filter { project in
                ([project.name] + (project.previousNames ?? [])).contains { value in
                    let name = normalized(value)
                    guard !name.isEmpty else { return false }
                    if name.count < 2 { return text == name }
                    let escaped = NSRegularExpression.escapedPattern(for: name)
                    let leading = name.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true ? "(?<![a-z0-9])" : ""
                    let trailing = name.last.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true ? "(?![a-z0-9])" : ""
                    return text.range(of: leading + escaped + trailing, options: .regularExpression) != nil
                }
            }
            return matches.count == 1 ? matches.first?.name : nil
        }

        func canonicalName(_ value: String) -> String {
            let matches = uniqueProjects.filter { project in
                ([project.name] + (project.previousNames ?? [])).contains { normalized($0) == normalized(value) }
            }
            return matches.count == 1 ? matches[0].name : value
        }

        let events = snapshot.events.map { event in
            var linked = event
            if let project = linked.projectName { linked.projectName = canonicalName(project) }
            else { linked.projectName = match(event.title + "\n" + event.detail) }
            return linked
        }
        let todayEvents = events.filter { calendar.isDate($0.startsAt, inSameDayAs: now) }
        let todos = snapshot.todos.map { todo in
            var linked = todo
            if let project = linked.projectName { linked.projectName = canonicalName(project) }
            else if !todo.isPersonal { linked.projectName = match(todo.title) }
            if linked.relatedEventID == nil, let project = linked.projectName {
                let related = todayEvents.filter { $0.projectName.map(normalized) == normalized(project) }
                if related.count == 1 { linked.relatedEventID = related[0].id }
            }
            return linked
        }
        return DailyDataSnapshot(events: events, todos: todos, sourceLabel: snapshot.sourceLabel, usesDemoData: snapshot.usesDemoData)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
