import Foundation
import CryptoKit

struct ActiveReminderSourceBatch {
    let candidates: [ActiveReminderCandidate]
    var warning: String? = nil
    var unavailableKinds: [String] = []
}

enum ActiveReminderSources {
    static func limit() -> Int {
        let points = AssistantRuntime.preferences.integer(forKey: "relationshipPoints")
        let relationship = (RelationshipStage.allCases.last { points >= $0.minimumPoints } ?? .stranger).dailyReminderLimit
        let url = LocalAssistantPaths.dataDirectory.appendingPathComponent("memories.json")
        if !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) { return relationship }
        guard let memories = LocalJSONFileStore.load(from: url, as: [AssistantMemory].self) else { return 0 }
        guard memories.allSatisfy({ ($0.actionPreferences ?? []).allSatisfy(\.isValid) }) else { return 0 }
        return MemoryActionPolicy.reminderLimit(memories: memories, relationshipLimit: relationship)
    }
    static func fingerprint() -> String {
        var data = Data((DailyPlanSchedulePolicy.dayKey(for: Date()) + TimeZone.current.identifier).utf8)
        for name in ["personal-todos.json", "hidden-external-todos.json", "projects.json", "saved-day-plans.json", "background-daily-plan.json", "matter-followups.json", "memories.json", "matter-context.json", "dingtalk-research.json"] {
            if let bytes = try? Data(contentsOf: LocalAssistantPaths.dataDirectory.appendingPathComponent(name)) { data.append(bytes) }
        }
        if let settings = try? DingTalkEventStore().settings(), let state = try? DingTalkEventStore().state() {
            data.append(Data(([settings.scopeKey, String(settings.enabled), String(settings.notify)] + state.events.map { $0.id + String($0.dismissed) }).joined(separator: "|").utf8))
        } else { data.append(Data("event-state-unreadable".utf8)) }
        let defaults = AssistantRuntime.preferences
        data.append(Data(([String(defaults.integer(forKey: "relationshipPoints")), defaults.string(forKey: "assistantAddress") ?? "你", defaults.string(forKey: "assistantName") ?? "予安"] + (defaults.stringArray(forKey: "dingTalkSelectedProfiles") ?? [])).joined(separator: "|").utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func read<T: Decodable>(_ name: String, fallback: T) throws -> T {
        let url = LocalAssistantPaths.dataDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) { throw ProjectUpdateError.invalid("本机事项需要恢复，提醒已暂停；请打开工作台检查。") }
            return fallback
        }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch { throw ProjectUpdateError.invalid("本机事项读取失败，提醒已暂停；请打开工作台检查。") }
    }
    static func load() async throws -> ActiveReminderSourceBatch {
        try await load(at: Date(), source: DingTalkDailyDataSource())
    }
    static func load(at now: Date, source: any DailyDataSource) async throws -> ActiveReminderSourceBatch {
        let remote: DailyDataSnapshot
        var warning: String?
        do { remote = try await source.loadSnapshot(at: now) }
        catch {
            remote = DailyDataSnapshot(events: [], todos: [], sourceLabel: "钉钉暂未同步", usesDemoData: false)
            warning = "钉钉来源暂不可用：" + String(error.localizedDescription.prefix(140)) + " 本机已确认事项仍正常提醒。"
        }
        let hidden: [HiddenExternalTodo] = try read("hidden-external-todos.json", fallback: [])
        let personal: [PersonalTodo] = try read("personal-todos.json", fallback: [])
        let projects: [AssistantProject] = try read("projects.json", fallback: [])
        let snapshot = DailyProjectAssociation.apply(to: remote.excludingHiddenExternalTodos(Set(hidden.map(\.id))).includingPersonalTodos(personal), projects: projects, now: now)
        let plan = DailyPlanComposer().compose(snapshot: snapshot, now: now)
        let saved: [SavedDayPlan] = try read("saved-day-plans.json", fallback: [])
        let background = try BackgroundPlanStore().state().result?.plan
        let currentPlan = saved.first { $0.day == DailyPlanSchedulePolicy.dayKey(for: now) && $0.timeZone == TimeZone.current.identifier } ?? background.flatMap { $0.day == DailyPlanSchedulePolicy.dayKey(for: now) && $0.timeZone == TimeZone.current.identifier ? $0 : nil }
        let address = AssistantRuntime.preferences.string(forKey: "assistantAddress") ?? "你"
        let prefix = address == "你" ? "提醒你，" : address + "，"
        func preparation(_ id: String) -> String {
            let raw = id.hasPrefix("personal-") ? String(id.dropFirst(9)) : id
            guard let step = currentPlan?.steps.first(where: {
                if $0.sourceKind == "personal", let a = UUID(uuidString: $0.sourceID ?? ""), let b = UUID(uuidString: raw) { return a == b }
                return $0.sourceID == raw
            }), !step.preparation.isEmpty else { return "" }
            return " 可以先" + String(step.preparation.prefix(80)) + "。"
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "HH:mm"
        let events = plan.events.filter { $0.startsAt > now }.sorted { $0.startsAt < $1.startsAt }.map { event in
            ActiveReminderCandidate(id: event.id, title: event.title,
                body: prefix + "「" + event.title + "」将在" + formatter.string(from: event.startsAt) + "开始。" + preparation(event.id), kind: "event", eventStartsAt: event.startsAt)
        }
        let tasks = (plan.rankedTasks + plan.deferredTasks).prefix(60).map { task in
            ActiveReminderCandidate(id: task.id, title: task.record.title,
                body: prefix + "「" + task.record.title + "」还未完成（" + task.dueLabel + "）。按你的实际进度处理就好。" + preparation(task.id), kind: task.record.isPersonal ? "personal" : "external")
        }
        let candidates = Array((events + tasks).prefix(200)).map { value in
            ActiveReminderCandidate(id: value.id, title: String(value.title.prefix(160)), body: String(value.body.prefix(500)), kind: value.kind, eventStartsAt: value.eventStartsAt)
        }
        var eligible = Set(personal.filter { !$0.isComplete }.map { MatterReference.personal($0.id) })
        eligible.formUnion(projects.filter { $0.status != "已完成" }.map { MatterReference.project($0.id) })
        eligible.formUnion(snapshot.todos.filter { !$0.isPersonal && !$0.isComplete }.map { MatterReference(kind: "external", id: $0.id) })
        let rules = try FollowupStore().load()
        let remoteUnavailable = warning != nil
        let entries: [MatterContextEntry] = (try? read("matter-context.json", fallback: [])) ?? []
        var observations = entries.map { FollowupPolicy.Observation(reference: $0.reference, excerpt: $0.content, source: "已确认事项记录", date: $0.recordedAt) }
        let selectedProfiles = Set(AssistantRuntime.preferences.stringArray(forKey: "dingTalkSelectedProfiles") ?? [])
        let research = (try? DingTalkResearchStore().load()) ?? DingTalkResearchState()
        observations += research.links.compactMap { link in
            guard selectedProfiles.contains(link.item.profile.id), let stamp = link.item.sourceTime else { return nil }
            return .init(reference: link.target, excerpt: link.item.readableExcerpt, source: link.item.kind == "message" ? "已关联消息" : "已关联资料", date: stamp)
        }
        let followups = FollowupPolicy.candidates(rules, eligible: eligible, observations: observations, now: now)
        let occupied = Set(rules.filter { $0.status == "pending" && eligible.contains($0.reference) }.compactMap { rule -> String? in
            if rule.reference.kind == "personal" { return "personal-" + rule.reference.id }
            return rule.reference.kind == "external" ? rule.reference.id : nil
        })
        var eventCandidates: [ActiveReminderCandidate] = []; var unavailable = remoteUnavailable ? ["external", "event", "followup-external"] : []
        do {
            let settings = try DingTalkEventStore().settings(); let state = try DingTalkEventStore().state()
            let selected = Set(AssistantRuntime.preferences.stringArray(forKey: "dingTalkSelectedProfiles") ?? [])
            eventCandidates = state.events.compactMap { DingTalkEventPolicy.candidate($0, settings: settings, selected: selected, now: now) }
        } catch {
            unavailable.append("dingtalk-im")
            warning = (warning ?? "") + " 实时消息来源暂不可用，其他事项提醒继续核对。"
        }
        return ActiveReminderSourceBatch(candidates: Array((eventCandidates + followups + candidates.filter { !occupied.contains($0.id) }).prefix(200)), warning: warning, unavailableKinds: unavailable)
    }
}
