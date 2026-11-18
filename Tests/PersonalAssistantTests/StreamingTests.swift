import Foundation
import Testing
@testable import PersonalAssistant

private func frame(_ object: [String: Any]) throws -> String {
    "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\r\n\r\n"
}
private func delta(_ content: String? = nil, tools: [[String: Any]]? = nil, finish: String? = nil) -> [String: Any] {
    var d: [String: Any] = [:]
    if let content { d["content"] = content }; if let tools { d["tool_calls"] = tools }
    var c: [String: Any] = ["index": 0, "delta": d]
    if let finish { c["finish_reason"] = finish }
    return ["choices": [c], "model": "deepseek-flash"]
}
private func parse(_ text: String, limit: Int = 64_000) throws -> DeepSeekStreamAccumulator {
    var parser = DeepSeekStreamAccumulator(tokenLimit: limit)
    for byte in text.utf8 { _ = try parser.consume(byte) }
    _ = try parser.finish(); return parser
}

@Suite(.serialized) @MainActor struct StreamingTests {
    @Test func byteFramingPreservesChineseMultilineAndFinalUsage() throws {
        let data = try frame(delta("你好，")) + frame(delta("世界\n第二行", finish: "stop")) + frame(["choices": [], "usage": ["prompt_tokens": 9, "completion_tokens": 3, "total_tokens": 12]]) + "data: [DONE]\n\n"
        var parser = DeepSeekStreamAccumulator(); var previews: [AssistantStreamUpdate] = []
        for b in data.utf8 { if let p = try parser.consume(b) { previews.append(p) } }
        let result = try parser.finish()
        #expect(result.text == "你好，世界\n第二行" && result.calls.isEmpty)
        #expect(previews.first == .text("你好，") && parser.usage?.totalTokens == 12)
    }
    @Test func fragmentedToolJSONIsPrivateAndCannotBecomeACallBeforeDone() throws {
        let first: [String: Any] = ["index":0,"id":"call-a","type":"function","function":["name":"create_personal_todo","arguments":"{\"title\":\"含"]]
        let second: [String: Any] = ["index":0,"function":["arguments":"引号\\\"的标题\"}"]]
        let body = try frame(delta("先核对")) + frame(delta(tools: [first])) + frame(delta(tools: [second], finish: "tool_calls"))
        var parser = DeepSeekStreamAccumulator(); var updates: [AssistantStreamUpdate] = []
        for b in body.utf8 { if let value = try parser.consume(b) { updates.append(value) } }
        #expect(throws: DeepSeekStreamError.self) { _ = try parser.finish() }
        for b in "data: [DONE]\n\n".utf8 { _ = try parser.consume(b) }
        let result = try parser.finish()
        #expect(result.calls.count == 1 && updates.last == .reset)
        let args = try #require(JSONSerialization.jsonObject(with: Data(result.calls[0].function.arguments.utf8)) as? [String:String])
        #expect(args["title"] == "含引号\"的标题")
        #expect(!updates.contains { if case let .text(t) = $0 { return t.contains("arguments") }; return false })
    }
    @Test func disconnectTruncationMalformedAndBudgetCannotBecomeSuccess() throws {
        let partial = try frame(delta("部分回复"))
        for text in [partial, partial + "data: [DONE]\n\n", partial + (try frame(delta(finish: "length"))), "data: broken\n\n"] {
            #expect(throws: (any Error).self) { _ = try parse(text) }
        }
        let over = try frame(delta("正文", finish: "stop")) + frame(["choices": [], "usage": ["prompt_tokens": 60, "completion_tokens": 10, "total_tokens": 70]]) + "data: [DONE]\n\n"
        #expect(throws: DeepSeekStreamError.self) { _ = try parse(over, limit: 70) }
        var large = DeepSeekStreamAccumulator()
        #expect(throws: DeepSeekStreamError.self) { for _ in 0...128_000 { _ = try large.consume(97) } }
    }
    @Test func missingOrInvalidAccountingRemainsUnknownAndSentinelMayEndAtEOF() throws {
        for usage: Any in [NSNull(), ["total_tokens":-1], ["prompt_tokens": Int.max, "completion_tokens":1, "total_tokens":Int.max]] {
            let text = try frame(delta("OK", finish: "stop")) + frame(["choices": [], "usage": usage]) + "data: [DONE]"
            let parser = try parse(text)
            #expect(parser.done && parser.usage == nil)
        }
    }
    @Test func transportDeliversBeforeDoneAndCountsOneRequest() async throws {
        let body = try frame(delta("首段")) + frame(delta("结束", finish: "stop")) + frame(["choices": [], "usage": ["prompt_tokens": 10, "completion_tokens":2, "total_tokens":12]]) + "data: [DONE]\n\n"
        StreamProtocol.configure(parts: [(0,try frame(delta("首段"))), (0.3, String(body.dropFirst(try frame(delta("首段")).count)))])
        let session = StreamProtocol.session(); defer { session.invalidateAndCancel() }
        let usage = ScenarioUsage(); var previews: [String] = []; var firstAt: TimeInterval?
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await DeepSeekClient(session: session, usageObserver: { usage.record($0) }).assistantTurn(to: [.init(role:"user",content:"只读说明")], enabledSkillIDs: [], apiKey: "unused", onStream: { update in
            if case let .text(text) = update {
                previews.append(text)
                if firstAt == nil { firstAt = ProcessInfo.processInfo.systemUptime - start }
            }
        })
        #expect(result.text == "首段结束" && previews.first == "首段")
        let first = try #require(firstAt)
        #expect(first < 0.25)
        #expect(usage.count == 1 && usage.tokens == 12 && StreamProtocol.requests == 1)
    }
    @Test func failedCheckpointPreventsAnyNetworkRequest() async throws {
        StreamProtocol.configure(parts: [(0,try frame(delta("不应请求",finish:"stop")) + "data: [DONE]\n\n")])
        let session = StreamProtocol.session(); defer { session.invalidateAndCancel() }
        for reads in [false,true] {
            do {
                _ = try await DeepSeekClient(session:session).assistantTurn(to:[.init(role:"user",content:"只读")],enabledSkillIDs:[],apiKey:"unused",readContext:reads ? .init() : nil,onStream:{ _ in },onCheckpoint:{ _ in throw URLError(.cannotWriteToFile) })
                Issue.record("Failed checkpoint cannot start a request")
            } catch { #expect((error as? URLError)?.code == .cannotWriteToFile) }
        }
        #expect(StreamProtocol.requests == 0)
    }

    @Test func cancellationAndDeadlineStopLateNetworkFragments() async throws {
        for cancel in [true,false] {
            StreamProtocol.configure(parts: [(0,try frame(delta("临时片段"))), (0.5,try frame(delta("迟到内容",finish:"stop")) + "data: [DONE]\n\n")])
            let session = StreamProtocol.session(); defer { session.invalidateAndCancel() }
            var seen: [String] = []
            let task = Task {
                try await DeepSeekClient(session: session).assistantTurn(to:[.init(role:"user",content:"只读")], enabledSkillIDs:[], apiKey:"unused", readContext: .init(), budget: .init(maxSeconds: cancel ? 2 : 0.08), onStream: { update in
                    if case let .text(t) = update { seen.append(t) }
                })
            }
            if cancel {
                for _ in 0..<100 where seen.isEmpty { try await Task.sleep(for:.milliseconds(5)) }
                #expect(!seen.isEmpty); task.cancel()
            }
            do { _ = try await task.value; Issue.record("Interrupted stream returned success") }
            catch { if cancel { #expect(error is CancellationError) } else { #expect((error as? DeepSeekRequestError) != nil) } }
            let count = seen.count
            try await Task.sleep(for:.milliseconds(550))
            #expect(seen.count == count && !seen.contains(where: { $0.contains("迟到") }) && StreamProtocol.requests == 1)
        }

    }
    @Test func streamingUsesRemainingBudgetAndKeepAliveIsNotText() async throws {
        StreamProtocol.configure(parts:[(0,": keep-alive\n\n"),(0.12,try frame(delta("连接测试通过",finish:"stop"))+"data: [DONE]\n\n")])
        let session=StreamProtocol.session();defer{session.invalidateAndCancel()};var previews:[String]=[]
        let reply=try await DeepSeekClient(session:session).assistantTurn(to:[.init(role:"user",content:"只读连接测试")],enabledSkillIDs:[],apiKey:"unused",readContext:.init(),budget:.init(maxSeconds:80),onStream:{if case let .text(t)=$0 {previews.append(t)}})
        #expect(reply.text=="连接测试通过" && StreamProtocol.timeouts.first.map{$0>79 && $0<=80}==true)
        #expect(previews.allSatisfy{!$0.contains("keep-alive")} && StreamProtocol.requests==1)
    }
    @Test func keepAliveCannotExtendHardBudgetOrProduceSuccess() async throws {
        StreamProtocol.configure(parts:[(0,": keep-alive\n\n"),(0.3,": keep-alive\n\n"),(0.6,try frame(delta("迟到",finish:"stop"))+"data: [DONE]\n\n")])
        let session=StreamProtocol.session();defer{session.invalidateAndCancel()}
        do {_=try await DeepSeekClient(session:session).assistantTurn(to:[.init(role:"user",content:"只读")],enabledSkillIDs:[],apiKey:"unused",readContext:.init(),budget:.init(maxSeconds:0.15),onStream:{_ in});Issue.record("Keepalive bypassed deadline")}
        catch let DeepSeekRequestError.streamTimedOut(phase,bytes) {#expect(phase == .modelContent && bytes>0)}
        #expect(StreamProtocol.requests==1 && StreamProtocol.timeouts[0]<=0.15)
    }
    @Test func timeoutProgressDistinguishesHeadersQueueAndPartialContent() {
        let progress=DeepSeekStreamProgress()
        if case let .streamTimedOut(phase,_) = progress.timeoutError() {#expect(phase == .responseHeaders)}
        progress.receivedHeaders();progress.receivedBytes(20)
        if case let .streamTimedOut(phase,_) = progress.timeoutError() {#expect(phase == .modelContent)}
        progress.receivedBytes(40,hasPayload:true)
        if case let .streamTimedOut(phase,bytes) = progress.timeoutError() {#expect(phase == .receiving && bytes==40)}
        #expect(AssistantTurnDiagnostic.category(for:progress.timeoutError())=="timeout")
    }

}

private final class StreamProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var parts: [(Double,String)] = []
    static var requests = 0
    static var timeouts:[TimeInterval]=[]
    private var stopped = false
    private let lock = NSLock()
    static func configure(parts: [(Double,String)]) { lock.lock(); defer { lock.unlock() }; self.parts = parts; requests = 0;timeouts=[] }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StreamProtocol.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let parts = Self.parts; Self.requests += 1; Self.timeouts.append(request.timeoutInterval); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields:["Content-Type":"text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let queue = DispatchQueue(label:"stream-fixture")
        for (i,part) in parts.enumerated() {
            queue.asyncAfter(deadline: .now()+part.0) { [self] in
                lock.lock(); let alive = !stopped; lock.unlock(); guard alive else { return }
                client?.urlProtocol(self, didLoad: Data(part.1.utf8))
                if i == parts.count-1 { client?.urlProtocolDidFinishLoading(self) }
            }
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
