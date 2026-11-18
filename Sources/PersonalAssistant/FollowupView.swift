import SwiftUI

struct FollowupSection: View {
    @EnvironmentObject private var model: AssistantModel
    var target: MatterTarget? = nil
    var dueOnly = false
    var allowsCreation = true
    @State private var creating = false
    @State private var error: String?
    private var rules: [MatterFollowup] {
        model.followups.filter { rule in
            if let target { return rule.reference == target.reference }
            return model.matterTargets.contains { $0.reference == rule.reference }
        }.filter { !dueOnly || ($0.status == "pending" && FollowupPolicy.deliveryDate($0.checkAt) <= Date()) }
            .sorted { $0.checkAt < $1.checkAt }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(dueOnly ? "到点跟进" : "待跟进").font(.system(size: 15, weight: .semibold))
                Spacer()
                if target != nil && allowsCreation { Button("安排跟进") { creating = true }.font(.system(size: 11)) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if rules.filter({ $0.status == "pending" }).isEmpty {
                Text(dueOnly ? "当前没有到点待核对的跟进。" : "暂无待跟进事项。可在具体事项的“事项详情”里安排，或通过对话交代跟进对象、时间和完成条件。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(rules.filter { $0.status == "pending" }.prefix(10)) { rule in FollowupCard(rule: rule, showsMatterLink: target == nil) }
            if rules.filter({ $0.status == "pending" }).count > 10 { Text("仅显示最早10项，可从各事项查看其余跟进。").font(.caption) }
            if !rules.filter({ $0.status != "pending" }).isEmpty {
                DisclosureGroup("已结束的跟进") {
                    ForEach(rules.filter { $0.status != "pending" }.suffix(20).reversed()) { rule in FollowupCard(rule: rule, showsMatterLink: target == nil) }
                }.font(.system(size: 12))
            }
            Text(model.proactiveRemindersEnabled ? "提醒与日常提醒共用亲密度额度和免打扰；错过补发窗口或额度不足时，请在这里核对，不会每天重复催问。" : "主动提醒当前未开启；跟进仍保存在这里，可到助手面板的定时任务开启提醒。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .onAppear {
                do { model.followups = try FollowupStore().load() }
                catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $creating) { if let target { FollowupEditor(target: target) } }
    }
}

struct FollowupEditor: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    let target: MatterTarget
    @State private var waitingFor = ""
    @State private var criterion = ""
    @State private var nextStep = ""
    @State private var date = Date().addingTimeInterval(3_600)
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("安排跟进").font(.title2); Spacer(); Button("取消") { dismiss() } }
            Text(target.title).fontWeight(.medium)
            TextField("等待谁或什么输入", text: $waitingFor).accessibilityLabel("跟进等待对象")
            TextField("满足什么条件就算解决", text: $criterion, axis: .vertical).accessibilityLabel("跟进完成条件")
            TextField("到时先做哪一步", text: $nextStep, axis: .vertical).accessibilityLabel("跟进下一步")
            DatePicker("跟进时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
            Text("实际可提醒时间：" + FollowupPolicy.deliveryDate(date).formatted(date: .abbreviated, time: .shortened)).font(.caption)
            Text("免打扰期间顺延到可提醒时间；系统检查可能延后。提醒错过10分钟不追补，事项仍留在工作台等待反馈。保存不会修改原待办或项目。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("确认安排跟进") {
                let waiting = waitingFor.trimmingCharacters(in: .whitespacesAndNewlines)
                let goal = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
                let next = nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
                let quote = "等待：\(waiting)；完成条件：\(goal)；下一步：\(next)"
                let rule = MatterFollowup(reference: target.reference, title: target.title, waitingFor: waiting, criterion: goal, nextStep: next, checkAt: date, quote: String(quote.prefix(1_000)), sourceMessageID: nil)
                do { try model.createFollowup(rule); dismiss() } catch { self.error = error.localizedDescription }
            }.disabled(waitingFor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || criterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 550).textFieldStyle(.roundedBorder)
            .foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
    }
}

struct FollowupCard: View {
    @EnvironmentObject private var model: AssistantModel
    let rule: MatterFollowup
    var showsMatterLink = true
    @State private var postponing = false
    @State private var date = Date().addingTimeInterval(3_600)
    @State private var detail = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Text(rule.title + " · " + (rule.status == "resolved" ? "已解决" : rule.status == "stopped" ? "不再跟进" : FollowupPolicy.deliveryDate(rule.checkAt) <= timeline.date ? "到期需反馈" : "等待跟进"))
                    .font(.system(size: 13, weight: .medium))
            }
            Text("等待：" + rule.waitingFor + " · 跟进：" + FollowupPolicy.deliveryDate(rule.checkAt).formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11))
            if rule.status == "pending", sourcePaused {
                Text("源事项已完成、隐藏或当前不可用，暂停该跟进的系统提醒；请核对并反馈结果。").font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text("核对条件：" + rule.criterion).font(.system(size: 12))
            Text("下一步：" + rule.nextStep).font(.system(size: 12))
            if showsMatterLink {
                MatterContextButton(target: .init(reference: rule.reference, title: rule.title))
            }
            if rule.status == "pending" {
                TextField("反馈结果（可选，最多500字）", text: $detail).textFieldStyle(.roundedBorder).font(.system(size: 11)).accessibilityLabel("跟进反馈说明")
                Button("核对新进展") {
                    model.draft="只读核对已有跟进「\(rule.title)」（followup_id：\(rule.id.uuidString)）的新进展：在当前已选钉钉组织里查询相关消息，比较跟进基线、等待对象与完成条件，给出依据和下一步；不解决跟进，不修改源事项。"
                    model.sendMessage()
                }.font(.system(size:11)).disabled(model.isSending || sourcePaused || model.selectedDingTalkProfileIDs.isEmpty || !model.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).help("只读核对新依据；已有草稿时请先处理草稿。")
                HStack {
                    Button("已解决") { respond("resolved") }
                    Button("稍后跟进") { postponing = true }
                    Button("不再跟进") { respond("stop") }
                }.font(.system(size: 11))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            DisclosureGroup("依据与反馈（\(rule.outcomes.count)）") {
                Text("原话：" + rule.quote).textSelection(.enabled)
                ForEach(Array(rule.outcomes.enumerated()), id: \.offset) { _, outcome in
                    Text(outcome.date.formatted(date: .abbreviated, time: .shortened) + " · " + (["resolved":"已解决", "postpone":"稍后跟进", "stop":"不再跟进"][outcome.action] ?? outcome.action) + (outcome.detail.isEmpty ? "" : " · " + outcome.detail))
                }
                Text("跟进结果与原任务完成状态分别保存。").foregroundStyle(.secondary)
            }.font(.system(size: 10))
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 9))
            .sheet(isPresented: $postponing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("稍后跟进").font(.title2)
                    DatePicker("下次时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    Text("实际可提醒时间：" + FollowupPolicy.deliveryDate(date).formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack { Button("取消") { postponing = false }; Spacer(); Button("确认稍后跟进") { if respond("postpone", nextDate: date) { postponing = false } } }
                }.padding(24).frame(width: 430).foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
                    .onAppear { date = max(rule.checkAt, Date()).addingTimeInterval(3_600) }
            }
    }
    private var sourcePaused: Bool {
        if rule.reference.kind == "personal" { return model.personalTodos.first { $0.id.uuidString == rule.reference.id }?.isComplete != false }
        if rule.reference.kind == "project" { return model.projects.first { $0.id.uuidString == rule.reference.id }.map { $0.status == "已完成" } ?? true }
        return !model.matterTargets.contains { $0.reference == rule.reference }
    }
    @discardableResult private func respond(_ action: String, nextDate: Date? = nil) -> Bool {
        do { try model.respondFollowup(id: rule.id, revision: rule.revision, action: action, detail: detail, nextDate: nextDate); error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
