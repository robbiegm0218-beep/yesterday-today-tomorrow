import Foundation
import Testing
@testable import PersonalAssistant

@Suite(.serialized) @MainActor struct StageCompositeFactTests {
    let helper=StageFactsTests()
    func stage(_ a:PersonalTodo,_ b:PersonalTodo,_ c:PersonalTodo?=nil)->AssistantGoalStage {
        var s=helper.stage(a,status:"complete")
        s.factCriterion = .init(targetID:a.id,expectedStatus:"complete",expectedTitle:nil,allOf:[.init(targetID:b.id,expectedStatus:"open",expectedTitle:b.title)]+(c.map{[.init(targetID:$0.id,expectedStatus:"any",expectedTitle:nil)]} ?? []));return s
    }
    @Test func allFieldsRequiredAndEveryComponentIsReported() throws {
        let d=try helper.directory();defer{try? FileManager.default.removeItem(at:d)};var a=PersonalTodo(title:"A",importance:.normal);let b=PersonalTodo(title:"B",importance:.normal),s=stage(a,b)
        try helper.write([a,b],d);let unmet=try #require(StageFactPolicy.read(stage:s,directory:d));#expect(unmet.status=="unsatisfied" && unmet.components?.map(\.status)==["unsatisfied","satisfied"]);try unmet.validate(stage:s)
        a.isComplete=true;try helper.write([a,b],d);let satisfied=try #require(StageFactPolicy.read(stage:s,directory:d));#expect(satisfied.status=="satisfied");try satisfied.validate(stage:s)
    }
    @Test func anyUnknownKeepsAggregateUnknownEvenWithKnownUnmetItem() throws {
        let d=try helper.directory();defer{try? FileManager.default.removeItem(at:d)};let a=PersonalTodo(title:"A",importance:.normal),b=PersonalTodo(title:"B",importance:.normal),s=stage(a,b)
        try helper.write([a],d);let proof=try #require(StageFactPolicy.read(stage:s,directory:d));#expect(proof.status=="unknown" && proof.components?.map(\.status)==["unsatisfied","unknown"]);try proof.validate(stage:s)
    }
    @Test func sameTitleCannotReplaceMissingSecondaryID() throws {
        let d=try helper.directory();defer{try? FileManager.default.removeItem(at:d)};let a=PersonalTodo(title:"A",importance:.normal),b=PersonalTodo(title:"同名",importance:.normal);var other=b;other.id=UUID();try helper.write([a,other],d)
        let proof=try #require(StageFactPolicy.read(stage:stage(a,b),directory:d));#expect(proof.components?[1].targetID==b.id && proof.components?[1].gaps==["target_missing"])
    }
    @Test func corruptPrimaryAndDuplicateRecordIDsMakeEveryItemUnknown() throws {
        let d=try helper.directory();defer{try? FileManager.default.removeItem(at:d)};let a=PersonalTodo(title:"A",importance:.normal),b=PersonalTodo(title:"B",importance:.normal),s=stage(a,b)
        try JSONEncoder().encode([a,b]).write(to:d.appendingPathComponent("personal-todos.json.backup"));try Data("broken".utf8).write(to:d.appendingPathComponent("personal-todos.json"))
        #expect(StageFactPolicy.read(stage:s,directory:d)?.components?.allSatisfy{$0.status=="unknown" && $0.gaps==["source_unavailable"]}==true)
        try helper.write([a,a,b],d);#expect(StageFactPolicy.read(stage:s,directory:d)?.status=="unknown")
    }
    @Test func secondaryChangeAltersSignatureButClockAloneDoesNot() throws {
        let d=try helper.directory();defer{try? FileManager.default.removeItem(at:d)};let a=PersonalTodo(title:"A",importance:.normal);var b=PersonalTodo(title:"B",importance:.normal);let s=stage(a,b);try helper.write([a,b],d)
        let old=try #require(StageFactPolicy.read(stage:s,directory:d,now:Date(timeIntervalSince1970:1))),clock=try #require(StageFactPolicy.read(stage:s,directory:d,now:Date(timeIntervalSince1970:2)))
        #expect(StageNextStepPolicy.signature(old)==StageNextStepPolicy.signature(clock));b.title="B改名";try helper.write([a,b],d)
        #expect(StageNextStepPolicy.signature(old) != StageNextStepPolicy.signature(StageFactPolicy.read(stage:s,directory:d)!))
    }
    @Test func duplicateTargetsAndMoreThanFourConditionsAreRejected() throws {
        let a=PersonalTodo(title:"A",importance:.normal),b=PersonalTodo(title:"B",importance:.normal);var rule=try #require(stage(a,b).factCriterion)
        rule.allOf=[.init(targetID:a.id,expectedStatus:"open",expectedTitle:nil)];#expect(throws:(any Error).self){try rule.validate()}
        rule.allOf=(0..<4).map{_ in .init(targetID:UUID(),expectedStatus:"any",expectedTitle:nil)};#expect(throws:(any Error).self){try rule.validate()}
    }
    @Test func compositeCannotExpandIntoWritesOrCreatedReferences() throws {
        let h=StageCreatedReferenceTests();let(d,l,_,s,_)=try h.fixture();defer{try? FileManager.default.removeItem(at:d)};var change=h.revision(l,s)
        change.extraFacts=[.init(targetID:UUID().uuidString)];#expect(throws:(any Error).self){try l.reviseStage(change,scope:h.scope)}
        change.createdTargetReference=nil;change.actionTool="complete_personal_todo";#expect(throws:(any Error).self){try l.reviseStage(change,scope:h.scope)}
    }
    @Test func aggregateTamperingAndMissingComponentsAreRejected() throws {
        let d=try helper.directory();defer{try? FileManager.default.removeItem(at:d)};let a=PersonalTodo(title:"A",importance:.normal),b=PersonalTodo(title:"B",importance:.normal),s=stage(a,b);try helper.write([a,b],d)
        let original=try #require(StageFactPolicy.read(stage:s,directory:d));var bytes=try JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as! [String:Any];bytes["status"]="satisfied"
        let bad=try JSONDecoder().decode(AssistantStageFactCheck.self,from:JSONSerialization.data(withJSONObject:bytes));#expect(throws:(any Error).self){try bad.validate(stage:s)}
        var missing=original;missing.components=nil;#expect(throws:(any Error).self){try missing.validate(stage:s)}
    }
    @Test func contradictoryGapCannotMasqueradeAsSatisfiedComponent() throws {
        let rule=AssistantStageFactRequirement(targetID:UUID(),expectedStatus:"any",expectedTitle:nil)
        let bad=AssistantStageFactComponent(targetID:rule.targetID,status:"satisfied",observedTitle:"A",observedComplete:false,reason:"伪造",gaps:["target_missing"])
        #expect(throws:(any Error).self){try bad.validate(requirement:rule)}
    }
    @Test func boundedUnknownRecheckStopsAndSurvivesRestart() throws {
        let(d,l,p,c,a)=try helper.fixture();defer{try? FileManager.default.removeItem(at:d)};let b=PersonalTodo(title:"B",importance:.normal),stageID=l.rows[0].stagePlan!.stages[0].id
        try l.stageTransaction{rows in rows[0].stagePlan!.stages[0].factCriterion=self.stage(a,b).factCriterion};try helper.write([a],d)
        _=try l.checkStageFacts(parentID:p,stageID:stageID,scope:helper.scope,directory:d);#expect(l.rows[0].stagePlan!.stages[0].nextStep?.kind == .query)
        _=try l.checkStageFacts(parentID:p,stageID:stageID,scope:helper.scope,directory:d,selectedRecheck:true)
        let restored=AssistantRunLedger(store:.init(directory:d));#expect(restored.rows[0].stagePlan!.stages[0].nextStep?.kind == .stop && restored.rows[0].stagePlan!.stages[0].nextStep?.rechecks==1 && restored.rows.first{$0.id==c}?.modelRequests==0)
    }
    @Test func reviewRereadsAllConditionsAndRejectsStaleSatisfiedSnapshot() throws {
        let(d,l,p,_,a)=try helper.fixture();defer{try? FileManager.default.removeItem(at:d)};var done=a;done.isComplete=true;let b=PersonalTodo(title:"B",importance:.normal),id=l.rows[0].stagePlan!.stages[0].id
        try l.stageTransaction{rows in rows[0].stagePlan!.stages[0].factCriterion=self.stage(a,b).factCriterion};try helper.write([done,b],d);_=try l.checkStageFacts(parentID:p,stageID:id,scope:helper.scope,directory:d)
        var changed=b;changed.isComplete=true;try helper.write([done,changed],d)
        #expect(throws:(any Error).self){try l.reviewStage(parentID:p,stageID:id,note:"之前全部满足",scope:helper.scope,directory:d)}
        #expect(l.rows[0].stagePlan!.stages[0].factCheck?.status=="unsatisfied" && !l.rows[0].stagePlan!.stages[0].isComplete)
    }
    @Test func singleConditionEncodingAndHashRemainCompatible() throws {
        let a=PersonalTodo(title:"A",importance:.normal),s=helper.stage(a),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let encoded=try encoder.encode(s.factCriterion);#expect(!String(decoding:encoded,as:UTF8.self).contains("allOf"))
        let old=AssistantRun.digest(s.id.uuidString+s.instruction+s.criterion+String(decoding:encoded,as:UTF8.self));#expect(StageFactPolicy.hash(s)==old)
    }
}
