import Foundation

struct AssistantGoalStage: Codable, Identifiable, Equatable {
    var id = UUID()
    let title: String
    let instruction: String
    let criterion: String
    let reviewMode: String
    let dependencies: [Int]
    var createdTargetReference:AssistantStageCreatedReference? = nil
    var remoteFactCriterion:AssistantStageRemoteCriterion? = nil
    var remoteFactCheck:AssistantStageRemoteCheck? = nil
    var factCriterion:AssistantStageFactCriterion? = nil
    var factCheck:AssistantStageFactCheck? = nil
    var nextStep:AssistantStageNextStep? = nil
    var actionTool: String? = nil
    var requiredInput: String? = nil
    var inputTargetKind: String? = nil
    var actionLabel: String { ["create_personal_todo":"创建个人待办","update_personal_todo":"修改个人待办","complete_personal_todo":"完成个人待办","reopen_personal_todo":"重开个人待办"][actionTool ?? ""] ?? "只读核对" }
    var childRunID: UUID? = nil
    var reviewNote: String? = nil
    var reviewedAt: Date? = nil
    var isComplete: Bool { reviewedAt != nil }
}
struct AssistantGoalStagePlan: Codable, Identifiable, Equatable {
    var id = UUID()
    let requestHash: String
    var stages: [AssistantGoalStage]
    var status = "pending"
    var isComplete: Bool { stages.allSatisfy(\.isComplete) }
    func validate(draft: Bool = false) throws {
        guard requestHash.count==64, requestHash.allSatisfy(\.isHexDigit), (2...4).contains(stages.count),
              Set(stages.map(\.id)).count==stages.count, ["pending","confirmed","dismissed"].contains(status) else { throw ProjectUpdateError.invalid("阶段方案格式无效。") }
        for (i,s) in stages.enumerated() {
            if let reference=s.createdTargetReference {guard !draft else {throw ProjectUpdateError.invalid("跨阶段引用须由已有回执明确选择，不能由模型预造。")};try StageCreatedReferencePolicy.validate(reference,stage:s,index:i,plan:self)}
            try s.remoteFactCriterion?.validate();try s.remoteFactCheck?.validate(stage:s)
            if s.remoteFactCriterion != nil {
                guard s.reviewMode=="read_review",s.actionTool==nil,s.createdTargetReference==nil,(s.factCriterion?.requirements.count ?? 0)+1<=4 else {throw ProjectUpdateError.invalid("远端条件首批只读，最多含1个远端与总计4项条件，不与创建引用混用。")}
            }
            guard !draft || s.remoteFactCriterion==nil && s.remoteFactCheck==nil else {throw ProjectUpdateError.invalid("远端条件需通过当前授权事项明确选择，不能由模型预造。")}
            try s.factCriterion?.validate()
            if s.factCriterion?.allOf != nil {guard s.reviewMode=="read_review",s.actionTool==nil,s.createdTargetReference==nil else {throw ProjectUpdateError.invalid("组合条件首批仅支持只读阶段，不能扩大为多目标写入或混入创建引用。")}}
            try s.factCheck?.validate(stage:s)
            try s.nextStep?.validate(stage:s)
            guard !draft || (s.factCheck==nil && s.nextStep==nil) else {throw ProjectUpdateError.invalid("待采用方案不能包含模型生成的事实结论。")}
            guard !s.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, s.title.count<=100,
                  !s.instruction.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, s.instruction.count<=600,
                  !s.criterion.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, s.criterion.count<=300,
                  ["read_review","confirmed_operation"].contains(s.reviewMode),
                  (s.reviewMode=="read_review" ? s.actionTool==nil : GoalStagePlanning.actionTools.contains(s.actionTool ?? "")),
                  s.requiredInput==nil || ["todo_title","target_choice"].contains(s.requiredInput!),
                  (s.requiredInput=="target_choice" ? ["personal","external","project","any"].contains(s.inputTargetKind ?? "") && (s.actionTool==nil || s.inputTargetKind=="personal") : s.inputTargetKind==nil),
                  s.requiredInput != "todo_title" || s.actionTool=="create_personal_todo", Set(s.dependencies).count==s.dependencies.count,
                  s.dependencies.allSatisfy({$0>=0 && $0<i}), (s.reviewNote?.count ?? 0)<=500,
                  (s.reviewedAt == nil)==(s.reviewNote == nil), s.reviewedAt?.timeIntervalSince1970.isFinite ?? true,
                  !s.isComplete || (s.childRunID != nil && !(s.reviewNote?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true)),
                  !draft || (s.childRunID==nil && !s.isComplete) else { throw ProjectUpdateError.invalid("阶段依赖、完成条件或核对记录无效。") }
        }
    }
}

