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
    var meetingEvidence: [MeetingActionEvidence]? = nil
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
        case saveProject(project: AssistantProject, expectedUpdatedAt: Date?)
        case completeTodo(id: UUID)
        case reopenTodo(id: UUID)
        case externalTodoMutation(request: DingTalkTodoMutationRequest)
        case saveDayPlan(plan: SavedDayPlan, expectedRevision: Int)
        case adjustDayPlan(change: DayPlanAdjustment)
        case reviewPreviousDay(proposal: DayReviewProposal)
        case createFollowup(rule: MatterFollowup)
        case respondFollowup(id: UUID, revision: Int, action: String, detail: String, nextDate: Date?)
        case appendMatterContext(entry: MatterContextEntry, expectedRevision: Int)
    }

    var id = UUID()
    var summary: String
    var operation: Operation
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

    /// Native tool arrays avoid nested JSON escaping. Legacy strings remain
    /// supported, but contradictory dual representations are rejected.
    static func nativeArrayArguments(_ data: Data, key: String, legacyKey: String) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let array = object[key] else { return data }
        guard object[legacyKey] == nil, let rows = array as? [[String: Any]], rows.count <= 20,
              let bytes = try? JSONSerialization.data(withJSONObject: rows), let text = String(data: bytes, encoding: .utf8) else { return nil }
        object.removeValue(forKey: key); object[legacyKey] = text
        return try? JSONSerialization.data(withJSONObject: object)
    }

    static func proposals(from calls: [DeepSeekToolCall], todos: [PersonalTodo], projects: [AssistantProject], plans: [SavedDayPlan] = [], planReferences: [DayPlanReference] = [], allowProjectCreation: Bool = false, matterTargets: [MatterTarget] = [], matterEntries: [MatterContextEntry] = [], sourceMessage: AssistantMessage? = nil, followups: [MatterFollowup] = [], externalTodoTargets: [DingTalkTodoChatTarget] = []) -> [PendingAssistantAction] {
        calls.compactMap { call in
            guard let data = call.function.arguments.data(using: .utf8) else { return nil }
            switch call.function.name {
            case "mutate_dingtalk_todo":
                guard let user = sourceMessage, let args = try? JSONDecoder().decode(DingTalkTodoMutationArguments.self, from: data) else { return nil }
                return DingTalkTodoMutationParser.proposal(args, user: user, targets: externalTodoTargets, personal: todos)
            case "append_matter_context":
                guard let sourceMessage, sourceMessage.isUser, (!AssistantToolIntent.declinesWriteTools(in: sourceMessage.text) || AssistantToolIntent.requestsMatterContext(sourceMessage.text)),
                      let args = try? JSONDecoder().decode(MatterContextToolArguments.self, from: data) else { return nil }
                let reference = MatterReference(kind: args.kind, id: args.kind == "external" ? args.targetID : (UUID(uuidString: args.targetID)?.uuidString ?? ""))
                let content = args.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let quote = args.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                guard quote.count >= 2, sourceMessage.text.contains(quote),
                      let target = matterTargets.first(where: { $0.reference == reference }) else { return nil }
                // A same-kind duplicate title cannot be disambiguated by the model's guessed ID.
                let sameNames = matterTargets.filter { $0.reference.kind == reference.kind && ProjectUpdatePolicy.nameKey($0.title) == ProjectUpdatePolicy.nameKey(target.title) }
                guard sameNames.count == 1 || sourceMessage.text.contains(reference.id) else { return nil }
                let entry = MatterContextEntry(reference: reference, category: args.category, content: content, quote: quote, sourceMessageID: sourceMessage.id, recordedAt: sourceMessage.time)
                guard (try? MatterContextPolicy.validate([entry])) != nil else { return nil }
                let revision = matterEntries.filter { $0.reference == reference }.count
                return PendingAssistantAction(summary: "记录\(reference.sourceLabel)「\(target.title)」的\(args.category)：\(content)；仅追加本机记录，不改变原事项状态", operation: .appendMatterContext(entry: entry, expectedRevision: revision))
            case "review_previous_day":
                guard let user = sourceMessage, user.isUser, AssistantToolIntent.requestsDayReview(user.text),
                      let args = try? JSONDecoder().decode(DayReviewToolArguments.self, from: data), args.quote.count >= 2, args.quote.count <= 1_000,
                      user.text.contains(args.quote), args.choicesJSON.utf8.count <= 30_000,
                      let origin = DayReviewPolicy.availableOrigins(plans: plans).first(where: { $0.day == args.sourceDay }),
                      let inputs = try? JSONDecoder().decode([DayReviewInput].self, from: Data(args.choicesJSON.utf8)),
                      inputs.allSatisfy({ ($0.reason?.isEmpty ?? true) || user.text.contains($0.reason!) }),
                      let proposal = try? DayReviewPolicy.proposal(origin: origin, today: plans.first { $0.day == DailyPlanSchedulePolicy.dayKey(for: Date()) }, inputs: inputs, references: planReferences, quote: args.quote, sourceMessageID: user.id) else { return nil }
                return .init(summary: "回顾\(origin.day)：核对\(inputs.count)项安排，确认后才衔接今天或保存改期决策", operation: .reviewPreviousDay(proposal: proposal))
            case "create_matter_followup":
                guard let user = sourceMessage, user.isUser, (!AssistantToolIntent.declinesWriteTools(in: user.text) || AssistantToolIntent.requestsFollowup(user.text)),
                      let args = try? JSONDecoder().decode(CreateFollowupArguments.self, from: data),
                      args.quote.count >= 2, user.text.contains(args.quote),
                      let date = ISO8601DateFormatter().date(from: args.checkAt) else { return nil }
                let reference = MatterReference(kind: args.kind, id: args.kind == "external" ? args.targetID : (UUID(uuidString: args.targetID)?.uuidString ?? ""))
                guard let target = matterTargets.first(where: { $0.reference == reference }),
                      matterTargets.filter({ $0.reference.kind == reference.kind && ProjectUpdatePolicy.nameKey($0.title) == ProjectUpdatePolicy.nameKey(target.title) }).count == 1 else { return nil }
                let rule = MatterFollowup(reference: reference, title: String(target.title.prefix(160)), waitingFor: args.waitingFor, criterion: args.criterion, nextStep: args.nextStep, checkAt: date, quote: args.quote, sourceMessageID: user.id)
                guard (try? FollowupPolicy.creating(rule, among: followups, targets: matterTargets)) != nil else { return nil }
                return .init(summary: "安排跟进：\(target.title) · 等待\(rule.waitingFor) · \(FollowupPolicy.deliveryDate(date).formatted(date: .abbreviated, time: .shortened)) · 核对：\(rule.criterion) · 下一步：\(rule.nextStep)；不改变源状态", operation: .createFollowup(rule: rule))
            case "respond_matter_followup":
                guard let user = sourceMessage, user.isUser, (!AssistantToolIntent.declinesWriteTools(in: user.text) || AssistantToolIntent.requestsFollowup(user.text)),
                      let args = try? JSONDecoder().decode(RespondFollowupArguments.self, from: data),
                      args.quote.count >= 2, args.quote.count <= 500, user.text.contains(args.quote),
                      let rule = followups.first(where: { $0.id == args.followupID && $0.status == "pending" }),
                      matterTargets.contains(where: { $0.reference == rule.reference }) else { return nil }
                let nextDate = args.nextDate.flatMap { ISO8601DateFormatter().date(from: $0) }
                guard ["resolved", "postpone", "stop"].contains(args.action), args.action != "postpone" || (nextDate.map { $0 > Date() } ?? false) else { return nil }
                let label = ["resolved":"已解决", "postpone":"稍后跟进", "stop":"不再跟进"][args.action]!
                return .init(summary: "跟进反馈：\(rule.title) · \(label)" + (nextDate.map { " · " + FollowupPolicy.deliveryDate($0).formatted(date: .abbreviated, time: .shortened) } ?? "") + " · 依据：" + args.quote + "；不完成原待办", operation: .respondFollowup(id: rule.id, revision: rule.revision, action: args.action, detail: args.quote, nextDate: nextDate))
            case "adjust_day_plan":
                guard let user = sourceMessage, !AssistantToolIntent.declinesWriteTools(in: user.text) || AssistantToolIntent.requestsDayPlan(user.text),
                      let existing = plans.first(where: { $0.day == DailyPlanSchedulePolicy.dayKey(for: Date()) }),
                      let normalized = nativeArrayArguments(data, key: "operations", legacyKey: "operations_json"),
                      let args = try? JSONDecoder().decode(DayPlanAdjustmentArguments.self, from: normalized),
                      let change = try? DayPlanAdjustmentPolicy.proposal(args, original: existing, references: planReferences, user: user) else { return nil }
                return PendingAssistantAction(summary: "调整今日计划：\(DayPlanReview.differences(from: existing, to: change.proposed).count)项变化 · 基于第\(existing.revision)版；确认前不保存", operation: .adjustDayPlan(change: change))
            case "propose_day_plan":
                guard let normalized = nativeArrayArguments(data, key: "steps", legacyKey: "steps_json"),
                      let args = try? JSONDecoder().decode(DayPlanToolArguments.self, from: normalized),
                      let plan = try? SavedDayPlanPolicy.proposal(json: args.stepsJSON, references: planReferences), !plan.steps.isEmpty else { return nil }
                let existing = plans.first(where: { $0.day == plan.day })
                guard existing == nil else { return nil } // Existing plans require an explicit bounded patch.
                let revision = existing?.revision ?? 0
                let draft = SavedDayPlanPolicy.preservingProgress(in: plan, from: existing)
                return PendingAssistantAction(summary: "保存今日计划：\(draft.steps.count)项安排 · 预计\(draft.steps.reduce(0) { $0 + $1.durationMinutes })分钟；不修改原待办或日历", operation: .saveDayPlan(plan: draft, expectedRevision: revision))
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
                let matches = projects.filter { project in ([project.name] + (project.previousNames ?? [])).contains { ProjectUpdatePolicy.nameKey($0) == ProjectUpdatePolicy.nameKey(name) } }
                let existing: AssistantProject?
                if let rawID = args.projectID {
                    guard let id = UUID(uuidString: rawID), let found = projects.first(where: { $0.id == id }),
                          ([found.name] + (found.previousNames ?? [])).contains(where: { ProjectUpdatePolicy.nameKey($0) == ProjectUpdatePolicy.nameKey(name) }) else { return nil }
                    existing = found
                } else {
                    guard matches.count <= 1 else { return nil }
                    existing = matches.first
                }
                guard existing != nil || allowProjectCreation else { return nil }
                guard !(args.clearDueDate == true && args.dueDate != nil) else { return nil }
                let due = date(from: args.dueDate)
                if args.dueDate != nil && due == nil { return nil }
                var project = existing ?? AssistantProject(name: name, progressNote: "")
                if args.clearDueDate == true { project.dueAt = nil } else if let due { project.dueAt = due }
                if let value = args.progressNote { project.progressNote = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let value = args.nextStep { project.nextStep = ProjectUpdatePolicy.cleaned(value) }
                if let value = args.blocker { project.blocker = ProjectUpdatePolicy.cleaned(value) }
                if let value = args.waitingFor { project.waitingFor = ProjectUpdatePolicy.cleaned(value) }
                if let value = args.status { project.status = ProjectUpdatePolicy.cleaned(value) }
                guard (try? ProjectUpdatePolicy.validate(project)) != nil else { return nil }
                let changes = [args.progressNote.map { "进展：\($0.isEmpty ? "清空" : $0)" }, args.nextStep.map { "下一步：\($0.isEmpty ? "清空" : $0)" }, args.blocker.map { "阻塞：\($0.isEmpty ? "清空" : $0)" }, args.waitingFor.map { "等待：\($0.isEmpty ? "清空" : $0)" }, args.status.map { "状态：\($0.isEmpty ? "清空" : $0)" }, due.map { "截止\($0.formatted(date: .abbreviated, time: .omitted))" }, args.clearDueDate == true ? "清除截止日期" : nil].compactMap { $0 }
                guard existing == nil || !changes.isEmpty else { return nil }
                let summary = (existing == nil ? "新建本地项目：" : "更新本地项目：") + project.name + " · " + (changes.isEmpty ? "进展待补充" : changes.joined(separator: " · "))
                return PendingAssistantAction(summary: summary, operation: .saveProject(project: project, expectedUpdatedAt: existing?.updatedAt))
            case "reopen_personal_todo":
                guard let user = sourceMessage, !user.text.contains("钉钉"), AssistantToolIntent.requestsTodoReopen(user.text),
                      let args = try? JSONDecoder().decode(ReopenTodoArguments.self, from: data),
                      let id = UUID(uuidString: args.todoID), let todo = todos.first(where: { $0.id == id && $0.isComplete }),
                      args.quote.count >= 2, args.quote.count <= 1000, user.text.contains(args.quote) else { return nil }
                return .init(summary: "恢复个人待办为未完成：\(todo.title)", operation: .reopenTodo(id: id))
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

private struct DayPlanToolArguments: Decodable {
    let stepsJSON: String
    enum CodingKeys: String, CodingKey { case stepsJSON = "steps_json" }
}

enum AssistantToolIntent {
    static func requestsProjectCreation(_ request: String) -> Bool {
        request.contains("项目") && !declinesWriteTools(in: request) && ["创建", "新建", "新增", "建立", "建一个", "建个", "建项目"].contains(where: request.contains)
    }
    static func requestsDayPlan(_ request: String) -> Bool {
        if ["只查看", "仅查看", "只查询", "只读", "不要保存", "不用保存", "只给建议", "只建议"].contains(where: request.contains) { return false }
        let clauses = request.components(separatedBy: CharacterSet(charactersIn: "，,。；;\n"))
        if clauses.contains(where: { clause in
            ["不要安排", "不用安排", "不安排"].contains(where: clause.contains) && !["过去", "已结束", "已完成", "重复"].contains(where: clause.contains)
        }) { return false }
        if ["安排今天", "规划今天", "今天怎么安排", "安排一下今天"].contains(where: request.contains) { return true }
        return ["今日计划", "今天的计划"].contains(where: request.contains) && ["生成", "保存", "调整", "修改", "重新", "创建", "规划"].contains(where: request.contains)
    }
    static func declinesWriteTools(in request: String) -> Bool {
        let text = request.lowercased()
        let statusQuestion = ["完成了吗", "完成了没", "做完了吗", "是否完成", "有没有完成", "是不是已经完成"].contains(where: text.contains)
        let explicitCommand = ["帮我完成", "请完成", "标记完成", "标记为完成", "设为完成"].contains(where: text.contains)
        if statusQuestion && !explicitCommand { return true }
        if ["只核对", "不修改", "不更改", "不写入", "不创建", "不改动"].contains(where: text.contains) { return true }
        if ["只查看", "只查询", "仅查询", "仅查看", "只读", "read-only", "do not modify", "don't modify", "do not create", "don't create"].contains(where: text.contains) { return true }
        for negation in ["不要", "别", "不需要", "不想", "先不", "暂不", "无需"] {
            var tail = text.startIndex..<text.endIndex
            while let range = text.range(of: negation, range: tail) {
                let nearby = text[range.upperBound...].prefix(12).prefix { !"，,。；;！!？?\n".contains($0) }
                if ["创建", "新建", "新增", "添加", "修改", "改成", "改为", "改到", "改期", "重开", "重新打开", "恢复", "延期", "提前", "更新", "完成", "标记", "推进", "记录"].contains(where: nearby.contains) { return true }
                tail = range.upperBound..<text.endIndex
            }
        }
        return false
    }

    static func requestsDayReview(_ request: String) -> Bool {
        if declinesWriteTools(in: request) || ["只回顾", "仅回顾", "先别衔接", "不要衔接"].contains(where: request.contains) { return false }
        return ["昨天", "昨日", "此前推迟"].contains(where: request.contains) && (["衔接", "挪到", "延续", "安排今天", "今天继续", "改天再安排", "不再安排"].contains(where: request.contains) || (request.contains("今天") && request.contains("继续")))
    }

    static func requestsFollowup(_ request: String) -> Bool {
        if ["只查看", "只查询", "只读", "仅查看", "仅查询", "read-only", "不要安排跟进", "不要创建跟进", "不用安排跟进"].contains(where: request.contains) { return false }
        return request.contains("跟进") && ["安排", "提醒", "反馈", "核对", "解决", "稍后", "不再"].contains(where: request.contains)
    }

    static func requestsMatterContext(_ request: String) -> Bool {
        let text = request.lowercased()
        if ["只查看", "仅查看", "只查询", "仅查询", "只读", "read-only"].contains(where: text.contains) { return false }
        for negation in ["不要", "不用", "别", "不需要", "无需", "暂不", "先不"] {
            for clause in text.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n")) {
                if let range = clause.range(of: negation), ["记录", "保存", "记下", "补充"].contains(where: clause[range.upperBound...].prefix(12).contains) { return false }
            }
        }
        return ["记录进展", "补充进展", "更新进展", "记录阻塞", "记录决策", "更正记录", "补充记录", "记下进展"].contains(where: text.contains)
    }

    static func requestsTodoReopen(_ text: String) -> Bool {
        guard !declinesWriteTools(in: text), !["怎么", "如何", "能不能", "是否"].contains(where: text.hasPrefix) else { return false }
        let question = ["吗", "？", "?", "怎么", "如何", "还能", "能否"].contains(where: text.contains)
        let explicit = ["帮我", "请将", "请把", "请恢复", "请重开", "请重新打开", "我要恢复"].contains(where: text.contains)
        if question && !explicit { return false }
        if ["恢复为未完成", "设为未完成", "改为未完成", "取消完成", "重新打开", "重开"].contains(where: text.contains) { return true }
        return text.contains("恢复") && ["任务", "待办"].contains(where: text.contains) && !["标题", "期限", "截止", "日期", "优先级", "进展", "恢复到"].contains(where: text.contains)
    }

    static func shouldEnforceProposal(_ request: String, tool: String?, groundedTargetCount: Int, external: Bool) -> Bool {
        guard !declinesWriteTools(in: request) else { return false }
        let asksAboutAction = ["怎么", "如何", "假如", "如果", "是否", "会怎样", "会怎么样", "会不会", "能不能", "能否", "可以吗"].contains(where: request.contains)
        let explicitAction = ["请把", "请将", "请恢复", "请重开", "我要"].contains(where: request.contains) || request.range(of: "帮我(?!解释|分析|理解|了解|评估|看看)", options: .regularExpression) != nil
        if asksAboutAction && !explicitAction { return false }
        if ["propose_day_plan", "review_previous_day", "create_personal_todo"].contains(tool ?? "") { return true }
        guard groundedTargetCount == 1 else { return false }
        let hasValue = ["改为", "改成", "改到", "更新为", "设置为", "延期到", "提前到"].contains { word in
            request.range(of: word).map { request[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 } ?? false
        }
        if external { return hasValue || DingTalkTodoMutationIntent.wantsReopen(request) || ["标记完成", "标记为完成", "完成待办"].contains(where: request.contains) }
        if ["complete_personal_todo", "reopen_personal_todo"].contains(tool ?? "") { return true }
        return ["update_personal_todo", "upsert_local_project"].contains(tool ?? "") && hasValue
    }

    static func forcedToolName(for userRequest: String, enabledSkillIDs: Set<String>) -> String? {
        let request = userRequest.lowercased()
        let asksForTodo = ["待办", "任务", "todo"].contains(where: request.contains)
        let asksForProject = ["项目", "project"].contains(where: request.contains)
        if enabledSkillIDs.contains("daily-planning"), requestsDayReview(request) { return "review_previous_day" }
        if enabledSkillIDs.contains("daily-planning"), requestsDayPlan(request) { return "propose_day_plan" }
        if (enabledSkillIDs.contains("todo-priority") || enabledSkillIDs.contains("project-followup")), requestsMatterContext(request) { return "append_matter_context" }
        guard !declinesWriteTools(in: request) else { return nil }

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
        if asksForTodo, requestsTodoReopen(request) { return "reopen_personal_todo" }
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
    var projectID: String?
    var nextStep: String?
    var blocker: String?
    var waitingFor: String?
    var status: String?
    var clearDueDate: Bool?
    let projectName: String
    let progressNote: String?
    let dueDate: String?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case nextStep = "next_step"
        case blocker, status
        case waitingFor = "waiting_for"
        case clearDueDate = "clear_due_date"
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

private struct ReopenTodoArguments: Decodable {
    let todoID: String
    let quote: String
    enum CodingKeys: String, CodingKey { case todoID = "todo_id", quote }
}
