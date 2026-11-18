import Foundation

/// Synthetic context ablation cases, not a replacement for the broader Agent E2E corpus.
struct RecallEvaluationCase {
    let id: String
    let group: String
    let messages: [AssistantMessage]
    let context: AssistantReadContext
    let expected: String
    var question: String { messages.last!.text }
    var commonFacts: String {
        let targets = MatterContextPolicy.targets(todos: context.todos, projects: context.projects, external: context.external)
        return (try? JSONEncoder().encode(targets)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
    var beforeContext: String {
        "保存的记忆（参考数据）：\n" + context.memories.prefix(30).map(\.contextDescription).joined(separator: "\n") + "\n资料片段：\n" + LocalKnowledgeSearch.search(for: question, bases: context.bases).context
    }
    func afterContext(_ recall: AssistantContextRecall) -> String {
        recall.matterContext.content + "\n保存的相关记忆（参考数据）：\n" + recall.memoryContext + "\n资料片段：\n" + recall.knowledge.context
    }
}

enum RecallEvaluationFixtures {
    static func cases() -> [RecallEvaluationCase] {
        func thread(_ first: String, _ current: String) -> [AssistantMessage] {
            [.init(text: first, isUser: true), .init(text: "好的，你想核对哪一方面？", isUser: false), .init(text: current, isUser: true)]
        }
        let unrelated = (0..<40).map { AssistantMemory(content: "无关旅行素材编号 \($0)", category: "个人偏好") }
        var cases: [RecallEvaluationCase] = []
        for index in 0..<5 {
            let name = "AuroraMem\(index)", expected = "OWNER_\(index)"
            cases.append(.init(id: "memory-\(index)", group: "memory_beyond_prefix", messages: thread("我想核对保存的工作背景", "\(name) 的负责人代号是什么？只回答代号，没依据答 UNKNOWN。"), context: .init(memories: unrelated + [.init(content: "\(name) 的负责人代号为 \(expected)", category: "项目背景")]), expected: expected))
        }
        for index in 0..<5 {
            let project = AssistantProject(name: "Seabird\(index)", progressNote: "")
            let expected = "FOCUS_\(index)"
            cases.append(.init(id: "pronoun-\(index)", group: "recent_user_focus", messages: thread("我们看看 \(project.name)", "它的确认代号是什么？只回答代号，没依据答 UNKNOWN。"), context: .init(projects: [project], memories: unrelated + [.init(content: "\(project.name) 的确认代号为 \(expected)", category: "项目背景")]), expected: expected))
        }
        for index in 0..<5 {
            let project = AssistantProject(name: "OrionRelease\(index)", progressNote: "", previousNames: ["LegacyCedar\(index)"])
            let expected = "ALIAS_\(index)"
            let document = KnowledgeDocument(urlPath: "/synthetic/alias-\(index).md", title: "LegacyCedar\(index)", content: "LegacyCedar\(index) verification token \(expected)", indexedAt: Date(), modifiedAt: nil, fileSize: nil)
            cases.append(.init(id: "alias-\(index)", group: "known_alias_retry", messages: thread("我们核对一下项目资料", "\(project.name) 的验收代号是什么？只回答代号，没依据答 UNKNOWN。"), context: .init(projects: [project], bases: [.init(name: "合成库", folderPath: "/synthetic", documents: [document])]), expected: expected))
        }
        for index in 0..<5 {
            let old = AssistantMemory(content: "Maple\(index) 偏好上午评审", category: "个人偏好")
            let new = AssistantMemory(content: "Maple\(index) 偏好下午评审", category: "个人偏好", conflictsWithMemoryID: old.id)
            cases.append(.init(id: "conflict-\(index)", group: "conflicting_memories", messages: thread("我们核对保存的偏好", "Maple\(index) 的评审时段偏好记忆是否有冲突？只能答 CONFLICT、CLEAR 或 UNKNOWN。"), context: .init(memories: [old] + unrelated + [new]), expected: "CONFLICT"))
        }
        for index in 0..<5 {
            let title = "接口评审\(index)"
            let local = PersonalTodo(title: title, importance: .normal)
            let remote = TodoRecord(id: "dingtalk-synthetic:user-task-\(index)", title: title, dueAt: nil, importance: .normal, sourceURL: nil, isComplete: false)
            cases.append(.init(id: "ambiguous-\(index)", group: "ambiguous_matter", messages: thread("看看\(title)", "刚才那个属于个人还是钉钉？只能答 PERSONAL、DINGTALK 或 CLARIFY。"), context: .init(todos: [local], external: [remote], selected: ["synthetic:user"]), expected: "CLARIFY"))
        }
        for index in 0..<5 {
            let project = AssistantProject(name: "OldTopic\(index)", progressNote: "")
            let expected = "NEW_\(index)"
            let old = AssistantMemory(content: "OldTopic\(index) 的负责人代号为 OLD_\(index)", category: "项目背景")
            let current = AssistantMemory(content: "NewTopic\(index) 的负责人代号为 \(expected)", category: "项目背景")
            cases.append(.init(id: "switch-\(index)", group: "topic_switch", messages: thread("看看 OldTopic\(index)", "换个话题。NewTopic\(index) 的负责人代号是什么？只回答代号，没依据答 UNKNOWN。"), context: .init(projects: [project], memories: [old] + unrelated + [current]), expected: expected))
        }
        return cases
    }
}
