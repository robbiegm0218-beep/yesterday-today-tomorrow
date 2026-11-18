import Foundation
import CryptoKit

struct MeetingActionEvidence: Codable, Equatable, Identifiable {
    let id: String
    let sourceID: String
    let sourceTitle: String
    let sourceURL: URL?
    let quote: String
    let owner: String
    let dueText: String
    let recordedAt: Date

    static func sourceID(text: String, url: URL?) -> String {
        if let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = components.queryItems?.filter {
                !$0.name.lowercased().hasPrefix("utm_") && !["spm", "tracking"].contains($0.name.lowercased())
            }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            components.fragment = nil
            return hash(components.string ?? url.absoluteString)
        }
        return hash(normalize(text))
    }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func normalize(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN")).filter { !$0.isWhitespace })
    }
    static func make(action: ExtractedMeetingAction, source: String, title: String, url: URL?, now: Date = Date()) throws -> Self {
        guard !MeetingActionEvidenceValidator.verified([action], against: source).isEmpty else {
            throw ProjectUpdateError.invalid("行动项依据已不在当前纪要中，请重新提取。")
        }
        let sourceID = sourceID(text: source, url: url)
        return Self(id: hash(sourceID + "|" + normalize(action.sourceQuote)), sourceID: sourceID,
                    sourceTitle: String(title.prefix(160)), sourceURL: url.flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil },
                    quote: String(action.sourceQuote.prefix(1_000)), owner: String(action.owner.prefix(100)), dueText: String(action.dueText.prefix(100)), recordedAt: now)
    }
}

enum MeetingFollowupPolicy {
    static func existing(for evidence: MeetingActionEvidence, todos: [PersonalTodo]) -> PersonalTodo? {
        todos.first { todo in (todo.meetingEvidence ?? []).contains { $0.id == evidence.id } }
    }
    /// Recommendations only: title resemblance never creates, merges or completes tasks.
    static func candidates(for action: ExtractedMeetingAction, todos: [PersonalTodo]) -> [PersonalTodo] {
        let title = titleKey(action.title)
        guard !title.isEmpty else { return [] }
        return todos.filter { todo in
            let other = titleKey(todo.title)
            if title == other { return true }
            guard min(title.count, other.count) >= 4 else { return false }
            let a = pairs(title), b = pairs(other)
            return Double(a.intersection(b).count) / Double(max(1, a.union(b).count)) >= 0.45
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private static func titleKey(_ value: String) -> String {
        String(MeetingActionEvidence.normalize(value).filter { $0.isLetter || $0.isNumber })
    }
    private static func pairs(_ value: String) -> Set<String> {
        let chars = Array(value); guard chars.count > 1 else { return [value] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
    }
    static func saving(action: ExtractedMeetingAction, evidence: MeetingActionEvidence, targetID: UUID?, projectName: String?, todos: [PersonalTodo]) throws -> [PersonalTodo] {
        if existing(for: evidence, todos: todos) != nil { return todos }
        var next = todos
        if let targetID {
            guard let index = next.firstIndex(where: { $0.id == targetID }) else { throw ProjectUpdateError.invalid("关联的待办已删除，请重新选择。") }
            guard (next[index].meetingEvidence?.count ?? 0) < 200 else { throw ProjectUpdateError.invalid("该待办来源已达200条，请先整理。") }
            next[index].meetingEvidence = (next[index].meetingEvidence ?? []) + [evidence]
            // Linking only adds evidence. Preserve edited title, deadline, project and completion.
        } else {
            // Preserve compatibility with pre-upgrade meeting todos that lack provenance.
            if next.contains(where: { ($0.meetingEvidence ?? []).isEmpty && MeetingActionTodoFactory.hasEquivalentTodo(for: action, in: [$0]) }) {
                throw ProjectUpdateError.invalid("已有相同纪要依据的历史待办，请选择关联，补充来源后再继续。")
            }
            guard var todo = MeetingActionTodoFactory.makeTodo(from: action) else { throw ProjectUpdateError.invalid("请填写有效行动项标题。") }
            todo.projectName = projectName
            todo.meetingEvidence = [evidence]
            next.insert(todo, at: 0)
        }
        return next
    }
}
