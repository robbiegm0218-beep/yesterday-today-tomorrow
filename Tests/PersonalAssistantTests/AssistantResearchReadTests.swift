import Foundation
import Testing
@testable import PersonalAssistant

@MainActor
struct AssistantResearchReadTests {
    private func call(_ name: String, _ arguments: [String:Any]) throws -> DeepSeekToolCall {
        .init(id: UUID().uuidString, function: .init(name:name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:arguments),as:UTF8.self)))
    }
    private func object(_ result: AssistantReadResult) throws -> [String:Any] { try #require(JSONSerialization.jsonObject(with:Data(result.content.utf8)) as? [String:Any]) }
    private func reader(_ backend: ResearchStub, request: String = "查钉钉文档", scope: (@MainActor () -> Set<String>)? = nil) -> AssistantResearchReader {
        AssistantResearchReader(client:backend,selected:[backend.profile.id],request:request,scope:scope ?? { [backend] in [backend.profile.id] })
    }
    private func handle(_ reader: AssistantResearchReader) async throws -> String {
        let result = try await reader.execute(call("search_dingtalk_documents",["query":"评审"]),timeout:3)
        let rows = try #require(object(result)["items"] as? [[String:Any]])
        return try #require(rows.first?["document_handle"] as? String)
    }
    @Test func malformedCoverageNeverClaimsComplete() {
        let complete: [String:Any] = ["complete":true,"hasMore":false,"failures":[],"status":"success"]
        #expect(AssistantResearchParser.complete(complete))
        for extra: [String:Any] in [["truncatedByPageLimit":true],["truncatedByResultLimit":1],["hasMore":true],["hasMore":"false"],["truncated":"false"],["partial":0],["failures":"none"],["warnings":["limited"]],["failedCount":"0"],["warningCount":true],["outcome":"partial"],["status":"failed"]] {
            #expect(!AssistantResearchParser.complete(complete.merging(extra) { _,new in new }))
        }
    }
    @Test func metadataIsNotBodyAndUnknownHandleNeverReachesRemote() async throws {
        let backend = ResearchStub(); let r = reader(backend)
        let invalid = try await r.execute(call("read_dingtalk_document",["document_handle":"node-a"]),timeout:3)
        #expect(invalid.remoteSucceeded == false && backend.calls.isEmpty)
        let result = try await r.execute(call("search_dingtalk_documents",["query":"评审"]),timeout:3)
        #expect(result.remoteSources.first?.coverage.contains("尚未读取") == true)
        #expect(!result.content.contains("正文密文"))
        let rows = try #require(object(result)["items"] as? [[String:Any]])
        #expect(rows.first?["content_read"] as? Bool == false)
    }
    @Test func pagesUseOneExactFetchAndKeepCoverageAndSanitizedEvidence() async throws {
        let backend = ResearchStub(); backend.body = "密钥sk-abcdefghijklmnopqrst https://example.org/?access_token=secret " + String(repeating:"甲",count:4500)
        let r = reader(backend), h = try await handle(r)
        let first = try await r.execute(call("read_dingtalk_document",["document_handle":h]),timeout:3)
        let firstJSON = try object(first)
        #expect(firstJSON["complete"] as? Bool == false && firstJSON["next_offset"] as? Int == 4000)
        #expect(!first.content.contains("abcdefghijklmnopqrst") && !first.content.contains("access_token=secret"))
        let second = try await r.execute(call("read_dingtalk_document",["document_handle":h,"offset":4000]),timeout:3)
        #expect(try object(second)["page_complete"] as? Bool == true)
        #expect(try object(second)["complete"] as? Bool == false)
        #expect(backend.calls.count == 2 && backend.calls.last == .document(node:"node-a",keyword:""))
        let invalid = try await r.execute(call("read_dingtalk_document",["document_handle":h,"offset":3999]),timeout:3)
        #expect(invalid.remoteSucceeded == false && backend.calls.count == 2)
        #expect(first.remoteSources.first?.safeURL?.absoluteString == "https://alidocs.dingtalk.com/i/nodes/node-a")
    }
    @Test func focusedExcerptAndWrongReturnedIdentityAreHandledSeparately() async throws {
        let backend = ResearchStub(); let r = reader(backend); let h = try await handle(r)
        let result = try await r.execute(call("read_dingtalk_document",["document_handle":h,"keyword":"验收"]),timeout:3)
        let resultJSON = try object(result)
        #expect(result.remoteSucceeded == true && result.content.contains("局部验收依据") && resultJSON["complete"] as? Bool == false)
        #expect(resultJSON["whole_document_length_known"] as? Bool == false && result.content.contains("Whole-document length is UNKNOWN"))
        backend.wrongIdentity = true
        let bad = try await r.execute(call("read_dingtalk_document",["document_handle":h]),timeout:3)
        #expect(bad.remoteSucceeded == false && !bad.content.contains("正文密文"))
    }
    @Test func ambiguousCandidateIsNotAutomaticallyReadAndCompleteZeroStopsBroadening() async throws {
        let backend = ResearchStub(); backend.documentCount = 2
        let r = reader(backend); let h = try await handle(r)
        let result = try await r.execute(call("read_dingtalk_document",["document_handle":h]),timeout:3)
        #expect(result.remoteSucceeded == false && backend.calls.count == 1)
        let empty = ResearchStub(); empty.documentCount = 0
        let zero = reader(empty)
        #expect(try object(await zero.execute(call("search_dingtalk_documents",["query":"精确标题"]),timeout:3))["complete"] as? Bool == true)
        let broadened = try await zero.execute(call("search_dingtalk_documents",["query":"换个词"]),timeout:3)
        #expect(broadened.remoteSucceeded == false && empty.calls.count == 1)
    }
    @Test func partialZeroIsNotAuthoritativeAndRangeMismatchNeverBecomesEvidence() async throws {
        let backend = ResearchStub(); backend.documentCount = 0; backend.partial = true
        let r = reader(backend)
        let zero = try await r.execute(call("search_dingtalk_documents",["query":"评审"]),timeout:3)
        #expect(try object(zero)["zero_result_authoritative_for_query"] as? Bool == false)
        _ = try await r.execute(call("search_dingtalk_documents",["query":"另一关键词"]),timeout:3)
        #expect(backend.calls.count == 2)
        backend.badRange = true
        let mismatch = try await r.execute(call("search_dingtalk_messages",["query":"评审"]),timeout:3)
        #expect(mismatch.remoteSucceeded == false && mismatch.remoteSources.isEmpty && !mismatch.content.contains("最新窗口"))
    }
    @Test func messageTimeScopeAndStrictArguments() async throws {
        let backend = ResearchStub(); let r = reader(backend)
        let valid = try await r.execute(call("search_dingtalk_messages",["query":"窗口","days":2]),timeout:3)
        #expect(valid.remoteSucceeded == true && valid.content.contains("最新窗口") && valid.remoteSources.first?.kind == "message")
        #expect(try object(valid)["lookback_days"] as? Int == 2)
        #expect(valid.content.contains("(2 days)") && !valid.content.contains("last_1_to_7_days"))
        for args: [String:Any] in [["query":"窗口","days":true],["query":"窗口","days":8],["query":"窗口","days":"2"],["query":"窗口","profile_id":"other:user"],["query":"窗口","send":true],["query":"窗\n口"]] {
            #expect(try await r.execute(call("search_dingtalk_messages",args),timeout:3).remoteSucceeded == false)
        }
        #expect(backend.calls.count == 1)
        #expect(AssistantResearchOperation.documents(query:"--help").arguments.contains("--query=--help"))
    }
    @Test func selectionChangeAndMultipleOrganizationsNeverPickFirst() async throws {
        let backend = ResearchStub(); var selected: Set<String> = [backend.profile.id]
        backend.onRun = { selected = [] }
        let r = reader(backend,scope:{selected})
        let result = try await r.execute(call("search_dingtalk_messages",["query":"窗口"]),timeout:3)
        #expect(result.remoteSucceeded == false && result.remoteSources.isEmpty && !result.content.contains("最新窗口"))
        let multiple = ResearchStub(); multiple.extraProfile = .init(corpID:"other",userID:"self",corpName:"另一组织",userName:nil,isOrgCurrent:false)
        let both: Set<String> = [multiple.profile.id,multiple.extraProfile!.id]
        let ambiguous = AssistantResearchReader(client:multiple,selected:both,request:"查钉钉消息",scope:{both})
        #expect(try await ambiguous.execute(call("search_dingtalk_messages",["query":"窗口","profile_id":multiple.profile.id]),timeout:3).remoteSucceeded == false)
        #expect(multiple.calls.isEmpty)
        let explicit = AssistantResearchReader(client:multiple,selected:both,request:"查评估组织的钉钉消息",scope:{both})
        #expect(try await explicit.execute(call("search_dingtalk_messages",["query":"窗口"]),timeout:3).remoteSucceeded == true)
    }
    @Test func timeoutFailureAndCancellationNeverProduceEvidence() async throws {
        let backend = ResearchStub(); let r = reader(backend)
        backend.error = DingTalkCLIError.timedOut
        #expect(try await r.execute(call("search_dingtalk_documents",["query":"评审"]),timeout:3).remoteSucceeded == false)
        backend.error = CancellationError()
        do { _ = try await r.execute(call("search_dingtalk_documents",["query":"评审"]),timeout:3); Issue.record("Cancellation swallowed") }
        catch is CancellationError { }
    }
    @Test func failedRemoteReadDiscardsSameBatchWriteAndStopsModelLoop() async throws {
        let backend = ResearchStub(); backend.error = DingTalkCLIError.timedOut
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResearchLoopProtocol.self]
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
        let result = try await DeepSeekClient(session:session).assistantTurn(to:[.init(role:"user",content:"先查钉钉消息，再创建待办；失败就停止")],enabledSkillIDs:["todo-priority"],apiKey:"unused",readContext:.init(researchReader:reader(backend)),budget:.init(maxSeconds:3))
        #expect(result.stopReason == "remote_read_failed" && result.toolCalls.isEmpty && result.modelRounds == 1)
        #expect(result.text?.contains("未知") == true && result.remoteSources.isEmpty)
    }
    @Test func safeLinksAndIntentGate() {
        for raw in ["https://evil.test/i/nodes/a","http://alidocs.dingtalk.com/i/nodes/a","https://alidocs.dingtalk.com/i/nodes/a/b","https://alidocs.dingtalk.com:444/i/nodes/a","https://alidocs.dingtalk.com/i/nodes/a?token=x"] {
            let source = AssistantRemoteSource(id:"a",kind:"document",profileID:"p",organization:"o",title:"t",observedAt:Date(),sourceTime:nil,coverage:"c",url:URL(string:raw))
            #expect(source.safeURL == nil)
        }
        #expect(!AssistantResearchIntent.allows("你好",previousUserRequests:[]))
        #expect(!AssistantResearchIntent.allows("读一下正文",previousUserRequests:[]))
        #expect(AssistantResearchIntent.allows("读一下正文",previousUserRequests:["查钉钉文档"]))
    }
}

