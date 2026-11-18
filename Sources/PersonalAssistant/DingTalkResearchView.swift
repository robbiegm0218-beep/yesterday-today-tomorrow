import SwiftUI
import AppKit

struct DingTalkResearchView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [DingTalkProfile] = []
    @State private var profileID = ""
    @State private var kind = "message"
    @State private var query = ""
    @State private var spaces: [DingTalkWikiSpace] = []
    @State private var spaceID = ""
    @State private var acrossDirectories = false
    @State private var submittedAcrossDirectories = false
    @State private var folder: DingTalkResearchItem?
    @State private var result: DingTalkResearchResult?
    @State private var submittedQuery = ""
    @State private var submittedKind = "message"
    @State private var submittedFolderID: String?
    @State private var submittedSpace: DingTalkWikiSpace?
    @State private var submittedProfile: DingTalkProfile?
    @State private var busy = false
    @State private var error: String?
    @State private var status: String?
    @State private var request: Task<Void, Never>?
    @State private var linking: DingTalkResearchItem?
    @State private var targetID = ""
    private var profile: DingTalkProfile? { profiles.first { $0.id == profileID } }
    private var space: DingTalkWikiSpace? { spaces.first { $0.id == spaceID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text("钉钉消息与知识库").font(.title2.bold()); Spacer(); Button("完成") { request?.cancel(); dismiss() } }
            Text("检索、查看来源并关联到事项；关注的检索由你点击“检查变化”时更新。消息范围为最近7天，结果最多展示200条。")
                .font(.caption).foregroundStyle(AssistantTheme.secondaryText)
            Picker("组织", selection: $profileID) {
                Text("请选择已接入组织").tag("")
                ForEach(profiles) { Text($0.corpName).tag($0.id) }
            }.disabled(busy)
            Picker("来源", selection: $kind) { Text("消息").tag("message"); Text("组织知识库").tag("wiki") }.pickerStyle(.segmented).disabled(busy)
            if kind == "wiki" {
                HStack {
                    Picker("知识库", selection: $spaceID) { Text("请选择知识库").tag(""); ForEach(spaces) { Text($0.name).tag($0.id) } }.disabled(busy)
                    Button("加载知识库") { loadSpaces() }.disabled(profile == nil || busy)
                }
                Toggle("跨目录关键词搜索（最多核验50项，不下载正文）", isOn: $acrossDirectories).font(.caption).disabled(busy)
                if let folder, !acrossDirectories {
                    HStack { Text("当前目录：\(folder.title)").font(.caption); Button("返回知识库首页") { self.folder = nil; query = ""; search() } }
                }
            }
            HStack {
                TextField(kind == "message" ? "消息关键词（最近7天）" : (acrossDirectories ? "知识库内跨目录关键词" : "留空浏览；仅筛选当前目录标题，不含子目录"), text: $query).textFieldStyle(.roundedBorder).onSubmit(search).disabled(busy)
                Button(busy ? "读取中…" : kind == "wiki" && query.isEmpty ? "浏览" : "搜索", action: search).disabled(busy || profile == nil || (kind == "message" && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (kind == "wiki" && (space == nil || (acrossDirectories && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))))
            }
            if busy { ProgressView() }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let status { Text(status).font(.caption).foregroundStyle(AssistantTheme.accent) }
            if let issue = model.dingTalkResearchError { Text(issue).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    DisclosureGroup("关注的范围（\(model.dingTalkResearchState.watches.count)/5）") {
                        watchContents
                    }.font(.headline)
                    if let result {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("本次返回\(result.returnedCount)项 · 展示\(result.items.count)项 · \(result.complete ? "查询完成" : "结果不完整，不能确认全部内容")").font(.caption)
                                if let start = result.start, let end = result.end { Text("\(start.formatted()) — \(end.formatted())（不含结束时刻）").font(.caption2) }
                            }
                            Spacer()
                            Button("关注本次范围") { watch() }.disabled(!result.complete || (submittedKind == "message" && submittedQuery.isEmpty) || busy)
                        }
                        if result.items.isEmpty { Text(result.complete ? "本次范围内没有匹配项。" : "当前没有返回匹配项，不能据此确认没有相关内容。").font(.callout) }
                        ForEach(result.items) { item in
                            DingTalkResearchItemCard(item: item) {
                                if item.isFolder {
                                    Button("浏览目录") { folder = item; query = ""; search() }.disabled(busy)
                                } else { Button("关联到事项") { linking = item; targetID = ""; error = nil } }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 760, height: 660).foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
        .task {
            model.reloadDingTalkResearch()
            let selected = model.selectedDingTalkProfileIDs
            do { profiles = try await Task.detached { try DingTalkContentService().profiles(selectedIDs: selected) }.value; if profiles.count == 1 { profileID = profiles[0].id } }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: kind) { _ in query = ""; invalidate() }
        .onChange(of: profileID) { _ in spaces = []; spaceID = ""; invalidate() }
        .onChange(of: spaceID) { _ in invalidate() }
        .onChange(of: acrossDirectories) { _ in invalidate() }
        .onChange(of: model.selectedDingTalkProfileIDs) { _ in request?.cancel(); profiles = []; profileID = ""; spaces = []; spaceID = ""; invalidate(); error = "接入组织已变化，请关闭后重新打开检索。" }
        .onDisappear { request?.cancel() }
        .sheet(item: $linking) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("关联来源到事项").font(.headline)
                Text(item.title).font(.callout)
                Text("\(item.profile.corpName) · 只保存这条来源引用和片段到本机，不修改源消息、文档或事项状态。").font(.caption)
                Picker("目标事项", selection: $targetID) { Text("请选择事项").tag(""); ForEach(model.matterTargets) { target in Text(target.title + " · " + target.reference.sourceLabel + (model.matterTargets.filter { $0.title == target.title }.count > 1 ? " · " + String(target.reference.id.suffix(6)) : "")).tag(target.id) } }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("取消") { linking = nil }; Spacer()
                    Button("确认关联") {
                        guard let target = model.matterTargets.first(where: { $0.id == targetID }) else { return }
                        do { try model.linkDingTalkEvidence(item, target: target.reference); linking = nil; status = "已关联。可在该事项的“事项详情”查看；对话提及该事项时会参考这份依据。" }
                        catch { self.error = error.localizedDescription }
                    }.disabled(targetID.isEmpty || !model.selectedDingTalkProfileIDs.contains(item.profile.id))
                }
            }.padding(24).frame(width: 550).background(AssistantTheme.canvas).foregroundStyle(AssistantTheme.text)
        }
    }
    private var watchContents: some View {
        VStack(alignment: .leading, spacing: 12) {
                    Text("只比较本次查询命中；不把未命中解释为源消息被删除或任务完成。不完整或失败时保留原对比基线。消息采用滚动7天范围，知识库比较已选目录或跨目录关键词范围中的标题及元信息；索引延迟也可能带来新命中。本入口不自动监听或推送。").font(.caption).foregroundStyle(AssistantTheme.secondaryText)
                    ForEach(model.dingTalkResearchState.watches) { watch in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(watch.query.isEmpty ? "知识库目录" : watch.query).font(.headline)
                                Spacer()
                                Button(model.checkingResearchWatches.contains(watch.id) ? "核对中…" : "检查变化") { Task { await model.checkDingTalkResearchWatch(watch.id) } }
                                    .disabled(model.checkingResearchWatches.contains(watch.id) || !model.selectedDingTalkProfileIDs.contains(watch.profile.id))
                                Button("取消关注") { do { try model.removeDingTalkResearchWatch(watch.id) } catch { self.error = error.localizedDescription } }.disabled(model.checkingResearchWatches.contains(watch.id))
                            }
                            Text("\(watch.profile.corpName) · \(watch.kind == "message" ? "消息/最近7天" : (watch.workspaceName ?? "知识库") + (watch.acrossDirectories == true ? " · 跨目录检索" : (watch.folderID == nil ? " · 首页目录" : " · 所选子目录"))) · 最近成功检查：\(watch.checkedAt.formatted())").font(.caption)
                            if let error = watch.error { Text(error + " 原对比基线保留。").font(.caption).foregroundStyle(.orange) }
                            Text("上次成功检查发现\(watch.changeCount)项新命中或变化，最多展示30项；初次关注仅建立基线。").font(.caption)
                            ForEach(watch.changes) { item in
                                DingTalkResearchItemCard(item: item) { if !item.isFolder { Button("关联到事项") { linking = item; targetID = "" } } }
                            }
                        }.padding(12).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 10))
                    }
        }
    }
    private func invalidate() { request?.cancel(); result = nil; folder = nil; busy = false; error = nil; status = nil }
    private func loadSpaces() {
        guard let profile, !busy else { return }
        busy = true; error = nil; let selected = model.selectedDingTalkProfileIDs
        request = Task { @MainActor in
            let response = await Task.detached { Result { try DingTalkResearchService().spaces(profile: profile, selected: selected) } }.value
            guard !Task.isCancelled, profileID == profile.id, selected == model.selectedDingTalkProfileIDs else { return }
            busy = false
            do { spaces = try response.get(); if spaces.isEmpty { status = "当前组织没有返回可访问的组织知识库。" } } catch { self.error = error.localizedDescription }
        }
    }
    private func search() {
        guard let profile, !busy else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines); let selected = model.selectedDingTalkProfileIDs
        let searchKind = kind; let searchSpace = space; let searchAcross = searchKind == "wiki" && acrossDirectories; let searchFolder = folder?.sourceID
        guard (searchKind == "message" && !text.isEmpty) || (searchKind == "wiki" && searchSpace != nil) else { return }
        busy = true; error = nil; status = nil; result = nil
        request = Task { @MainActor in
            let response = await Task.detached { Result {
                let service = DingTalkResearchService()
                if searchKind == "message" { return try service.messages(query: text, profile: profile, selected: selected) }
                guard let searchSpace else { throw DingTalkContentError.invalidResponse }
                if searchAcross { return try service.searchAcrossWiki(space: searchSpace, query: text, selected: selected) }
                return try service.nodes(space: searchSpace, query: text, folder: searchFolder, selected: selected)
            } }.value
            guard !Task.isCancelled, selected == model.selectedDingTalkProfileIDs, profile.id == profileID, searchKind == kind else { return }
            busy = false
            do { result = try response.get(); submittedQuery = text; submittedKind = searchKind; submittedProfile = profile; submittedSpace = searchSpace; submittedFolderID = searchFolder; submittedAcrossDirectories = searchAcross }
            catch { self.error = error.localizedDescription }
        }
    }
    private func watch() {
        guard let result, let profile = submittedProfile else { return }
        do { try model.watchDingTalkResearch(result: result, profile: profile, kind: submittedKind, query: submittedQuery, space: submittedSpace, folderID: submittedAcrossDirectories ? nil : submittedFolderID, acrossDirectories: submittedAcrossDirectories); status = "已关注；初次建立基线，请点击“检查变化”进行后续核对。" }
        catch { self.error = error.localizedDescription }
    }
}

