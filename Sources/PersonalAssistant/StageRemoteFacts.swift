import Foundation

struct AssistantStageRemoteCriterion:Codable,Equatable {
    let profileID:String
    let taskID:String
    let expectedStatus:String
    let expectedTitle:String?
    var targetID:String {"dingtalk-"+profileID+"-"+taskID}
    var description:String {"钉钉组织 "+profileID+"；任务ID "+taskID+"；期望："+(["any":"存在","open":"未完成","complete":"已完成"][expectedStatus] ?? "未知")+(expectedTitle.map{"；标题："+$0} ?? "")}
    func validate() throws {
        guard !profileID.isEmpty,profileID.count<=300,!profileID.contains(where:{$0.isWhitespace}),!taskID.isEmpty,taskID.count<=1000,!taskID.contains(where:{$0.isWhitespace}),["any","open","complete"].contains(expectedStatus),expectedTitle.map{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count<=300} ?? true else {throw ProjectUpdateError.invalid("请明确选择原组织与精确任务，远端条件仅支持存在/完成状态及可选标题。")}
    }
}
struct AssistantStageRemoteCheck:Codable,Equatable {
    var id=UUID()
    let criterionHash:String
    let profileID:String
    let targetID:String
    let status:String
    let checkedAt:Date
    let observedTitle:String?
    let observedComplete:Bool?
    let reason:String
    let source:String
    func validate(stage:AssistantGoalStage) throws {
        guard let rule=stage.remoteFactCriterion,criterionHash==StageRemoteFactPolicy.hash(stage),profileID==rule.profileID,targetID==rule.targetID,
              ["satisfied","unsatisfied","unknown"].contains(status),source=="live_exact_task_read",checkedAt.timeIntervalSince1970.isFinite,!reason.isEmpty,reason.count<=500,
              status=="unknown" ? observedTitle==nil && observedComplete==nil : observedTitle?.isEmpty==false && (observedTitle?.count ?? 0)<=1000 && observedComplete != nil else {throw ProjectUpdateError.invalid("远端复核的归属、版本或结果无效。")}
        if status != "unknown",let title=observedTitle,let complete=observedComplete {
            let matches=(rule.expectedStatus=="any" || (rule.expectedStatus=="complete" ? complete : !complete)) && (rule.expectedTitle==nil || rule.expectedTitle==title)
            guard (status=="satisfied")==matches else {throw ProjectUpdateError.invalid("远端结论与实际字段不一致。")}
        }
    }
}
struct StageRemoteFactOption:Identifiable {
    let profileID:String
    let taskID:String
    let title:String
    let organization:String
    var id:String {"dingtalk-"+profileID+"-"+taskID}
    var label:String {title+" · "+organization+" · "+String(taskID.suffix(8))}
}
struct StageRemoteCheckToken {
    let parentID:UUID,stageID:UUID,childID:UUID
    let parentRevision:Int,childRevision:Int
    let scope:String,criterionHash:String
    let baseMilliseconds:Int,reservedMilliseconds:Int
    let started:TimeInterval
}
struct StageRemoteReviewAuthorization {
    fileprivate let parentID:UUID,stageID:UUID,checkID:UUID
    fileprivate let revision:Int
    fileprivate let scope:String
    func matches(parent:AssistantRun,stage:AssistantGoalStage,scope:String,now:Date=Date())->Bool {
        guard parent.id==parentID,stage.id==stageID,parent.revision==revision,self.scope==scope,let check=stage.remoteFactCheck else {return false}
        let age=now.timeIntervalSince(check.checkedAt)
        return check.id==checkID && check.criterionHash==StageRemoteFactPolicy.hash(stage) && age>=0 && age<=25
    }
}
enum StageRemoteFactPolicy {
    static func combinedStatus(_ stage:AssistantGoalStage)->String {
        let statuses=[stage.remoteFactCheck?.status ?? "unknown"]+(stage.factCriterion==nil ? [] : [stage.factCheck?.status ?? "unknown"])
        if statuses.contains("unknown") {return "unknown"}
        return statuses.allSatisfy{$0=="satisfied"} ? "satisfied" : "unsatisfied"
    }
    static func hash(_ stage:AssistantGoalStage)->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return AssistantRun.digest(stage.id.uuidString+stage.instruction+stage.criterion+String(decoding:(try? encoder.encode(stage.remoteFactCriterion)) ?? Data(),as:UTF8.self))
    }
    static func unknown(stage:AssistantGoalStage,reason:String,now:Date=Date())->AssistantStageRemoteCheck {
        let rule=stage.remoteFactCriterion!
        return .init(criterionHash:hash(stage),profileID:rule.profileID,targetID:rule.targetID,status:"unknown",checkedAt:now,observedTitle:nil,observedComplete:nil,reason:reason,source:"live_exact_task_read")
    }
    static func read(stage:AssistantGoalStage,reader:AssistantLiveTodoReader,timeout:TimeInterval) async throws ->AssistantStageRemoteCheck {
        let rule=stage.remoteFactCriterion!
        guard timeout.isFinite,timeout>0 else {return unknown(stage:stage,reason:"原读取时间预算不足，结果未知，没有发起新查询。")}
        let started=ProcessInfo.processInfo.systemUptime
        let result=try await reader.read(id:rule.targetID,timeout:timeout)
        guard ProcessInfo.processInfo.systemUptime-started<=timeout else {return unknown(stage:stage,reason:"本次读取超过原剩余时间预算，结果未知，未据此完成阶段。")}
        guard result.liveVerified==true,let object=(try? JSONSerialization.jsonObject(with:Data(result.content.utf8))) as? [String:Any],object["target_id"] as? String==rule.targetID,let title=object["title"] as? String,let status=object["status"] as? String,["已完成","未完成"].contains(status) else {return unknown(stage:stage,reason:"当前精确任务读取失败、权限/范围变化或身份未能验证；结果未知，不用旧快照或同名项替代。")}
        let complete=status=="已完成",matches=(rule.expectedStatus=="any" || (rule.expectedStatus=="complete" ? complete : !complete)) && (rule.expectedTitle==nil || rule.expectedTitle==title)
        return .init(criterionHash:hash(stage),profileID:rule.profileID,targetID:rule.targetID,status:matches ? "satisfied" : "unsatisfied",checkedAt:Date(),observedTitle:title,observedComplete:complete,reason:matches ? "当前精确任务字段满足此项；仅覆盖该任务，不代表整个组织或其他业务条件。" : "当前任务状态或标题与期望不一致。",source:"live_exact_task_read")
    }
}
extension AssistantRunLedger {
    func reserveRemoteCheck(parentID:UUID,stageID:UUID,scope:String) throws ->StageRemoteCheckToken {
        var result:StageRemoteCheckToken?
        try stageTransaction {rows in
            guard let p=rows.firstIndex(where:{$0.id==parentID}),rows[p].state != .cancelled,rows[p].scopeHash==scope,
                  let i=rows[p].stagePlan?.stages.firstIndex(where:{$0.id==stageID}),let stage=rows[p].stagePlan?.stages[i],!stage.isComplete,stage.remoteFactCriterion != nil,
                  stage.dependencies.allSatisfy({rows[p].stagePlan!.stages[$0].isComplete}),let c=rows.firstIndex(where:{$0.id==stage.childRunID}),
                  [.paused,.ready,.responded,.failed].contains(rows[c].state),!rows[c].inFlight,rows[c].stageQuestion==nil,!rows[c].receipts.contains(where:{["pending","unverified"].contains($0.state)}),rows[c].readCalls<6,rows[c].elapsedMilliseconds<90_000 else {throw ProjectUpdateError.invalid("阶段、范围、原卡片或读取预算尚未就绪；没有启动远端查询。")}
            let base=rows[c].elapsedMilliseconds,reserve=min(20_000,90_000-base)
            rows[c].readCalls+=1;rows[c].elapsedMilliseconds+=reserve;rows[c].revision+=1;rows[p].revision+=1
            rows[p].stagePlan!.stages[i].remoteFactCheck=nil
            result = .init(parentID:parentID,stageID:stageID,childID:rows[c].id,parentRevision:rows[p].revision,childRevision:rows[c].revision,scope:scope,criterionHash:StageRemoteFactPolicy.hash(stage),baseMilliseconds:base,reservedMilliseconds:reserve,started:ProcessInfo.processInfo.systemUptime)
        }
        return result!
    }
    func recordRemoteCheck(_ token:StageRemoteCheckToken,proof:AssistantStageRemoteCheck,reply:AssistantMessage,scope:String) throws ->StageRemoteReviewAuthorization {
        var authorization:StageRemoteReviewAuthorization?
        try stageTransaction {rows in
            guard token.scope==scope,let p=rows.firstIndex(where:{$0.id==token.parentID}),rows[p].scopeHash==scope,rows[p].state != .cancelled,rows[p].revision==token.parentRevision,
                  let i=rows[p].stagePlan?.stages.firstIndex(where:{$0.id==token.stageID}),let stage=rows[p].stagePlan?.stages[i],!stage.isComplete,StageRemoteFactPolicy.hash(stage)==token.criterionHash,
                  let c=rows.firstIndex(where:{$0.id==token.childID}),rows[c].revision==token.childRevision,stage.childRunID==rows[c].id else {throw ProjectUpdateError.invalid("查询期间范围、阶段或版本改变，迟到结果已丢弃；没有完成阶段。")}
            try proof.validate(stage:stage)
            if let local=StageFactPolicy.read(stage:stage,directory:dataDirectory) {rows[p].stagePlan!.stages[i].factCheck=local}
            rows[p].stagePlan!.stages[i].nextStep=nil
            rows[p].stagePlan!.stages[i].remoteFactCheck=proof;rows[p].revision+=1;rows[p].updatedAt=Date()
            let spent=max(1,Int((ProcessInfo.processInfo.systemUptime-token.started)*1000))
            rows[c].elapsedMilliseconds=min(90_000,token.baseMilliseconds+spent);rows[c].revision+=1;rows[c].updatedAt=Date()
            rows[c].stageRevisionPending=nil;rows[c].state = .responded;rows[c].replyIDs.append(reply.id);rows[c].checkpoint="远端条件已实时核对；其余任务内容和业务条件仍需人工核对，不自动完成"
            authorization = .init(parentID:token.parentID,stageID:token.stageID,checkID:proof.id,revision:rows[p].revision,scope:scope)
        }
        return authorization!
    }
}
