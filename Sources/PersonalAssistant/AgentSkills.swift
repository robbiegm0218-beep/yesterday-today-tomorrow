import Foundation

struct AssistantSkill: Identifiable, Codable, Equatable {
    static let maximumCustomSkills = 30
    static let maximumInstructionLength = 1_000

    let id: String
    var name: String
    var summary: String
    var instruction: String
    var isEnabled: Bool

    static let defaults: [AssistantSkill] = [
        AssistantSkill(id: "daily-planning", name: "日程规划", summary: "结合安排整理今天的节奏", instruction: "日程规划：先列清今天的安排，再结合可用时间给出简明的行动建议；不得编造空闲时间。", isEnabled: true),
        AssistantSkill(id: "todo-priority", name: "待办优先级", summary: "按期限、重要性和日程关联排序", instruction: "待办优先级：说明优先顺序和依据，关注已逾期、今天到期及与今天日程相关的事项。", isEnabled: true),
        AssistantSkill(id: "minutes-actions", name: "会议纪要提取", summary: "从纪要中提取行动项和依据", instruction: "会议纪要提取：用户提供纪要时，提取行动项、负责人、截止日期和原文依据；不确定的信息标为待确认，不要声称已创建钉钉待办。", isEnabled: true),
        AssistantSkill(id: "project-followup", name: "项目进度跟进", summary: "整理当前进展、截止日期和风险", instruction: "项目进度跟进：根据已提供的信息整理进展、截止日期和风险；缺少的信息直接标明。", isEnabled: false)
    ]
}

enum LocalSkillStore {
    private static let key = "assistantSkills"

    static func load() -> [AssistantSkill] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([AssistantSkill].self, from: data) else { return AssistantSkill.defaults }
        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let builtInSkills = AssistantSkill.defaults.map { definition in
            guard let savedSkill = savedByID[definition.id] else { return definition }
            var merged = definition
            merged.isEnabled = savedSkill.isEnabled
            return merged
        }
        let builtInIDs = Set(AssistantSkill.defaults.map(\.id))
        let customSkills = saved.filter { $0.id.hasPrefix("custom-") && !builtInIDs.contains($0.id) }
        return builtInSkills + customSkills
    }

    static func save(_ skills: [AssistantSkill]) throws {
        let data = try JSONEncoder().encode(skills)
        UserDefaults.standard.set(data, forKey: key)
    }
}
