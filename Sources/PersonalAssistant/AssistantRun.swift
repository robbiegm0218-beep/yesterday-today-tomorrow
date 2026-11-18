import Foundation
import CryptoKit

enum AssistantRunEvent { case modelStarted, modelFinished(DeepSeekTokenUsage?), readStarted }

struct AssistantRun: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case running, paused, awaitingConfirmation, ready, responded, cancelled, failed, blocked
        var label: String {
            switch self {
            case .running: "正在核对"
            case .paused: "已暂停，继续时重新核对"
            case .awaitingConfirmation: "等待原操作卡片确认或取消"
            case .ready: "本轮操作已处理，可核对剩余目标"
            case .responded: "已回复，目标结果仍需你核对"
            case .cancelled: "已停止，不自动恢复"
            case .failed: "本轮未完成"
            case .blocked: "需要先核对原操作结果"
            }
        }
    }
    struct Receipt: Codable, Equatable {
        let actionID: UUID
        let messageID: UUID
        let key: String
        let summary: String
        var state: String
        var operationKind:String? = nil
        var createdTodo:AssistantCreatedTodoResult? = nil
    }
    var id = UUID()
    let originalMessageID: UUID
    let requestHash: String
    let goal: String
    let scopeHash: String
    var messageIDs: [UUID]
    var replyIDs: [UUID] = []
    var state: State = .running
    var checkpoint = "开始核对"
    var modelRequests = 0
    var readCalls = 0
    var tokens = 0
    var usageComplete = true
    var elapsedMilliseconds = 0
    var inFlight = false
    var receipts: [Receipt] = []
    var revision = 0
    var createdAt = Date()
    var updatedAt = Date()
    var stageRevisions:[AssistantStageRevisionRecord]? = nil
    var stageRevisionPending:Bool? = nil
    var supersededActionIDs:[UUID]? = nil
    var stagePlan: AssistantGoalStagePlan? = nil
    var parentRunID: UUID? = nil
    var parentStageID: UUID? = nil
    var stageQuestion: AssistantStageQuestion? = nil
    var stageSupplements: [AssistantStageSupplement]? = nil
    var budget: AssistantAgentBudget {
        .init(maxModelRounds: max(0, 4-modelRequests), maxReadCalls: max(0, 6-readCalls), maxSeconds: max(0, 90-Double(elapsedMilliseconds)/1000), maxTotalTokens: max(0, 64_000-tokens))
    }
    var canContinue: Bool { stagePlan==nil && [.paused,.ready,.responded,.failed].contains(state) && modelRequests < 4 && readCalls <= 6 && elapsedMilliseconds < 90_000 && tokens < 64_000 && !inFlight && !receipts.contains { ["pending","unverified"].contains($0.state) } }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format:"%02x",$0) }.joined() }
}

