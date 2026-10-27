import Foundation

struct PersonalTodo: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var dueAt: Date?
    var importance: TaskImportance
    var projectName: String?
    var createdAt: Date = Date()
    var isComplete = false
    var sourceActionID: UUID? = nil
    var owner: String? = nil
    var dueText: String? = nil
    var sourceQuote: String? = nil
}

enum MeetingActionTodoFactory {
    static func makeTodo(from action: ExtractedMeetingAction) -> PersonalTodo? {
        let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160 else { return nil }
        let owner = action.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let dueText = action.dueText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceQuote = action.sourceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceQuote.isEmpty else { return nil }
        return PersonalTodo(
            title: title,
            dueAt: AssistantActionParser.date(from: dueText),
            importance: .normal,
            sourceActionID: action.id,
            owner: owner.isEmpty ? nil : String(owner.prefix(100)),
            dueText: dueText.isEmpty ? nil : String(dueText.prefix(100)),
            sourceQuote: String(sourceQuote.prefix(300))
        )
    }

    static func adding(_ actions: [ExtractedMeetingAction], to todos: [PersonalTodo]) -> (todos: [PersonalTodo], addedCount: Int) {
        var nextTodos = todos
        var knownActionIDs = Set(todos.compactMap(\.sourceActionID))
        var knownEvidence = Set(todos.compactMap { todo in
            todo.sourceQuote.map { evidenceKey(owner: todo.owner ?? "", dueText: todo.dueText ?? "", sourceQuote: $0) }
        })
        var addedCount = 0
        for action in actions {
            guard !knownActionIDs.contains(action.id), let todo = makeTodo(from: action) else { continue }
            guard let sourceQuote = todo.sourceQuote else { continue }
            let signature = evidenceKey(owner: todo.owner ?? "", dueText: todo.dueText ?? "", sourceQuote: sourceQuote)
            guard !knownEvidence.contains(signature) else { continue }
            nextTodos.insert(todo, at: 0)
            knownActionIDs.insert(action.id)
            knownEvidence.insert(signature)
            addedCount += 1
        }
        return (nextTodos, addedCount)
    }

    static func hasEquivalentTodo(for action: ExtractedMeetingAction, in todos: [PersonalTodo]) -> Bool {
        if todos.contains(where: { $0.sourceActionID == action.id }) { return true }
        guard let todo = makeTodo(from: action), let sourceQuote = todo.sourceQuote else { return false }
        let signature = evidenceKey(owner: todo.owner ?? "", dueText: todo.dueText ?? "", sourceQuote: sourceQuote)
        return todos.contains { existing in
            guard let existingQuote = existing.sourceQuote else { return false }
            return evidenceKey(owner: existing.owner ?? "", dueText: existing.dueText ?? "", sourceQuote: existingQuote) == signature
        }
    }

    private static func evidenceKey(owner: String, dueText: String, sourceQuote: String) -> String {
        [owner, dueText, sourceQuote].map { value in
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }.joined(separator: "\u{1F}")
    }
}

enum LocalTodoStore {
    private static var fileURL: URL {
        LocalAssistantPaths.dataDirectory.appendingPathComponent("personal-todos.json")
    }

    static func load() -> [PersonalTodo] { load(from: fileURL) }

    static func load(from url: URL) -> [PersonalTodo] {
        LocalJSONFileStore.load(from: url, as: [PersonalTodo].self) ?? []
    }

    static func save(_ todos: [PersonalTodo]) throws { try save(todos, to: fileURL) }

    static func save(_ todos: [PersonalTodo], to url: URL) throws {
        try LocalJSONFileStore.save(todos, to: url)
    }
}

enum AssistantActionStatus: String, Codable {
    case pending
    case completed
    case dismissed
}

struct PendingAssistantAction: Identifiable, Codable {
    enum Operation: Codable {
        case createTodo(title: String, dueAt: Date?, importance: TaskImportance, projectName: String?)
        case updateTodo(id: UUID, title: String?, dueAt: Date?, importance: TaskImportance?, projectName: String?)
        case upsertProject(name: String, dueAt: Date?, progressNote: String?)
        case completeTodo(id: UUID)
    }

    var id = UUID()
    let summary: String
    let operation: Operation
    var status: AssistantActionStatus = .pending
    var failureMessage: String? = nil
}

