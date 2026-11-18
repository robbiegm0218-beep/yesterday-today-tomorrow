import SwiftUI

struct StageInputQuestionView:View {
    @EnvironmentObject private var model:AssistantModel
    let question:AssistantStageQuestion
    @State private var answer=""
    private var active:Bool {
        guard let row=model.assistantRuns.first(where:{$0.id==question.runID}),row.canContinue,row.stageQuestion?.id==question.id else {return false}
        return model.assistantRuns.contains {$0.id==row.parentRunID && $0.state != .cancelled}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            Text(active ? "补充后继续当前阶段" : "原提问已处理、结束或原预算已用完").font(.system(size:12,weight:.medium))
            Text(question.question).font(.system(size:11))
            if active {
                ForEach(Array(question.choices.enumerated()),id:\.element.id) { i,c in
                    Button("\(i+1). "+c.label) {model.answerStageQuestion(question.runID,input:String(i+1),questionID:question.id)}.disabled(model.isSending).controlSize(.small)
                }
                if question.purpose=="missing_details" {
                    TextField("补充必要信息（最多1500字）",text:$answer,axis:.vertical).font(.system(size:11))
                    Button("补充并继续本阶段") {model.answerStageQuestion(question.runID,input:answer,questionID:question.id)}
                        .disabled(model.isSending || answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).controlSize(.small)
                }
                Text("也可直接回复这条提问。沿原阶段和原预算继续，不扩大操作权限；写入仍须确认。")
                    .font(.system(size:10)).foregroundStyle(.secondary)
            }
        }.padding(10).background(AssistantTheme.inset,in:RoundedRectangle(cornerRadius:8))
    }
}
