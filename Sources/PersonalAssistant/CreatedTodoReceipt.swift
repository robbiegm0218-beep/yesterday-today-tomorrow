import Foundation

/// A verified operation receipt identifies its result, not business completion.
struct AssistantCreatedTodoResult:Codable,Equatable {
    var targetID:UUID?
    let status:String
    let checkedAt:Date
    let source:String
    let observedTitle:String?
    let observedComplete:Bool?
    let reason:String
    var isLocated:Bool {status=="located"}
    func validate() throws {
        guard ["located","source_unavailable","target_missing","ambiguous_source_action","provenance_mismatch","invalid_target"].contains(status),source=="personal-todos.json",
              checkedAt.timeIntervalSince1970.isFinite,!reason.isEmpty,reason.count<=500,(observedTitle?.count ?? 0)<=300,
              isLocated ? targetID != nil && observedTitle?.isEmpty==false && observedComplete != nil : observedTitle==nil && observedComplete==nil else {throw ProjectUpdateError.invalid("新建事项回执的目标或核对结果无效。")}
    }
}
enum CreatedTodoReceiptPolicy {
    static let operationKind="create_personal_todo"
    static func read(actionID:UUID,previous:AssistantCreatedTodoResult?,directory:URL=LocalAssistantPaths.dataDirectory,now:Date=Date())->AssistantCreatedTodoResult {
        func result(_ status:String,_ reason:String,_ todo:PersonalTodo?=nil)->AssistantCreatedTodoResult {
            .init(targetID:previous?.targetID ?? todo?.id,status:status,checkedAt:now,source:"personal-todos.json",observedTitle:todo?.title,observedComplete:todo?.isComplete,reason:reason)
        }
        let url=directory.appendingPathComponent("personal-todos.json")
        guard let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=8_000_000,
              let bytes=try? Data(contentsOf:url),bytes.count<=8_000_000,let todos=try? JSONDecoder().decode([PersonalTodo].self,from:bytes),Set(todos.map(\.id)).count==todos.count else {return result("source_unavailable","当前文件无法核对；没有用内存或恢复副本替代，也没有重新创建事项。")}
        let matches=todos.filter{$0.sourceActionID==actionID}
        // Once bound, never retarget another record, even with the same action/title.
        let todo:PersonalTodo
        if let id=previous?.targetID {
            guard let exact=todos.first(where:{$0.id==id}) else {return result("target_missing","已绑定的新事项ID当前不存在；保留原ID，不用同名项或另一条记录替代，不重新创建。")}
            guard exact.sourceActionID==actionID else {return result("provenance_mismatch","原ID的来源操作与这张卡片不一致，结果未知；未更换绑定或重新提交。")}
            guard matches.count==1 else {return result("ambiguous_source_action","同一操作标记对应多条记录，结果未知；不默认选择其中一条。")}
            todo=exact
        } else {
            guard !matches.isEmpty else {return result("target_missing","当前文件未找到原创建卡片对应的记录；同名不等于同一事项，不重新创建。")}
            guard matches.count==1 else {return result("ambiguous_source_action","原创建卡片对应多条记录，暂不绑定，不默认第一条。")}
            todo=matches[0]
        }
        guard !todo.title.isEmpty,todo.title.count<=300 else {return result("invalid_target","原创建记录内容异常，暂不能核对；保留已有绑定。")}
        return result("located","已按原卡片的操作标记及精确ID定位当前记录；仅证明创建结果仍可定位，不代表业务目标完成。",todo)
    }
    static func needsReview(_ stage:AssistantGoalStage)->Bool {stage.actionTool==operationKind}
    static func reviewable(_ child:AssistantRun)->Bool {
        let completed=child.receipts.filter{$0.operationKind==operationKind && $0.state=="completed"}
        return !completed.isEmpty && completed.allSatisfy{$0.createdTodo?.isLocated==true}
    }
}
extension AssistantRunLedger {
    func checkCreatedStageTargets(parentID:UUID,stageID:UUID,scope:String,directory:URL=LocalAssistantPaths.dataDirectory) throws {
        try stageTransaction {rows in
            guard let p=rows.firstIndex(where:{$0.id==parentID}),rows[p].scopeHash==scope,rows[p].state != .cancelled,
                  let stage=rows[p].stagePlan?.stages.first(where:{$0.id==stageID}),!stage.isComplete,CreatedTodoReceiptPolicy.needsReview(stage),
                  let c=rows.firstIndex(where:{$0.id==stage.childRunID}),![.running,.cancelled].contains(rows[c].state),!rows[c].inFlight,
                  !rows[c].receipts.contains(where:{["pending","unverified"].contains($0.state)}) else {throw ProjectUpdateError.invalid("阶段、范围或原操作尚未核对，未更新创建目标结果。")}
            let indexes=rows[c].receipts.indices.filter{rows[c].receipts[$0].operationKind==CreatedTodoReceiptPolicy.operationKind && rows[c].receipts[$0].state=="completed"}
            guard !indexes.isEmpty else {throw ProjectUpdateError.invalid("尚无可定位的创建回执；请核对原卡片，不能按标题猜测创建结果。")}
            for j in indexes {rows[c].receipts[j].createdTodo=CreatedTodoReceiptPolicy.read(actionID:rows[c].receipts[j].actionID,previous:rows[c].receipts[j].createdTodo,directory:directory)}
            rows[c].revision+=1;rows[c].updatedAt=Date();rows[p].revision+=1;rows[p].updatedAt=Date()
        }
    }
}
