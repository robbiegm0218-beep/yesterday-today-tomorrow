import Foundation

struct AssistantChatRetrySnapshot {
    let priorMessages: [AssistantMessage]
    let prompt: String
}

enum AssistantChatRetryPolicy {
    static let failurePrefix = "暂时没能联系上 DeepSeek："
    static let stoppedPrefix = "已停止等待本轮处理："

    static func isRetryableMessage(_ message: AssistantMessage) -> Bool {
        !message.isUser && (message.text.hasPrefix(failurePrefix) || message.text.hasPrefix(stoppedPrefix))
    }

    static func snapshot(messages: [AssistantMessage], failureMessageID: UUID) -> AssistantChatRetrySnapshot? {
        guard let failureIndex = messages.firstIndex(where: { $0.id == failureMessageID }),
              failureIndex == messages.count - 1,
              isRetryableMessage(messages[failureIndex]),
              let userIndex = messages[..<failureIndex].lastIndex(where: \.isUser),
              userIndex == failureIndex - 1 else { return nil }

        return AssistantChatRetrySnapshot(
            priorMessages: Array(messages[..<userIndex]),
            prompt: messages[userIndex].text
        )
    }
}

enum AssistantTodoCompletionResolution: Equatable {
    case needsCompletion
    case alreadyComplete
    case missing

    static func resolve(todoID: UUID, in todos: [PersonalTodo]) -> Self {
        guard let todo = todos.first(where: { $0.id == todoID }) else { return .missing }
        return todo.isComplete ? .alreadyComplete : .needsCompletion
    }
}
