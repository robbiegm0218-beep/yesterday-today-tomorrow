import Foundation

struct DingTalkTodoPatch: Codable, Equatable {
    var title: String? = nil
    var dueAt: Date? = nil
    var priority: Int? = nil
    var dateOnly = false
    var isValid: Bool {
        (title != nil || dueAt != nil || priority != nil) &&
        (title.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 } ?? true) &&
        (priority.map { [10,20,30,40].contains($0) } ?? true) && (!dateOnly || dueAt != nil)
    }
}

struct DingTalkTodoMutationRequest: Identifiable, Codable, Equatable {
    enum Mode: String, Codable { case update, complete, reopen
        var label: String { switch self { case .update: "修改钉钉待办"; case .complete: "完成钉钉待办"; case .reopen: "重新打开钉钉待办" } }
    }
    var id = UUID()
    let localID: String
    let expectedTitle: String
    let mode: Mode
    var patch: DingTalkTodoPatch? = nil
    var quote: String? = nil
    var isValid: Bool {
        localID.hasPrefix("dingtalk-") && localID.count <= 1_000 && !expectedTitle.isEmpty && expectedTitle.count <= 1_000 &&
        (quote?.count ?? 0) <= 1_000 && (mode == .update ? patch?.isValid == true : patch == nil)
    }
}
struct DingTalkTodoMutationTarget: Identifiable, Codable, Equatable {
    let localID: String
    let taskID: String
    let profile: DingTalkProfile
    let title: String
    let dueAt: Date?
    let priority: Int
    let isDone: Bool
    let modifiedTime: Double
    var id: String { localID }
    func expected(_ request: DingTalkTodoMutationRequest) -> Self {
        .init(localID: localID, taskID: taskID, profile: profile, title: request.patch?.title ?? title,
              dueAt: request.patch?.dueAt ?? dueAt, priority: request.patch?.priority ?? priority,
              isDone: request.mode == .complete ? true : request.mode == .reopen ? false : isDone, modifiedTime: modifiedTime)
    }
    func matches(_ other: Self) -> Bool {
        localID == other.localID && taskID == other.taskID && profile.id == other.profile.id && title == other.title && priority == other.priority && isDone == other.isDone &&
        ((dueAt == nil && other.dueAt == nil) || (dueAt != nil && other.dueAt != nil && abs(dueAt!.timeIntervalSince(other.dueAt!)) < 1))
    }
}
struct DingTalkTodoMutationReceipt: Identifiable, Codable {
    enum State: String, Codable { case submitting, verified }
    let request: DingTalkTodoMutationRequest
    let before: DingTalkTodoMutationTarget
    var state: State
    var updatedAt: Date
    var id: UUID { request.id }
}
struct DingTalkTodoMutationStore {
    let url: URL
    init(url: URL = LocalAssistantPaths.dataDirectory.appendingPathComponent("dingtalk-todo-mutations.json")) { self.url = url }
    func load() throws -> [DingTalkTodoMutationReceipt] {
        if !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) { return [] }
        guard let rows = LocalJSONFileStore.load(from: url, as: [DingTalkTodoMutationReceipt].self) else { throw ProjectUpdateError.invalid("钉钉变更记录无法读取，已暂停写入，避免重复提交。") }
        try Self.validate(rows); return rows
    }
    func save(_ rows: [DingTalkTodoMutationReceipt]) throws { try Self.validate(rows); try LocalJSONFileStore.save(rows, to: url) }
    static func validate(_ rows: [DingTalkTodoMutationReceipt]) throws {
        guard rows.count <= 5_000, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ $0.request.isValid && $0.request.localID == $0.before.localID && $0.request.expectedTitle == $0.before.title && $0.before.localID == "dingtalk-\($0.before.profile.id)-\($0.before.taskID)" && !$0.before.taskID.isEmpty && [10,20,30,40].contains($0.before.priority) }) else { throw ProjectUpdateError.invalid("钉钉变更记录格式无效，已暂停写入。") }
    }
    static func merge(_ current: [DingTalkTodoMutationReceipt], _ imported: [DingTalkTodoMutationReceipt]) -> [DingTalkTodoMutationReceipt] {
        var byID = Dictionary(uniqueKeysWithValues: imported.map { ($0.id, $0) })
        // Existing local submission protection must survive an older backup.
        for row in current { byID[row.id] = row }
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }
}
protocol DingTalkTodoMutating: DingTalkTodoCompleting {
    func mutateTodo(taskID: String, mode: DingTalkTodoMutationRequest.Mode, patch: DingTalkTodoPatch?, profile: DingTalkProfile) throws -> DingTalkCLIResult
}

