import Foundation

/// A persisted understanding hint, never a write authorization. Numbering comes
/// only from the list the app actually displayed, including across restart.
struct AssistantConversationFocus: Codable, Equatable {
    let references: [MatterReference]
    let isChoice: Bool
    let originMessageID: UUID
    let selected: Set<String>
    let hidden: Set<String>
    var choiceReferences: [MatterReference]? = nil
    var discussionOnly: Bool? = nil

    func resolve(messages: [AssistantMessage], targets: [MatterTarget], selected: Set<String>, hidden: Set<String>, now: Date, forChoice: Bool = false) -> [MatterTarget]? {
        let references = forChoice ? (choiceReferences ?? (isChoice ? self.references : [])) : self.references
        guard self.selected == selected, self.hidden == hidden,
              !references.isEmpty, references.count <= 6, Set(references).count == references.count,
              references.allSatisfy(\.isValid), isChoice || self.references.count == 1,
              !forChoice || self.references.allSatisfy(references.contains),
              let origin = messages.suffix(12).first(where: { $0.id == originMessageID && $0.isUser }),
              now.timeIntervalSince(origin.time) >= 0, now.timeIntervalSince(origin.time) < 86400 else { return nil }
        let rows = references.compactMap { ref in targets.first { $0.reference == ref } }
        // Losing an option invalidates the entire old numbering, even when a
        // different item with the same title now occupies its old position.
        return rows.count == references.count ? rows : nil
    }

    enum Selection: Equatable {
        case number(Int)
        case other
        case completion(Bool)
    }

    static func selection(_ text: String) -> Selection? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = ordinal(text) { return .number(index) }
        // Anchored expressions only: negative/alternative/business sentences
        // must stay ordinary user input, never select a target by substring.
        let key = text.hasSuffix("。") ? String(text.dropLast()) : text
        if ["换成另一个", "改成另一个", "不是这个，是另一个", "我说的是另一个"].contains(key) { return .other }
        for (word, complete) in [("未完成", false), ("已完成", true)] {
            if ["刚才那个" + word + "的", "刚才" + word + "的那个", "选" + word + "的那个", "换成" + word + "的那个", word + "的那个"].contains(key) { return .completion(complete) }
        }
        let correction = key.components(separatedBy: "，是")
        if correction.count == 2, correction[0].hasPrefix("不是"),
           ordinal(String(correction[0].dropFirst(2))) != nil, let index = ordinal(correction[1]) { return .number(index) }
        for prefix in ["不是这个，是", "我说的是", "改成", "刚才列表里", "上面列表里", "刚才"] where key.hasPrefix(prefix) {
            if let index = ordinal(String(key.dropFirst(prefix.count))) { return .number(index) }
        }
        return nil
    }

    static func ordinal(_ text: String) -> Int? {
        var key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["我选", "选择", "换成", "选"] where key.hasPrefix(prefix) { key = String(key.dropFirst(prefix.count)); break }
        for suffix in ["。", "，", "吧"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)); break }
        guard key.hasPrefix("第"), key.hasSuffix("个") else { return nil }
        let value = String(key.dropFirst().dropLast())
        let numbers = ["零":0,"一":1,"二":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9,"十":10]
        return numbers[value] ?? (value.allSatisfy(\.isNumber) ? Int(value) : nil)
    }
}

extension AssistantContextRecall {
    func conflictsWithFocus(_ operation: PendingAssistantAction.Operation) -> Bool {
        guard ["saved_numbered_choice", "saved_conversation_focus", "saved_focus_correction"].contains(basis),
              !requiresClarification, candidates.count == 1, let expected = candidates.first?.reference else { return false }
        let actual: MatterReference
        switch operation {
        case let .updateTodo(id, _, _, _, _), let .completeTodo(id), let .reopenTodo(id): actual = .personal(id)
        case let .saveProject(project, _): actual = .project(project.id)
        case let .externalTodoMutation(request): actual = .init(kind: "external", id: request.localID)
        case let .appendMatterContext(entry, _): actual = entry.reference
        case let .createFollowup(rule): actual = rule.reference
        default: return false
        }
        return actual != expected
    }

    var correctionAcknowledgement: String? {
        guard isFocusCorrection, !requiresClarification, let target = candidates.first else { return nil }
        return "已切换讨论对象为「" + target.title + "」（" + target.reference.sourceLabel + "，ID=" + target.reference.id + "）。可以继续问它的进度或明确提出新的修改。已有卡片状态保持；如不再需要，请取消原卡片。此次没有查询远端、生成变更或执行原请求。"
    }

    func savedFocus(messages: [AssistantMessage], selected: Set<String>, hidden: Set<String>) -> AssistantConversationFocus? {
        guard resolutionIssue == nil, !candidates.isEmpty,
              requiresClarification || candidates.count == 1,
              let origin = originMessageID ?? messages.last(where: \.isUser)?.id else { return nil }
        return .init(references: Array(candidates.prefix(6)).map(\.reference), isChoice: requiresClarification, originMessageID: origin, selected: selected, hidden: hidden, choiceReferences: requiresClarification ? nil : retainedChoiceReferences, discussionOnly: isFocusCorrection ? true : nil)
    }
}