struct AssistantRunStore {
    var directory = LocalAssistantPaths.dataDirectory
    var url: URL { directory.appendingPathComponent("assistant-runs.json") }
    func load() throws -> [AssistantRun] {
        guard FileManager.default.fileExists(atPath:url.path) || FileManager.default.fileExists(atPath:url.appendingPathExtension("backup").path) else { return [] }
        guard let rows = LocalJSONFileStore.load(from:url, as:[AssistantRun].self) else { throw ProjectUpdateError.invalid("目标记录无法读取，原文件保留；暂不开始新的模型请求。") }
        try Self.validate(rows); return rows
    }
    static func validate(_ rows: [AssistantRun]) throws {
        guard rows.count <= 200, Set(rows.map(\.id)).count == rows.count else { throw ProjectUpdateError.invalid("目标记录数量或标识无效。") }
        func hash(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { $0.isHexDigit } }
        for r in rows {
            for receipt in r.receipts {
                guard receipt.operationKind==nil || receipt.operationKind==CreatedTodoReceiptPolicy.operationKind else {throw ProjectUpdateError.invalid("回执操作类型无效。")}
                if let result=receipt.createdTodo {
                    guard receipt.operationKind==CreatedTodoReceiptPolicy.operationKind,receipt.state=="completed" else {throw ProjectUpdateError.invalid("创建目标不能脱离已完成的原操作回执。")}
                    try result.validate()
                }
            }
            if let history=r.stageRevisions {
                guard r.parentRunID==nil,r.stagePlan != nil,history.count<=4 else {throw ProjectUpdateError.invalid("阶段修订历史无效。")}
                for h in history {
                    guard h.previous.id==h.replacement.id,h.previous.dependencies==h.replacement.dependencies,h.previous.childRunID==h.replacement.childRunID,!h.reason.isEmpty,h.reason.count<=500,h.at.timeIntervalSince1970.isFinite,h.previousSupplements.count<=6 else {throw ProjectUpdateError.invalid("阶段修订归属或记录无效。")}
                    try h.previousQuestion?.validate()
                    var old=r.stagePlan!;guard let i=old.stages.firstIndex(where:{$0.id==h.previous.id}) else {throw ProjectUpdateError.invalid("修订阶段不存在。")}
                    old.stages[i]=h.previous;try old.validate();old.stages[i]=h.replacement;try old.validate()
                }
            }
            if let ids=r.supersededActionIDs {
                guard r.parentRunID != nil,ids.count<=100,Set(ids).count==ids.count,ids.allSatisfy({id in r.receipts.contains{$0.actionID==id && $0.state=="dismissed"}}) else {throw ProjectUpdateError.invalid("修订替代卡片记录无效。")}
            }
            if r.stageRevisionPending != nil, r.parentRunID==nil {throw ProjectUpdateError.invalid("修订结果标记不能脱离阶段。")}
            if let q=r.stageQuestion {try q.validate();guard q.runID==r.id,r.parentRunID != nil else {throw ProjectUpdateError.invalid("阶段提问归属无效。")}}
            if let inputs=r.stageSupplements {
                guard r.parentRunID != nil,inputs.count<=6,Set(inputs.map(\.messageID)).count==inputs.count,
                      inputs.allSatisfy({r.messageIDs.contains($0.messageID) && !$0.text.isEmpty && $0.text.count<=3000 && ($0.selected?.isValid ?? true)}) else {throw ProjectUpdateError.invalid("阶段补充记录无效或超过上限。")}
            }
            if let plan=r.stagePlan {
                try plan.validate()
                guard r.parentRunID==nil, plan.status=="confirmed", plan.requestHash==r.requestHash else { throw ProjectUpdateError.invalid("阶段父目标关系无效。") }
                for stage in plan.stages {
                    if let reference=stage.createdTargetReference {
                        guard let source=plan.stages.first(where:{$0.id==reference.sourceStageID}),let child=rows.first(where:{$0.id==source.childRunID}),
                              child.receipts.contains(where:{$0.actionID==reference.actionID && $0.operationKind==CreatedTodoReceiptPolicy.operationKind && $0.state=="completed" && $0.createdTodo?.targetID==reference.targetID}) else {throw ProjectUpdateError.invalid("跨阶段引用与原创建回执归属不一致。")}
                    }
                    if let id=stage.childRunID {
                        guard let child=rows.first(where:{$0.id==id}), child.parentRunID==r.id, child.parentStageID==stage.id, child.stagePlan==nil, child.scopeHash==r.scopeHash else { throw ProjectUpdateError.invalid("阶段运行记录缺失或归属不一致。") }
                    }
                    if stage.isComplete, !stage.dependencies.allSatisfy({plan.stages[$0].isComplete}) { throw ProjectUpdateError.invalid("已核对阶段仍有未完成依赖。") }
                }
            }
            if let parent=r.parentRunID {
                guard let owner=rows.first(where:{$0.id==parent}), owner.stagePlan?.stages.contains(where:{$0.id==r.parentStageID && $0.childRunID==r.id})==true else { throw ProjectUpdateError.invalid("阶段运行不能脱离原父目标。") }
            } else if r.parentStageID != nil { throw ProjectUpdateError.invalid("阶段所属标识无效。") }
            guard r.goal.count <= 2000, !r.goal.isEmpty, hash(r.requestHash), hash(r.scopeHash),
                  (0..<1_000_000).contains(r.revision), (0...4).contains(r.modelRequests), (0...6).contains(r.readCalls),
                  (0...10_000_000).contains(r.tokens), (0...1_000_000).contains(r.elapsedMilliseconds), r.checkpoint.count <= 300,
                  r.messageIDs.count <= 30, r.replyIDs.count <= 30, Set(r.messageIDs).count == r.messageIDs.count,
                  Set(r.replyIDs).count == r.replyIDs.count, r.receipts.count <= 100, Set(r.receipts.map(\.actionID)).count == r.receipts.count,
                  r.receipts.allSatisfy({ hash($0.key) && $0.summary.count <= 500 && ["pending","completed","dismissed","unverified"].contains($0.state) }) else { throw ProjectUpdateError.invalid("目标检查点或预算记录无效，未覆盖原文件。") }
        }
    }
    func save(_ rows: [AssistantRun]) throws { try Self.validate(rows); try LocalJSONFileStore.save(rows,to:url) }
}

