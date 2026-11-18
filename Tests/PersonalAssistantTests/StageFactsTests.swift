import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct StageFactsTests {
    let scope=AssistantRun.digest("facts-scope")
    func directory() throws ->URL {let d=FileManager.default.temporaryDirectory.appendingPathComponent("stage-facts-"+UUID().uuidString);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true);return d}
    func stage(_ todo:PersonalTodo,status:String="complete",title:String?=nil)->AssistantGoalStage {
        .init(title:"核对事实",instruction:"按精确ID读取",criterion:"当前记录满足条件",reviewMode:"read_review",dependencies:[],factCriterion:.init(targetID:todo.id,expectedStatus:status,expectedTitle:title))
    }
    func write(_ todos:[PersonalTodo],_ dir:URL) throws {try JSONEncoder().encode(todos).write(to:dir.appendingPathComponent("personal-todos.json"),options:.atomic)}
    func fixture() throws ->(URL,AssistantRunLedger,UUID,UUID,PersonalTodo) {
        let d=try directory();let ledger=AssistantRunLedger(store:.init(directory:d));let todo=PersonalTodo(title:"银杏核对",importance:.normal);try write([todo],d)
        let p=try ledger.start(message:.init(text:"分阶段核对",isUser:true),scope:scope)
        let plan=AssistantGoalStagePlan(requestHash:ledger.rows[0].requestHash,stages:[stage(todo),.init(title:"总结",instruction:"只读总结",criterion:"人工核对",reviewMode:"read_review",dependencies:[0])])
        let msg=AssistantMessage(text:"待采用",isUser:false,goalPlanDraft:plan);try ledger.finish(p,reply:msg,state:.awaitingConfirmation,note:"待采用");try ledger.installStagePlan(plan,parentID:p,replyID:msg.id,scope:scope)
        let c=try ledger.start(message:.init(text:"核对当前记录",isUser:true),scope:scope,parentID:p,stageIndex:0)
        try ledger.finish(c,reply:.init(text:"模型说已经满足",isUser:false),state:.responded,note:"文字不算证据")
        return(d,ledger,p,c,todo)
    }
    @Test func statusAndTitleAreCheckedAgainstExactCurrentRecord() throws {
        let d=try directory();defer{try? FileManager.default.removeItem(at:d)};var todo=PersonalTodo(title:"银杏核对",importance:.normal)
        let rule=stage(todo,title:todo.title);try write([todo],d)
        #expect(StageFactPolicy.read(stage:rule,directory:d)?.status=="unsatisfied")
        todo.isComplete=true;try write([todo],d)
        #expect(StageFactPolicy.read(stage:rule,directory:d)?.status=="satisfied")
        todo.title="新标题";try write([todo],d)
        let check=try #require(StageFactPolicy.read(stage:rule,directory:d));#expect(check.status=="unsatisfied" && check.observedTitle=="新标题")
    }
    @Test func sameTitleDifferentIDCannotSatisfyMissingTarget() throws {
        let d=try directory();defer{try? FileManager.default.removeItem(at:d)}
        let todo=PersonalTodo(title:"同名",importance:.normal);var another=todo;another.id=UUID();another.isComplete=true
        try write([another],d);#expect(StageFactPolicy.read(stage:stage(todo),directory:d)?.status=="unknown")
    }
    @Test func missingCorruptAndBackupOnlyNeverUseOldSatisfiedSnapshot() throws {
        let d=try directory();defer{try? FileManager.default.removeItem(at:d)};var todo=PersonalTodo(title:"旧快照",importance:.normal);todo.isComplete=true
        let old=try JSONEncoder().encode([todo]);try old.write(to:d.appendingPathComponent("personal-todos.json.backup"))
        #expect(StageFactPolicy.read(stage:stage(todo),directory:d)?.status=="unknown")
        let file=d.appendingPathComponent("personal-todos.json");try Data("broken".utf8).write(to:file)
        #expect(StageFactPolicy.read(stage:stage(todo),directory:d)?.status=="unknown")
        #expect(try Data(contentsOf:file)==Data("broken".utf8))
    }
    @Test func duplicateIDIsUnknownAndExistenceOnlyDoesNotImplyCompletion() throws {
        let d=try directory();defer{try? FileManager.default.removeItem(at:d)};let todo=PersonalTodo(title:"存在",importance:.normal)
        try write([todo,todo],d);#expect(StageFactPolicy.read(stage:stage(todo),directory:d)?.status=="unknown")
        try write([todo],d);let check=StageFactPolicy.read(stage:stage(todo,status:"any"),directory:d)
        #expect(check?.status=="satisfied" && check?.observedComplete==false)
    }
    @Test func reviewRereadsAndBlocksStaleSatisfiedResult() throws {
        let (d,l,p,_,original)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let id=l.rows[0].stagePlan!.stages[0].id
        var todo=original;todo.isComplete=true;try write([todo],d)
        #expect(try l.checkStageFacts(parentID:p,stageID:id,scope:scope,directory:d).status=="satisfied")
        todo.isComplete=false;try write([todo],d)
        #expect(throws:(any Error).self){try l.reviewStage(parentID:p,stageID:id,note:"沿用旧满足结论",scope:scope,directory:d)}
        #expect(l.rows[0].stagePlan?.stages[0].factCheck?.status=="unsatisfied" && l.rows[0].stagePlan?.stages[0].isComplete==false)
    }
    @Test func successfulReviewRequiresCurrentFactsAndPreservesBusinessAndBudget() throws {
        let (d,l,p,c,original)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let id=l.rows[0].stagePlan!.stages[0].id;var todo=original;todo.isComplete=true;try write([todo],d)
        let before=try Data(contentsOf:d.appendingPathComponent("personal-todos.json"));let child=l.rows.first{$0.id==c}!
        try l.reviewStage(parentID:p,stageID:id,note:"核对最新已完成字段",scope:scope,directory:d)
        #expect(l.rows[0].stagePlan?.stages[0].isComplete==true && l.rows[0].stagePlan?.stages[1].childRunID==nil)
        let after=try Data(contentsOf:d.appendingPathComponent("personal-todos.json"))
        #expect(l.rows.first{$0.id==c}==child && before==after)
    }
    @Test func scopeFailureDoesNotReadPersistOrCreateNewRuns() throws {
        let (d,l,p,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let before=l.rows,id=l.rows[0].stagePlan!.stages[0].id
        #expect(throws:(any Error).self){try l.checkStageFacts(parentID:p,stageID:id,scope:AssistantRun.digest("other"),directory:d)}
        #expect(l.rows==before)
    }
    @Test func revisionClearsOldProofAndKeepsRuleInDraft() throws {
        let (d,l,p,c,todo)=try fixture();defer{try? FileManager.default.removeItem(at:d)};let id=l.rows[0].stagePlan!.stages[0].id
        _=try l.checkStageFacts(parentID:p,stageID:id,scope:scope,directory:d)
        var change=StageRevisionDraft(parent:l.rows[0],stage:l.rows[0].stagePlan!.stages[0],child:l.rows.first{$0.id==c});#expect(change.factEnabled && change.factTargetID==todo.id.uuidString)
        change.title="更正后的核对";change.reason="更新范围";try l.reviseStage(change,scope:scope)
        #expect(l.rows[0].stagePlan?.stages[0].factCriterion?.targetID==todo.id && l.rows[0].stagePlan?.stages[0].factCheck==nil)
    }
    @Test func malformedProofAndRuleRejectedWhileLegacyFieldsRemainOptional() throws {
        let todo=PersonalTodo(title:"核对",importance:.normal);let row=stage(todo)
        let proof=AssistantStageFactCheck(criterionHash:StageFactPolicy.hash(row),status:"satisfied",checkedAt:Date(),source:"personal-todos.json",targetID:todo.id,observedTitle:todo.title,observedComplete:false,reason:"伪造满足")
        #expect(throws:(any Error).self){try proof.validate(stage:row)}
        #expect(throws:(any Error).self){try AssistantStageFactCriterion(targetID:todo.id,expectedStatus:"automatic",expectedTitle:nil).validate()}
        let legacy=AssistantGoalStage(title:"旧阶段",instruction:"只读",criterion:"人工",reviewMode:"read_review",dependencies:[])
        let decoded=try JSONDecoder().decode(AssistantGoalStage.self,from:JSONEncoder().encode(legacy));#expect(decoded.factCriterion==nil && decoded.factCheck==nil)
    }
    @Test func plannerBindsOnlyKnownPersonalIDsAndRejectsUntrustedExtraFields() throws {
        let todo=PersonalTodo(title:"核对",importance:.normal)
        let first:[String:Any]=["title":"核对","instruction":"只读精确ID","criterion":"当前已完成","review_mode":"read_review","action_tool":"none","depends_on":[],"fact_check":["target_id":todo.id.uuidString,"expected_status":"complete","expected_title":""]]
        let second:[String:Any]=["title":"总结","instruction":"只读总结","criterion":"人工核对","review_mode":"read_review","action_tool":"none","depends_on":[0]]
        let call=DeepSeekToolCall(id:"facts",function:.init(name:GoalStagePlanning.name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:["stages":[first,second]]),as:UTF8.self)))
        #expect(GoalStagePlanning.propose(call,request:"请分阶段核对",knownPersonalIDs:[todo.id]).goalPlanDraft?.stages[0].factCriterion?.targetID==todo.id)
        #expect(GoalStagePlanning.propose(call,request:"请分阶段核对",knownPersonalIDs:[]).goalPlanDraft==nil)
        var invalid=first;invalid["fact_check"]=["target_id":todo.id.uuidString,"expected_status":"complete","expected_title":"","status":"satisfied"]
        let forged=DeepSeekToolCall(id:"forged",function:.init(name:GoalStagePlanning.name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:["stages":[invalid,second]]),as:UTF8.self)))
        #expect(GoalStagePlanning.propose(forged,request:"请分阶段核对",knownPersonalIDs:[todo.id]).goalPlanDraft==nil)
    }

    @Test func commonNumberedStagePlanningIntentAndNegation() {
        #expect(GoalStagePlanning.requested("请分两个阶段规划，先只给方案"))
        #expect(GoalStagePlanning.requested("分成三个阶段推进"))
        #expect(!GoalStagePlanning.requested("不要分两个阶段规划"))
        #expect(!GoalStagePlanning.requested("不分阶段，只读核对"))
    }

    @Test func emptyOptionalFactAnnotationMakesNoMachineClaim() throws {
        let row:[String:Any]=["title":"创建待办","instruction":"标题待补充","criterion":"人工核对创建回执","review_mode":"confirmed_operation","action_tool":"create_personal_todo","depends_on":[]]
        func call(_ annotation:Any) throws ->DeepSeekToolCall {
            var first=row;first["fact_check"]=annotation
            let second:[String:Any]=["title":"总结","instruction":"只读总结","criterion":"人工核对","review_mode":"read_review","action_tool":"none","depends_on":[0]]
            return .init(id:"empty",function:.init(name:GoalStagePlanning.name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:["stages":[first,second]]),as:UTF8.self)))
        }
        for annotation in [NSNull(),["target_id":"","expected_status":"any","expected_title":""]] as [Any] {
            let plan=GoalStagePlanning.propose(try call(annotation),request:"请分阶段规划",knownPersonalIDs:[]).goalPlanDraft
            #expect(plan != nil && plan?.stages[0].factCriterion==nil)
        }
        #expect(GoalStagePlanning.propose(try call(["target_id":"","expected_status":"complete","expected_title":""]),request:"请分阶段规划",knownPersonalIDs:[]).goalPlanDraft==nil)
    }

}
