import Foundation

struct LocalAssistantDataExport: Codable {
    struct Profile: Codable {
        let name: String
        let personality: String
        let tone: String
        let address: String
        let avatar: String
        let relationshipPoints: Int
        let automaticMemoryEnabled: Bool
    }

    struct KnowledgeBase: Codable {
        let id: UUID
        let name: String
        let folderPath: String
        let documents: [KnowledgeDocument]
        let lastIndexedAt: Date?
        let isSingleFile: Bool?

        init(_ base: LocalKnowledgeBase) {
            id = base.id
            name = base.name
            folderPath = base.folderPath
            documents = base.documents
            lastIndexedAt = base.lastIndexedAt
            isSingleFile = base.isSingleFile
        }
    }

    var formatVersion: Int? = 1
    let exportedAt: Date
    let profile: Profile
    let conversation: [AssistantMessage]
    let memories: [AssistantMemory]
    let projects: [AssistantProject]
    let personalTodos: [PersonalTodo]
    let skills: [AssistantSkill]
    let knowledgeBases: [KnowledgeBase]
    var hiddenExternalTodos: [HiddenExternalTodo]? = nil
    var dingTalkWrites: [DingTalkWriteReceipt]? = nil
    var dingTalkEventHistory: [DingTalkReceivedEvent]? = nil
    var dingTalkResearch: DingTalkResearchState? = nil
    var dingTalkMutations: [DingTalkTodoMutationReceipt]? = nil
    var savedDayPlans: [SavedDayPlan]? = nil
    var backgroundPlanState: BackgroundPlanState? = nil
    var activeReminderState: ActiveReminderState? = nil
    var matterEntries: [MatterContextEntry]? = nil
    var followups: [MatterFollowup]? = nil
    var skillRuns: [SkillRun]? = nil
    var assistantRuns: [AssistantRun]? = nil
}

enum LocalAssistantDataManager {
    static let maximumImportSize = 50 * 1_024 * 1_024

    private static let preferenceKeys = [
        "assistantName", "assistantPersonality", "assistantTone", "assistantAddress", "assistantAvatar",
        "profileSetupComplete", "autoMemoryEnabled", "assistantSkills", "relationshipPoints",
        "proactiveRemindersEnabled", "scheduledReminderDay", "scheduledReminderSlots", "lastDailyPlanDate", "dingTalkSelectedProfiles"
    ]

    static func makeExport(from defaults: UserDefaults = .standard, exportedAt: Date = Date()) -> LocalAssistantDataExport {
        let profile = LocalAssistantDataExport.Profile(
            name: defaults.string(forKey: "assistantName") ?? "予安",
            personality: defaults.string(forKey: "assistantPersonality") ?? "温柔陪伴型",
            tone: defaults.string(forKey: "assistantTone") ?? "温柔亲切",
            address: defaults.string(forKey: "assistantAddress") ?? "你",
            avatar: defaults.string(forKey: "assistantAvatar") ?? "warm",
            relationshipPoints: defaults.integer(forKey: "relationshipPoints"),
            automaticMemoryEnabled: defaults.object(forKey: "autoMemoryEnabled") as? Bool ?? true
        )
        return LocalAssistantDataExport(
            exportedAt: exportedAt,
            profile: profile,
            conversation: LocalConversationStore.load(),
            memories: LocalMemoryStore.load(),
            projects: LocalProjectStore.load(),
            personalTodos: LocalTodoStore.load(),
            skills: LocalSkillStore.load(),
            knowledgeBases: LocalKnowledgeStore.load().map(LocalAssistantDataExport.KnowledgeBase.init),
            hiddenExternalTodos: ExternalTodoVisibilityStore.load(),
            dingTalkWrites: try? LocalDingTalkWriteStore.load(),
            dingTalkEventHistory: try? DingTalkEventStore().state().events,
            dingTalkResearch: try? DingTalkResearchStore().load(),
            dingTalkMutations: try? DingTalkTodoMutationStore().load(),
            savedDayPlans: LocalDayPlanStore.load(),
            backgroundPlanState: try? BackgroundPlanStore().state(),
            activeReminderState: try? ActiveReminderStore().state(),
            matterEntries: try? MatterContextStore().load(),
            followups: try? FollowupStore().load(),
            skillRuns: try? SkillRunStore().load(),
            assistantRuns: try? AssistantRunStore().load()
        )
    }