@MainActor
final class AssistantRunLedger {
    var dataDirectory:URL {store.directory}
    private let store: AssistantRunStore
    private let onChange: ([AssistantRun]) -> Void
    private(set) var rows: [AssistantRun] = []
    private(set) var error: String?
    private var segment: (id: UUID, start: TimeInterval, base: Int)?
    init(store: AssistantRunStore = .init(), onChange: @escaping ([AssistantRun]) -> Void = { _ in }) {
        self.store = store; self.onChange = onChange
        do {
            rows = try store.load()
            var recovered = rows
            for i in recovered.indices where recovered[i].state == .running {
                if recovered[i].inFlight { recovered[i].usageComplete = false; recovered[i].elapsedMilliseconds = min(90_000,recovered[i].elapsedMilliseconds+45_000) }
                recovered[i].inFlight = false; recovered[i].state = .paused
                recovered[i].checkpoint = "上次进程中断；未完成读取不重放，继续时重新核对当前事实"
                recovered[i].revision += 1
            }
            if recovered != rows { try store.save(recovered); rows = recovered }
        } catch { self.error = error.localizedDescription }
        onChange(rows)
    }
    private func write(_ updated: [AssistantRun]) throws {
        if let error { throw ProjectUpdateError.invalid(error) }
        let latest = try store.load()
        guard latest == rows else { throw ProjectUpdateError.invalid("目标记录已有其他版本，请重新打开助手核对，未覆盖。") }
        try store.save(updated); rows = updated; onChange(rows)
    }
    func stageTransaction(_ change:(inout [AssistantRun]) throws -> Void) throws {
        var next=rows;try change(&next);try write(next)
    }
    @discardableResult
    func start(message: AssistantMessage, scope: String, parentID: UUID? = nil, stageIndex: Int? = nil) throws -> UUID {
        var next = rows
        var ownerIndex:Int?
        if let parentID {
            guard let index=next.firstIndex(where:{$0.id==parentID}), next[index].scopeHash==scope, next[index].state != .cancelled,
                  let plan=next[index].stagePlan, let stageIndex, plan.stages.indices.contains(stageIndex), plan.stages[stageIndex].childRunID==nil,
                  plan.stages[stageIndex].dependencies.allSatisfy({plan.stages[$0].isComplete}),
                  !plan.stages.contains(where:{$0.childRunID != nil && !$0.isComplete}) else { throw ProjectUpdateError.invalid("阶段已启动、依赖尚未核对或已有阶段未结束；不会新建运行或重置预算。") }
            try StageCreatedReferencePolicy.requireCurrent(plan.stages[stageIndex],directory:store.directory)
            ownerIndex=index
        } else if stageIndex != nil { throw ProjectUpdateError.invalid("缺少阶段父目标。") }
        if next.count >= 200, let i = next.firstIndex(where:{ $0.stagePlan==nil && $0.parentRunID==nil && [.responded,.cancelled,.ready].contains($0.state) }) { next.remove(at:i) }
        guard next.count < 200 else { throw ProjectUpdateError.invalid("待处理目标过多，请先核对并结束已有目标。") }
        var row = AssistantRun(originalMessageID:message.id,requestHash:AssistantRun.digest(message.text),goal:String(message.text.prefix(2000)),scopeHash:scope,messageIDs:[message.id])
        if ownerIndex != nil, let parentID, let stageIndex, let p=next.firstIndex(where:{$0.id==parentID}) {
            row.parentRunID=parentID;row.parentStageID=next[p].stagePlan!.stages[stageIndex].id
            next[p].stagePlan!.stages[stageIndex].childRunID=row.id;next[p].revision+=1
            next[p].checkpoint="第\(stageIndex+1)阶段已启动；阶段预算保留，不自动推进下一阶段"
        }
        next.append(row); try write(next)
        segment = (row.id,ProcessInfo.processInfo.systemUptime,0)
        return row.id
    }
    private func mutate(_ id: UUID, _ change: (inout AssistantRun) throws -> Void) throws {
        guard let index = rows.firstIndex(where:{$0.id == id}) else { throw ProjectUpdateError.invalid("目标记录已不存在。") }
        var next = rows
        if let segment, segment.id == id { next[index].elapsedMilliseconds = min(1_000_000,segment.base+max(0,Int((ProcessInfo.processInfo.systemUptime-segment.start)*1000))) }
        try change(&next[index]); next[index].revision += 1; next[index].updatedAt = Date()
        try write(next)
    }
    func mutateForStageInterpretation(_ id: UUID, messageID: UUID) throws {
        try mutate(id) { row in
            row.messageIDs.append(messageID); row.state = .running
            row.checkpoint = "只生成阶段替代预览；原问题、卡片、方案和预算保留"
        }
        let row = rows.first { $0.id == id }!
        segment = (id, ProcessInfo.processInfo.systemUptime, row.elapsedMilliseconds)
    }
    func resume(_ id: UUID, messageID: UUID, scope: String, supplement: AssistantStageSupplement? = nil) throws {
        try verifyStageRun(id,scope:scope)
        try mutate(id) { row in
            guard row.scopeHash == scope else { throw ProjectUpdateError.invalid("来源、隐藏范围、资料或技能选择已变化。请恢复原范围后继续，或明确提出新请求；没有重放旧操作。") }
            guard row.canContinue else { throw ProjectUpdateError.invalid("目标尚有待确认/未核验操作，或原预算已用完。请先核对原卡片；不会重新执行写入。") }
            if let input=supplement {
                guard let question=row.stageQuestion, question.id==input.questionID, question.runID==id, input.messageID==messageID,
                      row.parentRunID != nil, (row.stageSupplements?.count ?? 0)<6, !input.text.isEmpty,input.text.count<=3000 else {throw ProjectUpdateError.invalid("原阶段提问已处理、归属不符或补充次数已满；未发送模型请求。")}
                row.stageSupplements=(row.stageSupplements ?? [])+[input];row.stageQuestion=nil
            } else if row.stageQuestion != nil {throw ProjectUpdateError.invalid("本阶段正在等待补充信息，请回答原问题；不会原样重发指令。")}
            row.messageIDs.append(messageID); row.state = .running; row.checkpoint = "用户继续：重新读取当前事实"
        }
        let row = rows.first { $0.id == id }!
        segment = (id,ProcessInfo.processInfo.systemUptime,row.elapsedMilliseconds)
    }
    func event(_ event: AssistantRunEvent, id: UUID) throws {
        try mutate(id) { row in
            guard row.state == .running else { throw CancellationError() }
            switch event {
            case .modelStarted:
                guard !row.inFlight, row.modelRequests < 4, row.tokens < 64_000, row.elapsedMilliseconds < 90_000 else { throw ProjectUpdateError.invalid("原目标模型或时间/token预算已用完；暂停恢复不会重置预算。") }
                row.modelRequests += 1; row.inFlight = true; row.checkpoint = "模型请求进行中"
            case let .modelFinished(usage):
                guard row.inFlight else { throw ProjectUpdateError.invalid("目标请求检查点顺序异常。") }
                row.inFlight = false
                if let usage { row.tokens = min(10_000_000,row.tokens+usage.totalTokens) } else { row.usageComplete = false }
                row.checkpoint = "模型返回；结果尚未执行"
            case .readStarted:
                guard row.readCalls < 6, row.elapsedMilliseconds < 90_000 else { throw ProjectUpdateError.invalid("原目标查询或时间预算已用完。") }
                row.readCalls += 1; row.checkpoint = "只读查询进行中；恢复时重查"
            }
        }
    }
    func finish(_ id: UUID, reply: AssistantMessage?, state: AssistantRun.State, note: String) throws {
        try mutate(id) { row in
            if row.inFlight { row.usageComplete = false }; row.inFlight = false
            row.state = state; row.checkpoint = String(note.prefix(300))
            if let reply {
                if let q=reply.stageQuestion {guard row.parentRunID != nil,q.runID==row.id else {throw ProjectUpdateError.invalid("提问不能脱离原阶段。")};try q.validate()}
                row.stageRevisionPending=nil
                row.stageQuestion=reply.stageQuestion
                if !row.replyIDs.contains(reply.id) { row.replyIDs.append(reply.id) }
                for action in reply.pendingActions ?? [] where !row.receipts.contains(where:{$0.actionID == action.id}) {
                    var receipt=AssistantRun.Receipt(actionID:action.id,messageID:reply.id,key:AssistantRunReplay.key(action.operation),summary:String(action.summary.prefix(500)),state:"pending")
                    if case .createTodo=action.operation {receipt.operationKind=CreatedTodoReceiptPolicy.operationKind}
                    row.receipts.append(receipt)
                }
            }
        }
        if segment?.id == id { segment = nil }
    }
    func applying(_ actionID: UUID) throws {
        guard let row = rows.first(where:{$0.receipts.contains(where:{$0.actionID == actionID})}) else { return }
        try verifyStageRun(row.id,scope:row.scopeHash)
        guard row.state != .cancelled else { throw ProjectUpdateError.invalid("此目标已结束，旧卡片不会继续执行；已执行结果不会撤销。") }
        guard !row.receipts.contains(where: { $0.actionID == actionID && ["completed","dismissed"].contains($0.state) }) else {
            throw ProjectUpdateError.invalid("目标回执已记录此操作为已核验或已取消；这张旧状态卡片不会再次执行。请核对当前事项，或关闭旧卡片后继续。")
        }
        try mutate(row.id) { run in
            run.state = .blocked; run.checkpoint = "原操作正在提交/核验；未验证前不能继续或重复提交"
            if let i = run.receipts.firstIndex(where: { $0.actionID == actionID }) { run.receipts[i].state = "unverified" }
        }
    }
    func reconcile(messages: [AssistantMessage],directory:URL?=nil) throws {
        var next = rows
        for i in next.indices {
            var changed = false
            for j in next[i].receipts.indices {
                let receipt = next[i].receipts[j]
                guard let action = messages.first(where:{$0.id == receipt.messageID})?.pendingActions?.first(where:{$0.id == receipt.actionID}) else { continue }
                let state: String
                if ["completed","dismissed"].contains(receipt.state) { state = receipt.state }
                else if action.status == .completed { state = "completed" }
                else if receipt.state == "unverified" || action.failureMessage != nil { state = "unverified" }
                else { state = action.status == .dismissed ? "dismissed" : "pending" }
                if state != receipt.state { next[i].receipts[j].state = state; changed = true }
                if case .createTodo=action.operation {
                    guard receipt.key==AssistantRunReplay.key(action.operation) else {throw ProjectUpdateError.invalid("原创建卡片参数与回执不一致，未改写目标绑定。")}
                    if next[i].receipts[j].operationKind==nil {next[i].receipts[j].operationKind=CreatedTodoReceiptPolicy.operationKind;changed=true}
                    if state=="completed",receipt.createdTodo==nil {
                        next[i].receipts[j].createdTodo=CreatedTodoReceiptPolicy.read(actionID:receipt.actionID,previous:nil,directory:directory ?? store.directory);changed=true
                    }
                }

            }
            if changed {
                if next[i].state != .cancelled { next[i].state = next[i].receipts.contains(where:{$0.state == "unverified"}) ? .blocked : next[i].receipts.contains(where:{$0.state == "pending"}) ? .awaitingConfirmation : .ready }
                next[i].checkpoint = "卡片结果已核对；已确认或取消的部分不重放"
                next[i].revision += 1
            }
        }
        if next != rows { try write(next) }
    }
    func explicitRetry(_ id: UUID) throws {
        try mutate(id) { row in
            guard row.stagePlan==nil else { throw ProjectUpdateError.invalid("阶段目标不能通过普通重试重新激活，请核对阶段进度；已结束方案不恢复。") }
            guard row.state == .cancelled else { return }
            row.state = .paused
        }
    }
    func filtered(_ actions: [PendingAssistantAction], id: UUID) -> [PendingAssistantAction] {
        let row=rows.first(where:{$0.id==id}),superseded=Set(row?.supersededActionIDs ?? [])
        let keys = Set(row?.receipts.filter {$0.state != "pending" && !superseded.contains($0.actionID)}.map(\.key) ?? [])
        return actions.filter { !keys.contains(AssistantRunReplay.key($0.operation)) }
    }
}

