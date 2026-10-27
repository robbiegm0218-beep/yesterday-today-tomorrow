import SwiftUI

struct DingTalkDocumentsView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var result: DingTalkDocumentSearch?
    @State private var submittedQuery = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?
    private let project: AssistantProject?

    init(project: AssistantProject? = nil) {
        self.project = project
        _query = State(initialValue: project?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(project == nil ? "钉钉文档搜索" : "项目资料推荐").font(.system(size: 20, weight: .semibold))
                    Text("在所选组织中搜索可访问的文档，每次推荐最多 3 篇。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { request?.cancel(); dismiss() }
            }
            if let project {
                Text("项目：\(project.name) · 截止：\(project.dueAt?.formatted(date: .abbreviated, time: .omitted) ?? "未设置")\n当前进展：\(project.progressNote.isEmpty ? "待补充" : project.progressNote)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                TextField("文档标题或关键词", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button(isLoading ? "搜索中…" : "搜索", action: search)
                    .disabled(isLoading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.red) }
            if isLoading { ProgressView("检索钉钉资料…").frame(maxWidth: .infinity) }
            if let result {
                Text("关键词：\(submittedQuery) · 本次返回 \(result.returnedCount) 篇，展示前 \(result.recommendations.count) 篇")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !result.complete {
                    Label("检索未完成全部分页，当前仅显示已返回的资料。", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                if result.recommendations.isEmpty {
                    Text(result.complete ? "没有找到匹配的文档。可以调整关键词再搜索。" : "本次没有返回匹配项；检索尚未完成，暂不能确认没有文档。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(result.recommendations) { document in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(document.title).font(.system(size: 13, weight: .medium))
                                Text("检索组织：" + document.profile.corpName).font(.system(size: 10)).foregroundStyle(.secondary)
                                HStack {
                                    Text(document.updatedAt.map { "更新：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "更新时间未提供")
                                    Spacer()
                                    if let url = document.sourceURL { Link("打开钉钉原文", destination: url) }
                                    else { Text("未提供来源链接") }
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            } else { Spacer() }
            Text("按搜索结果推荐；可结合项目进展和截止日期选择参考资料。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 680, height: 540)
        .task { if !query.isEmpty { search() } }
        .onDisappear { request?.cancel() }
        .onChange(of: model.selectedDingTalkProfileIDs) { _ in
            request?.cancel(); result = nil; isLoading = false
            error = "接入组织已变更，请重新搜索。"
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLoading, !text.isEmpty else { return }
        let selected = model.selectedDingTalkProfileIDs
        isLoading = true; error = nil; result = nil; submittedQuery = text
        request = Task { @MainActor in
            let response = await Task.detached { Result { try DingTalkContentService().documents(query: text, selectedIDs: selected) } }.value
            guard !Task.isCancelled else { return }
            isLoading = false
            switch response {
            case .success(let value): result = value
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
