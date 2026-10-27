import Foundation
import Testing
@testable import PersonalAssistant

struct DingTalkContentTests {
    @Test func summaryRequiresTheRequestedSourceAndAnExplicitSuccessfulArtifact() throws {
        let client = ContentFixture()
        let service = DingTalkContentService(client: client)
        let minute = DingTalkMinute(taskID: "note", title: "合成会议", startsAt: nil, sourceURL: nil, organizationName: nil, profile: client.profile)
        client.response = #"{"complete":true,"results":[{"taskUuid":"another-note","complete":true,"summary":{"success":"true","result":{"fullSummary":"不属于所选纪要"}}}]}"#
        #expect(throws: DingTalkContentError.self) { try service.summary(for: minute) }
        client.response = #"{"complete":true,"results":[{"taskUuid":"note","complete":true,"summary":{"success":"false","result":{"fullSummary":"失败的产物"}}}]}"#
        #expect(throws: DingTalkContentError.self) { try service.summary(for: minute) }
        client.response = #"{"complete":true,"results":[{"taskUuid":"note","complete":true,"summary":{"success":"true","result":{"fullSummary":"请准备合成验收材料。"}}}]}"#
        #expect(try service.summary(for: minute) == "请准备合成验收材料。")
        client.response = #"{"complete":true,"taskUuid":"note","failureCount":0,"summary":{"success":"true","result":{"fullSummary":"单条听记的真实回执格式。"}}}"#
        #expect(try service.summary(for: minute) == "单条听记的真实回执格式。")
        #expect(client.profilesUsed.allSatisfy { $0 == client.profile.id })
    }

    @Test func minuteListDoesNotTreatIncompleteDataAsAnEmptySuccess() throws {
        let client = ContentFixture()
        let service = DingTalkContentService(client: client)
        client.response = #"{"outcome":"success","data":{"complete":false,"minutes":[]}}"#
        #expect(throws: DingTalkContentError.self) { try service.minutes(from: .distantPast, to: Date(), selectedIDs: [client.profile.id]) }
        client.response = #"{"outcome":"success","data":{"complete":true,"minutes":[{"taskUuid":"note","title":"会议","startTime":1793016000000,"url":"https://shanji.dingtalk.com/app/transcribes/note"}]}}"#
        let notes = try service.minutes(from: .distantPast, to: Date(), selectedIDs: [client.profile.id])
        #expect(notes.count == 1)
        #expect(notes.first?.organizationName == nil)
        #expect(notes.first?.startsAt == Date(timeIntervalSince1970: 1793016000))
    }

    @Test func documentSearchKeepsPartialStateAndRejectsUnrelatedMetadataDates() throws {
        let client = ContentFixture()
        client.response = #"{"status":"success","complete":false,"hasMore":true,"documents":[{"nodeId":"doc","name":"项目材料","url":"https://alidocs.dingtalk.com/i/nodes/doc","modifiedTime":null,"docType":"adoc"}],"failures":[]}"#
        client.metadata = #"{"success":true,"result":{"nodeId":"different-doc","updateTime":1793016000000}}"#
        let result = try DingTalkContentService(client: client).documents(query: "项目材料", selectedIDs: [client.profile.id])
        #expect(!result.complete)
        #expect(result.returnedCount == 1)
        #expect(result.recommendations.first?.updatedAt == nil)
        #expect(result.recommendations.first?.title == "项目材料")
        #expect(DingTalkJSON.webURL("file:///tmp/unsafe") == nil)
    }

    @Test func documentRecommendationsAreLimitedToThreeAndMetadataStaysInProfile() throws {
        let client = ContentFixture()
        let documents = (1...4).map { ["nodeId": "doc\($0)", "name": "材料\($0)", "url": "https://alidocs.dingtalk.com/i/nodes/doc\($0)", "docType": "adoc"] }
        client.response = String(data: try JSONSerialization.data(withJSONObject: ["status": "success", "complete": true, "hasMore": false, "documents": documents, "failures": []]), encoding: .utf8)!
        let result = try DingTalkContentService(client: client).documents(query: "项目", selectedIDs: [client.profile.id])
        #expect(result.recommendations.count == 3)
        #expect(result.returnedCount == 4)
        #expect(client.metadataReads == 3)
        #expect(client.profilesUsed.allSatisfy { $0 == client.profile.id })
    }
}

private final class ContentFixture: DingTalkReading {
    let profile = DingTalkProfile(corpID: "corp", userID: "user", corpName: "合成组织", userName: nil, isOrgCurrent: true)
    var response = "{}"
    var metadata = "{}"
    var profilesUsed: [String] = []
    var metadataReads = 0
    func listProfiles() throws -> [DingTalkProfile] { [profile] }
    func run(_ operation: DingTalkReadOperation, profile: DingTalkProfile?) throws -> DingTalkCLIResult {
        profilesUsed.append(profile?.id ?? "missing")
        if case .documentInfo = operation {
            metadataReads += 1
            return .init(data: Data(metadata.utf8), exitCode: 0)
        }
        return .init(data: Data(response.utf8), exitCode: 0)
    }
}
