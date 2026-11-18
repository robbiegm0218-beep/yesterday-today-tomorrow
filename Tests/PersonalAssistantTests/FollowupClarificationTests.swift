import Foundation
import Testing
@testable import PersonalAssistant
struct FollowupClarificationTests {
    func fixture()->([MatterFollowup],[MatterTarget]) {
        let a=MatterReference.personal(UUID()),b=MatterReference.personal(UUID())
        let rules=[MatterFollowup(reference:a,title:"核对接口",waitingFor:"小林",criterion:"确认字段",nextStep:"核对",checkAt:Date(),quote:"等确认",sourceMessageID:nil),MatterFollowup(reference:b,title:"核对发布",waitingFor:"小林",criterion:"确认字段",nextStep:"核对",checkAt:Date(),quote:"等确认",sourceMessageID:nil)]
        return(rules,[.init(reference:a,title:"核对接口"),.init(reference:b,title:"核对发布")])
    }
    @Test func sameWaiterProducesBoundedChoicesBeforeRemoteQuery() {
        let (rows,targets)=fixture();let question=FollowupAmbiguityPolicy.prompt(request:"等小林的跟进有新进展吗",rules:rows,targets:targets)
        #expect(question?.contains("多个")==true && question?.contains("核对接口")==true && question?.contains("核对发布")==true)
    }
    @Test func exactTargetAndUnrelatedConversationDoNotTriggerQuestion() {
        let (rows,targets)=fixture()
        #expect(FollowupAmbiguityPolicy.prompt(request:"核对接口跟进有新进展吗",rules:rows,targets:targets)==nil)
        #expect(FollowupAmbiguityPolicy.prompt(request:"小林的跟进有新进展吗"+rows[1].id.uuidString,rules:rows,targets:targets)==nil)
        #expect(FollowupAmbiguityPolicy.prompt(request:"小林今天怎么样",rules:rows,targets:targets)==nil)
    }
    @Test func HiddenOrResolvedFollowupsDoNotBecomeCandidates() {
        var (rows,targets)=fixture();rows[1].status="resolved"
        #expect(FollowupAmbiguityPolicy.prompt(request:"小林的跟进有新进展吗",rules:rows,targets:targets)==nil)
        rows[1].status="pending"
        #expect(FollowupAmbiguityPolicy.prompt(request:"小林的跟进有新进展吗",rules:rows,targets:Array(targets.prefix(1)))==nil)
    }
    @Test func exactFocusSuppliesFollowupIDInsteadOfMatterID() {
        let (rows,targets)=fixture()
        #expect(FollowupAmbiguityPolicy.exactFocus(request:"核对接口有新进展吗",rules:rows,targets:targets)?.id==rows[0].id)
        #expect(FollowupAmbiguityPolicy.exactFocus(request:"小林的跟进有新进展吗",rules:rows,targets:targets)==nil)
    }

}
