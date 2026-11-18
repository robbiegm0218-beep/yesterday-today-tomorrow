import Foundation

struct MemoryActionPreference: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case replyLength, focusWindow, reminderLimit
        var label: String {
            switch self { case .replyLength: "回复长短"; case .focusWindow: "专注时段"; case .reminderLimit: "每日提醒上限" }
        }
    }
    let kind: Kind
    let value: String
    let end: String?
    let confirmedAt: Date
    var id: String { kind.rawValue }
    var isValid: Bool {
        switch kind {
        case .replyLength: return ["brief", "balanced", "detailed"].contains(value) && end == nil
        case .reminderLimit: return ["1", "2", "3", "4", "5"].contains(value) && end == nil
        case .focusWindow:
            if let a = Self.minutes(value), let end, let b = Self.minutes(end) { return a < b }
            return false
        }
    }
    static func minutes(_ time: String) -> Int? {
        let pieces = time.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count == 2, pieces[1].count == 2,
              pieces.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let h = Int(pieces[0]), let m = Int(pieces[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
    var summary: String {
        switch kind {
        case .replyLength: ["brief": "简短直接", "balanced": "适中", "detailed": "详细说明"][value] ?? "无效设置"
        case .focusWindow: "\(value)–\(end ?? "")（本机时间）"
        case .reminderLimit: "每天最多\(value)次（仍受亲密度额度约束）"
        }
    }
}

struct EffectiveMemoryPreference: Identifiable {
    let memoryID: UUID
    let memoryContent: String
    let preference: MemoryActionPreference
    var id: String { preference.id }
}

enum MemoryActionPolicy {
    static func planningWarnings(_ plan: SavedDayPlan, memories: [AssistantMemory]) -> [String] {
        guard let focus = effective(memories).first(where: { $0.preference.kind == .focusWindow })?.preference,
              let start = MemoryActionPreference.minutes(focus.value), let end = focus.end.flatMap(MemoryActionPreference.minutes) else { return [] }
        return plan.steps.filter { step in
            guard !step.isDone, step.sourceKind != "event", let time = MemoryActionPreference.minutes(step.plannedTime) else { return false }
            return time < start || time + step.durationMinutes > end
        }.map { "「\($0.title)」在偏好专注时段\(focus.value)–\(focus.end!)之外；可核对原因或手动保留，不会自动搬动。" }
    }
    static func effective(_ memories: [AssistantMemory]) -> [EffectiveMemoryPreference] {
        // Both sides of an unresolved factual conflict are excluded.
        let conflicted = Set(memories.compactMap(\.conflictsWithMemoryID))
        var result: [MemoryActionPreference.Kind: EffectiveMemoryPreference] = [:]
        for memory in memories where memory.category == "个人偏好" && memory.conflictsWithMemoryID == nil && !conflicted.contains(memory.id) {
            for preference in memory.actionPreferences ?? [] where preference.isValid {
                let existing = result[preference.kind]
                if let existing, existing.preference.confirmedAt > preference.confirmedAt { continue }
                if let existing, existing.preference.confirmedAt == preference.confirmedAt, existing.memoryID.uuidString < memory.id.uuidString { continue }
                result[preference.kind] = .init(memoryID: memory.id, memoryContent: memory.content, preference: preference)
            }
        }
        return MemoryActionPreference.Kind.allCases.compactMap { result[$0] }
    }
    static func reminderLimit(memories: [AssistantMemory], relationshipLimit: Int) -> Int {
        let requested = effective(memories).first { $0.preference.kind == .reminderLimit }.flatMap { Int($0.preference.value) } ?? 5
        return max(0, min(5, relationshipLimit, requested))
    }
    static func context(_ memories: [AssistantMemory], planning: Bool = false) -> DeepSeekChatMessage {
        let items = effective(memories).filter { !planning || $0.preference.kind == .focusWindow }
        let lines = items.map { entry in
            let p = entry.preference
            let rule: String
            switch p.kind {
            case .replyLength:
                rule = p.value == "brief" ? "默认最多3个短段落或5个要点，先给结论；用户本轮要求完整细节时展开，不遗漏关键事实或确认事项。" : (p.value == "detailed" ? "默认解释依据、取舍和具体下一步，避免重复；用户本轮要求简短时缩短。" : "默认适中篇幅，给结论和必要依据。")
            case .focusWindow:
                rule = "新建议中的可灵活安排任务优先放在本机\(p.value)–\(p.end!)，仅在事实证明有空时给具体时刻；保留已有日程、已保存安排、明确截止要求及本轮指定时间。窗口装不下时明确说明，不硬塞、改期或编造空闲。"
            case .reminderLimit:
                rule = "每日提醒上限已由本机执行器限制为用户上限与亲密度额度的较小值；不要承诺额外通知或绕过免打扰。"
            }
            // Only validated structured values become instructions; memory content
            // and evidence never get interpolated into the instruction channel.
            return "- \(p.kind.label)：\(p.summary)。\(rule)"
        }
        return .init(role: "system", content: "用户在记忆页明确确认的行动偏好（当前请求优先；不改变事实、权限和写入确认要求）：\n" + (lines.isEmpty ? "目前没有已启用的相关偏好。" : lines.joined(separator: "\n")))
    }
    static func setting(_ preferences: [MemoryActionPreference], for memoryID: UUID, among memories: [AssistantMemory]) throws -> [AssistantMemory] {
        guard let memory = memories.first(where: { $0.id == memoryID }), memory.category == "个人偏好",
              memory.conflictsWithMemoryID == nil, !memories.contains(where: { $0.conflictsWithMemoryID == memoryID }),
              preferences.count <= 3, preferences.allSatisfy(\.isValid), Set(preferences.map(\.kind)).count == preferences.count else {
            throw ProjectUpdateError.invalid("偏好来源或设置无效，请先核对记忆冲突及时间范围。")
        }
        let kinds = Set(preferences.map(\.kind))
        return memories.map { original in
            var item = original
            if item.id == memoryID { item.actionPreferences = preferences.isEmpty ? nil : preferences }
            else {
                let remaining = (item.actionPreferences ?? []).filter { !kinds.contains($0.kind) }
                item.actionPreferences = remaining.isEmpty ? nil : remaining
            }
            return item
        }
    }
}
