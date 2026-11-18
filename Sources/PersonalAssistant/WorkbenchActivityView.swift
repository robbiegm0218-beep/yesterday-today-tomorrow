import SwiftUI

struct WorkbenchActivityView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingMessages = true
    @State private var linking: DingTalkResearchItem?
    @State private var showingResearch = false
    @State private var error: String?
    private var events: [DingTalkReceivedEvent] {
        model.dingTalkEventState.events.filter { model.selectedDingTalkProfileIDs.contains($0.item.profile.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("动态").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Picker("动态来源", selection: $showingMessages) {
                Text("消息收件").tag(true); Text("关注变化").tag(false)
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showingMessages { messages } else { watches }
                    if let error = error ?? model.dingTalkResearchError { Text(error).font(.caption).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 620, height: 640)
            .foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
            .sheet(item: $linking) { item in WorkbenchEvidenceLinkView(item: item) }
            .sheet(isPresented: $showingResearch) { DingTalkResearchView() }
            .task {
                model.reloadDingTalkResearch()
                while !Task.isCancelled {
                    model.reloadDingTalkEvents()
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
    }
    private var messages: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已接收消息保留在这里；标为已查看只影响本机。监听范围和连接状态可在助手页的“消息监听设置”管理。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.dingTalkEventSettings.enabled { Text("消息监听未开启。").font(.callout) }
            if let issue = model.dingTalkEventError ?? model.dingTalkEventState.error { Text(issue).font(.caption).foregroundStyle(.orange) }
            if events.isEmpty { Text("当前没有已接收的消息。").foregroundStyle(.secondary) }
            ForEach(events) { event in
                DingTalkResearchItemCard(item: event.item) {
                    HStack {
                        if event.dismissed { Text("已查看").font(.caption) }
                        else { Button("标为已查看") {
                            do { try model.dismissDingTalkEvent(event.id) } catch { self.error = error.localizedDescription }
                        } }
                        Button("关联到事项") { linking = event.item }
                    }
                }
            }
        }
    }
    private var watches: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关注范围只在点击“检查变化”时更新，与实时消息收件分别运行。不完整查询保留原基线，未命中不代表源内容已删除。")
                .font(.caption).foregroundStyle(.secondary)
            Button("查找资料并管理关注范围") { showingResearch = true }
            let visible = model.dingTalkResearchState.watches.filter { model.selectedDingTalkProfileIDs.contains($0.profile.id) }
            if visible.isEmpty { Text("还没有关注的查询范围。").foregroundStyle(.secondary) }
            ForEach(visible) { watch in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(watch.query.isEmpty ? "知识库目录" : watch.query).font(.headline)
                        Spacer()
                        Button(model.checkingResearchWatches.contains(watch.id) ? "检查中…" : "检查变化") {
                            Task { await model.checkDingTalkResearchWatch(watch.id) }
                        }.disabled(model.checkingResearchWatches.contains(watch.id))
                    }
                    Text(watch.profile.corpName + " · " + (watch.kind == "message" ? "最近7天消息" : "组织知识库") + " · 上次成功检查：" + watch.checkedAt.formatted())
                        .font(.caption).foregroundStyle(.secondary)
                    Text("上次检查发现\(watch.changeCount)项新命中或变化").font(.caption)
                    if let issue = watch.error { Text(issue + " 原基线保留。").font(.caption).foregroundStyle(.orange) }
                    ForEach(watch.changes) { item in
                        DingTalkResearchItemCard(item: item) {
                            if !item.isFolder { Button("关联到事项") { linking = item } }
                        }
                    }
                }.padding(12).background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private struct WorkbenchEvidenceLinkView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    let item: DingTalkResearchItem
    @State private var targetID = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("关联来源到事项").font(.headline)
            Text(item.profile.corpName + " · " + item.title).font(.caption)
            Picker("事项", selection: $targetID) {
                Text("请选择事项").tag("")
                ForEach(model.matterTargets) { target in
                    Text(target.title + " · " + target.reference.sourceLabel + " · " + String(target.reference.id.suffix(6))).tag(target.id)
                }
            }
            Text("只保存来源引用，不改变消息已读或事项状态。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button("确认关联") {
                    guard let target = model.matterTargets.first(where: { $0.id == targetID }) else { return }
                    do { try model.linkDingTalkEvidence(item, target: target.reference); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(targetID.isEmpty || !model.selectedDingTalkProfileIDs.contains(item.profile.id))
            }
        }.padding(24).frame(width: 520)
    }
}
