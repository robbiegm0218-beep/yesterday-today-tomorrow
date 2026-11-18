import Foundation

/// Owned QA identity plus explicit opt-in only. Never inherits production keys.
enum StreamingPreviewQA {
    static func shouldEnable(bundleID: String?, arguments: [String], infoOptIn: Bool = false) -> Bool {
        bundleID?.hasPrefix("com.yuan.personal-assistant.qa.") == true && (arguments.contains("--stream-preview-qa") || infoOptIn)
    }
    static var isEnabled: Bool {
        shouldEnable(bundleID: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments, infoOptIn: Bundle.main.object(forInfoDictionaryKey: "AssistantLocalStreamingQA") as? Bool == true)
    }
    static func services() -> AssistantModelServices {
        guard isEnabled else { return .init() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingPreviewProtocol.self]
        return .init(chatClient: DeepSeekClient(session: URLSession(configuration: config)), memoryExtractor: { _,_ in [] }, apiKey: { "unused-local-qa-placeholder" })
    }
    @MainActor static func makeModel() -> AssistantModel {
        isEnabled ? AssistantModel(dailyDataSource: LocalOnlyDailyDataSource(), services: services()) : AssistantModel()
    }
}

/// Every URL in this QA-only session is intercepted, including unexpected hosts.
final class StreamingPreviewProtocol: URLProtocol, @unchecked Sendable {
    private static let counterLock = NSLock()
    private static var counter = 0
    private let deliveryQueue = DispatchQueue(label: "com.yuan.local-streaming-qa.delivery")
    private let lock = NSLock()
    private var stopped = false
    static func text(request: Int, part: Int) -> String {
        part == 0 ? "【本地模拟请求\(request)】正在逐段生成，未调用外部模型。\n\n" : "本地第\(part)段：可以输入下一条草稿、滚动历史或停止生成。\n\n"
    }
    static func packet(content: String? = nil, final: Bool = false) -> Data {
        var choice: [String: Any] = ["index": 0, "delta": content.map { ["content": $0] } ?? [:]]
        if final { choice["finish_reason"] = "stop" }
        var body: [String: Any] = ["choices": [choice], "model": "local-streaming-qa"]
        if final { body["usage"] = ["prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2] }
        let json = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return Data(("data: " + String(decoding: json, as: UTF8.self) + "\n\n" + (final ? "data: [DONE]\n\n" : "")).utf8)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counterLock.lock(); Self.counter += 1; let number = Self.counter; Self.counterLock.unlock()
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.packet(content: Self.text(request: number, part: 0)))
        for part in 1...40 {
            deliveryQueue.asyncAfter(deadline: .now() + Double(part) * 0.8) { [self] in
                lock.lock(); let alive = !stopped; lock.unlock(); guard alive else { return }
                client?.urlProtocol(self, didLoad: Self.packet(content: Self.text(request: number, part: part), final: part == 40))
                if part == 40 { client?.urlProtocolDidFinishLoading(self) }
            }
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
