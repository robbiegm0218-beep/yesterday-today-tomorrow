import SwiftUI

struct CreatedTodoReceiptView:View {
    @EnvironmentObject private var model:AssistantModel
    let parentID:UUID
    let stage:AssistantGoalStage
    let child:AssistantRun
    var body:some View {
        if CreatedTodoReceiptPolicy.needsReview(stage),child.receipts.contains(where:{$0.state=="completed"}) {
            VStack(alignment:.leading,spacing:4) {
                Text("本阶段新建事项与回执").fontWeight(.medium)
                ForEach(child.receipts.filter{$0.operationKind==CreatedTodoReceiptPolicy.operationKind && $0.state=="completed"},id:\.actionID) {receipt in
                    Text("原创建卡片："+receipt.actionID.uuidString)
                    if let result=receipt.createdTodo {
                        Text("创建目标："+(result.targetID?.uuidString ?? "尚未绑定"))
                        Text(result.isLocated ? "当前记录：已精确定位" : "当前记录：未知，暂不能完成阶段")
                        if let title=result.observedTitle,let done=result.observedComplete {Text(title+" · "+(done ? "已完成" : "未完成"))}
                        Text(result.reason)
                        Text("来源："+result.source+" · 核对时点："+result.checkedAt.formatted(date:.abbreviated,time:.standard))
                    } else {Text("尚未核对创建结果，不能用文字回执代替精确目标。")}
                }
                Text("这里只核实原创建结果；业务完成条件仍需你逐项核对。")
                if !stage.isComplete {
                    Button("核对原创建结果，不重新创建") {model.checkCreatedGoalStage(parentID,stageID:stage.id)}.disabled(model.isSending)
                }
            }.padding(6)
        }
    }
}
