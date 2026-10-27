import SwiftUI

struct DingTalkMinutesView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var minutes: [DingTalkMinute] = []
    @State private var isLoading = false
    @State private var readingID: String?
    @State private var error: String?
    @State private var didLoad = false
    @State private var request: Task<Void, Never>?
    @State private var reading: MinuteReading?
    @State private var showingWriteHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("钉钉 AI 听记").font(.system(size: 20, weight: .semibold))
                    Text("查询所选组织可访问的听记；选定一条摘要后，再整理行动项。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { request?.cancel(); dismiss() }
            }
            HStack {
                DatePicker("开始", selection: $start, displayedComponents: .date)
                DatePicker("结束", selection: $end, displayedComponents: .date)
                Button(isLoading ? "查询中…" : "查询听记", action: load)
                    .disabled(isLoading || readingID != nil)
            }.font(.system(size: 11))
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.red) }
            if isLoading { ProgressView("读取听记列表…").frame(maxWidth: .infinity) }
            if didLoad && minutes.isEmpty && !isLoading {
                Text("所选日期范围内没有可访问的听记。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(minutes) { minute in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(minute.title).font(.system(size: 13, weight: .medium))
                            HStack {
                                Text(minute.startsAt?.formatted(date: .abbreviated, time: .shortened) ?? "时间未提供")
                                if let organization = minute.organizationName, !organization.isEmpty { Text(organization) }
                                Spacer()
                                if let url = minute.sourceURL { Link("钉钉原文", destination: url) }
                                Button(readingID == minute.id ? "读取中…" : "读取摘要") { read(minute) }
                                    .disabled(isLoading || readingID != nil)
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            HStack {
                Text("点击“提取行动项”后，摘要会交给已配置的模型处理。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("待办写入记录") { showingWriteHistory = true }.font(.system(size: 10))
            }
        }
        .padding(24).frame(width: 720, height: 620)
        .task { load() }
        .onDisappear { request?.cancel() }
        .onChange(of: model.selectedDingTalkProfileIDs) { _ in
            request?.cancel(); minutes = []; didLoad = false; isLoading = false; readingID = nil; reading = nil
            error = "接入组织已变更，请重新查询。"
        }
        .sheet(item: $reading) { item in
            MeetingMinutesToolView(initialMinutes: item.summary, sourceTitle: item.minute.title, sourceURL: item.minute.sourceURL, sourceMinute: item.minute)
        }
        .sheet(isPresented: $showingWriteHistory) { DingTalkWriteHistoryView() }
    }

    private func load() {
        guard !isLoading, readingID == nil else { return }
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: start)
        guard let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)), from < to else {
            error = "开始日期不能晚于结束日期。"; return
        }
        let selected = model.selectedDingTalkProfileIDs
        isLoading = true; error = nil; didLoad = false; minutes = []
        request = Task { @MainActor in
            let result = await Task.detached { Result { try DingTalkContentService().minutes(from: from, to: to, selectedIDs: selected) } }.value
            guard !Task.isCancelled else { return }
            isLoading = false
            switch result {
            case .success(let items): minutes = items; didLoad = true
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private func read(_ minute: DingTalkMinute) {
        readingID = minute.id; error = nil
        request = Task { @MainActor in
            let result = await Task.detached { Result { try DingTalkContentService().summary(for: minute) } }.value
            guard !Task.isCancelled else { return }
            readingID = nil
            switch result {
            case .success(let summary): reading = MinuteReading(minute: minute, summary: summary)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

private struct MinuteReading: Identifiable {
    let id = UUID()
    let minute: DingTalkMinute
    let summary: String
}
