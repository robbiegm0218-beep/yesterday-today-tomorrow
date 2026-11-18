import Foundation
import CryptoKit

struct FollowupOutcome: Codable, Equatable {
    let date: Date
    let action: String
    let detail: String
}
struct MatterFollowup: Identifiable, Codable, Equatable {
    var id = UUID()
    let reference: MatterReference
    let title: String
    let waitingFor: String
    let criterion: String
    let nextStep: String
    var checkAt: Date
    var status = "pending"
    var revision = 1
    var updatedAt = Date()
    var outcomes: [FollowupOutcome] = []
    let quote: String
    let sourceMessageID: UUID?
    var lastActionID: UUID?
    var candidateID: String { "followup-\(id.uuidString)-\(revision)" }
}

enum FollowupPolicy {
    static func validate(_ rules: [MatterFollowup]) throws {
        guard rules.count <= 1_000, Set(rules.map(\.id)).count == rules.count,
              rules.allSatisfy({ rule in
                  rule.reference.isValid && !rule.title.isEmpty && rule.title.count <= 160 &&
                  !rule.waitingFor.isEmpty && rule.waitingFor.count <= 100 && !rule.criterion.isEmpty && rule.criterion.count <= 500 &&
                  !rule.nextStep.isEmpty && rule.nextStep.count <= 500 && !rule.quote.isEmpty && rule.quote.count <= 1_000 &&
                  ["pending", "resolved", "stopped"].contains(rule.status) && (1..<1_000_000).contains(rule.revision) &&
                  rule.outcomes.count <= 100 && rule.outcomes.allSatisfy { ["resolved", "postpone", "stop"].contains($0.action) && $0.detail.count <= 500 } &&
                  rule.checkAt.timeIntervalSince1970.isFinite
              }) else { throw ProjectUpdateError.invalid("跟进记录无效或超出上限，原资料保留。") }
    }
    static func deliveryDate(_ requested: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: requested)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if minute < 540 { return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: requested) ?? requested }
        if minute >= 750 && minute < 780 { return calendar.date(bySettingHour: 13, minute: 0, second: 0, of: requested) ?? requested }
        if minute >= 1_260 {
            let next = calendar.date(byAdding: .day, value: 1, to: requested) ?? requested
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: next) ?? requested
        }
        return requested
    }
    static func creating(_ draft: MatterFollowup, among rules: [MatterFollowup], targets: [MatterTarget], now: Date = Date()) throws -> [MatterFollowup] {
        if let existing = rules.first(where: { $0.id == draft.id }) {
            guard existing == draft else { throw ProjectUpdateError.invalid("跟进操作标识冲突，请重新确认。") }; return rules
        }
        guard draft.status == "pending", draft.revision == 1, draft.outcomes.isEmpty, draft.checkAt > now,
              targets.contains(where: { $0.reference == draft.reference }) else { throw ProjectUpdateError.invalid("跟进时间已过或原事项不可用，请重新核对。") }
        guard !rules.contains(where: { $0.status == "pending" && $0.reference == draft.reference }) else { throw ProjectUpdateError.invalid("该事项已有待跟进安排，请反馈结果或选择稍后跟进。") }
        let next = rules + [draft]; try validate(next); return next
    }
    static func responding(id: UUID, revision: Int, action: String, detail: String, nextDate: Date?, actionID: UUID, rules: [MatterFollowup], now: Date = Date()) throws -> [MatterFollowup] {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { throw ProjectUpdateError.invalid("跟进记录不存在。") }
        if rules[index].lastActionID == actionID { return rules }
        guard rules[index].revision == revision, rules[index].status == "pending", rules[index].outcomes.count < 100 else { throw ProjectUpdateError.invalid("跟进已有新结果，请查看最新记录后操作。") }
        var next = rules
        switch action {
        case "resolved": next[index].status = "resolved"
        case "stop": next[index].status = "stopped"
        case "postpone":
            guard let nextDate, nextDate > now else { throw ProjectUpdateError.invalid("请选择未来的跟进时间。") }
            next[index].checkAt = nextDate
        default: throw ProjectUpdateError.invalid("未知跟进反馈。")
        }
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 500 else { throw ProjectUpdateError.invalid("结果说明最多500字。") }
        next[index].revision += 1; next[index].updatedAt = now; next[index].lastActionID = actionID
        next[index].outcomes.append(.init(date: now, action: action, detail: text))
        try validate(next); return next
    }
    struct Observation {
        let reference: MatterReference
        let excerpt: String
        let source: String
        let date: Date
    }
    static func candidates(_ rules: [MatterFollowup], eligible: Set<MatterReference>, observations: [Observation] = [], now: Date = Date()) -> [ActiveReminderCandidate] {
        rules.filter { $0.status == "pending" && eligible.contains($0.reference) }.map { rule in
            let latest = observations.filter { $0.reference == rule.reference && $0.date > rule.updatedAt && $0.date <= now }.max { $0.date < $1.date }
            let body: String
            if let latest {
                body = "「\(rule.title)」有关来源有更新（\(latest.source)，\(AssistantFactTime.timestamp(latest.date))）：\(String(latest.excerpt.prefix(180)))。请核对是否满足「\(rule.criterion)」，再\(rule.nextStep)。这不代表原任务已完成。"
            } else {
                body = "该跟进「\(rule.title)」了：目前没有取得可验证的新依据。待核对：等待\(rule.waitingFor)，\(rule.criterion)。建议：\(rule.nextStep)。请反馈已解决、稍后或不再跟进；不代表原任务已完成。"
            }
            return .init(id: rule.candidateID, title: rule.title, body: body,
                         kind: rule.reference.kind == "external" ? "followup-external" : "followup", followupAt: rule.checkAt)
        }
    }

}
struct FollowupStore {
    var directory = LocalAssistantPaths.dataDirectory
    var url: URL { directory.appendingPathComponent("matter-followups.json") }
    func load() throws -> [MatterFollowup] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { let value = try JSONDecoder().decode([MatterFollowup].self, from: Data(contentsOf: url)); try FollowupPolicy.validate(value); return value }
        catch { throw ProjectUpdateError.invalid("跟进资料无法读取，原文件保留；请先检查本机资料。") }
    }
    func save(_ rules: [MatterFollowup]) throws { _ = try load(); try FollowupPolicy.validate(rules); try LocalJSONFileStore.save(rules, to: url) }
}

struct CreateFollowupArguments: Decodable {
    let kind: String
    let targetID: String
    let waitingFor: String
    let criterion: String
    let nextStep: String
    let checkAt: String
    let quote: String
    enum CodingKeys: String, CodingKey { case kind, criterion, quote; case targetID = "target_id"; case waitingFor = "waiting_for"; case nextStep = "next_step"; case checkAt = "check_at" }
}
struct RespondFollowupArguments: Decodable {
    let followupID: UUID
    let action: String
    let nextDate: String?
    let quote: String
    enum CodingKeys: String, CodingKey { case action, quote; case followupID = "followup_id"; case nextDate = "next_date" }
}
