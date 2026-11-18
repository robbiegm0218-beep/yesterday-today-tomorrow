import Foundation

enum StageNextStepKind:String,Codable {
    case query,ask,adjust,resume,review,answer,inspect,stop,wait
    var buttonTitle:String? {
        switch self {
        case .query:"重新核对当前记录"
        case .ask:"补充目标信息"
        case .adjust:"调整本阶段"
        case .resume:"继续本阶段，保留预算"
        default:nil
        }
    }
}
struct AssistantStageNextStep:Codable,Equatable {
    let kind:StageNextStepKind
    let reason:String
    let proofSignature:String
    var rechecks=0
    var clarificationUsed=false
    var verifiedReceiptIDs:[UUID]? = nil
    func validate(stage:AssistantGoalStage) throws {
        guard let proof=stage.factCheck,proofSignature==StageNextStepPolicy.signature(proof),!reason.isEmpty,reason.count<=500,(0...1).contains(rechecks),(verifiedReceiptIDs?.count ?? 0)<=100,Set(verifiedReceiptIDs ?? []).count==(verifiedReceiptIDs?.count ?? 0) else {throw ProjectUpdateError.invalid("阶段下一步与事实版本或尝试次数不一致。")}
    }
}
struct StageNextStepToken:Equatable {
    let parentID:UUID
    let stageID:UUID
    let childID:UUID
    let parentRevision:Int
    let childRevision:Int
    let criterionHash:String
    let proofSignature:String
    let kind:StageNextStepKind
}
enum StageNextStepPolicy {
    static func matches(_ operation:PendingAssistantAction.Operation,target:UUID)->Bool {
        switch operation {
        case let .updateTodo(id,_,_,_,_),let .completeTodo(id),let .reopenTodo(id):return id==target
        default:return false
        }
    }
    static func canProposeKnownStateChange(stage:AssistantGoalStage,proof:AssistantStageFactCheck?)->Bool {
        guard stage.reviewMode=="confirmed_operation",stage.requiredInput==nil,let rule=stage.factCriterion,let proof,
              proof.targetID==rule.targetID,proof.criterionHash==StageFactPolicy.hash(stage),proof.status=="unsatisfied",proof.observedComplete != nil,
              (proof.gaps ?? []).contains("status_mismatch"),!(proof.gaps ?? []).contains("title_mismatch") else {return false}
        return (stage.actionTool=="complete_personal_todo" && rule.expectedStatus=="complete") || (stage.actionTool=="reopen_personal_todo" && rule.expectedStatus=="open")
    }
    static func signature(_ proof:AssistantStageFactCheck)->String {
        var values=["criterion":proof.criterionHash,"status":proof.status,"title":proof.observedTitle ?? "","complete":proof.observedComplete.map{String($0)} ?? "","gaps":(proof.gaps ?? []).sorted().joined(separator:",")]
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        if let parts=proof.components {values["components"]=String(decoding:(try? encoder.encode(parts)) ?? Data(),as:UTF8.self)}
        return AssistantRun.digest(String(decoding:(try? encoder.encode(values)) ?? Data(),as:UTF8.self))
    }
    static func decide(stage:AssistantGoalStage,child:AssistantRun?,parentState:AssistantRun.State)->AssistantStageNextStep {
        let previous=stage.nextStep,signature=stage.factCheck.map(Self.signature) ?? ""
        func step(_ kind:StageNextStepKind,_ reason:String)->AssistantStageNextStep {.init(kind:kind,reason:reason,proofSignature:signature,rechecks:previous?.rechecks ?? 0,clarificationUsed:previous?.clarificationUsed ?? false,verifiedReceiptIDs:previous?.verifiedReceiptIDs)}
        guard parentState != .cancelled,!stage.isComplete else {return step(.stop,"目标已结束或本阶段已核对完成，不再启动旧步骤。")}
        guard let child else {return step(.wait,"先按原依赖启动本阶段，再根据实际结果选择下一步。")}
        if child.state == .running || child.inFlight {return step(.wait,"本阶段正在处理，等待当前请求；不并发重复执行。")}
        if child.state == .cancelled {return step(.stop,"本阶段已停止，不能通过建议恢复旧操作。")}
        if child.receipts.contains(where:{["pending","unverified"].contains($0.state)}) {return step(.inspect,"先核对原操作卡片的待确认或未知结果，不另发同类操作。")}
        if stage.remoteFactCriterion != nil {
            return step(.wait,"本阶段含远端条件，请按原组织实时核对；确认阶段时还会重新读取，不以本地满足或旧远端快照代替。")
        }
        let completed=Set(child.receipts.filter{$0.state=="completed"}.map(\.actionID))
        if !completed.isEmpty,completed != Set(previous?.verifiedReceiptIDs ?? []) {return step(.query,"已有新的执行回执，先核对当前记录与结果，不再次提交操作。")}
        if stage.factCheck?.status=="satisfied",child.stageRevisionPending != true,child.stageQuestion==nil {
            if stage.reviewMode=="confirmed_operation",!child.receipts.contains(where:{$0.state=="completed"}) {return child.canContinue ? step(.adjust,"当前字段已经满足，但没有本阶段操作回执；请调整为只读核对，避免为取得回执重复写入。") : step(.stop,"字段已满足，但缺少本阶段操作回执且原预算耗尽；不能改阶段绕过预算或重复写入。")}
            if [.ready,.responded].contains(child.state),!child.replyIDs.isEmpty {return step(.review,"已配置字段满足，请填写其他条件的人工核对依据，再确认阶段完成。")}
            return child.canContinue ? step(.resume,"字段已满足，但本阶段尚无可核对的新回复，沿原预算说明当前事实。") : step(.stop,"本阶段尚无有效回复且预算已用完，不能用事实标记绕过结果核对。")
        }
        guard child.canContinue else {return step(.stop,"原阶段预算已耗尽或当前不能继续；不重置额度、不另建替代运行。")}
        if child.stageQuestion != nil {return step(.answer,"请回答本阶段已有问题；不会再提一个相同问题。")}
        if child.stageRevisionPending==true {return step(.resume,"阶段已修订，沿同一运行取得新结果，旧回复不能用于完成。")}
        guard let rule=stage.factCriterion,let proof=stage.factCheck else {return step(.query,"先读取当前记录，不能根据历史回复选择操作。")}
        if child.receipts.contains(where:{$0.state=="completed"}) {return step(.stop,"已有执行回执而当前条件仍未核实，请先核对源变化；不重放已执行操作。")}
        if rule.allOf != nil {
            if proof.status=="unknown" {return (previous?.rechecks ?? 0)>=1 ? step(.stop,"组合条件仍有未知项，停止重复尝试；恢复当前来源后可手动核对，不猜测目标或执行多目标写入。") : step(.query,"组合条件包含未知项，可对同一文件快照有限复核一次，逐项查看缺口。")}
            return step(.adjust,"组合条件尚未全部满足，请逐项核对并明确调整只读阶段；不把多目标缺口自动变成写入。")
        }
        if proof.status=="unknown" {
            if stage.createdTargetReference != nil {return step(.stop,"引用的原创建事项暂不能核实，请恢复来源或明确修订；不换成同名项，也不重新创建。")}
            if proof.gaps?.contains("target_missing")==true {
                if previous?.clarificationUsed==true || !(child.stageSupplements ?? []).isEmpty {return step(.adjust,"补充后原ID仍无法定位，请明确修订目标；不会按同名项自动替换。")}
                return step(.ask,"原精确ID当前无法定位，先确认目标信息，不猜测另一条同名事项。")
            }
            return (previous?.rechecks ?? 0)>=1 ? step(.stop,"复核后仍没有可用的新事实，停止重复尝试；恢复来源后可手动复核。") : step(.query,"来源暂不能核实，可有限复核一次；不依据未知结果生成操作。")
        }
        if child.receipts.contains(where:{$0.state=="dismissed" && !(child.supersededActionIDs ?? []).contains($0.actionID)}) {return step(.stop,"原操作已经取消，不再提交同类卡片；请明确调整阶段或提出新请求。")}
        let titleGap=rule.expectedTitle.map{$0 != proof.observedTitle} ?? false
        let stateGap=(rule.expectedStatus=="complete" && proof.observedComplete==false) || (rule.expectedStatus=="open" && proof.observedComplete==true)
        let compatible=(stage.actionTool=="complete_personal_todo" && rule.expectedStatus=="complete" && stateGap && !titleGap) || (stage.actionTool=="reopen_personal_todo" && rule.expectedStatus=="open" && stateGap && !titleGap) || (stage.actionTool=="update_personal_todo" && titleGap && !stateGap)
        if compatible {return step(.resume,"缺口与已确认的阶段操作一致，沿原预算继续生成原确认卡片；确认前不写入。")}
        return step(.adjust,"当前字段与期望不一致，现有操作不能可靠补齐缺口；请明确调整阶段，不能把只读核对擅自变成写入。")
    }
}
extension AssistantRunLedger {
    func validateNextStep(_ token:StageNextStepToken,scope:String) throws {
        guard let parent=rows.first(where:{$0.id==token.parentID}),parent.scopeHash==scope,parent.revision==token.parentRevision,parent.state != .cancelled,
              let stage=parent.stagePlan?.stages.first(where:{$0.id==token.stageID && $0.childRunID==token.childID}),!stage.isComplete,StageFactPolicy.hash(stage)==token.criterionHash,
              let child=rows.first(where:{$0.id==token.childID}),child.revision==token.childRevision,
              StageNextStepPolicy.decide(stage:stage,child:child,parentState:parent.state).kind==token.kind,
              (stage.factCheck.map(StageNextStepPolicy.signature) ?? "")==token.proofSignature else {throw ProjectUpdateError.invalid("阶段、范围、回执或下一步已有变化，请核对最新建议；没有重放操作。")}
    }
    func askNextStep(parentID:UUID,stageID:UUID,reply:AssistantMessage,scope:String) throws {
        try stageTransaction { rows in
            guard let p=rows.firstIndex(where:{$0.id==parentID}),rows[p].scopeHash==scope,rows[p].state != .cancelled,
                  let i=rows[p].stagePlan?.stages.firstIndex(where:{$0.id==stageID}),let childID=rows[p].stagePlan?.stages[i].childRunID,
                  let c=rows.firstIndex(where:{$0.id==childID}),let q=reply.stageQuestion,q.runID==childID,
                  StageNextStepPolicy.decide(stage:rows[p].stagePlan!.stages[i],child:rows[c],parentState:rows[p].state).kind == .ask else {throw ProjectUpdateError.invalid("当前阶段不需要新提问，未重复追问。")}
            try q.validate()
            rows[c].stageQuestion=q;rows[c].replyIDs.append(reply.id);rows[c].state = .responded;rows[c].revision+=1;rows[c].updatedAt=Date();rows[c].checkpoint="按缺口等待目标信息，原预算保留"
            rows[p].stagePlan!.stages[i].nextStep?.clarificationUsed=true
            let updated=StageNextStepPolicy.decide(stage:rows[p].stagePlan!.stages[i],child:rows[c],parentState:rows[p].state)
            rows[p].stagePlan!.stages[i].nextStep=updated;rows[p].revision+=1;rows[p].updatedAt=Date()
        }
    }
}
