import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct InputBudgetTests {
    @Test func moduleAuditPreservesSourceAndNeverPersistsText() throws {
        let secret = "不应保存的内容🙂精确ID-123"
        let messages: [DeepSeekChatMessage] = [.init(role: "system", content: secret), .init(role: "assistant", content: "历史"), .init(role: "user", content: secret)]
        let audit = AssistantInputAudit.make(messages: messages, names: ["system", "recent_history", "current_request"])
        #expect(audit.characters == messages.reduce(0) { $0 + $1.content.count })
        #expect(audit.utf8Bytes == messages.reduce(0) { $0 + $1.content.utf8.count })
        #expect(audit.modules.count == 3 && audit.modules.last?.retention == "preserved_without_trimming")
        let encoded = String(decoding: try JSONEncoder().encode(audit), as: UTF8.self)
        #expect(!encoded.contains(secret) && !encoded.contains("精确ID"))
        #expect(messages.last?.content == secret)
        let grouped = AssistantInputAudit.make(messages: messages, names: ["same", "same"])
        #expect(grouped.modules.first?.messageCount == 2 && grouped.modules.last?.name == "protected_task_context")
    }
    @Test func policyChecksExactByteAndEstimateBoundariesWithoutOverflow() {
        let p = AssistantInputPolicy(maximumEstimatedInputTokens: 10, maximumRequestBytes: 40, outputReserve: 8)
        #expect(p.accepts(bytes: 30) && !p.accepts(bytes: 31))
        let q = AssistantInputPolicy(maximumEstimatedInputTokens: 100, maximumRequestBytes: 40, outputReserve: 8)
        #expect(q.accepts(bytes: 40) && !q.accepts(bytes: 41))
        #expect(!q.accepts(bytes: -1) && AssistantInputPolicy.estimate(bytes: Int.max) > 0)
        #expect(!AssistantInputPolicy(outputReserve: 0).accepts(bytes: 1))
    }
    @Test func blockedStreamingAndNonStreamingNeverReachTransportOrUsageObserver() async throws {
        for streaming in [false, true] {
            InputBudgetProtocol.reset()
            let session = InputBudgetProtocol.session(); defer { session.invalidateAndCancel() }
            let usage = ScenarioUsage(); var metrics: [AssistantRequestInputMetric] = []
            let client = DeepSeekClient(session: session, usageObserver: { usage.record($0) }, assistantInputPolicy: .init(maximumEstimatedInputTokens: 10, maximumRequestBytes: 40, outputReserve: 8))
            var handler: (@MainActor (AssistantStreamUpdate) -> Void)? = nil
            if streaming { handler = { _ in } }
            do {
                _ = try await client.assistantTurn(to: [.init(role: "user", content: "保留原问题和ID")], enabledSkillIDs: [], apiKey: "unused", onStream: handler, onInput: { metrics.append($0) })
                Issue.record("Expected local input budget block")
            } catch { #expect(error is AssistantInputBudgetError) }
            #expect(InputBudgetProtocol.bodies.isEmpty && usage.count == 0)
            #expect(metrics.count == 1 && metrics.first?.state == "blocked_before_network" && metrics.first?.actualPromptTokens == nil)
        }
    }
    @Test func wireIncludesToolsAndKeepsMessagesExactWhileCappingOutput() async throws {
        InputBudgetProtocol.reset()
        let session = InputBudgetProtocol.session(); defer { session.invalidateAndCancel() }
        var metrics: [AssistantRequestInputMetric] = []
        let text = "请帮我整理待办，精确ID保留🙂"
        let result = try await DeepSeekClient(session: session, assistantInputPolicy: .init(outputReserve: 512)).assistantTurn(to: [.init(role: "system", content: "规则"), .init(role: "user", content: text)], enabledSkillIDs: ["todo-priority"], apiKey: "unused", onInput: { metrics.append($0) })
        let body = try #require(InputBudgetProtocol.bodies.first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.last?["content"] as? String == text && json["max_tokens"] as? Int == 512)
        #expect((json["tools"] as? [Any])?.isEmpty == false && result.text == "模拟回答")
        #expect(metrics.count == 2 && metrics[0].id == metrics[1].id && metrics[1].requestBytes == body.count)
        #expect(metrics[1].actualPromptTokens == 100 && metrics[1].estimateMinusActual == metrics[1].estimatedInputTokens - 100)
        let wire = try JSONEncoder().encode(metrics[1]); #expect(try JSONDecoder().decode(AssistantRequestInputMetric.self, from: wire) == metrics[1])
        #expect(!String(decoding: wire, as: UTF8.self).contains(text))
    }
    @Test func toolSchemaAloneCanExceedBudgetBeforeNetwork() async throws {
        InputBudgetProtocol.reset()
        let session = InputBudgetProtocol.session(); defer { session.invalidateAndCancel() }
        let small: [DeepSeekChatMessage] = [.init(role: "user", content: "解释")]
        let client = DeepSeekClient(session: session, assistantInputPolicy: .init(maximumEstimatedInputTokens: 500, maximumRequestBytes: 1500, outputReserve: 512))
        _ = try await client.assistantTurn(to: small, enabledSkillIDs: [], apiKey: "unused")
        #expect(InputBudgetProtocol.bodies.count == 1)
        await #expect(throws: AssistantInputBudgetError.self) { _ = try await client.assistantTurn(to: small, enabledSkillIDs: ["todo-priority"], apiKey: "unused") }
        #expect(InputBudgetProtocol.bodies.count == 1)
    }
    @Test func followupReadRoundIsRecheckedWithToolResultIncluded() async throws {
        InputBudgetProtocol.reset(readFirst: true)
        let session = InputBudgetProtocol.session(); defer { session.invalidateAndCancel() }
        let messages: [DeepSeekChatMessage] = [.init(role: "user", content: "只读查记忆")]
        _ = try await DeepSeekClient(session: session).assistantTurn(to: messages, enabledSkillIDs: [], apiKey: "unused", readContext: .init())
        let firstBytes = try #require(InputBudgetProtocol.bodies.first?.count)
        #expect(InputBudgetProtocol.bodies.count == 2)
        InputBudgetProtocol.reset(readFirst: true)
        var metrics: [AssistantRequestInputMetric] = []
        let client = DeepSeekClient(session: session, assistantInputPolicy: .init(maximumEstimatedInputTokens: Int.max, maximumRequestBytes: firstBytes + 10, outputReserve: 8192))
        await #expect(throws: AssistantInputBudgetError.self) {
            _ = try await client.assistantTurn(to: messages, enabledSkillIDs: [], apiKey: "unused", readContext: .init(), onInput: { metrics.append($0) })
        }
        #expect(InputBudgetProtocol.bodies.count == 1 && metrics.last?.state == "blocked_before_network")
        #expect(metrics.first?.state == "prepared" && metrics[1].state == "completed" && metrics[1].actualPromptTokens == 100)
        #expect(metrics.last?.requestBytes ?? 0 > firstBytes)
    }
    @Test func proposalRepairAlsoChecksCompletePayloadBeforeDispatch() async throws {
        InputBudgetProtocol.reset()
        let session = InputBudgetProtocol.session(); defer { session.invalidateAndCancel() }
        let client = DeepSeekClient(session: session, assistantInputPolicy: .init(maximumEstimatedInputTokens: 10, maximumRequestBytes: 40, outputReserve: 8))
        let rejected = DeepSeekAssistantTurn(text: nil, toolCalls: [.init(id: "same-card", function: .init(name: "propose_day_plan", arguments: "{}"))])
        var metrics: [AssistantRequestInputMetric] = []
        await #expect(throws: AssistantInputBudgetError.self) {
            _ = try await client.repairDayPlan(messages: [.init(role: "user", content: "原计划")], rejected: rejected, apiKey: "unused", timeout: 10, onInput: { metrics.append($0) })
        }
        #expect(InputBudgetProtocol.bodies.isEmpty && metrics.last?.state == "blocked_before_network")
    }
    @Test func jointBudgetCapsOutputAndKeepsExactMessages() async throws {
        InputBudgetProtocol.reset()
        let session = InputBudgetProtocol.session(); defer { session.invalidateAndCancel() }
        let client = DeepSeekClient(session:session)
        let messages: [DeepSeekChatMessage] = [.init(role:"user",content:"精确ID保留🙂")]
        _ = try await client.assistantTurn(to:messages,enabledSkillIDs:[],apiKey:"unused")
        let original = try #require(InputBudgetProtocol.bodies.first)
        let remaining = AssistantInputPolicy.estimate(bytes:original.count) + 37
        InputBudgetProtocol.reset(); var metrics:[AssistantRequestInputMetric]=[]
        _ = try await client.assistantTurn(to:messages,enabledSkillIDs:[],apiKey:"unused",budget:.init(maxTotalTokens:remaining),onInput:{metrics.append($0)})
        let body = try #require(InputBudgetProtocol.bodies.first)
        let json = try #require(JSONSerialization.jsonObject(with:body) as? [String:Any])
        let metric = try #require(metrics.last)
        #expect(json["max_tokens"] as? Int == 37 && metric.effectiveOutputTokens == 37)
        #expect(metric.remainingRunTokens == remaining && metric.estimatedInputTokens + 37 <= remaining)
        #expect((json["messages"] as? [[String:Any]])?.last?["content"] as? String == messages.last?.content)
    }
    @Test func exhaustedRemainingBudgetBlocksBeforeDispatchAndDoesNotRecordUsage() async throws {
        InputBudgetProtocol.reset()
        let session = InputBudgetProtocol.session(); defer { session.invalidateAndCancel() }
        let usage=ScenarioUsage();var metrics:[AssistantRequestInputMetric]=[]
        let client=DeepSeekClient(session:session,usageObserver:{usage.record($0)})
        await #expect(throws:AssistantInputBudgetError.self) {
            _ = try await client.assistantTurn(to:[.init(role:"user",content:"原请求")],enabledSkillIDs:[],apiKey:"unused",budget:.init(maxTotalTokens:0),onInput:{metrics.append($0)})
        }
        #expect(InputBudgetProtocol.bodies.isEmpty && usage.count == 0)
        #expect(metrics.last?.remainingRunTokens == 0 && metrics.last?.effectiveOutputTokens == nil)
    }
    @Test func laterReadRoundDeductsMeasuredUsageAndCanStopBeforeSecondSend() async throws {
        InputBudgetProtocol.reset(readFirst:true)
        let session=InputBudgetProtocol.session();defer{session.invalidateAndCancel()}
        let messages:[DeepSeekChatMessage]=[.init(role:"user",content:"只读查记忆")]
        _ = try await DeepSeekClient(session:session).assistantTurn(to:messages,enabledSkillIDs:[],apiKey:"unused",readContext:.init())
        let firstBytes=try #require(InputBudgetProtocol.bodies.first?.count)
        let secondBytes=try #require(InputBudgetProtocol.bodies.last?.count)
        let remaining=AssistantInputPolicy.estimate(bytes:firstBytes)+103
        #expect(AssistantInputPolicy.estimate(bytes:secondBytes)>remaining-102)
        InputBudgetProtocol.reset(readFirst:true);var metrics:[AssistantRequestInputMetric]=[]
        await #expect(throws:AssistantInputBudgetError.self) {
            _ = try await DeepSeekClient(session:session).assistantTurn(to:messages,enabledSkillIDs:[],apiKey:"unused",readContext:.init(),budget:.init(maxTotalTokens:remaining),onInput:{metrics.append($0)})
        }
        #expect(InputBudgetProtocol.bodies.count==1 && metrics.last?.state=="blocked_before_network")
        #expect(metrics.last?.remainingRunTokens==remaining-102 && metrics[1].actualPromptTokens==100)
    }
    @Test func repairUsesExplicitRemainingAllowance() async throws {
        InputBudgetProtocol.reset()
        let session=InputBudgetProtocol.session();defer{session.invalidateAndCancel()}
        let rejected=DeepSeekAssistantTurn(text:nil,toolCalls:[.init(id:"same-card",function:.init(name:"propose_day_plan",arguments:"{}"))])
        var metrics:[AssistantRequestInputMetric]=[]
        await #expect(throws:AssistantInputBudgetError.self) {
            _ = try await DeepSeekClient(session:session).repairDayPlan(messages:[.init(role:"user",content:"原计划")],rejected:rejected,apiKey:"unused",timeout:10,remainingTokens:0,onInput:{metrics.append($0)})
        }
        #expect(InputBudgetProtocol.bodies.isEmpty && metrics.last?.remainingRunTokens==0)
    }
    @Test func outputPlanningHandlesBoundariesAndVeryLargeAllowancesWithoutOverflow() {
        let p=AssistantInputPolicy()
        #expect(p.outputLimit(bytes:300,remainingTokens:100,requested:8192)==nil)
        #expect(p.outputLimit(bytes:300,remainingTokens:101,requested:8192)==1)
        #expect(p.outputLimit(bytes:300,remainingTokens:1000,requested:256)==256)
        #expect(p.outputLimit(bytes:300,remainingTokens:Int.max,requested:Int.max)==8192)
        #expect(p.outputLimit(bytes:300,remainingTokens:-1,requested:8192)==nil)
    }
    @Test func explicitFreshRequestCanRecoverWithoutDeletingHistory() {
        let old = AssistantMessage(text: String(repeating: "长材料", count: 80_000), isUser: true)
        let plain = [old, AssistantMessage(text: "小问题", isUser: true)]
        #expect(AssistantInputHistory.recent(plain).count == 2)
        let fresh = [old, AssistantMessage(text: "仅以本条为准：解释一个新问题", isUser: true)]
        #expect(AssistantInputHistory.recent(fresh).count == 1 && fresh[0].text == old.text)
        #expect(AssistantInputHistory.recent(Array(plain + fresh)).last?.id == fresh.last?.id)
        let continued = fresh + [AssistantMessage(text: "新答复", isUser: false), AssistantMessage(text: "普通继续提问", isUser: true)]
        #expect(AssistantInputHistory.recent(continued).count == 3)
        #expect(AssistantInputHistory.selectionName(continued) == "explicit_history_boundary")
        #expect(!AssistantInputHistory.recent(continued).contains { $0.id == old.id })
    }
    @Test func oldDiagnosticsDecodeAndBudgetErrorsRemainContentFree() throws {
        let old = AssistantTurnDiagnostic()
        let data = try JSONEncoder().encode(old)
        let restored = try JSONDecoder().decode(AssistantTurnDiagnostic.self, from: data)
        #expect(restored.inputAudit == nil && restored.inputRequests == nil)
        #expect(AssistantTurnDiagnostic.category(for: AssistantInputBudgetError()) == "input_budget")
        #expect(AssistantInputBudgetError().localizedDescription.contains("没有自动截断"))
    }
}

private final class InputBudgetProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var captured: [Data] = []
    private static var readFirst = false
    static var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset(readFirst: Bool = false) { lock.lock(); captured = []; Self.readFirst = readFirst; lock.unlock() }
    static func session() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Self.self]; return URLSession(configuration: c) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) } }
        Self.lock.lock(); Self.captured.append(body); let read = Self.readFirst && Self.captured.count == 1; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        if read {
            let payload = #"{"choices":[{"message":{"tool_calls":[{"id":"read1","function":{"name":"search_memory","arguments":"{\"query\":\"测试\"}"}}]}}],"usage":{"prompt_tokens":100,"completion_tokens":2,"total_tokens":102}}"#
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
        } else {
        client?.urlProtocol(self, didLoad: Data("{\"choices\":[{\"message\":{\"content\":\"模拟回答\"}}],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":2,\"total_tokens\":102}}".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
