import SwiftUI
import ServiceManagement

extension AssistantModel {
    func reloadDingTalkEvents() {
        do { dingTalkEventSettings = try DingTalkEventStore().settings(); dingTalkEventState = try DingTalkEventStore().state(); dingTalkEventError = nil }
        catch { dingTalkEventError = error.localizedDescription }
    }
    func configureDingTalkEvents(_ settings: DingTalkEventSettings) async {
        guard !dingTalkEventBusy else { return }
        dingTalkEventBusy = true; defer { dingTalkEventBusy = false }
        let store = DingTalkEventStore(); let agent = SMAppService.agent(plistName: "com.yuan.personal-assistant.message-receiver.plist")
        do {
            if settings.enabled {
                guard Bundle.main.bundleIdentifier == "com.yuan.personal-assistant" else { throw ProjectUpdateError.invalid("隔离验收包不建立真实订阅，请在正式助手中启用。") }
                guard settings.valid, let profile = settings.profile, selectedDingTalkProfileIDs.contains(profile.id) else { throw DingTalkContentError.selectOrganization }
                let budget = try store.state().budgets[settings.scopeKey] ?? .init()
                guard budget.allows(at: Date()) else { throw ProjectUpdateError.invalid("连接恢复预算暂未允许再次启动；请查看失败记录和下次允许时间。") }
                if agent.status == .enabled || agent.status == .requiresApproval { try await agent.unregister() }
                try store.setSettings(settings)
                do { try agent.register() }
                catch { var disabled = settings; disabled.enabled = false; try? store.setSettings(disabled); throw error }
            } else {
                var disabled = try store.settings(); disabled.enabled = false; try store.setSettings(disabled)
                var stopped = false
                for _ in 0..<30 {
                    if let lease = try BackgroundPlanLease(directory: store.directory, fileName: "dingtalk-event-worker.lock") { withExtendedLifetime(lease) {}; stopped = true; break }
                    try await Task.sleep(for: .milliseconds(500))
                }
                guard stopped else { throw ProjectUpdateError.invalid("关闭指令已保存，仍在等待DWS清理订阅；请稍后刷新状态，不要重复创建连接。") }
                if agent.status == .enabled || agent.status == .requiresApproval { try await agent.unregister() }
                try store.update { $0.status = "disabled"; $0.subscriptionID = nil; $0.heartbeatAt = Date() }
                Task { await refreshActiveReminders(force: true) }
            }
            reloadDingTalkEvents()
        } catch {
            let message = String(error.localizedDescription.prefix(300))
            try? store.update { $0.status = "failed"; $0.error = message }
            reloadDingTalkEvents(); dingTalkEventError = message
        }
    }
    func dismissDingTalkEvent(_ id: String) throws {
        try DingTalkEventStore().update { state in if let i = state.events.firstIndex(where: { $0.id == id }) { state.events[i].dismissed = true } }
        reloadDingTalkEvents(); Task { await refreshActiveReminders(force: true) }
    }
}