enum DingTalkTodoMutationError: LocalizedError {
    case changed, notExecutor, unverified, invalid
    var errorDescription: String? {
        switch self {
        case .changed: "待办、执行身份或接入组织已变化，请关闭后重新核对；没有重放旧变更。"
        case .notExecutor: "未能证明你是该待办的执行人，请到钉钉处理。"
        case .unverified: "变更结果尚未核验。请只重新核验，不会重复提交；如仍不一致，请先在钉钉核对或调整至目标状态，再回来核验。"
        case .invalid: "变更参数或服务端字段无法核对，请刷新后重试。"
        }
    }
}
struct DingTalkTodoMutationService {
    private static let lock = NSLock()
    let client: any DingTalkTodoMutating
    let store: DingTalkTodoMutationStore
    init(client: any DingTalkTodoMutating = DingTalkCLIClient(), store: DingTalkTodoMutationStore = .init()) { self.client = client; self.store = store }
    func prepare(localID: String, expectedTitle: String, selected: Set<String>) throws -> DingTalkTodoMutationTarget {
        _ = try store.load()
        let profiles = try client.listProfiles().filter { selected.contains($0.id) && localID.hasPrefix("dingtalk-\($0.id)-") }
        guard profiles.count == 1, let profile = profiles.first else { throw DingTalkTodoMutationError.changed }
        let taskID = String(localID.dropFirst("dingtalk-\(profile.id)-".count))
        guard !taskID.isEmpty else { throw DingTalkTodoMutationError.invalid }
        let target = try read(localID: localID, taskID: taskID, profile: profile)
        guard target.title == expectedTitle else { throw DingTalkTodoMutationError.changed }
        try verifyOwn(target); return target
    }
    func confirmed(_ request: DingTalkTodoMutationRequest, preview: DingTalkTodoMutationTarget, selected: Set<String>) throws -> DingTalkTodoMutationTarget {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard request.isValid, selected.contains(preview.profile.id), request.localID == preview.localID, request.expectedTitle == preview.title,
              try client.listProfiles().contains(where: { $0.id == preview.profile.id }) else { throw DingTalkTodoMutationError.changed }
        var rows = try store.load()
        if let row = rows.first(where: { $0.id == request.id }) {
            guard row.request == request else { throw DingTalkTodoMutationError.changed }
            return try reconcileLocked(row, rows: &rows, selected: selected)
        }
        guard !rows.contains(where: { $0.before.localID == preview.localID && $0.state == .submitting }) else { throw DingTalkTodoMutationError.unverified }
        guard rows.count < 5_000 else { throw ProjectUpdateError.invalid("变更记录已达上限，请先整理记录，未提交。") }
        let latest = try read(localID: preview.localID, taskID: preview.taskID, profile: preview.profile)
        let desired = preview.expected(request)
        if desired.matches(latest) {
            try verifyOwn(latest)
            rows.append(.init(request: request, before: preview, state: .verified, updatedAt: Date())); try store.save(rows)
            return latest
        }
        guard latest.matches(preview), latest.modifiedTime == preview.modifiedTime else { throw DingTalkTodoMutationError.changed }
        try verifyOwn(latest)
        rows.append(.init(request: request, before: preview, state: .submitting, updatedAt: Date()))
        try store.save(rows) // Durable intent before touching the remote record.
        do { _ = try DingTalkJSON.decode(client.mutateTodo(taskID: preview.taskID, mode: request.mode, patch: request.patch, profile: preview.profile)) }
        catch { throw DingTalkTodoMutationError.unverified }
        return try reconcileLocked(rows.last!, rows: &rows, selected: selected)
    }
    func reconcile(_ id: UUID, selected: Set<String>) throws -> DingTalkTodoMutationTarget {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var rows = try store.load()
        guard let row = rows.first(where: { $0.id == id }) else { throw DingTalkTodoMutationError.invalid }
        return try reconcileLocked(row, rows: &rows, selected: selected)
    }
    private func reconcileLocked(_ row: DingTalkTodoMutationReceipt, rows: inout [DingTalkTodoMutationReceipt], selected: Set<String>) throws -> DingTalkTodoMutationTarget {
        guard selected.contains(row.before.profile.id) else { throw DingTalkTodoMutationError.changed }
        do {
            let latest = try read(localID: row.before.localID, taskID: row.before.taskID, profile: row.before.profile)
            guard row.before.expected(row.request).matches(latest) else { throw DingTalkTodoMutationError.unverified }
            try verifyOwn(latest)
            guard let index = rows.firstIndex(where: { $0.id == row.id }) else { throw DingTalkTodoMutationError.invalid }
            rows[index].state = .verified; rows[index].updatedAt = Date(); try store.save(rows)
            return latest
        } catch { throw DingTalkTodoMutationError.unverified }
    }
    private func read(localID: String, taskID: String, profile: DingTalkProfile) throws -> DingTalkTodoMutationTarget {
        let root = try DingTalkJSON.decode(client.run(.todoDetails(id: taskID), profile: profile))
        guard let d = (root["result"] as? [String: Any])?["todoDetailModel"] as? [String: Any], d["taskId"] as? String == taskID,
              let title = d["subject"] as? String, !title.isEmpty, let priority = d["priority"] as? Int, [10,20,30,40].contains(priority),
              let done = d["isDone"] as? Bool, d["dueTime"] != nil, let modified = d["modifiedTime"] as? NSNumber, modified.doubleValue.isFinite else { throw DingTalkTodoMutationError.invalid }
        return .init(localID: localID, taskID: taskID, profile: profile, title: title, dueAt: DingTalkJSON.date(d["dueTime"]), priority: priority, isDone: done, modifiedTime: modified.doubleValue)
    }
    private func verifyOwn(_ target: DingTalkTodoMutationTarget) throws {
        let root = try DingTalkJSON.decode(client.run(target.isDone ? .ownCompletedTodos : .ownOpenTodos, profile: target.profile))
        guard let data = root["data"] as? [String: Any], data["complete"] as? Bool == true, let todos = data["todos"] as? [[String: Any]], data["count"] as? Int == todos.count,
              todos.filter({ $0["taskId"] as? String == target.taskID }).count == 1 else { throw DingTalkTodoMutationError.notExecutor }
    }
}