    static func encodedExport(from defaults: UserDefaults = .standard, exportedAt: Date = Date()) throws -> Data {
        _ = try AssistantRunStore().load()
        _ = try FollowupStore().load()
        _ = try SkillRunStore().load()
        _ = try MatterContextStore().load()
        _ = try LocalDingTalkWriteStore.load()
        _ = try DingTalkTodoMutationStore().load()
        _ = try DingTalkResearchStore().load()
        _ = try DingTalkEventStore().state()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(makeExport(from: defaults, exportedAt: exportedAt))
    }

    static func decodeImport(_ data: Data) throws -> LocalAssistantDataExport {
        guard !data.isEmpty, data.count <= maximumImportSize else {
            throw LocalAssistantDataError.invalidArchive("资料文件必须小于 50 MB。")
        }
        let archive: LocalAssistantDataExport
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        do {
            archive = try isoDecoder.decode(LocalAssistantDataExport.self, from: data)
        } catch {
            let legacyDecoder = JSONDecoder()
            do {
                archive = try legacyDecoder.decode(LocalAssistantDataExport.self, from: data)
            } catch {
                throw LocalAssistantDataError.invalidArchive("文件不是有效的予安资料备份，或版本不受支持。")
            }
        }
        try validate(archive)
        return archive
    }