/// Stable semantic signatures exclude generated card/step IDs and timestamps.
/// They only block replay WITHIN a continued goal, never merge unrelated tasks.
enum AssistantRunReplay {
    static func key(_ op: PendingAssistantAction.Operation) -> String {
        func date(_ d: Date?) -> String { d.map { String($0.timeIntervalSince1970.rounded(.down)) } ?? "" }
        func normalized(_ s: String?) -> String { s?.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping ?? "" }
        let values: [String]
        switch op {
        case let .createTodo(title,_,_,project): values = ["create",normalized(title).lowercased(),normalized(project).lowercased()]
        case let .updateTodo(id,title,due,importance,project): values = ["update",id.uuidString,normalized(title),date(due),importance.map { String($0.rawValue) } ?? "",normalized(project)]
        case let .completeTodo(id): values = ["complete",id.uuidString]
        case let .reopenTodo(id): values = ["reopen",id.uuidString]
        case let .upsertProject(name,due,progress): values = ["project",normalized(name),date(due),normalized(progress)]
        case let .saveProject(p,_): values = ["project",normalized(p.name),date(p.dueAt),p.progressNote,normalized(p.nextStep),normalized(p.blocker),normalized(p.waitingFor),normalized(p.status)]
        case let .saveDayPlan(p,_): values = ["plan",p.day]
        case let .adjustDayPlan(c): values = ["plan",c.original.day]
        case let .reviewPreviousDay(p): values = ["review",p.original.day]
        case let .externalTodoMutation(r):
            values = ["external",r.localID,r.mode.rawValue,normalized(r.patch?.title),date(r.patch?.dueAt),r.patch?.priority.map(String.init) ?? "",String(r.patch?.dateOnly ?? false)]
        case let .appendMatterContext(e,_): values = ["context",e.reference.kind,e.reference.id,e.category,normalized(e.content)]
        case let .createFollowup(r): values = ["followup",r.reference.kind,r.reference.id,normalized(r.waitingFor),normalized(r.criterion),normalized(r.nextStep),date(r.checkAt)]
        case let .respondFollowup(id,_,action,detail,dateValue): values = ["respond",id.uuidString,action,detail,date(dateValue)]
        }
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return AssistantRun.digest(String(decoding:data,as:UTF8.self))
    }
}
