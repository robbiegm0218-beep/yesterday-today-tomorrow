import Foundation

struct ExecutableSkillDefinition: Identifiable {
    let id: String
    let name: String
    let input: String
    let boundary: String
    let steps: [String]
    let recovery: String
    static let all: [Self] = [
        .init(id: "daily-planning", name: "日程规划", input: "当前日程、待办、已保存计划及本轮要求", boundary: "只读取已选组织；仅在确认后保存本机计划，不修改钉钉日程或待办。", steps: ["核对当前来源", "生成计划建议", "校验来源与差异", "等待确认", "保存并回查"], recovery: "来源失败请刷新后重试；计划已变化则重新生成。保存中断只回查，不自动重放。"),
        .init(id: "minutes-actions", name: "会后行动整理", input: "用户粘贴的纪要正文和来源标题", boundary: "只提取有原文依据的行动项；核对重复项后确认创建或关联本机待办，不发送消息、不写企业数据。", steps: ["检查纪要输入", "提取行动项", "核对原文与重复项", "等待确认", "保存并回查"], recovery: "提取失败不保存部分结果，可重新提供原文重试；执行记录不保留纪要全文。已保存记录按来源核验，避免重复创建。")
    ]
    static func find(_ id: String) -> Self? { all.first { $0.id == id } }
}

struct SkillMeetingProposal: Codable, Identifiable {
    let title: String
    let evidence: MeetingActionEvidence
    var id: String { evidence.id }
    var action: ExtractedMeetingAction { .init(title: title, owner: evidence.owner, dueText: evidence.dueText, sourceQuote: evidence.quote, confidence: "已核对原文") }
}

struct SkillRun: Codable, Identifiable {
    enum Status: String, Codable {
        case running, awaitingConfirmation, committing, verificationNeeded, completed, cancelled, failed
        var label: String {
            switch self {
            case .running: "执行中"; case .awaitingConfirmation: "待确认"; case .committing: "保存核验中"; case .verificationNeeded: "待回查"; case .completed: "已核验完成"; case .cancelled: "已取消"; case .failed: "未完成"
            }
        }
    }
    var id = UUID()
    let skillID: String
    let startedAt: Date
    var updatedAt: Date
    var status: Status = .running
    var completedSteps = 0
    var sourceSummary = ""
    var action: PendingAssistantAction?
    var meetingProposals: [SkillMeetingProposal] = []
    var selectedEvidenceIDs: [String] = []
    var links: [String: UUID] = [:]
    var resultSummary: String?
    var error: String?
}

