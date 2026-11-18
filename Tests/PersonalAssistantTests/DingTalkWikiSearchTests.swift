import Foundation
import Testing
@testable import PersonalAssistant

struct DingTalkWikiSearchTests {
    let profile = DingTalkProfile(corpID: "corp", userID: "user", corpName: "隔离组织", userName: "测试本人", isOrgCurrent: true)
    @Test func searchVerifiesEveryResultWithNodeMetadataInSameProfile() throws {
        let client = WikiSearchClient(profile: profile); let service = DingTalkResearchService(client: client)
        let result = try service.searchAcrossWiki(space: .init(workspaceID: "w1", name: "合成库", profile: profile), query: "评审", selected: [profile.id])
        #expect(result.complete && result.items.count == 2 && client.proofs == ["n1","n2"])
        #expect(client.arguments.allSatisfy { $0.contains(profile.id) && !$0.contains("--yes") })
        #expect(result.items.allSatisfy { $0.containerID == "w1" })
    }
    @Test func wrongWorkspaceChangedTitleMalformedRowsAndDuplicateIDsFailClosed() throws {
        for kind in 0..<4 {
            let client = WikiSearchClient(profile: profile); client.foreign = kind == 0; client.changed = kind == 1; client.missing = kind == 2; client.duplicate = kind == 3
            #expect(throws: (any Error).self) { try DingTalkResearchService(client: client).searchAcrossWiki(space: .init(workspaceID: "w1", name: "合成库", profile: profile), query: "评审", selected: [profile.id]) }
        }
    }
    @Test func partialOrTooManyResultsCannotBecomeWatchBaseline() throws {
        let client = WikiSearchClient(profile: profile); client.complete = false
        let r = try DingTalkResearchService(client: client).searchAcrossWiki(space: .init(workspaceID: "w1", name: "合成库", profile: profile), query: "评审", selected: [profile.id])
        #expect(!r.complete)
        #expect(throws: (any Error).self) { try DingTalkResearchPolicy.watching(result: r, profile: profile, kind: "wiki", query: "评审", space: .init(workspaceID: "w1", name: "合成库", profile: profile), acrossDirectories: true, state: .init()) }
    }
    @Test func acrossDirectoryWatchScopeDoesNotOverwriteDirectoryWatch() throws {
        let client = WikiSearchClient(profile: profile); let space = DingTalkWikiSpace(workspaceID: "w1", name: "合成库", profile: profile)
        let r = try DingTalkResearchService(client: client).searchAcrossWiki(space: space, query: "评审", selected: [profile.id])
        let directory = try DingTalkResearchPolicy.watching(result: r, profile: profile, kind: "wiki", query: "评审", space: space, state: .init())
        let combined = try DingTalkResearchPolicy.watching(result: r, profile: profile, kind: "wiki", query: "评审", space: space, acrossDirectories: true, state: directory)
        #expect(combined.watches.count == 2 && combined.watches.last?.acrossDirectories == true)
    }
}
private final class WikiSearchClient: DingTalkReading {
    let profile: DingTalkProfile; var proofs: [String] = []; var arguments: [[String]] = []
    var foreign = false; var changed = false; var missing = false; var duplicate = false; var complete = true
    init(profile: DingTalkProfile) { self.profile = profile }
    func listProfiles() throws -> [DingTalkProfile] { [profile] }
    func result(_ object: [String: Any]) throws -> DingTalkCLIResult { .init(data: try JSONSerialization.data(withJSONObject: object), exitCode: 0) }
    func run(_ operation: DingTalkReadOperation, profile: DingTalkProfile?) throws -> DingTalkCLIResult {
        #expect(profile == self.profile); arguments.append(operation.arguments(profile: profile))
        switch operation {
        case .searchWiki:
            if missing { return try result(["ok":true,"data":["count":0,"autoPageComplete":true]]) }
            return try result(["ok":true,"data":["count":2,"autoPageComplete":complete,"hasMore":!complete,"nodes":[["nodeId":"n1","name":"评审n1"],["nodeId":duplicate ? "n1" : "n2","name":"评审n2"]]]])
        case .wikiNodeInfo(let id):
            proofs.append(id)
            return try result(["ok":true,"data":["success":true,"nodeId":id,"workspaceId":foreign ? "other" : "w1","name":changed ? "他人已改名" : "评审" + id,"extension":"adoc"]])
        default: throw DingTalkContentError.invalidResponse
        }
    }
}