enum GoalStagePlanning {
    static let name="propose_goal_stages"
    static let actionTools:Set<String>=["create_personal_todo","update_personal_todo","complete_personal_todo","reopen_personal_todo"]
    static func requested(_ text:String) -> Bool {
        (["分阶段","阶段计划","拆解目标","长期目标","分步骤推进","拆成几个阶段"].contains(where:text.contains) || text.range(of:"分(?:成)?[二三四两234]个?阶段",options:.regularExpression) != nil) &&
        text.range(of:"(?:不要|先别|不)分(?:成)?(?:[二三四两234]个?)?阶段",options:.regularExpression)==nil &&
        !["不要分阶段","不分阶段","先别分阶段","分阶段是什么意思","分阶段有什么好处","怎么理解分阶段","解释分阶段","什么是分阶段"].contains(where:text.contains)
    }
    static var definition:DeepSeekToolDefinition {
        typealias P=DeepSeekToolDefinition.Parameters.Property
        let fact=P(type:"object",description:"Optional machine-checkable PERSONAL TODO condition, only for an exact known existing ID. Omit when unknown/newly created target or criterion cannot be expressed. Does not assert business completion. Never infer completed just from creating a card.",enumValues:nil,properties:["target_id":P(type:"string",description:"Exact known personal todo UUID",enumValues:nil),"expected_status":P(type:"string",description:"any means existence only; open means not completed; complete means completed",enumValues:["any","open","complete"]),"expected_title":P(type:"string",description:"Exact required title, or empty if title is not part of completion",enumValues:nil)],required:["target_id","expected_status","expected_title"])
        let row=P(type:"object",description:"One bounded stage; order dependencies before dependents",enumValues:nil,properties:[
            "title":P(type:"string",description:"Stage title,1-100 chars",enumValues:nil),
            "instruction":P(type:"string",description:"Concrete task within user's original goal,1-600 chars. No invented identities or extra authority. Every business write still requires a separate confirmation.",enumValues:nil),
            "criterion":P(type:"string",description:"Observable completion condition,1-300 chars. A reply, created task or operation receipt is not automatically business completion.",enumValues:nil),
            "review_mode":P(type:"string",description:"User reviews answer/evidence, or completed operation receipts plus explicit human review",enumValues:["read_review","confirmed_operation"]),
            "action_tool":P(type:"string",description:"Typed operation the user will adopt. none for read_review. First batch supports local personal todo operations only; every operation still needs a separate confirmation.",enumValues:["none"]+actionTools.sorted()),
            "required_input":P(type:"string",description:"Only information still REQUIRED when this stage starts. none when target/title is already specified; todo_title only for create with unknown title; target_choice when user must select an unresolved target. Do not request already provided data.",enumValues:["none","todo_title","target_choice"]),
            "input_target_kind":P(type:"string",description:"none unless required_input=target_choice. Personal todo write stages must use personal.",enumValues:["none","personal","external","project","any"]),
            "fact_check":fact,
            "depends_on":P(type:"array",description:"Zero-based earlier stage indexes only; no self/forward/cyclic dependencies. Empty for independent stage.",enumValues:nil,items:P(type:"integer",description:"Earlier index",enumValues:nil))],required:["title","instruction","criterion","review_mode","action_tool","required_input","input_target_kind","depends_on"])
        return .init(function:.init(name:name,description:"Propose a 2-4 stage plan ONLY when user explicitly asks for staged goal planning. Planning is a draft; does not save a plan, create tasks, run stages or authorize writes. Present criteria/dependencies and wait for user to adopt. Stages are manually started and reviewed, each retains its own bounded budget; no automatic next-stage execution. Do not combine with business write proposals.",parameters:.init(properties:["stages":P(type:"array",description:"2-4 ordered stages",enumValues:nil,items:row)],required:["stages"])))
    }
    static func propose(_ call:DeepSeekToolCall, request:String,knownPersonalIDs:Set<UUID>?=nil) -> AssistantReadResult {
        if let directory=AssistantRuntime.evaluationDirectory, let data=call.function.arguments.data(using:.utf8) {
            try? data.write(to:directory.appendingPathComponent("evaluation-stage-plan-"+UUID().uuidString+".json"),options:.atomic)
        }
        do {
            guard requested(request), request.count<=2000, call.function.arguments.utf8.count<=12000,
                  let root=try JSONSerialization.jsonObject(with:Data(call.function.arguments.utf8)) as? [String:Any], Set(root.keys)==["stages"],
                  let rows=root["stages"] as? [[String:Any]], (2...4).contains(rows.count) else { throw DingTalkContentError.invalidResponse }
            let stages=try rows.map { r -> AssistantGoalStage in
                guard Set(r.keys).isSubset(of:["title","instruction","criterion","review_mode","action_tool","required_input","input_target_kind","depends_on","fact_check"]),
                      let title=r["title"] as? String, let instruction=r["instruction"] as? String, let criterion=r["criterion"] as? String,
                      let mode=r["review_mode"] as? String, (r["required_input"]==nil || r["required_input"] is String), (r["input_target_kind"]==nil || r["input_target_kind"] is String), let action=r["action_tool"] as? String, let raw=r["depends_on"] as? [Any] else { throw DingTalkContentError.invalidResponse }
                let deps=try raw.map { value -> Int in guard let n=AssistantResearchParser.int(value) else { throw DingTalkContentError.invalidResponse };return n }
                let input=r["required_input"] as? String ?? "none",kind=r["input_target_kind"] as? String ?? "none"
                guard ["none","todo_title","target_choice"].contains(input),["none","personal","external","project","any"].contains(kind) else {throw DingTalkContentError.invalidResponse}
                // Source kind constrains candidate selection only. A model may repeat
                // the known source on a title/no-input stage; discard that redundant
                // annotation instead of rejecting an otherwise valid adopted plan.
                var check:AssistantStageFactCriterion?
                if let raw=r["fact_check"],!(raw is NSNull) {
                    guard let f=raw as? [String:Any],Set(f.keys)==["target_id","expected_status","expected_title"],let idText=f["target_id"] as? String,let status=f["expected_status"] as? String,let title=f["expected_title"] as? String else {throw DingTalkContentError.invalidResponse}
                    // Explicit empty optional annotation means no machine claim.
                    // Any real expectation still requires an exact known ID.
                    if !(idText.isEmpty && status=="any" && title.isEmpty) {
                        guard let id=UUID(uuidString:idText),knownPersonalIDs?.contains(id) ?? true else {throw DingTalkContentError.invalidResponse}
                        check = .init(targetID:id,expectedStatus:status,expectedTitle:title.isEmpty ? nil : title);try check?.validate()
                    }
                }
                return .init(title:title,instruction:instruction,criterion:criterion,reviewMode:mode,dependencies:deps,factCriterion:check,actionTool:action=="none" ? nil : action,requiredInput:input=="none" ? nil : input,inputTargetKind:input=="target_choice" ? kind : nil)
            }
            let plan=AssistantGoalStagePlan(requestHash:AssistantRun.digest(request),stages:stages)
            try plan.validate(draft:true)
            return .init(content:"{\"state\":\"draft_only\",\"stages_started\":0}",goalPlanDraft:plan)
        } catch { return .init(content:"{\"error\":\"invalid_stage_plan\",\"hint\":\"Original goal must be at most2000chars. Use2-4 bounded stages, earlier dependency indexes, concrete completion criteria and valid review_mode. required_input=todo_title only with create_personal_todo; target_choice requires input_target_kind=personal/external/project/any, and personal for local writes. Correct within remaining budget. No plan adopted or task executed.\"}") }
    }
}