enum SkillRunPolicy {
    static func shouldRecoverOnLaunch(arguments: [String]) -> Bool {
        !arguments.contains { $0 == "--dingtalk-event-worker" || $0 == "--daily-plan-worker" || $0.hasPrefix("--verify-") || $0.hasPrefix("--background-qa-") }
    }
    static func validate(_ runs: [SkillRun]) throws {
        guard runs.count <= 40, Set(runs.map(\.id)).count == runs.count else { throw ProjectUpdateError.invalid("技能执行记录数量或标识无效。") }
        for run in runs {
            guard ExecutableSkillDefinition.find(run.skillID) != nil, (0...5).contains(run.completedSteps),
                  run.sourceSummary.count <= 300, (run.resultSummary?.count ?? 0) <= 500, (run.error?.count ?? 0) <= 500,
                  run.meetingProposals.count <= 100, Set(run.meetingProposals.map(\.id)).count == run.meetingProposals.count,
                  Set(run.selectedEvidenceIDs).count == run.selectedEvidenceIDs.count,
                  Set(run.selectedEvidenceIDs).isSubset(of: Set(run.meetingProposals.map(\.id))),
                  Set(run.links.keys).isSubset(of: Set(run.selectedEvidenceIDs)) else { throw ProjectUpdateError.invalid("技能执行记录格式无效。") }
            if let action = run.action {
                guard run.skillID == "daily-planning" else { throw ProjectUpdateError.invalid("技能工具越界。") }
                switch action.operation {
                case .saveDayPlan(let plan, _): try SavedDayPlanPolicy.validateShape(plan)
                case .adjustDayPlan(let change): try SavedDayPlanPolicy.validateShape(change.original); try SavedDayPlanPolicy.validateShape(change.proposed)
                default: throw ProjectUpdateError.invalid("该技能不允许此工具。")
                }
            }
            guard run.skillID != "daily-planning" || run.meetingProposals.isEmpty,
                  run.meetingProposals.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 160 && $0.evidence.id.count == 64 && $0.evidence.sourceID.count == 64 && !$0.evidence.quote.isEmpty && $0.evidence.quote.count <= 1_000 && $0.evidence.sourceTitle.count <= 160 && $0.evidence.owner.count <= 100 && $0.evidence.dueText.count <= 100 }) else { throw ProjectUpdateError.invalid("技能产物依据无效。") }
        }
    }
    static func recovered(_ runs: [SkillRun], now: Date = Date()) -> [SkillRun] {
        runs.map { original in
            var run = original
            if run.status == .running {
                run.status = .failed; run.updatedAt = now; run.error = "准备过程已中断，未自动继续。重新执行会重新读取来源或要求纪要原文。"
            } else if run.status == .committing {
                run.status = .verificationNeeded; run.updatedAt = now; run.error = "保存过程已中断，请只回查原结果，不自动重放。"
            }
            return run
        }
    }
    static func meetingProposals(_ actions: [ExtractedMeetingAction], source: String, title: String) throws -> [SkillMeetingProposal] {
        let valid = MeetingActionEvidenceValidator.verified(actions, against: source)
        guard valid.count == actions.count, actions.count <= 100 else { throw ProjectUpdateError.invalid("部分行动项缺少原文依据，未生成可保存结果。") }
        var seen = Set<String>()
        return try actions.compactMap { action in
            let evidence = try MeetingActionEvidence.make(action: action, source: source, title: title, url: nil)
            guard !action.title.isEmpty, action.title.count <= 160 else { throw ProjectUpdateError.invalid("行动项标题无效。") }
            guard seen.insert(evidence.id).inserted else { return nil }
            return SkillMeetingProposal(title: action.title, evidence: evidence)
        }
    }
    static func meetingResult(_ run: SkillRun, among todos: [PersonalTodo]) throws -> [PersonalTodo] {
        guard run.skillID == "minutes-actions", run.status == .committing, !run.selectedEvidenceIDs.isEmpty else { throw ProjectUpdateError.invalid("请先选择行动项并确认。") }
        try validate([run])
        var next = todos
        for id in run.selectedEvidenceIDs {
            guard let proposal = run.meetingProposals.first(where: { $0.id == id }) else { throw ProjectUpdateError.invalid("行动项已变化。") }
            if let linked = run.links[id], let existing = MeetingFollowupPolicy.existing(for: proposal.evidence, todos: next), existing.id != linked { throw ProjectUpdateError.invalid("该来源已经关联其他待办，请核对重复项。") }
            next = try MeetingFollowupPolicy.saving(action: proposal.action, evidence: proposal.evidence, targetID: run.links[id], projectName: nil, todos: next)
        }
        return next
    }
    static func verify(_ run: SkillRun, plans: [SavedDayPlan], todos: [PersonalTodo]) throws -> String {
        if run.skillID == "daily-planning", let action = run.action {
            guard let saved = plans.first(where: { $0.sourceActionID == action.id }) else { throw ProjectUpdateError.invalid("没有找到本次计划保存回执；未重放，请重新读取当前计划。") }
            return "已回查本机计划：\(saved.day)，第\(saved.revision)版，\(saved.steps.count)项安排。原待办和日历保留。"
        }
        guard run.skillID == "minutes-actions", !run.selectedEvidenceIDs.isEmpty else { throw ProjectUpdateError.invalid("没有可回查的已确认产物。") }
        for id in run.selectedEvidenceIDs {
            guard let proposal = run.meetingProposals.first(where: { $0.id == id }), let todo = MeetingFollowupPolicy.existing(for: proposal.evidence, todos: todos),
                  run.links[id] == nil || run.links[id] == todo.id else { throw ProjectUpdateError.invalid("尚未在本机待办中找到全部行动项来源；未重放，请核对待办或重新准备。") }
        }
        return "已回查\(run.selectedEvidenceIDs.count)项行动依据，均已创建或关联本机待办；没有写入企业数据。"
    }
}

struct SkillRunStore {
    let directory: URL
    init(directory: URL = LocalAssistantPaths.dataDirectory) { self.directory = directory }
    var fileURL: URL { directory.appendingPathComponent("skill-runs.json") }
    func load() throws -> [SkillRun] {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) { return [] }
        guard let runs = LocalJSONFileStore.load(from: url, as: [SkillRun].self) else { throw ProjectUpdateError.invalid("技能执行记录无法读取，已暂停新执行，原文件保留。") }
        try SkillRunPolicy.validate(runs); return runs
    }
    func save(_ runs: [SkillRun]) throws { try SkillRunPolicy.validate(runs); try LocalJSONFileStore.save(runs, to: fileURL) }
}