struct DingTalkResearchItemCard<Actions: View>: View {
    let item: DingTalkResearchItem
    @ViewBuilder let actions: () -> Actions
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.title).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
            Text(item.excerpt.isEmpty ? "正文未提供" : item.readableExcerpt).font(.system(size: 12)).lineLimit(expanded ? nil : 6).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if item.readableExcerpt.count > 180 || item.readableExcerpt.filter({ $0 == "\n" }).count > 5 {
                Button(expanded ? "收起片段" : "展开片段") { expanded.toggle() }.font(.caption)
            }
            Text(item.profile.corpName + " · " + (item.sourceTime?.formatted() ?? "源时间未提供")).font(.caption2).foregroundStyle(AssistantTheme.secondaryText)
            HStack {
                if let url = item.sourceURL { Link("打开钉钉原文", destination: url) }
                Button("复制来源引用") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(item.profile.corpName) · \(item.kind)\n来源ID：\(item.sourceID)\n容器ID：\(item.containerID)\n\(item.title)\n\(item.excerpt)", forType: .string)
                }
                Spacer(); actions()
            }.font(.caption)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 10))
    }
}
struct DingTalkEvidenceSection: View {
    @EnvironmentObject private var model: AssistantModel
    let target: MatterTarget
    @State private var showingResearch = false
    @State private var error: String?
    private var links: [DingTalkEvidenceLink] { model.dingTalkResearchState.links.filter { $0.target == target.reference } }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("关联的钉钉依据（\(links.count)）").font(.headline); Spacer(); Button("查找消息与知识库") { showingResearch = true } }
            Text("由你明确关联的历史片段，不代表当前源状态。取消关联只移除本机引用。").font(.caption).foregroundStyle(AssistantTheme.secondaryText)
            ForEach(links) { link in
                DingTalkResearchItemCard(item: link.item) {
                    Button("取消关联") { do { try model.unlinkDingTalkEvidence(link.id) } catch { self.error = error.localizedDescription } }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.task { model.reloadDingTalkResearch() }
            .sheet(isPresented: $showingResearch) { DingTalkResearchView().environmentObject(model) }
    }
}
