import SwiftUI

struct DingTalkWriteHistoryView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var receipts: [DingTalkWriteReceipt] = []
    @State private var error: String?
    @State private var checkingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("钉钉待办写入记录").font(.system(size: 19, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.disabled(checkingID != nil)
            }
            Text("仅显示当前接入组织的记录。提交结果不明时，先在钉钉中核对，避免重复创建。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            if receipts.isEmpty { Text("暂无写入记录。").font(.system(size: 12)).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(receipts) { receipt in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(receipt.title).font(.system(size: 13, weight: .medium))
                            Text(receipt.state == .verified ? "已从钉钉读回核验" : (receipt.taskID == nil ? "提交结果待核对，已阻止重复创建" : "已收到待办 ID，仍需读回核验"))
                                .font(.system(size: 11)).foregroundStyle(receipt.state == .verified ? .green : .orange)
                            Text("来源：" + receipt.sourceTitle).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(receipt.evidence).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                            if let issue = receipt.verificationIssue { Text(issue).font(.system(size: 10)).foregroundStyle(.orange) }
                            HStack {
                                Text(receipt.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                if let url = receipt.sourceURL { Link("来源听记", destination: url) }
                                if receipt.taskID != nil {
                                    Button(checkingID == receipt.id ? "核验中…" : "重新核验") { reconcile(receipt) }
                                        .disabled(checkingID != nil)
                                }
                            }.font(.system(size: 10))
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }.padding(24).frame(width: 680, height: 540)
        .onAppear(perform: load)
        .onChange(of: model.selectedDingTalkProfileIDs) { _ in load() }
        .interactiveDismissDisabled(checkingID != nil)
    }

    private func load() {
        do {
            receipts = try LocalDingTalkWriteStore.load().filter { model.selectedDingTalkProfileIDs.contains($0.profileID) }.sorted { $0.updatedAt > $1.updatedAt }
        } catch { self.error = error.localizedDescription }
    }

    private func reconcile(_ receipt: DingTalkWriteReceipt) {
        checkingID = receipt.id; error = nil
        let selected = model.selectedDingTalkProfileIDs
        Task { @MainActor in
            let result = await Task.detached { Result { try DingTalkTodoSubmissionService().reconcile(receiptID: receipt.id, selectedIDs: selected) } }.value
            checkingID = nil
            if case .failure(let failure) = result { error = failure.localizedDescription }
            load()
        }
    }
}
