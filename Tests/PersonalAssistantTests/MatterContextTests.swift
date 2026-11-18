import Testing
import Foundation
@testable import PersonalAssistant

struct MatterContextTests {
    private func note(_ ref: MatterReference, id: UUID = UUID(), text: String = "等待接口清单", date: Date = Date()) -> MatterContextEntry {
        .init(id: id, reference: ref, category: "阻塞", content: text, quote: text, sourceMessageID: UUID(), recordedAt: date)
    }
    @Test func stableIDsSeparateSameTitlesAndDoNotReassignDeletedTargets() throws {
        let a = PersonalTodo(title: "发布", importance: .normal)
        let b = PersonalTodo(title: "发布", importance: .normal)
        let remote = TodoRecord(id: "dingtalk-org-a-task", title: "发布", dueAt: nil, importance: .normal, projectName: nil, sourceURL: nil, isComplete: false)
        let targets = MatterContextPolicy.targets(todos: [a, b], projects: [], external: [remote])
        let entry = note(.personal(a.id))
        let saved = try MatterContextPolicy.appending(entry, expectedRevision: 0, entries: [], targets: targets)
        #expect(saved.first?.reference == .personal(a.id))
        #expect(throws: ProjectUpdateError.self) {
            _ = try MatterContextPolicy.appending(note(.personal(a.id)), expectedRevision: 1, entries: saved, targets: Array(targets.dropFirst()))
        }
        #expect(MatterReference(kind: "external", id: remote.id) != .personal(a.id))
        #expect(a.isComplete == false && remote.isComplete == false)
    }
    @Test func staleConfirmationAndDuplicateActionsCannotOverwriteNewerContext() throws {
        let todo = PersonalTodo(title: "发布", importance: .normal)
        let targets = MatterContextPolicy.targets(todos: [todo], projects: [], external: [])
        let first = note(.personal(todo.id))
        let saved = try MatterContextPolicy.appending(first, expectedRevision: 0, entries: [], targets: targets)
        #expect(try MatterContextPolicy.appending(first, expectedRevision: 0, entries: saved, targets: targets) == saved)
        #expect(throws: ProjectUpdateError.self) { _ = try MatterContextPolicy.appending(note(.personal(todo.id), text: "已拿到清单"), expectedRevision: 0, entries: saved, targets: targets) }
        let correction = MatterContextEntry(reference: .personal(todo.id), category: "更正", content: "已拿到清单", quote: "已拿到清单", sourceMessageID: nil, recordedAt: Date())
        let next = try MatterContextPolicy.appending(correction, expectedRevision: 1, entries: saved, targets: targets)
        #expect(next.count == 2 && next[0] == first)
        #expect(throws: ProjectUpdateError.self) { _ = try MatterContextPolicy.appending(note(.personal(todo.id), text: first.content), expectedRevision: 2, entries: next, targets: targets) }
    }
    @Test func parserRequiresCurrentUserQuoteExactTargetAndExplicitConfirmationOperation() throws {
        let todo = PersonalTodo(title: "发布", importance: .normal)
        let user = AssistantMessage(text: "给发布记录阻塞：等待接口清单", isUser: true)
        let targets = MatterContextPolicy.targets(todos: [todo], projects: [], external: [])
        func calls(id: String, quote: String) throws -> [DeepSeekToolCall] {
            let args = try JSONSerialization.data(withJSONObject: ["kind":"personal", "target_id": id, "category":"阻塞", "content":"等待接口清单", "quote":quote])
            return [.init(id: "synthetic", function: .init(name: "append_matter_context", arguments: String(decoding: args, as: UTF8.self)))]
        }
        let calls = try calls(id: todo.id.uuidString, quote: "等待接口清单")
        let parsed = AssistantActionParser.proposals(from: calls, todos: [todo], projects: [], matterTargets: targets, sourceMessage: user)
        let action = try #require(parsed.first)
        #expect(action.status == .pending)
        let duplicate = PersonalTodo(title: todo.title, importance: .normal)
        let ambiguous = MatterContextPolicy.targets(todos: [todo, duplicate], projects: [], external: [])
        #expect(AssistantActionParser.proposals(from: calls, todos: [todo, duplicate], projects: [], matterTargets: ambiguous, sourceMessage: user).isEmpty)
        guard case let .appendMatterContext(entry, revision) = action.operation else { Issue.record("wrong operation"); return }
        #expect(entry.sourceMessageID == user.id && revision == 0)
        #expect(AssistantActionParser.proposals(from: calls, todos: [todo], projects: [], matterTargets: targets).isEmpty)
        let forged = try selfCall(todo: todo, quote: "已经完成发布")
        #expect(AssistantActionParser.proposals(from: forged, todos: [todo], projects: [], matterTargets: targets, sourceMessage: user).isEmpty)
        #expect(AssistantActionParser.proposals(from: calls, todos: [], projects: [], matterTargets: [], sourceMessage: user).isEmpty)
        #expect(AssistantToolIntent.forcedToolName(for: user.text, enabledSkillIDs: ["todo-priority"]) == "append_matter_context")
        #expect(AssistantToolIntent.requestsMatterContext("记录阻塞：等待清单，不要新建待办"))
        #expect(!AssistantToolIntent.requestsMatterContext("只查看记录进展"))
        #expect(!AssistantToolIntent.requestsMatterContext("不要记录进展，只聊聊"))
    }
    private func selfCall(todo: PersonalTodo, quote: String) throws -> [DeepSeekToolCall] {
        let args = try JSONSerialization.data(withJSONObject: ["kind":"personal", "target_id":todo.id.uuidString,"category":"阻塞","content":"错误内容","quote":quote])
        return [.init(id: "forged", function: .init(name: "append_matter_context", arguments: String(decoding: args, as: UTF8.self)))]
    }
    @Test func recallIncludesCompletedMatterButNeverLeaksUnavailableSourceHistory() {
        var todo = PersonalTodo(title: "发布", importance: .normal); todo.isComplete = true
        let good = note(.personal(todo.id))
        let hidden = note(.init(kind: "external", id: "dingtalk-other-org-task"), text: "不应泄露的旧组织记录")
        let context = AssistantChatWorkbenchContext.message(personalTodos: [todo], projects: [], externalSnapshot: nil, lastSync: nil, isSyncing: false, syncError: nil, now: Date(), matterEntries: [good, hidden]).content
        #expect(context.contains("等待接口清单"))
        #expect(context.contains("已完成"))
        #expect(!context.contains(hidden.content))
        #expect(context.contains("历史阻塞"))
    }
    @Test func projectAssociationNeedsUniqueExactNameOrAlias() {
        var project = AssistantProject(name: "发布项目", progressNote: "准备中"); project.previousNames = ["旧发布"]
        #expect(MatterContextPolicy.confirmedProject(named: "旧发布", projects: [project])?.id == project.id)
        #expect(MatterContextPolicy.confirmedProject(named: "发布", projects: [project]) == nil)
        #expect(MatterContextPolicy.confirmedProject(named: "发布项目", projects: [project, .init(name: "发布项目", progressNote: "")]) == nil)
    }
    @Test func journalSurvivesRestartAndCorruptFileIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-matter-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MatterContextStore(directory: directory)
        let entries = [note(.personal(UUID()))]
        try store.save(entries)
        #expect(try MatterContextStore(directory: directory).load() == entries)
        let corrupt = Data("broken".utf8); try corrupt.write(to: store.url)
        #expect(throws: ProjectUpdateError.self) { try store.save([]) }
        #expect(try Data(contentsOf: store.url) == corrupt)
    }
    @Test func backupRestoresJournalAndLegacyArchiveDefaultsToEmpty() throws {
        let todo = PersonalTodo(title: "发布", importance: .normal)
        var archive = LocalAssistantDataExport(exportedAt: Date(), profile: .init(name: "QA", personality: "温柔", tone: "自然", address: "你", avatar: "warm", relationshipPoints: 0, automaticMemoryEnabled: false), conversation: [], memories: [], projects: [], personalTodos: [todo], skills: AssistantSkill.defaults, knowledgeBases: [])
        archive.matterEntries = [note(.personal(todo.id))]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoded = try LocalAssistantDataManager.decodeImport(encoder.encode(archive))
        #expect(decoded.matterEntries?.first?.reference == .personal(todo.id))
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("yuan-matter-restore-\(UUID())")
        let root = parent.appendingPathComponent("data")
        let suite = "yuan-matter-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: parent); defaults.removePersistentDomain(forName: suite) }
        try LocalAssistantDataManager.restore(decoded, defaults: defaults, appDataDirectory: root)
        #expect(try MatterContextStore(directory: root).load() == decoded.matterEntries)
        archive.matterEntries = nil
        let legacy = try LocalAssistantDataManager.decodeImport(encoder.encode(archive))
        #expect(legacy.matterEntries == nil)
        try LocalAssistantDataManager.restore(legacy, defaults: defaults, appDataDirectory: root)
        #expect(try MatterContextStore(directory: root).load().isEmpty)
        archive.matterEntries = [note(.init(kind: "external", id: "bad-id"))]
        #expect(throws: ProjectUpdateError.self) { _ = try LocalAssistantDataManager.decodeImport(encoder.encode(archive)) }
    }
}
