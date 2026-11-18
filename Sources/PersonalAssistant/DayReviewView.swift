import SwiftUI

struct DayReviewCard: View {
    @EnvironmentObject private var model: AssistantModel
    @State private var showing = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let day = DayReviewPolicy.yesterday(now: timeline.date)
            let yesterday = model.savedDayPlans.first { $0.day == day && $0.timeZone == TimeZone.current.identifier }
            let origins = DayReviewPolicy.availableOrigins(plans: model.savedDayPlans, now: timeline.date)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("昨日回顾与今日衔接").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("回顾与选择") { showing = true }.font(.system(size: 11)).disabled(origins.isEmpty)
                }
                if let yesterday {
                    Text("\(day) · 安排已勾选\(yesterday.steps.filter(\.isDone).count)项 · 未勾选\(yesterday.steps.filter { !$0.isDone }.count)项")
                        .font(.system(size: 12))
                    Text("勾选只反映保存过的执行安排，不代表任务实际在昨天完成。未完成原因未知时留空。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("昨天没有同一时区下保存的计划，不推断昨天做过什么。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                let due = origins.flatMap { $0.reviewDecisions ?? [] }.filter { $0.choice == "later" && $0.appliedDay == nil && ($0.targetDay.map { $0 <= DailyPlanSchedulePolicy.dayKey(for: timeline.date) } ?? false) }.count
                if due > 0 { Text("另有\(due)项此前推迟的安排已到核对日期，可选择是否衔接。").font(.system(size: 11)).foregroundStyle(AssistantTheme.accent) }
                if let error = model.dayReviewStatus { Text(error).font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        }.sheet(isPresented: $showing) { DayReviewSheet() }
    }
}

