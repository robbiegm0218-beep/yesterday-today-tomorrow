import SwiftUI

struct MemoryActionSummary: View {
    @EnvironmentObject private var model: AssistantModel
    var body: some View {
        let active = MemoryActionPolicy.effective(model.memories)
        VStack(alignment: .leading, spacing: 10) {
            Text("正在影响行动的偏好").font(.headline)
            if active.isEmpty {
                Text("尚未启用。可在下方个人偏好记忆中点“设定行动偏好”；自动记录的内容不会擅自变更提醒额度。")
                    .font(.callout).foregroundStyle(AssistantTheme.secondaryText)
            }
            ForEach(active) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.preference.kind.label + "：" + entry.preference.summary).font(.callout)
                    Text("依据记忆：" + entry.memoryContent).font(.caption).foregroundStyle(AssistantTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("设置于 " + entry.preference.confirmedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(AssistantTheme.secondaryText)
                }
            }
            Text("当前对话中的明确要求优先；已有日程、计划和免打扰规则保留。编辑记忆正文会停用该条的行动偏好，需重新核对启用。")
                .font(.caption).foregroundStyle(AssistantTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MemoryActionEditor: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    let item: AssistantMemory
    @State private var replyEnabled: Bool
    @State private var reply: String
    @State private var focusEnabled: Bool
    @State private var start: String
    @State private var end: String
    @State private var reminderEnabled: Bool
    @State private var reminder: String
    @State private var error: String?

    init(item: AssistantMemory) {
        self.item = item
        let preferences = item.actionPreferences ?? []
        let length = preferences.first { $0.kind == .replyLength }
        let focus = preferences.first { $0.kind == .focusWindow }
        let limit = preferences.first { $0.kind == .reminderLimit }
        _replyEnabled = State(initialValue: length != nil); _reply = State(initialValue: length?.value ?? "balanced")
        _focusEnabled = State(initialValue: focus != nil); _start = State(initialValue: focus?.value ?? "14:00"); _end = State(initialValue: focus?.end ?? "18:00")
        _reminderEnabled = State(initialValue: limit != nil); _reminder = State(initialValue: limit?.value ?? "3")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设定行动偏好").font(.title2.weight(.semibold))
            Text(item.content).font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Toggle("调整默认回复长短", isOn: $replyEnabled)
                if replyEnabled {
                    Picker("回复长短", selection: $reply) {
                        Text("简短直接").tag("brief"); Text("适中").tag("balanced"); Text("详细说明").tag("detailed")
                    }
                }
                Divider()
                Toggle("优先在专注时段安排灵活任务", isOn: $focusEnabled)
                if focusEnabled {
                    HStack {
                        TextField("开始 HH:mm", text: $start).accessibilityLabel("专注开始时间")
                        Text("至")
                        TextField("结束 HH:mm", text: $end).accessibilityLabel("专注结束时间")
                    }.textFieldStyle(.roundedBorder)
                    Text("按本机时间、同一天填写；不覆盖已有安排或明确截止要求，无法容纳时说明原因。")
                        .font(.caption).foregroundStyle(AssistantTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Toggle("限制每日主动提醒次数", isOn: $reminderEnabled)
                if reminderEnabled {
                    Picker("每天最多", selection: $reminder) {
                        ForEach(1...5, id: \.self) { n in Text("\(n)次").tag(String(n)) }
                    }
                    Text("与亲密度额度取较小值，共享已用次数；不会补发或重置今日额度。关闭主动提醒请到“定时任务”。")
                        .font(.caption).foregroundStyle(AssistantTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("保存会替换其他记忆中的同类行动设置；取消勾选后停用本条设置。原记忆和来源保留，后续新回复及计划建议采用设置。")
                .font(.caption).foregroundStyle(AssistantTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存并应用") { save() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 500).foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
    }
    private func save() {
        let now = Date()
        var preferences: [MemoryActionPreference] = []
        if replyEnabled { preferences.append(.init(kind: .replyLength, value: reply, end: nil, confirmedAt: now)) }
        if focusEnabled { preferences.append(.init(kind: .focusWindow, value: start, end: end, confirmedAt: now)) }
        if reminderEnabled { preferences.append(.init(kind: .reminderLimit, value: reminder, end: nil, confirmedAt: now)) }
        if model.setMemoryActionPreferences(item, preferences: preferences) { dismiss() }
        else { error = model.memoryStatus }
    }
}

struct MemoryPlanPreferenceHints: View {
    @EnvironmentObject private var model: AssistantModel
    let plan: SavedDayPlan
    var body: some View {
        let warnings = MemoryActionPolicy.planningWarnings(plan, memories: model.memories)
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
