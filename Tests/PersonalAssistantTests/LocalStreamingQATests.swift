import Foundation
import Testing
@testable import PersonalAssistant

struct LocalStreamingQATests {
    @Test func productionAndUnrelatedQAIdentitiesCannotOptIn() {
        for id in [nil, "com.yuan.personal-assistant", "other.qa.app", "com.yuan.personal-assistant.qa"] {
            #expect(!StreamingPreviewQA.shouldEnable(bundleID: id, arguments: ["--stream-preview-qa"], infoOptIn: true))
        }
    }
    @Test func ownedQAStillNeedsExplicitOptIn() {
        let id = "com.yuan.personal-assistant.qa.localstream"
        #expect(!StreamingPreviewQA.shouldEnable(bundleID: id, arguments: []))
        #expect(StreamingPreviewQA.shouldEnable(bundleID: id, arguments: ["--stream-preview-qa"]))
        #expect(StreamingPreviewQA.shouldEnable(bundleID: id, arguments: [], infoOptIn: true))
    }
    @Test func unexpectedHostsAreInterceptedRatherThanFallingThrough() {
        #expect(StreamingPreviewProtocol.canInit(with: URLRequest(url: URL(string: "https://unexpected.invalid/")!)))
    }
    @Test func packetsAreValidSSEAndOnlyFinalCarriesCompletion() throws {
        let content = "中文🙂\n\"引用\""
        for final in [false, true] {
            let packet = String(decoding: StreamingPreviewProtocol.packet(content: content, final: final), as: UTF8.self)
            let line = try #require(packet.components(separatedBy: "\n").first)
            let body = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any]
            let choice = (body["choices"] as! [[String: Any]])[0]
            #expect((choice["delta"] as? [String: String])?["content"] == content)
            #expect(packet.contains("[DONE]") == final)
            #expect((choice["finish_reason"] as? String == "stop") == final)
        }
    }

    @Test func localStreamDeliversAllSegmentsInOrder() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingPreviewProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: URL(string: "https://unexpected.invalid/local-qa")!)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        var pieces: [String] = []
        for line in lines where line.hasPrefix("data: ") && !line.contains("[DONE]") {
            let body = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any]
            let choice = (body["choices"] as! [[String: Any]])[0]
            if let text = (choice["delta"] as? [String: String])?["content"] { pieces.append(text) }
        }
        #expect(pieces.count == 41)
        #expect(pieces.first?.contains("未调用外部模型") == true)
        #expect(Array(pieces.dropFirst()) == (1...40).map { StreamingPreviewProtocol.text(request: 1, part: $0) })
    }
}
