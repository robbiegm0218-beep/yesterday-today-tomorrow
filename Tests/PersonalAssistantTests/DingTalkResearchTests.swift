import Foundation
import Testing
@testable import PersonalAssistant

struct DingTalkResearchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var profile: DingTalkProfile { ResearchClient.profile }
    func result(_ items: [DingTalkResearchItem], complete: Bool = true) -> DingTalkResearchResult { .init(items: items, returnedCount: items.count, complete: complete, checkedAt: now, start: now.addingTimeInterval(-7 * 86400), end: now) }
    func item(id: String = "msg-1", text: String = "已确认评审", kind: String = "message") -> DingTalkResearchItem {
        .init(kind: kind, profile: profile, sourceID: id, containerID: kind == "message" ? "conversation-1" : "workspace-1", title: "合成依据", excerpt: text, sourceURL: nil, sourceTime: now.addingTimeInterval(-100), fingerprint: DingTalkResearchItem.digest([text]))
    }
    @Test func longSourceLinksAreCollapsedForReadabilityButOriginalEvidenceIsPreserved() {
        let text = "先核对 [原文](https://example.com/very-long-path) 再准备。https://example.com/another 保留事实"
        let value = item(text: text)
        #expect(value.readableExcerpt.contains("先核对 原文") && value.readableExcerpt.contains("保留事实"))
        #expect(!value.readableExcerpt.contains("https://") && value.excerpt == text)
    }
    @Test func recalledFocusReadsOnlyCurrentlyAvailableAuthorizedLinks() throws {
        let target = MatterTarget(reference: .personal(UUID()), title: "合成项目")
        let state = try DingTalkResearchPolicy.linking(item(text: "焦点来源哨兵"), to: target.reference, targets: [target], selected: [profile.id], state: .init())
        let visible = DingTalkResearchPolicy.context(state: state, targets: [target], selected: [profile.id], text: "它的依据呢", focusedReferences: [target.reference])
        #expect(visible.content.contains("焦点来源哨兵"))
        #expect(!DingTalkResearchPolicy.context(state: state, targets: [], selected: [profile.id], text: "它的依据呢", focusedReferences: [target.reference]).content.contains("焦点来源哨兵"))
        #expect(!DingTalkResearchPolicy.context(state: state, targets: [target], selected: [], text: "它的依据呢", focusedReferences: [target.reference]).content.contains("焦点来源哨兵"))
    }
    @Test func actualCLIDisplayTimestampParsesInLocalTimezoneAndMalformedDateDoesNot() {
        let stamp = "2026-10-30 11:23:26"
        let date = DingTalkResearchService.messageDate(stamp)
        #expect(date != nil)
        #expect(Calendar.current.component(.hour, from: date!) == 11)
        #expect(DingTalkResearchService.messageDate("2026-02-31 11:23:26") == nil)
        #expect(DingTalkResearchService.messageDate("2026-10-30") == nil)
    }
    @Test func messageReadUsesExactProfileAndSevenDayRangeWithNoWriteFlags() throws {
        let c = ResearchClient(now: now); let s = DingTalkResearchService(client: c)
        let r = try s.messages(query: "评审", profile: profile, selected: [profile.id], now: now)
        #expect(r.complete && r.items.count == 1 && r.items[0].sourceID == "msg-1" && r.items[0].containerID == "conversation-1")
        #expect(r.start == now.addingTimeInterval(-7 * 86400) && r.end == now)
        let args = try #require(c.arguments.last)
        #expect(args.contains("--page-all") && args.contains("--no-reactions") && !args.contains("--yes"))
        #expect(args.contains(profile.id) && args.contains("评审"))
    }
    @Test func partialWarningsUnknownPaginationAndDisplayCapNeverBecomeComplete() throws {
        for kind in 0..<5 {
            let c = ResearchClient(now: now)
            c.partial = kind == 0; c.warning = kind == 1; c.paginationKnown = kind != 2; c.count = kind == 3 ? 201 : 1; c.hasMore = kind == 4
            let r = try DingTalkResearchService(client: c).messages(query: "评审", profile: profile, selected: [profile.id], now: now)
            #expect(!r.complete && r.items.count <= 200)
            #expect(throws: (any Error).self) { try DingTalkResearchPolicy.watching(result: r, profile: profile, kind: "message", query: "评审", space: nil, state: .init()) }
        }
    }
    @Test func malformedMissingDuplicateOrOutOfRangeMessagesFailClosed() throws {
        for kind in 0..<4 {
            let c = ResearchClient(now: now); c.missing = kind == 0; c.duplicate = kind == 1; c.wrongTime = kind == 2; c.countMismatch = kind == 3
            #expect(throws: (any Error).self) { try DingTalkResearchService(client: c).messages(query: "评审", profile: profile, selected: [profile.id], now: now) }
        }
    }
    @Test func wikiRequiresCorrectSpaceTypeAndNeverGuessesWorkspace() throws {
        let c = ResearchClient(now: now); let s = DingTalkResearchService(client: c)
        let spaces = try s.spaces(profile: profile, selected: [profile.id]); #expect(spaces.count == 1)
        let space = try #require(spaces.first)
        let nodes = try s.nodes(space: space, query: "", selected: [profile.id], now: now)
        #expect(nodes.complete && nodes.items.first?.kind == "wiki")
        #expect(try s.nodes(space: space, query: "评审", selected: [profile.id], now: now).complete)
        c.wrongSpace = true
        #expect(throws: (any Error).self) { try s.nodes(space: space, query: "", selected: [profile.id]) }
        c.wrongType = true
        #expect(throws: (any Error).self) { try s.spaces(profile: profile, selected: [profile.id]) }
    }
    @Test func wikiTitleFilterStaysInsideExplicitDirectoryAndWatchKeepsFolderScope() throws {
        let c = ResearchClient(now: now); let service = DingTalkResearchService(client: c)
        let space = DingTalkWikiSpace(workspaceID: "workspace-1", name: "合成知识库", profile: profile)
        let result = try service.nodes(space: space, query: "合成", folder: "folder-1", selected: [profile.id], now: now)
        #expect(result.complete && result.items.count == 1)
        #expect(c.arguments.last?.contains("--folder") == true && c.arguments.last?.contains("folder-1") == true)
        #expect(c.arguments.last?.contains("+node-search") == false)
        #expect(try service.nodes(space: space, query: "其他标题", folder: "folder-1", selected: [profile.id], now: now).items.isEmpty)
        let state = try DingTalkResearchPolicy.watching(result: result, profile: profile, kind: "wiki", query: "合成", space: space, folderID: "folder-1", state: .init())
        #expect(state.watches.first?.folderID == "folder-1")
        let root = try DingTalkResearchPolicy.watching(result: result, profile: profile, kind: "wiki", query: "合成", space: space, state: state)
        #expect(root.watches.count == 2)
    }
    @Test func ambiguousTargetTitleDoesNotLeakEitherSetOfEvidenceIntoChat() throws {
        let first = MatterTarget(reference: .personal(UUID()), title: "同名事项")
        let second = MatterTarget(reference: .personal(UUID()), title: "同名事项")
        let state = try DingTalkResearchPolicy.linking(item(text: "唯一哨兵"), to: first.reference, targets: [first,second], selected: [profile.id], state: .init())
        #expect(!DingTalkResearchPolicy.context(state: state, targets: [first,second], selected: [profile.id], text: "同名事项").content.contains("唯一哨兵"))
        #expect(DingTalkResearchPolicy.context(state: state, targets: [first,second], selected: [profile.id], text: first.reference.id).content.contains("唯一哨兵"))
    }
    @Test func unselectedProfilePreventsAnyBusinessRead() throws {
        let c = ResearchClient(now: now)
        #expect(throws: (any Error).self) { try DingTalkResearchService(client: c).messages(query: "评审", profile: profile, selected: [], now: now) }
        #expect(c.arguments.isEmpty)
    }
    @Test func explicitLinksDeduplicateByStableSourceAndTargetNotTitle() throws {
        let target = MatterTarget(reference: .personal(UUID()), title: "合成事项")
        var state = try DingTalkResearchPolicy.linking(item(), to: target.reference, targets: [target], selected: [profile.id], state: .init())
        state = try DingTalkResearchPolicy.linking(item(), to: target.reference, targets: [target], selected: [profile.id], state: state)
        #expect(state.links.count == 1)
        state = try DingTalkResearchPolicy.linking(item(id: "msg-2"), to: target.reference, targets: [target], selected: [profile.id], state: state)
        #expect(state.links.count == 2)
        #expect(throws: (any Error).self) { try DingTalkResearchPolicy.linking(item(), to: target.reference, targets: [], selected: [profile.id], state: state) }
        #expect(throws: (any Error).self) { try DingTalkResearchPolicy.linking(item(), to: target.reference, targets: [target], selected: [], state: state) }
    }
    @Test func changeBaselineOnlyAdvancesOnCompleteAndDoesNotTreatDisappearanceAsDeletion() throws {
        let original = item(); var state = try DingTalkResearchPolicy.watching(result: result([original]), profile: profile, kind: "message", query: "评审", space: nil, state: .init())
        let initial = try #require(state.watches.first); #expect(initial.changeCount == 0)
        let changed = item(text: "评审已延期"); let added = item(id: "msg-2")
        let next = try DingTalkResearchPolicy.checking(initial, result: result([changed, added]))
        #expect(next.changeCount == 2 && next.changes.count == 2)
        let unchanged = try DingTalkResearchPolicy.checking(next, result: result([changed, added]))
        #expect(unchanged.changeCount == 0)
        let expired = try DingTalkResearchPolicy.checking(next, result: result([]))
        #expect(expired.changeCount == 0 && expired.changes.isEmpty)
        #expect(throws: (any Error).self) { try DingTalkResearchPolicy.checking(next, result: result([original], complete: false)) }
        #expect(next.baseline[original.id] == changed.fingerprint)
        state = try DingTalkResearchPolicy.watching(result: result([original]), profile: profile, kind: "message", query: "评审", space: nil, state: state)
        #expect(state.watches.count == 1)
    }
    @Test func duplicateResultsCannotCrashOrResetWatchAndMaxFiveIsEnforced() throws {
        #expect(throws: (any Error).self) { try DingTalkResearchPolicy.watching(result: result([item(),item()]), profile: profile, kind: "message", query: "评审", space: nil, state: .init()) }
        var state = DingTalkResearchState()
        for n in 0..<5 { state = try DingTalkResearchPolicy.watching(result: result([]), profile: profile, kind: "message", query: "关键词\(n)", space: nil, state: state) }
        #expect(throws: (any Error).self) { try DingTalkResearchPolicy.watching(result: result([]), profile: profile, kind: "message", query: "第六个", space: nil, state: state) }
    }
    @Test func linkedContextOnlyContainsExplicitlyMentionedCurrentTargetsAndSelectedOrganization() throws {
        let target = MatterTarget(reference: .personal(UUID()), title: "合成评审事项")
        let state = try DingTalkResearchPolicy.linking(item(text: "合成依据哨兵"), to: target.reference, targets: [target], selected: [profile.id], state: .init())
        #expect(DingTalkResearchPolicy.context(state: state, targets: [target], selected: [profile.id], text: "合成评审事项有哪些依据").content.contains("合成依据哨兵"))
        #expect(!DingTalkResearchPolicy.context(state: state, targets: [target], selected: [profile.id], text: "其他问题").content.contains("合成依据哨兵"))
        #expect(!DingTalkResearchPolicy.context(state: state, targets: [target], selected: [], text: "合成评审事项").content.contains("合成依据哨兵"))
        #expect(!DingTalkResearchPolicy.context(state: state, targets: [], selected: [profile.id], text: "合成评审事项").content.contains("合成依据哨兵"))
    }
    @Test func backupRestorePreservesLinksAndManualWatchStateWithoutEnablingBackground() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dg03-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        let target = MatterTarget(reference: .personal(UUID()), title: "合成事项")
        var state = try DingTalkResearchPolicy.linking(item(), to: target.reference, targets: [target], selected: [profile.id], state: .init())
        state = try DingTalkResearchPolicy.watching(result: result([item()]), profile: profile, kind: "message", query: "评审", space: nil, state: state)
        let archive = LocalAssistantDataExport(exportedAt: now, profile: .init(name: "QA", personality: "自然", tone: "自然", address: "你", avatar: "warm", relationshipPoints: 0, automaticMemoryEnabled: false), conversation: [], memories: [], projects: [], personalTodos: [], skills: [], knowledgeBases: [], dingTalkResearch: state)
        let suite = "com.yuan.dg03.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try LocalAssistantDataManager.restore(archive, defaults: defaults, appDataDirectory: root)
        let restored = try DingTalkResearchStore(directory: root).load()
        #expect(restored.links == state.links && restored.watches.first?.baseline == state.watches.first?.baseline)
        #expect(try BackgroundPlanStore(directory: root).settings().enabled == false)
    }
    @Test func corruptResearchStoreCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dg03-corrupt-\(UUID())"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DingTalkResearchStore(directory: root); try Data("broken".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.save(.init()) }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "broken")
    }
}
private final class ResearchClient: DingTalkReading {
    static let profile = DingTalkProfile(corpID: "corp", userID: "employee", corpName: "隔离组织", userName: "本人", isOrgCurrent: true)
    let now: Date; var arguments: [[String]] = []
    var partial = false; var warning = false; var paginationKnown = true; var hasMore = false; var count = 1
    var missing = false; var duplicate = false; var wrongTime = false; var countMismatch = false; var wrongSpace = false; var wrongType = false
    init(now: Date) { self.now = now }
    func listProfiles() throws -> [DingTalkProfile] { [Self.profile] }
    func result(_ object: [String: Any]) throws -> DingTalkCLIResult { .init(data: try JSONSerialization.data(withJSONObject: object), exitCode: 0) }
    func run(_ operation: DingTalkReadOperation, profile: DingTalkProfile?) throws -> DingTalkCLIResult {
        #expect(profile == Self.profile); arguments.append(operation.arguments(profile: profile))
        switch operation {
        case .searchMessages:
            var rows: [[String: Any]] = (0..<count).map { ["messageId":"msg-\($0+1)","conversationId":"conversation-1","sender":"合成人员","text":"合成评审消息","createTime":now.addingTimeInterval(wrongTime ? 100 : -100).ISO8601Format()] }
            if duplicate { rows.append(rows[0]) }
            var r: [String: Any] = ["queryRange":["startTime":now.addingTimeInterval(-7 * 86400).ISO8601Format(),"endTime":now.ISO8601Format()],"contractVersion":"im.message-list.v1","messages":rows,"count":rows.count + (countMismatch ? 1 : 0),"complete":!partial,"hasMore":hasMore,"partial":partial,"truncated":false,"paginationKnown":paginationKnown,"failures":[],"failedCount":0,"warningCount":warning ? 1 : 0]
            if missing { r.removeValue(forKey: "messages") }; return try result(r)
        case .wikiSpaces:
            return try result(["ok":true,"data":["requestedType":wrongType ? "myWikiSpace" : "orgWikiSpace","autoPageComplete":true,"hasMore":false,"count":1,"spaces":[["workspaceId":"workspace-1","name":"合成知识库"]]]])
        case .wikiNodes:
            return try result(["ok":true,"data":["autoPageComplete":true,"hasMore":false,"count":1,"nodes":[["workspaceId":wrongSpace ? "other" : "workspace-1","nodeId":"node-1","name":"合成资料","extension":"adoc","updateTime":now.timeIntervalSince1970 * 1000]]]])
        default: throw DingTalkContentError.invalidResponse
        }
    }
}