private final class ResearchStub: AssistantResearchReading {
    let profile = DingTalkProfile(corpID:"evaluation",userID:"self",corpName:"评估组织",userName:nil,isOrgCurrent:true)
    var extraProfile: DingTalkProfile?
    var calls: [AssistantResearchOperation] = []
    var documentCount = 1
    var partial = false
    var badRange = false
    var wrongIdentity = false
    var body = "正文密文：验收采用逐项核对。"
    var error: Error?
    var onRun: (@MainActor () -> Void)?
    func profiles(timeout: TimeInterval) async throws -> [DingTalkProfile] { [profile] + (extraProfile.map { [$0] } ?? []) }
    @MainActor func run(_ operation: AssistantResearchOperation, profileID: String, timeout: TimeInterval) async throws -> DingTalkCLIResult {
        if let error { throw error }; calls.append(operation); onRun?()
        var value: [String:Any] = ["complete":!partial,"hasMore":partial,"failures":[],"status":"success"]
        switch operation {
        case let .messages(_,start,end):
            value.merge(["contractVersion":"im.message-list.v1","count":1,"paginationKnown":true,"queryRange":["startTime":badRange ? "2000-01-01T00:00:00Z" : start,"endTime":end],"messages":[["messageId":"m-a","conversationId":"c-a","sender":"小林","text":"最新窗口为灰雀七号","createTime":Date().addingTimeInterval(-60).ISO8601Format()]]]) { _,new in new }
        case .documents:
            value.merge(["contractVersion":"doc.list.v1","count":documentCount,"documents":(0..<documentCount).map { ["nodeId":$0 == 0 ? "node-a" : "node-b","name":"评审方案\($0)","docType":"adoc","url":"https://alidocs.dingtalk.com/i/nodes/node-a"] }]) { _,new in new }
        case let .document(node,keyword):
            value.merge(["contractVersion":"doc.content.v1","target":["canonicalId":wrongIdentity ? "wrong" : node,"product":"doc"],"content":keyword.isEmpty ? ["nodeId":node,"success":true,"markdown":body] : ["count":1,"matches":[["content":"局部验收依据","truncated":false]]]]) { _,new in new }
        }
        return .init(data:try JSONSerialization.data(withJSONObject:value),exitCode:0)
    }
}

private final class ResearchLoopProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let calls: [[String:Any]] = [
            ["id":"read", "type":"function", "function":["name":"search_dingtalk_messages", "arguments":"{\"query\":\"窗口\"}"]],
            ["id":"write", "type":"function", "function":["name":"create_personal_todo", "arguments":"{\"title\":\"不应提案\"}"]]]
        let body: [String:Any] = ["choices":[["message":["role":"assistant", "content":"先核对", "tool_calls":calls]]], "usage":["prompt_tokens":10,"completion_tokens":5,"total_tokens":15]]
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