enum AssistantActionParser {
    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    static func proposals(from calls: [DeepSeekToolCall], todos: [PersonalTodo], projects: [AssistantProject]) -> [PendingAssistantAction] {
        calls.compactMap { call in
            guard let data = call.function.arguments.data(using: .utf8) else { return nil }
            switch call.function.name {
            case "create_personal_todo":
                guard let args = try? JSONDecoder().decode(CreateTodoArguments.self, from: data) else { return nil }
                let title = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count <= 160 else { return nil }
                let dueAt = date(from: args.dueDate)
                if args.dueDate != nil, dueAt == nil { return nil }
                let importance: TaskImportance
                switch args.importance?.lowercased() {
                case "high": importance = .high
                case "low": importance = .low
                default: importance = .normal
                }
                let projectName = args.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard projectName.map({ $0.count <= 100 }) ?? true else { return nil }
                let project = projectName.map { requestedName in
                    projects.first { $0.name.localizedCaseInsensitiveCompare(requestedName) == .orderedSame }?.name ?? requestedName
                }
                let dueLabel = dueAt?.formatted(date: .abbreviated, time: .omitted) ?? "未设置"
                let summary = "新增个人待办：\(title) · 截止\(dueLabel) · \(project ?? "未关联项目")"
                return PendingAssistantAction(summary: summary, operation: .createTodo(title: title, dueAt: dueAt, importance: importance, projectName: project))
            case "update_personal_todo":
                guard let args = try? JSONDecoder().decode(UpdateTodoArguments.self, from: data),
                      let id = UUID(uuidString: args.todoID),
                      let todo = todos.first(where: { $0.id == id && !$0.isComplete }) else { return nil }
                let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard title.map({ !$0.isEmpty && $0.count <= 160 }) ?? true else { return nil }
                let dueAt = date(from: args.dueDate)
                if args.dueDate != nil, dueAt == nil { return nil }
                let importance = args.importance.flatMap { raw -> TaskImportance? in
                    switch raw.lowercased() {
                    case "high": .high
                    case "normal": .normal
                    case "low": .low
                    default: nil
                    }
                }
                if args.importance != nil && importance == nil { return nil }
                let projectName = args.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard projectName.map({ $0.count <= 100 }) ?? true else { return nil }
                let changes = [title.map { "标题：\($0)" }, dueAt.map { "截止：\($0.formatted(date: .abbreviated, time: .omitted))" }, importance.map { "优先级：\($0)" }, projectName.map { "项目：\($0)" }].compactMap { $0 }
                guard !changes.isEmpty else { return nil }
                return PendingAssistantAction(summary: "更新个人待办：\(todo.title) · \(changes.joined(separator: " · "))", operation: .updateTodo(id: id, title: title, dueAt: dueAt, importance: importance, projectName: projectName))
            case "upsert_local_project":
                guard let args = try? JSONDecoder().decode(UpsertProjectArguments.self, from: data) else { return nil }
                let name = args.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 100 else { return nil }
                let dueAt = date(from: args.dueDate)
                if args.dueDate != nil, dueAt == nil { return nil }
                let existing = projects.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
                let progress = args.progressNote?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard progress.map({ $0.count <= 1_000 }) ?? true else { return nil }
                let cleanedProgress = progress?.isEmpty == true ? nil : progress
                let parts = [dueAt.map { "截止\($0.formatted(date: .abbreviated, time: .omitted))" }, cleanedProgress].compactMap { $0 }
                let summary = existing == nil ? "新建本地项目：\(name)" : "更新本地项目：\(name)"
                let details = parts.isEmpty ? "保留现有进度和截止日期" : parts.joined(separator: " · ")
                return PendingAssistantAction(summary: "\(summary) · \(details)", operation: .upsertProject(name: name, dueAt: dueAt, progressNote: cleanedProgress))
            case "complete_personal_todo":
                guard let args = try? JSONDecoder().decode(CompleteTodoArguments.self, from: data),
                      let id = UUID(uuidString: args.todoID),
                      let todo = todos.first(where: { $0.id == id && !$0.isComplete }) else { return nil }
                return PendingAssistantAction(summary: "完成个人待办：\(todo.title)", operation: .completeTodo(id: id))
            default:
                return nil
            }
        }
    }
}

enum AssistantToolIntent {
    static func forcedToolName(for userRequest: String, enabledSkillIDs: Set<String>) -> String? {
        let request = userRequest.lowercased()
        let asksForTodo = ["待办", "任务", "todo"].contains(where: request.contains)
        let asksForProject = ["项目", "project"].contains(where: request.contains)
        let declinesAction = ["不要", "别", "不需要", "不想", "先不", "暂不", "无需"]
            .contains { negation in
                guard let range = request.range(of: negation) else { return false }
                let nearby = request[range.lowerBound...].prefix(12)
                return ["创建", "新建", "新增", "添加", "修改", "更新", "完成", "标记", "推进", "记录"]
                    .contains { nearby.contains($0) }
            }
        guard !declinesAction else { return nil }

        let creates = ["创建", "新建", "新增", "添加", "记下", "记一下", "拟一个", "拟个", "拟一条", "列一个", "列一条"]
            .contains(where: request.contains)
        let updates = ["修改", "更新", "调整", "改成", "改为", "延期", "提前", "恢复为", "恢复到", "还原为", "还原到", "恢复", "还原"]
            .contains(where: request.contains)
        let completes = ["标记完成", "标记为完成", "设为完成", "完成待办", "完成任务", "做完", "勾掉", "勾选完成"]
            .contains(where: request.contains)
        let providesTaskDetails = ["标题", "内容", "事项：", "任务：", "待办：", "「", "『", "“", "\"", "'"]
            .contains(where: request.contains)

        if asksForProject, !asksForTodo, enabledSkillIDs.contains("project-followup"), (creates || updates || request.contains("推进")) {
            return "upsert_local_project"
        }
        guard enabledSkillIDs.contains("todo-priority") else { return nil }
        if asksForTodo, completes { return "complete_personal_todo" }
        if asksForTodo, updates { return "update_personal_todo" }
        if asksForTodo, creates, providesTaskDetails {
            return "create_personal_todo"
        }
        return nil
    }
}

private struct UpdateTodoArguments: Decodable {
    let todoID: String
    let title: String?
    let dueDate: String?
    let importance: String?
    let projectName: String?

    enum CodingKeys: String, CodingKey {
        case title, importance
        case todoID = "todo_id"
        case dueDate = "due_date"
        case projectName = "project_name"
    }
}

private struct CreateTodoArguments: Decodable {
    let title: String
    let dueDate: String?
    let importance: String?
    let projectName: String?

    enum CodingKeys: String, CodingKey {
        case title, importance
        case dueDate = "due_date"
        case projectName = "project_name"
    }
}

private struct UpsertProjectArguments: Decodable {
    let projectName: String
    let progressNote: String?
    let dueDate: String?

    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
        case progressNote = "progress_note"
        case dueDate = "due_date"
    }
}

private struct CompleteTodoArguments: Decodable {
    let todoID: String

    enum CodingKeys: String, CodingKey {
        case todoID = "todo_id"
    }
}
