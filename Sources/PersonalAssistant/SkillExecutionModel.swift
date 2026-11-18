import Foundation

extension AssistantModel {
    @discardableResult
    func persistSkillRun(_ run: SkillRun) -> Bool {
        var next = skillRuns
        if let i = next.firstIndex(where: { $0.id == run.id }) { next[i] = run }
        else {
            if next.count >= 40 {
                guard let i = next.lastIndex(where: { [.completed, .failed, .cancelled].contains($0.status) }) else { skillStatus = "执行记录已满，请先取消旧的待确认提案。"; return false }
                next.remove(at: i)
            }
            next.insert(run, at: 0)
        }
        do { try SkillRunStore().save(next); skillRuns = next; skillStatus = nil; return true }
        catch {
            skillStatus = error.localizedDescription
            // The domain write may have succeeded even if the final journal
            // update failed. Expose reconciliation, never an automatic replay.
            if let i = skillRuns.firstIndex(where: { $0.id == run.id && $0.status == .committing }), [.completed, .verificationNeeded].contains(run.status) {
                skillRuns[i].status = .verificationNeeded
                skillRuns[i].error = "保存结果需回查；执行记录未能更新。请只回查，不重复保存。"
            }
            return false
        }
    }

    func startExecutableSkill(_ skillID: String, input: String, title: String = "用户提供的会议纪要") {
        guard !isExecutingSkill, !isSending, ExecutableSkillDefinition.find(skillID) != nil,
              skills.contains(where: { $0.id == skillID && $0.isEnabled }) else { skillStatus = "请先启用该技能，等待当前执行结束。"; return }
        do { _ = try SkillRunStore().load() }
        catch { skillStatus = error.localizedDescription; return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard skillID != "minutes-actions" || (!text.isEmpty && text.count <= DeepSeekClient.maximumMeetingMinutesCharacters),
              skillID != "daily-planning" || text.count <= 2_000 else { skillStatus = "请输入有效内容；规划要求最多2000字，纪要需在支持长度内。"; return }
        var run = SkillRun(skillID: skillID, startedAt: Date(), updatedAt: Date())
        run.sourceSummary = skillID == "minutes-actions" ? "\(String(title.prefix(160))) · \(text.count)字；仅保留行动摘录，不保存全文" : "当前工作台与已保存计划；本轮补充要求\(text.count)字"
        guard persistSkillRun(run) else { return }
        isExecutingSkill = true
        let runID = run.id
        activeSkillRunID = runID
        skillRunTask = Task {
            defer { if activeSkillRunID == runID { isExecutingSkill = false; skillRunTask = nil; activeSkillRunID = nil } }
            var key = ""
            do {
                guard let loaded = DeepSeekCredentialStore.load(), !loaded.isEmpty else { throw ProjectUpdateError.invalid("模型连接未配置或暂不可读取，请在助手设置核对。") }
                key = loaded
                if skillID == "daily-planning" {
                    guard !isRefreshing else { throw ProjectUpdateError.invalid("工作台正在刷新，请完成后重新执行。") }
                    await refreshWorkbenchAndWait()
                    try Task.checkCancellation()
                    guard syncError == nil else { throw ProjectUpdateError.invalid("当前来源刷新失败，请恢复连接后重试；未使用旧快照生成新计划。") }
                    let dateKey = DailyPlanSchedulePolicy.dayKey(for: Date()) + TimeZone.current.identifier
                    let existing = todaySavedPlan, refs = dayPlanReferences, sourcePlans = savedDayPlans
                    let facts = AssistantChatWorkbenchContext.message(personalTodos: personalTodos, projects: projects, externalSnapshot: skillSnapshot, lastSync: lastSync, isSyncing: false, syncError: nil, now: Date(), savedPlan: existing)
                    run.completedSteps = 1; run.updatedAt = Date()
                    guard persistSkillRun(run) else { return }
                    let request = (existing == nil ? "帮我安排今天，生成可确认的计划。" : "请局部调整今天的计划，保留已完成和未受影响的安排，生成确认提案。") + (text.isEmpty ? "" : "本轮要求：" + text)
                    let turn = try await DeepSeekClient().assistantTurn(to: [.init(role: "system", content: "执行日程规划技能：只生成一个本机计划或局部调整提案，引用当前来源；无真实空闲依据则时间留空，不编造准备事项，不写源数据。"), facts, MemoryActionPolicy.context(memories, planning: true), .init(role: "user", content: request)], enabledSkillIDs: ["daily-planning"], apiKey: key, hasSavedDayPlan: existing != nil)
                    try Task.checkCancellation()
                    guard dateKey == DailyPlanSchedulePolicy.dayKey(for: Date()) + TimeZone.current.identifier else { throw DayPlanError.invalid("日期或时区变化，请重新执行。") }
                    let proposals = AssistantActionParser.proposals(from: turn.toolCalls, todos: personalTodos, projects: projects, plans: sourcePlans, planReferences: refs, sourceMessage: .init(text: request, isUser: true))
                    guard proposals.count == 1 else { throw ProjectUpdateError.invalid("模型未生成唯一有效计划提案；没有写入安排，请重试。") }
                    run.action = proposals[0]
                } else {
                    run.completedSteps = 1; run.updatedAt = Date()
                    guard persistSkillRun(run) else { return }
                    let actions = try await DeepSeekClient().extractMeetingActions(from: text, apiKey: key)
                    try Task.checkCancellation()
                    run.meetingProposals = try SkillRunPolicy.meetingProposals(actions, source: text, title: title)
                    if run.meetingProposals.isEmpty {
                        run.status = .completed; run.completedSteps = 5; run.resultSummary = "已核对模型结果：未提取到有依据的行动项，没有创建待办。"
                    }
                }
                try Task.checkCancellation()
                guard skillRuns.contains(where: { $0.id == runID && $0.status == .running }) else { return }
                guard skills.contains(where: { $0.id == skillID && $0.isEnabled }) else { throw ProjectUpdateError.invalid("技能在准备期间被关闭，未生成可提交结果。") }
                if run.status != .completed { run.status = .awaitingConfirmation; run.completedSteps = 3 }
                try SkillRunPolicy.validate([run])
                run.updatedAt = Date(); _ = persistSkillRun(run)
            } catch {
                guard skillRuns.contains(where: { $0.id == runID && $0.status == .running }) else { return }
                run.status = Task.isCancelled ? .cancelled : .failed
                run.error = String(error.localizedDescription.replacingOccurrences(of: key.isEmpty ? "__absent_key__" : key, with: "[hidden]").prefix(500))
                run.updatedAt = Date(); _ = persistSkillRun(run)
            }
        }
    }

    func cancelSkillRun(_ id: UUID) {
        guard var run = skillRuns.first(where: { $0.id == id }), [.running, .awaitingConfirmation].contains(run.status) else { return }
        if run.status == .running { skillRunTask?.cancel() }
        run.status = .cancelled; run.updatedAt = Date(); run.error = "用户取消；未保存新的计划或待办。"; _ = persistSkillRun(run)
    }

    func confirmSkillRun(_ id: UUID, selected: Set<String> = [], links: [String: UUID] = [:]) {
        guard !isExecutingSkill, var run = skillRuns.first(where: { $0.id == id && $0.status == .awaitingConfirmation }),
              skills.contains(where: { $0.id == run.skillID && $0.isEnabled }) else { skillStatus = "执行状态或技能开关已变化，请重新核对。"; return }
        run.selectedEvidenceIDs = selected.sorted(); run.links = links.filter { selected.contains($0.key) }
        if run.skillID == "minutes-actions" && selected.isEmpty { skillStatus = "请选择至少一条行动项。"; return }
        run.status = .committing; run.updatedAt = Date(); run.completedSteps = 4
        guard persistSkillRun(run) else { return }
        do {
            if run.skillID == "daily-planning", let action = run.action {
                switch action.operation {
                case .saveDayPlan(let plan, let revision):
                    guard saveDayPlan(plan, expectedRevision: revision, actionID: action.id) else { throw DayPlanError.invalid(dayPlanStatus ?? "计划未保存。") }
                case .adjustDayPlan(let change):
                    if todaySavedPlan?.sourceActionID != action.id {
                        try DayPlanAdjustmentPolicy.validateConfirmation(change, current: todaySavedPlan)
                        guard saveDayPlan(change.proposed, expectedRevision: change.original.revision, actionID: action.id) else { throw DayPlanError.invalid(dayPlanStatus ?? "调整未保存。") }
                    }
                default: throw ProjectUpdateError.invalid("执行工具不在该技能允许范围内。")
                }
            } else {
                let updated = try SkillRunPolicy.meetingResult(run, among: personalTodos)
                try LocalTodoStore.save(updated); personalTodos = updated; skillDomainChanged()
            }
            run.resultSummary = try SkillRunPolicy.verify(run, plans: LocalDayPlanStore.load(), todos: LocalTodoStore.load())
            run.status = .completed; run.completedSteps = 5; run.error = nil
        } catch { run.status = .verificationNeeded; run.error = String(error.localizedDescription.prefix(500)) }
        run.updatedAt = Date(); _ = persistSkillRun(run)
    }

    func verifySkillRun(_ id: UUID) {
        guard var run = skillRuns.first(where: { $0.id == id && $0.status == .verificationNeeded }) else { return }
        do {
            run.resultSummary = try SkillRunPolicy.verify(run, plans: LocalDayPlanStore.load(), todos: LocalTodoStore.load())
            run.status = .completed; run.completedSteps = 5; run.error = nil
        } catch { run.error = String(error.localizedDescription.prefix(500)) }
        run.updatedAt = Date(); _ = persistSkillRun(run)
    }
}