struct DayReviewSheet: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceDay = ""
    @State private var inputs: [UUID: DayReviewInput] = [:]
    @State private var preview: DayReviewProposal?
    @State private var error: String?
    private var origins: [SavedDayPlan] { DayReviewPolicy.availableOrigins(plans: model.savedDayPlans) }
    private var origin: SavedDayPlan? { origins.first { $0.day == sourceDay } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(preview == nil ? "回顾与衔接" : "确认回顾决策").font(.system(size: 21, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }
                if preview != nil { Button("返回选择") { preview = nil } }
                Button(preview == nil ? "预览衔接" : "确认保存回顾") { proceed() }.disabled(preview == nil && inputs.isEmpty)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            if let preview {
                ScrollView { DayReviewPreview(proposal: preview) }
            } else {
                Picker("回顾日期", selection: $sourceDay) { ForEach(origins) { Text($0.day).tag($0.day) } }
                Text("只记录你选择的处理方式；不改变历史勾选、原任务或日历。改期仅保存待核对日期，不会预先覆盖未来计划。").font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    if let origin {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(origin.steps) { step in
                                DayReviewRow(step: step, origin: origin, value: Binding(get: { inputs[step.id] }, set: { inputs[step.id] = $0 }))
                            }
                        }
                    } else { Text("没有可回顾的来源，或日期已经变化，请重新打开。") }
                }
            }
        }.padding(24).frame(width: 680, height: 620)
            .foregroundStyle(AssistantTheme.text).background(AssistantTheme.canvas)
            .onAppear { sourceDay = origins.first?.day ?? "" }
            .onChange(of: sourceDay) { _ in inputs = [:]; error = nil; preview = nil }
    }
    private func proceed() {
        do {
            if let preview {
                try model.saveDayReview(preview); dismiss()
            } else if let origin {
                preview = try DayReviewPolicy.proposal(origin: origin, today: model.todaySavedPlan, inputs: origin.steps.compactMap { inputs[$0.id] }, references: model.dayPlanReferences)
                error = nil
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct DayReviewRow: View {
    @EnvironmentObject private var model: AssistantModel
    let step: DayPlanStep
    let origin: SavedDayPlan
    @Binding var value: DayReviewInput?
    private var previous: DayReviewDecision? { origin.reviewDecisions?.first { $0.stepID == step.id } }
    private var choice: Binding<String> { .init(get: { value?.choice ?? "none" }, set: { raw in
        if raw == "none" { value = nil; return }
        value = .init(stepID: step.id, choice: raw, targetDay: raw == "later" ? DailyPlanSchedulePolicy.dayKey(for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!) : nil, plannedTime: nil, reason: value?.reason)
    }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step.title + (step.isDone ? " · 昨日安排已勾选" : " · 昨日安排未勾选")).font(.system(size: 13, weight: .medium))
            if step.sourceKind == "personal", let todo = model.personalTodos.first(where: { $0.id.uuidString == step.sourceID }) {
                Text("当前原待办：" + (todo.isComplete ? "已完成" : "未完成")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let previous {
                Text("上次选择：" + label(previous.choice) + (previous.targetDay.map { " · " + $0 } ?? "") + (previous.reason.isEmpty ? "" : " · 原因：" + previous.reason))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if step.isDone { Text("保留原有勾选，不自动迁入。").font(.system(size: 11)).foregroundStyle(.secondary) }
            else if let applied = previous?.appliedDay { Text("已衔接至\(applied)，不会重复添加。").font(.system(size: 11)).foregroundStyle(AssistantTheme.accent) }
            else {
                Picker("处理方式", selection: choice) {
                    Text("暂不决定").tag("none")
                    if step.sourceKind != "event" {
                        Text("今天继续").tag("today")
                        Text("改天再安排").tag("later")
                    }
                    Text("不再安排这一步").tag("skip")
                }.font(.system(size: 12))
                if step.sourceKind == "event" { Text("历史会议不复制为今天的日程；需要会后行动请另建待办。").font(.system(size: 11)).foregroundStyle(.secondary) }
                if value?.choice == "later" {
                    DatePicker("待核对日期", selection: .init(get: { value?.targetDay.flatMap { AssistantActionParser.date(from: $0) } ?? Date().addingTimeInterval(86_400) }, set: { value?.targetDay = DailyPlanSchedulePolicy.dayKey(for: $0) }), displayedComponents: .date)
                }
                if value?.choice == "today" {
                    TextField("今天安排时间 HH:mm（可留空）", text: .init(get: { value?.plannedTime ?? "" }, set: { value?.plannedTime = $0 }))
                    Text("不沿用昨天的时间；同一源任务已在今天计划中时仅关联，不再新增。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if value != nil {
                    TextField("未完成原因（可选，未知留空）", text: .init(get: { value?.reason ?? "" }, set: { value?.reason = $0 }), axis: .vertical)
                }
            }
        }.textFieldStyle(.roundedBorder).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AssistantTheme.inset, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DayReviewPreview: View {
    let proposal: DayReviewProposal
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("回顾来源：\(proposal.original.day) · 衔接日期：\(proposal.targetDay)").font(.system(size: 12, weight: .medium))
            if let quote = proposal.quote { Text("你的原话：" + quote).font(.system(size: 11)).textSelection(.enabled) }
            ForEach(proposal.decisions.filter { decision in proposal.original.reviewDecisions?.first(where: { $0.stepID == decision.stepID }) != decision }) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text((proposal.original.steps.first { $0.id == item.stepID }?.title ?? "原安排") + " · " + label(item.choice))
                    if let day = item.targetDay { Text("目标日期：" + day) }
                    Text(item.reason.isEmpty ? "未完成原因：未提供，不作推断" : "你的原因：" + item.reason).foregroundStyle(.secondary)
                }.font(.system(size: 12))
            }
            if let today = proposal.todayProposed {
                DayPlanDifferenceView(original: proposal.todayOriginal ?? .init(day: today.day, timeZone: today.timeZone, steps: []), proposed: today)
            } else { Text("今日计划没有新增或替换；已存在的安排只记录关联，改天/不再安排只保存决策。").font(.system(size: 12)) }
            Text("不会完成、删除或改期原任务，不会更改源日历。").font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private func label(_ choice: String) -> String { ["today":"今天继续", "later":"改天再安排", "skip":"不再安排这一步"][choice] ?? choice }
