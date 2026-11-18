import SwiftUI

@MainActor final class AssistantComposerState: ObservableObject {
    @Published private(set) var text = ""
    func update(_ value: String) { if text != value { text = value } }
}

/// Counters are enabled only by isolated acceptance; never store user text.
@MainActor enum ChatPerformanceMetrics {
    static var enabled = false
    static var historyBodies = 0
    static var composerBodies = 0
    static var renderedMessageIDs: Set<UUID> = []
    static func reset() { historyBodies = 0; composerBodies = 0; renderedMessageIDs = [] }
    static func messageBody(_ id: UUID) { if enabled { renderedMessageIDs.insert(id) } }
    static func historyBody() { if enabled { historyBodies += 1 } }
    static func composerBody() { if enabled { composerBodies += 1 } }
}

struct ChatComposerView: View {
    @EnvironmentObject private var model: AssistantModel
    @ObservedObject var composer: AssistantComposerState
    @AppStorage("assistantName") private var assistantName = "予安"
    @FocusState private var focused: Bool
    var body: some View {
        let _ = ChatPerformanceMetrics.composerBody()
        VStack(spacing: 9) {
            HStack(alignment: .bottom, spacing: 16) {
                TextField("向\(assistantName)提问，或安排一件事…", text: Binding(get: { composer.text }, set: { model.draft = $0 }), axis: .vertical)
                    .font(.system(size: 15)).lineLimit(1...8).textFieldStyle(.plain)
                    .focused($focused).padding(.vertical, 9)
                    .accessibilityIdentifier("assistant-chat-composer")
                    .onSubmit { model.sendMessage() }
                if model.isSending {
                    Button { model.cancelChatRequest() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AssistantTheme.canvas).frame(width: 36, height: 36)
                            .background(AssistantTheme.text, in: Circle())
                    }.buttonStyle(.plain).help("停止生成").accessibilityLabel("停止生成")
                } else {
                    Button { model.sendMessage(); focused = true } label: {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AssistantTheme.canvas).frame(width: 36, height: 36)
                            .background(AssistantTheme.text.opacity(composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.28 : 1), in: Circle())
                    }.buttonStyle(.plain).disabled(composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("发送消息").accessibilityLabel("发送消息")
                }
            }.padding(12).padding(.leading, 5)
                .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(AssistantTheme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.035), radius: 8, y: 2)
        }.frame(maxWidth: 760).padding(.horizontal, 32).padding(.top, 10).padding(.bottom, 18)
    }
}