    static func restore(
        _ archive: LocalAssistantDataExport,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        appDataDirectory: URL? = nil
    ) throws {
        try validate(archive)
        let root = appDataDirectory ?? LocalAssistantPaths.dataDirectory
        let parent = root.deletingLastPathComponent()
        let staged = parent.appendingPathComponent("YuanPersonalAssistant.import-\(UUID().uuidString)", isDirectory: true)
        let previous = parent.appendingPathComponent("YuanPersonalAssistant.previous-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)

        do {
            let currentWrites = try LocalDingTalkWriteStore.load(from: root.appendingPathComponent("dingtalk-writes.json"))
            let mergedWrites = LocalDingTalkWriteStore.merge(currentWrites, archive.dingTalkWrites ?? [])
            try write(mergedWrites, to: staged.appendingPathComponent("dingtalk-writes.json"))
            let mutations = try DingTalkTodoMutationStore(url: root.appendingPathComponent("dingtalk-todo-mutations.json")).load()
            try write(DingTalkTodoMutationStore.merge(mutations, archive.dingTalkMutations ?? []), to: staged.appendingPathComponent("dingtalk-todo-mutations.json"))
            let currentEvents = try DingTalkEventStore(directory: root).state()
            var restoredByID = Dictionary(uniqueKeysWithValues: (archive.dingTalkEventHistory ?? []).map { ($0.id, $0) })
            for event in currentEvents.events { restoredByID[event.id] = event }
            let restoredEvents = restoredByID.values.sorted { $0.receivedAt > $1.receivedAt }.prefix(200).map { event in var copy = event; copy.dismissed = true; return copy }
            try write(DingTalkEventState(events: restoredEvents, budgets: currentEvents.budgets), to: staged.appendingPathComponent("dingtalk-event-state.json"))
            try write(DingTalkEventSettings(), to: staged.appendingPathComponent("dingtalk-event-settings.json"))
            try write(archive.dingTalkResearch ?? .init(), to: staged.appendingPathComponent("dingtalk-research.json"))
            try write(archive.assistantRuns ?? [], to: staged.appendingPathComponent("assistant-runs.json"))
            try write(archive.conversation, to: staged.appendingPathComponent("conversation.json"))
            try write(archive.memories, to: staged.appendingPathComponent("memories.json"))
            try write(archive.projects, to: staged.appendingPathComponent("projects.json"))
            try write(archive.personalTodos, to: staged.appendingPathComponent("personal-todos.json"))
            try write(archive.matterEntries ?? [], to: staged.appendingPathComponent("matter-context.json"))
            try write(archive.followups ?? [], to: staged.appendingPathComponent("matter-followups.json"))
            try write(SkillRunPolicy.recovered(archive.skillRuns ?? []), to: staged.appendingPathComponent("skill-runs.json"))
            try write(archive.savedDayPlans ?? [], to: staged.appendingPathComponent("saved-day-plans.json"))
            if var background = archive.backgroundPlanState {
                if background.status == "running" { background.status = "failed"; background.error = "从备份恢复了中断记录，请重新启用后检查。" }
                try write(background, to: staged.appendingPathComponent("background-daily-plan.json"))
            }
            var reminder = archive.activeReminderState ?? ActiveReminderState()
            let currentReminder = try ActiveReminderStore(directory: root).state()
            // Preserve already-used quota when restoring an older snapshot.
            for consumed in currentReminder.records where consumed.consumesQuota {
                reminder.records.removeAll { $0.id == consumed.id }; reminder.records.append(consumed)
            }
            for i in reminder.records.indices where ["planned", "submitting", "submitted", "system-record"].contains(reminder.records[i].status) {
                reminder.records[i].status = reminder.records[i].consumesQuota ? "withdrawn" : "cancelled"
            }
            try write(reminder, to: staged.appendingPathComponent("proactive-reminders.json"))
            try write(ActiveReminderSettings(enabled: false), to: staged.appendingPathComponent("proactive-reminder-settings.json"))
            // Restoring data must never grant persistent background execution.
            try write(BackgroundPlanSettings(enabled: false), to: staged.appendingPathComponent("background-daily-plan-settings.json"))
            try write(archive.hiddenExternalTodos ?? [], to: staged.appendingPathComponent("hidden-external-todos.json"))
            let knowledgeBases = archive.knowledgeBases.map { base in
                LocalKnowledgeBase(id: base.id, name: base.name, folderPath: base.folderPath, folderBookmark: nil, documents: base.documents, lastIndexedAt: base.lastIndexedAt, isSingleFile: base.isSingleFile)
            }
            try write(knowledgeBases, to: staged.appendingPathComponent("knowledge-bases.json"))

            let hadPreviousData = fileManager.fileExists(atPath: root.path)
            if hadPreviousData { try fileManager.moveItem(at: root, to: previous) }
            do {
                try fileManager.moveItem(at: staged, to: root)
                if hadPreviousData { try fileManager.removeItem(at: previous) }
            } catch {
                if fileManager.fileExists(atPath: root.path) { try? fileManager.removeItem(at: root) }
                if hadPreviousData, fileManager.fileExists(atPath: previous.path) { try? fileManager.moveItem(at: previous, to: root) }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }

        defaults.set(archive.profile.name, forKey: "assistantName")
        defaults.set(archive.profile.personality, forKey: "assistantPersonality")
        defaults.set(archive.profile.tone, forKey: "assistantTone")
        defaults.set(archive.profile.address, forKey: "assistantAddress")
        defaults.set(archive.profile.avatar, forKey: "assistantAvatar")
        defaults.set(archive.profile.relationshipPoints, forKey: "relationshipPoints")
        defaults.set(archive.profile.automaticMemoryEnabled, forKey: "autoMemoryEnabled")
        defaults.set(true, forKey: "profileSetupComplete")
        defaults.set(try JSONEncoder().encode(archive.skills), forKey: "assistantSkills")
        defaults.set(false, forKey: "proactiveRemindersEnabled")
        defaults.removeObject(forKey: "scheduledReminderDay")
        defaults.removeObject(forKey: "scheduledReminderSlots")
        defaults.removeObject(forKey: "lastDailyPlanDate")
    }

    private static func validate(_ archive: LocalAssistantDataExport) throws {
        guard (archive.formatVersion ?? 1) <= 1 else {
            throw LocalAssistantDataError.invalidArchive("此备份版本高于当前应用支持的版本。")
        }
        for message in archive.conversation { if let plan=message.goalPlanDraft { try plan.validate(draft:true) };if let question=message.stageQuestion {try question.validate()} }
        guard archive.conversation.allSatisfy({ ($0.followupChecks?.count ?? 0)<=4 && ($0.followupChecks ?? []).allSatisfy(\.isValid) }) else { throw LocalAssistantDataError.invalidArchive("跟进核对记录无效，未恢复资料。") }
        guard archive.conversation.allSatisfy({ ($0.remoteSources?.count ?? 0) <= 12 && ($0.remoteSources ?? []).allSatisfy { source in
            ["message","document"].contains(source.kind) && source.id.count == 64 && source.title.count <= 300 && source.organization.count <= 200 && source.profileID.count <= 1024 && source.coverage.count <= 300 && source.observedAt.timeIntervalSince1970.isFinite && (source.sourceTime?.timeIntervalSince1970.isFinite ?? true) && (source.url == nil || source.safeURL != nil)
        } }) else { throw LocalAssistantDataError.invalidArchive("远端依据元信息无效，未恢复资料。") }
        guard archive.conversation.count <= 50_000,
              archive.memories.count <= 10_000,
              archive.projects.count <= 10_000,
              archive.personalTodos.count <= 50_000,
              (archive.hiddenExternalTodos?.count ?? 0) <= 50_000,
              (archive.dingTalkWrites?.count ?? 0) <= 50_000,
              archive.skills.count <= 100,
              archive.knowledgeBases.count <= 500 else {
            throw LocalAssistantDataError.invalidArchive("备份中的条目数量超出导入上限。")
        }
        try DingTalkEventPolicy.validate(.init(events: archive.dingTalkEventHistory ?? []))
        try DingTalkResearchPolicy.validate(archive.dingTalkResearch ?? .init())
        try AssistantRunStore.validate(archive.assistantRuns ?? [])
        try DingTalkTodoMutationStore.validate(archive.dingTalkMutations ?? [])
        try FollowupPolicy.validate(archive.followups ?? [])
        try SkillRunPolicy.validate(archive.skillRuns ?? [])
        guard archive.memories.allSatisfy({ memory in
            let preferences = memory.actionPreferences ?? []
            return preferences.count <= 3 && preferences.allSatisfy(\.isValid) &&
                Set(preferences.map(\.kind)).count == preferences.count &&
                (preferences.isEmpty || memory.category == "个人偏好")
        }) else { throw LocalAssistantDataError.invalidArchive("记忆中的行动偏好格式无效。") }
        try MatterContextPolicy.validate(archive.matterEntries ?? [])
        let plans = archive.savedDayPlans ?? []
        guard plans.count <= 5_000, unique(plans.map(\.day)) else {
            throw LocalAssistantDataError.invalidArchive("保存的每日计划数量超限或日期重复。")
        }
        for plan in plans { try SavedDayPlanPolicy.validateShape(plan) }
        guard archive.projects.allSatisfy({ project in
            [project.nextStep, project.blocker, project.waitingFor].allSatisfy { ($0?.count ?? 0) <= 500 } &&
            (project.status.map { ProjectUpdatePolicy.statuses.contains($0) } ?? true) &&
            (project.previousNames?.count ?? 0) <= 50 && (project.previousNames?.allSatisfy { !$0.isEmpty && $0.count <= 100 } ?? true)
        }) else { throw LocalAssistantDataError.invalidArchive("项目跟进字段或旧名称记录无效。") }
        guard archive.personalTodos.allSatisfy({ todo in
            let sources = todo.meetingEvidence ?? []
            return sources.count <= 200 && Set(sources.map(\.id)).count == sources.count && sources.allSatisfy {
                $0.id.count == 64 && $0.sourceID.count == 64 && $0.sourceTitle.count <= 160 &&
                !$0.quote.isEmpty && $0.quote.count <= 1_000 && $0.owner.count <= 100 && $0.dueText.count <= 100 &&
                ($0.sourceURL.map { ["https", "http"].contains($0.scheme?.lowercased() ?? "") } ?? true)
            }
        }) else { throw LocalAssistantDataError.invalidArchive("会议行动项来源记录无效。") }
        if let background = archive.backgroundPlanState {
            guard background.history.count <= 20, (0...100_000).contains(background.attemptsToday), background.runKey.count <= 200,
                  (background.error?.count ?? 0) <= 240, background.history.allSatisfy({ $0.runKey.count <= 200 && $0.trigger.count <= 80 && ($0.error?.count ?? 0) <= 240 }) else {
                throw LocalAssistantDataError.invalidArchive("后台计划执行记录无效。")
            }
            if let result = background.result { try SavedDayPlanPolicy.validateShape(result.plan) }
        }
        if let reminder = archive.activeReminderState {
            let statuses = Set(["planned", "submitting", "submitted", "system-record", "cancelled", "withdrawn", "missed", "failed", "uncertain"])
            guard reminder.records.count <= 1_000, reminder.history.count <= 200, reminder.candidates.count <= 200,
                  Set(reminder.records.map(\.id)).count == reminder.records.count,
                  reminder.records.allSatisfy({ $0.id.hasPrefix(ActiveReminderPolicy.prefix) && $0.id.count <= 200 && statuses.contains($0.status) && $0.source.title.count <= 1_000 && $0.source.body.count <= 2_000 && ($0.error?.count ?? 0) <= 240 }),
                  reminder.history.allSatisfy({ $0.title.count <= 1_000 && ($0.detail?.count ?? 0) <= 240 }) else {
                throw LocalAssistantDataError.invalidArchive("提醒记录无效。")
            }
        }
        guard unique(archive.conversation.map(\.id)),
              unique(archive.memories.map(\.id)),
              unique(archive.projects.map(\.id)),
              unique(archive.personalTodos.map(\.id)),
              unique((archive.hiddenExternalTodos ?? []).map(\.id)),
              (archive.hiddenExternalTodos ?? []).allSatisfy({ $0.id.hasPrefix("dingtalk-") && $0.id.count <= 1_000 && $0.title.count <= 10_000 }),
              unique((archive.dingTalkWrites ?? []).map(\.id)),
              unique(archive.skills.map(\.id)),
              unique(archive.knowledgeBases.map(\.id)) else {
            throw LocalAssistantDataError.invalidArchive("备份包含重复标识，无法安全恢复。")
        }
        guard archive.profile.name.count <= 80,
              archive.profile.personality.count <= 100,
              archive.profile.tone.count <= 100,
              archive.profile.address.count <= 40,
              archive.knowledgeBases.allSatisfy({ base in
                  base.name.count <= 160 && base.documents.count <= 10_000 &&
                      unique(base.documents.map(\.urlPath)) &&
                      base.documents.allSatisfy { $0.title.count <= 500 && $0.content.count <= 120_000 }
              }),
              archive.skills.allSatisfy({ skill in
                  skill.id.count <= 100 && skill.name.count <= 40 && skill.summary.count <= 120 &&
                      skill.instruction.count <= AssistantSkill.maximumInstructionLength &&
                      (AssistantSkill.defaults.contains(where: { $0.id == skill.id }) || skill.id.hasPrefix("custom-"))
              }) else {
            throw LocalAssistantDataError.invalidArchive("备份中的字段长度或资料库内容超出导入上限。")
        }
    }

    private static func unique<Value: Hashable>(_ values: [Value]) -> Bool {
        Set(values).count == values.count
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    static func eraseAll(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        appDataDirectory: URL? = nil,
        deleteCredential: () -> Bool = { DeepSeekCredentialStore.delete() }
    ) throws {
        let root = appDataDirectory ?? LocalAssistantPaths.dataDirectory
        let tombstone = root.deletingLastPathComponent()
            .appendingPathComponent("YuanPersonalAssistant.deleting-\(UUID().uuidString)", isDirectory: true)
        let hasLocalFiles = fileManager.fileExists(atPath: root.path)
        if hasLocalFiles { try fileManager.moveItem(at: root, to: tombstone) }

        guard deleteCredential() else {
            if hasLocalFiles { try? fileManager.moveItem(at: tombstone, to: root) }
            throw LocalAssistantDataError.keychainDeleteFailed
        }

        do {
            if hasLocalFiles { try fileManager.removeItem(at: tombstone) }
        } catch {
            if hasLocalFiles { try? fileManager.moveItem(at: tombstone, to: root) }
            throw error
        }
        preferenceKeys.forEach(defaults.removeObject(forKey:))
    }
}

enum LocalAssistantDataError: LocalizedError {
    case keychainDeleteFailed
    case invalidArchive(String)

    var errorDescription: String? {
        switch self {
        case .keychainDeleteFailed:
            "无法从钥匙串移除 DeepSeek API Key；本机数据目录已恢复，请重试或检查钥匙串访问权限。"
        case let .invalidArchive(message): message
        }
    }
}
