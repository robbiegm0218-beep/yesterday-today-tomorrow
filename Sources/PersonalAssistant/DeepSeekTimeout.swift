import Foundation

enum DeepSeekTimeoutPhase:String,Codable {
    case responseHeaders="response_headers", modelContent="model_content", receiving="receiving"
    var explanation:String {
        switch self {
        case .responseHeaders:"尚未收到服务响应头，可能是网络链路或服务端等待。"
        case .modelContent:"已连接服务，但尚未收到模型正文，可能仍在排队。"
        case .receiving:"已收到部分模型内容，但未在本轮剩余预算内完成。"
        }
    }
}
final class DeepSeekStreamProgress:@unchecked Sendable {
    private let lock=NSLock()
    private var headers=false,payload=false,bytes=0
    func receivedHeaders() {lock.lock();headers=true;lock.unlock()}
    func receivedBytes(_ count:Int,hasPayload:Bool=false) {lock.lock();bytes=min(2_000_000,max(bytes,count));payload=payload || hasPayload;lock.unlock()}
    func timeoutError()->DeepSeekRequestError {
        lock.lock();defer{lock.unlock()}
        return .streamTimedOut(phase:!headers ? .responseHeaders : payload ? .receiving : .modelContent,receivedBytes:bytes)
    }
}
