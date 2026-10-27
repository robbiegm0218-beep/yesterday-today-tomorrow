import Foundation
import CryptoKit

struct DingTalkTodoDraft: Identifiable {
    let id = UUID()
    let minute: DingTalkMinute
    let action: ExtractedMeetingAction

    var submissionKey: String {
        let components = [minute.profile.id, minute.taskID, action.title, action.sourceQuote]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct DingTalkWriteReceipt: Identifiable, Codable, Equatable {
    enum State: String, Codable { case submitting, created, verified }
    let id: String
    let profileID: String
    let minuteID: String
    let sourceTitle: String
    let sourceURL: URL?
    let evidence: String
    let title: String
    let dueAt: Date?
    let priority: Int
    var taskID: String?
    var state: State
    var updatedAt: Date
    var verificationIssue: String? = nil
}

enum DingTalkSubmissionError: LocalizedError {
    case invalidDraft, organizationChanged, unknownSubmission, verificationPending, ledgerUnavailable, alreadySubmitted
    case verificationMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidDraft: "请填写有效标题并保留纪要依据；标题最多 200 字。"
        case .organizationChanged: "接入组织已变更，请重新打开听记并核对接收组织。"
        case .unknownSubmission: "此前已提交过这条行动项，但结果尚未确认。请先在钉钉中核对，予安已阻止重复创建。"
        case .verificationPending: "待办可能已创建，但服务端结果尚未核验。再次确认时只会读取原待办，不会重复创建。"
        case let .verificationMismatch(field): "待办已收到创建结果，但\(field)未通过服务端核验。记录已保留，可重新核验原待办。"
        case .ledgerUnavailable: "本机写入记录无法读取，已暂停创建以避免重复提交。请先恢复本机资料。"
        case .alreadySubmitted: "这条纪要行动项已提交过，修改标题或截止日期后不能再次创建。请在钉钉源头修改原待办。"
        }
    }
}

enum LocalDingTalkWriteStore {
    static var fileURL: URL { LocalAssistantPaths.dataDirectory.appendingPathComponent("dingtalk-writes.json") }

    static func load(from url: URL? = nil) throws -> [DingTalkWriteReceipt] {
        let url = url ?? fileURL
        if let receipts = LocalJSONFileStore.load(from: url, as: [DingTalkWriteReceipt].self) { return receipts }
        guard !FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) else { throw DingTalkSubmissionError.ledgerUnavailable }
        return []
    }

    static func save(_ receipts: [DingTalkWriteReceipt], to url: URL? = nil) throws {
        try LocalJSONFileStore.save(receipts, to: url ?? fileURL)
    }

    static func merge(_ current: [DingTalkWriteReceipt], _ imported: [DingTalkWriteReceipt]) -> [DingTalkWriteReceipt] {
        var byID: [String: DingTalkWriteReceipt] = [:]
        for receipt in current + imported {
            if let existing = byID[receipt.id], existing.updatedAt >= receipt.updatedAt { continue }
            byID[receipt.id] = receipt
        }
        return byID.values.sorted { $0.id < $1.id }
    }
}

struct DingTalkTodoSubmissionService {
    private static let lock = NSLock()
    let client: any DingTalkTodoAccess
    let ledgerURL: URL

    init(client: any DingTalkTodoAccess = DingTalkCLIClient(), ledgerURL: URL = LocalDingTalkWriteStore.fileURL) {
        self.client = client
        self.ledgerURL = ledgerURL
    }