extension AssistantRunLedger {
    func installStagePlan(_ plan:AssistantGoalStagePlan, parentID:UUID, replyID:UUID, scope:String) throws {
        try plan.validate(draft:true)
        try stageTransaction { rows in
            guard let i=rows.firstIndex(where:{$0.id==parentID}), rows[i].parentRunID==nil, rows[i].scopeHash==scope,
                  rows[i].requestHash==plan.requestHash, rows[i].replyIDs.contains(replyID), rows[i].state != .cancelled else { throw ProjectUpdateError.invalid("原目标、阶段方案或来源范围已变化，未采用。") }
            if let existing=rows[i].stagePlan {
                var seed=existing;seed.status=plan.status
                for j in seed.stages.indices {seed.stages[j].childRunID=nil;seed.stages[j].reviewNote=nil;seed.stages[j].reviewedAt=nil}
                guard seed==plan else { throw ProjectUpdateError.invalid("该目标已有不同阶段方案，不能覆盖。") };return
            }
            guard rows[i].state == .awaitingConfirmation, rows[i].receipts.isEmpty else { throw ProjectUpdateError.invalid("原目标尚有操作需要核对，未采用阶段方案。") }
            var confirmed=plan;confirmed.status="confirmed";rows[i].stagePlan=confirmed
            rows[i].state = .ready;rows[i].checkpoint="阶段方案已采用；尚未启动任何阶段，业务写入仍须确认";rows[i].revision+=1
        }
    }
    func verifyStageRun(_ id:UUID, scope:String) throws {
        guard let run=rows.first(where:{$0.id==id}) else { throw ProjectUpdateError.invalid("运行记录不存在。") }
        guard let parentID=run.parentRunID else { return }
        guard let parent=rows.first(where:{$0.id==parentID}), parent.state != .cancelled, parent.scopeHash==scope,
              let plan=parent.stagePlan, let s=plan.stages.first(where:{$0.id==run.parentStageID && $0.childRunID==run.id}), !s.isComplete,
              s.dependencies.allSatisfy({plan.stages[$0].isComplete}) else { throw ProjectUpdateError.invalid("父目标已结束、阶段已核对完成或范围/依赖发生变化，不能继续或重复执行。") }
        try StageCreatedReferencePolicy.requireCurrent(s,directory:dataDirectory)
    }
    func reviewStage(parentID:UUID, stageID:UUID, note:String, scope:String,directory:URL=LocalAssistantPaths.dataDirectory,remoteAuthorization:StageRemoteReviewAuthorization?=nil) throws {
        let clean=note.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count<=500 else { throw ProjectUpdateError.invalid("请先填写满足完成条件的核对依据（1—500字）。") }
        if let parent=rows.first(where:{$0.id==parentID}),let stage=parent.stagePlan?.stages.first(where:{$0.id==stageID}),stage.remoteFactCriterion != nil {
            guard remoteAuthorization?.matches(parent:parent,stage:stage,scope:scope)==true else {throw ProjectUpdateError.invalid("远端条件必须在这次确认时重新实时核对；不能沿用旧的满足快照。")}
            guard stage.remoteFactCheck?.status=="satisfied" else {throw ProjectUpdateError.invalid("本次远端条件未满足或仍未知。"+(stage.remoteFactCheck?.reason ?? "")+"阶段未完成，没有修改源事项。")}
        }
        if let stage=rows.first(where:{$0.id==parentID})?.stagePlan?.stages.first(where:{$0.id==stageID}),stage.factCriterion != nil {
            let check=try checkStageFacts(parentID:parentID,stageID:stageID,scope:scope,directory:directory)
            guard check.status=="satisfied" else {throw ProjectUpdateError.invalid("最新事实复核："+check.label+"。"+check.reason+"阶段没有完成。")}
        }
        if let stage=rows.first(where:{$0.id==parentID})?.stagePlan?.stages.first(where:{$0.id==stageID}),CreatedTodoReceiptPolicy.needsReview(stage) {
            try checkCreatedStageTargets(parentID:parentID,stageID:stageID,scope:scope,directory:directory)
            guard let child=rows.first(where:{$0.id==stage.childRunID}),CreatedTodoReceiptPolicy.reviewable(child) else {throw ProjectUpdateError.invalid("原创建结果当前无法精确定位，阶段未完成；不会按同名项替代或再次创建。")}
        }
        try stageTransaction { rows in
            guard let p=rows.firstIndex(where:{$0.id==parentID}), rows[p].scopeHash==scope, rows[p].state != .cancelled,
                  var plan=rows[p].stagePlan, let i=plan.stages.firstIndex(where:{$0.id==stageID}), !plan.stages[i].isComplete,
                  plan.stages[i].dependencies.allSatisfy({plan.stages[$0].isComplete}), let childID=plan.stages[i].childRunID,
                  let child=rows.first(where:{$0.id==childID}), child.stageRevisionPending != true, child.stageQuestion==nil, [.ready,.responded].contains(child.state), !child.inFlight, !child.replyIDs.isEmpty,
                  !child.receipts.contains(where:{["pending","unverified"].contains($0.state)}) else { throw ProjectUpdateError.invalid("阶段未取得有效结果、依赖未完成，或仍有待确认/未知操作；请先核对原卡片。") }
            if plan.stages[i].reviewMode=="confirmed_operation", !child.receipts.contains(where:{$0.state=="completed"}) { throw ProjectUpdateError.invalid("此阶段要求已核验的操作回执，当前尚无；不能把文字回复当作执行完成。") }
            plan.stages[i].reviewNote=clean;plan.stages[i].reviewedAt=Date();rows[p].stagePlan=plan
            rows[p].state = plan.isComplete ? .responded : .ready
            rows[p].checkpoint=plan.isComplete ? "全部阶段已由用户按条件核对完成；不改变源事项状态" : "阶段已由用户按条件核对；下一阶段尚未启动"
            rows[p].revision+=1;rows[p].updatedAt=Date()
        }
    }
    func endStagePlan(_ parentID:UUID) throws {
        try stageTransaction { rows in
            guard let p=rows.firstIndex(where:{$0.id==parentID}), let plan=rows[p].stagePlan else { throw ProjectUpdateError.invalid("阶段目标不存在。") }
            let family=Set(plan.stages.compactMap(\.childRunID)+[parentID])
            guard !rows.contains(where:{family.contains($0.id) && ($0.state == .running || $0.inFlight)}) else { throw ProjectUpdateError.invalid("请先暂停正在运行的阶段。") }
            for i in rows.indices where family.contains(rows[i].id) {
                rows[i].state = .cancelled;rows[i].checkpoint="用户结束阶段目标；不撤销已有结果，不再提交旧卡片";rows[i].revision+=1
            }
        }
    }
}
