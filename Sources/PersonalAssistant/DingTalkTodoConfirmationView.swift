import SwiftUI

struct DingTalkTodoConfirmationView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    let draft: DingTalkTodoDraft
    @State private var title: String
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var priority = 20
    @State private var isSubmitting = false
    @State private var receipt: DingTalkWriteReceipt?
    @State private var error: String?

    init(draft: DingTalkTodoDraft) {
        self.draft = draft
        _title = State(initialValue: draft.action.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认创建钉钉待办").font(.system(size: 19, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                Text("组织：\(draft.minute.profile.corpName)\n执行人：我（\(draft.minute.profile.userName ?? "当前登录账号")）")
                    .font(.system(size: 12))
                TextField("待办标题", text: $title).textFieldStyle(.roundedBorder)
                Text("纪要负责人：\(draft.action.owner.isEmpty ? "未明确" : draft.action.owner)\n纪要截止时间：\(draft.action.dueText.isEmpty ? "未明确" : draft.action.dueText)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("设置明确的截止时间", isOn: $hasDeadline)
                if hasDeadline { DatePicker("截止", selection: $deadline, displayedComponents: [.date, .hourAndMinute]) }
                Text("相对日期需要核对后手动设置；未设置时不会提交截止时间。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("优先级", selection: $priority) {
                    Text("低").tag(10); Text("普通").tag(20); Text("高").tag(30); Text("紧急").tag(40)
                }
                Text("听记：" + draft.minute.title).font(.system(size: 11, weight: .medium))
                Label(draft.action.sourceQuote, systemImage: "quote.opening").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(5)
            }.disabled(isSubmitting || receipt != nil)
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.red) }
            if receipt != nil {
                Label("已创建并从钉钉读回核验；听记来源和依据保存在本机写入记录中。", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green)
            }
            HStack {
                if let url = draft.minute.sourceURL { Link("打开来源听记", destination: url).font(.system(size: 11)) }
                Spacer()
                Button(receipt == nil ? "取消" : "完成") { dismiss() }.disabled(isSubmitting)
                if receipt == nil {
                    Button(isSubmitting ? "提交并核验中…" : "确认创建到钉钉", action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSubmitting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(24).frame(width: 540)
        .interactiveDismissDisabled(isSubmitting)
    }

    private func submit() {
        isSubmitting = true; error = nil
        let submittedTitle = title
        let dueAt = hasDeadline ? deadline : nil
        let submittedPriority = priority
        let selected = model.selectedDingTalkProfileIDs
        Task { @MainActor in
            let result = await Task.detached {
                Result { try DingTalkTodoSubmissionService().submitConfirmed(draft, title: submittedTitle, dueAt: dueAt, priority: submittedPriority, selectedIDs: selected) }
            }.value
            isSubmitting = false
            switch result {
            case .success(let value): receipt = value; model.refreshWorkbench()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