    /// The caller must display the final title, recipient, organization and
    /// deadline and obtain the user's explicit confirmation before calling.
    func submitConfirmed(_ draft: DingTalkTodoDraft, title: String, dueAt: Date?, priority: Int, selectedIDs: Set<String>) throws -> DingTalkWriteReceipt {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200, [10, 20, 30, 40].contains(priority),
              !draft.action.sourceQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DingTalkSubmissionError.invalidDraft }
        let profile = draft.minute.profile
        guard selectedIDs.contains(profile.id), try client.listProfiles().contains(where: { $0.id == profile.id }) else { throw DingTalkSubmissionError.organizationChanged }
        var receipts = try LocalDingTalkWriteStore.load(from: ledgerURL)
        let index: Int
        if let existing = receipts.firstIndex(where: { $0.id == draft.submissionKey }) {
            index = existing
            guard receipts[index].title == title, receipts[index].dueAt == dueAt, receipts[index].priority == priority else { throw DingTalkSubmissionError.alreadySubmitted }
            guard receipts[index].taskID != nil else { throw DingTalkSubmissionError.unknownSubmission }
        } else {
            index = receipts.count
            receipts.append(DingTalkWriteReceipt(id: draft.submissionKey, profileID: profile.id, minuteID: draft.minute.taskID, sourceTitle: draft.minute.title, sourceURL: draft.minute.sourceURL, evidence: draft.action.sourceQuote, title: title, dueAt: dueAt, priority: priority, taskID: nil, state: .submitting, updatedAt: Date()))
            // Persist before the non-idempotent call. A crash or unknown result
            // must not make the next click replay the creation.
            try LocalDingTalkWriteStore.save(receipts, to: ledgerURL)
            do {
                let response = try client.createOwnTodo(title: title, dueAt: dueAt, priority: priority, profile: profile)
                let root = try DingTalkJSON.decode(response)
                guard let result = root["result"] as? [String: Any], let taskID = result["taskId"] as? String, !taskID.isEmpty else { throw DingTalkSubmissionError.unknownSubmission }
                receipts[index].taskID = taskID
                receipts[index].state = .created
                receipts[index].updatedAt = Date()
                try LocalDingTalkWriteStore.save(receipts, to: ledgerURL)
            } catch {
                // The durable submitting state deliberately remains intact.
                throw DingTalkSubmissionError.unknownSubmission
            }
        }
        do {
            receipts[index] = try verify(receipts[index], profile: profile)
            try LocalDingTalkWriteStore.save(receipts, to: ledgerURL)
            return receipts[index]
        } catch {
            receipts[index].state = .created
            receipts[index].verificationIssue = error.localizedDescription
            try? LocalDingTalkWriteStore.save(receipts, to: ledgerURL)
            throw error
        }
    }

    func reconcile(receiptID: String, selectedIDs: Set<String>) throws -> DingTalkWriteReceipt {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var receipts = try LocalDingTalkWriteStore.load(from: ledgerURL)
        guard let index = receipts.firstIndex(where: { $0.id == receiptID }),
              selectedIDs.contains(receipts[index].profileID),
              let profile = try client.listProfiles().first(where: { $0.id == receipts[index].profileID }) else { throw DingTalkSubmissionError.organizationChanged }
        receipts[index] = try verify(receipts[index], profile: profile)
        try LocalDingTalkWriteStore.save(receipts, to: ledgerURL)
        return receipts[index]
    }

    private func verify(_ receipt: DingTalkWriteReceipt, profile: DingTalkProfile) throws -> DingTalkWriteReceipt {
        guard let taskID = receipt.taskID else { throw DingTalkSubmissionError.unknownSubmission }
        var resolved: [String: Any]?
        // A successful creation can become readable shortly after its receipt.
        // Retry only missing successful read results, never replay creation or
        // retry authentication/permission failures.
        for attempt in 0..<3 {
            let root: [String: Any]
            do { root = try DingTalkJSON.decode(client.run(.todoDetails(id: taskID), profile: profile)) }
            catch { throw DingTalkSubmissionError.verificationPending }
            if let result = root["result"] as? [String: Any], let detail = result["todoDetailModel"] as? [String: Any] {
                resolved = detail; break
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.25 * Double(attempt + 1)) }
        }
        guard let detail = resolved else { throw DingTalkSubmissionError.verificationPending }
            guard detail["taskId"] as? String == taskID else { throw DingTalkSubmissionError.verificationMismatch("待办标识") }
            guard detail["subject"] as? String == receipt.title else { throw DingTalkSubmissionError.verificationMismatch("标题") }
            guard detail["priority"] as? Int == receipt.priority else { throw DingTalkSubmissionError.verificationMismatch("优先级") }
            guard let executorIDs = detail["executorIds"] as? [String], executorIDs.count == 1, !executorIDs[0].isEmpty else { throw DingTalkSubmissionError.verificationMismatch("执行人") }
            if executorIDs[0] != profile.userID {
                // Personal Todo can expose an internal account ID while the
                // organization profile exposes an employee ID. Never compare
                // names or guess the mapping: prove this exact task belongs to
                // the authenticated user's executor-scoped task collection.
                let ownRoot: [String: Any]
                do { ownRoot = try DingTalkJSON.decode(client.run(.ownOpenTodos, profile: profile)) }
                catch { throw DingTalkSubmissionError.verificationPending }
                guard let data = ownRoot["data"] as? [String: Any], data["complete"] as? Bool == true,
                      let todos = data["todos"] as? [[String: Any]],
                      data["count"] as? Int == todos.count,
                      todos.filter({ $0["taskId"] as? String == taskID }).count == 1 else {
                    throw DingTalkSubmissionError.verificationMismatch("执行人")
                }
            }
            let dueAt = DingTalkJSON.date(detail["dueTime"])
            switch (receipt.dueAt, dueAt) {
            case let (expected?, actual?):
                guard abs(expected.timeIntervalSince(actual)) < 1 else { throw DingTalkSubmissionError.verificationMismatch("截止时间") }
            case (nil, nil): break
            default: throw DingTalkSubmissionError.verificationMismatch("截止时间")
            }
            var verified = receipt
            verified.state = .verified
            verified.updatedAt = Date()
            verified.verificationIssue = nil
            return verified
    }
}