struct DingTalkEventView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [DingTalkProfile] = []
    @State private var profileID = ""
    @State private var kind = "at-me"
    @State private var target = ""
    @State private var keyword = ""
    @State private var notify = true
    @State private var confirming = false
    private var selectedProfile: DingTalkProfile? { profiles.first { $0.id == profileID } }
    private var config: DingTalkEventSettings { .init(enabled: true, profile: selectedProfile, kind: kind, target: kind == "at-me" ? "" : target.trimmingCharacters(in: .whitespacesAndNewlines), keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines), notify: notify) }
    private var agentStatus: SMAppService.Status { SMAppService.agent(plistName: "com.yuan.personal-assistant.message-receiver.plist").status }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("钉钉实时消息").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("只接收你确认的范围，不发送回复、不标已读、不修改企业事项。原始消息保留在钉钉；本机最多保留最近200条事件片段。").font(.caption).foregroundStyle(AssistantTheme.secondaryText)
            Group {
                Picker("组织", selection: $profileID) { Text("请选择组织").tag(""); ForEach(profiles) { Text($0.corpName).tag($0.id) } }
                Picker("范围", selection: $kind) { Text("@我的消息").tag("at-me"); Text("指定群").tag("group"); Text("指定发送人").tag("sender") }
                if kind != "at-me" { TextField(kind == "group" ? "精确群名（须唯一匹配）" : "发送人姓名（须唯一匹配）", text: $target).textFieldStyle(.roundedBorder) }
                TextField("可选关键词过滤（留空接收上述范围）", text: $keyword).textFieldStyle(.roundedBorder)
                Toggle("有新事件时加入主动提醒", isOn: $notify)
            }.disabled(model.dingTalkEventSettings.enabled || model.dingTalkEventBusy)
            Text("提醒与已有日常提醒共用亲密度额度，每天最多5次，遵守免打扰。错过10分钟窗口不追补，事件仍可在这里查看。群/姓名有多个匹配时停止，不自动选择。").font(.caption).foregroundStyle(AssistantTheme.secondaryText)
            HStack {
                Button("刷新状态") { model.reloadDingTalkEvents() }
                if model.dingTalkEventSettings.enabled {
                    Button(model.dingTalkEventBusy ? "关闭中…" : "关闭监听") { Task { await model.configureDingTalkEvents(.init()) } }.disabled(model.dingTalkEventBusy)
                } else {
                    Button("核对并启用…") { confirming = true }.disabled(!config.valid || selectedProfile == nil || model.dingTalkEventBusy)
                }
                if agentStatus == .requiresApproval { Button("打开系统后台权限") { SMAppService.openSystemSettingsLoginItems() } }
            }
            TimelineView(.periodic(from: .now, by: 2)) { context in
                let state = model.dingTalkEventState
                let fresh = state.heartbeatAt.map { context.date.timeIntervalSince($0) < 20 } ?? false
                Text(!model.dingTalkEventSettings.enabled ? "未启用" : agentStatus == .requiresApproval ? "等待系统后台权限；尚未证明已监听" : agentStatus == .enabled && fresh && state.status == "ready" ? "监听进程已就绪；实时传输由DWS维护" : "状态：\(state.status)；\(fresh ? "正在核对" : "暂无有效心跳，不能确认正在监听")")
                    .font(.callout)
            }
            if let at = model.dingTalkEventState.readyAt { Text("最近就绪：\(at.formatted())").font(.caption) }
            if let last = model.dingTalkEventState.lastEventAt { Text("最近事件：\(last.formatted())").font(.caption) }
            if let budget = model.dingTalkEventState.budgets[model.dingTalkEventState.scopeKey] {
                Text("本轮连接尝试：\(budget.attempts)；可重试策略：\(budget.retryability)\(budget.nextAllowedAt.map { "；下次允许：" + $0.formatted() } ?? "")").font(.caption)
            }
            if let error = model.dingTalkEventError ?? model.dingTalkEventState.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("异常事件行：\(model.dingTalkEventState.rejectedLines)；来源可能存在断线或索引缺口，不承诺补齐历史事件。").font(.caption).foregroundStyle(AssistantTheme.secondaryText)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.dingTalkEventState.events.filter { model.selectedDingTalkProfileIDs.contains($0.item.profile.id) }) { event in
                        DingTalkResearchItemCard(item: event.item) {
                            if event.dismissed { Text("已查看").font(.caption) }
                            else { Button("标为已查看") { do { try model.dismissDingTalkEvent(event.id) } catch { model.dingTalkEventError = error.localizedDescription } } }
                        }
                    }
                }
            }
        }.padding(24).frame(width: 760, height: 690).foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
        .alert("启用钉钉实时消息？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("确认启用") { let settings = config; Task { await model.configureDingTalkEvents(settings) } }
        } message: { Text("组织：\(selectedProfile?.corpName ?? "未选择")\n范围：\(kind == "at-me" ? "@我的消息" : target)\n关键词：\(keyword.isEmpty ? "未设置" : keyword)\n会注册本机后台服务，退出助手后仍接收该范围的消息；你可随时关闭。\(notify ? "消息将纳入既有提醒额度与免打扰规则。" : "只保存事件，不发送系统提醒。")") }
        .task {
            model.reloadDingTalkEvents()
            let selected = model.selectedDingTalkProfileIDs
            profiles = (try? await Task.detached { try DingTalkContentService().profiles(selectedIDs: selected) }.value) ?? []
            let settings = model.dingTalkEventSettings
            if let profile = settings.profile, profiles.contains(where: { $0.id == profile.id }) { profileID = profile.id }
            else if profiles.count == 1 { profileID = profiles[0].id }
            kind = settings.kind; target = settings.target; keyword = settings.keyword; notify = settings.notify
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); if Task.isCancelled { break }; model.reloadDingTalkEvents() }
        }
    }
}
