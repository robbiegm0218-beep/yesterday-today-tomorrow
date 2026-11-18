import SwiftUI

struct MemoryProvenanceView: View {
    @EnvironmentObject private var model: AssistantModel
    let item: AssistantMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("来源：" + (item.sourceType ?? "历史记录（未记录最初来源）"))
            if let updatedAt = item.updatedAt {
                Text("最近更新：" + updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if item.sourceType == "手动编辑" {
                Text("当前内容由你手动编辑，下面的原话可能只对应编辑前内容。")
            }
            if let evidence = item.evidence, !evidence.isEmpty {
                Text("最近原话依据（最多10条）").fontWeight(.medium)
                ForEach(Array(evidence.reversed().enumerated()), id: \.offset) { _, source in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source.recordedAt.formatted(date: .abbreviated, time: .shortened))
                        Text(verbatim: "“" + source.quote + "”").foregroundStyle(AssistantTheme.text)
                            .textSelection(.enabled)
                        if let message = model.messages.first(where: { $0.id == source.messageID && $0.isUser }) {
                            DisclosureGroup("查看对应用户消息") {
                                Text(verbatim: message.text).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
                            }
                        } else {
                            Text("原消息已不在本机对话中，保留提取时的短引用。")
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                }
                if item.sourceType == nil {
                    Text("这些是后续补充的引用，不能倒推历史记录最初的来源。")
                }
            } else {
                Text("这条旧记录没有保存原话依据，不会根据内容猜测来源。")
            }
            if let revisions = item.revisions, !revisions.isEmpty {
                DisclosureGroup("编辑前内容（最近10次）") {
                    ForEach(Array(revisions.reversed().enumerated()), id: \.offset) { _, revision in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(revision.changedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(verbatim: revision.content).textSelection(.enabled)
                        }.padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.font(.system(size: 11)).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
    }
}
