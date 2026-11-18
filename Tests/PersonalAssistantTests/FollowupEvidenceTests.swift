import Foundation
import Testing
@testable import PersonalAssistant

@MainActor struct FollowupEvidenceTests {
    @Test func unlinkedMessageIsOnlyCandidateAndUnrelatedOrOldMessagesAreExcluded() async throws {
        let f=EvidenceFixture();f.backend.messages=[f.backend.message(),f.backend.message(id:"other",text:"另一项目已通过"),f.backend.message(id:"old",date:f.rule.updatedAt.addingTimeInterval(-60))]
        let result=try await f.check()
        #expect(result.followupChecks.first?.state=="new_candidates" && result.followupChecks.first?.candidateCount==1 && result.followupChecks.first?.linkedCount==0)
        #expect(result.remoteSources.count==1 && result.content.contains("UNKNOWN_REQUIRES_REVIEW") && !result.content.contains("另一项目已通过"))
        #expect(result.content.contains("\"old_results_excluded\":1") && result.content.contains("\"unrelated_results_excluded\":1"))
        #expect(f.rules[0].status=="pending" && f.backend.calls.count==1)
    }
    @Test func exactUserLinkedNewMessageUsesCorrectMatterIdentity() async throws {
        let f=EvidenceFixture();f.linkMessage()
        let result=try await f.check()
        #expect(result.followupChecks.first?.state=="new_linked_evidence" && result.followupChecks.first?.linkedCount==1)
        #expect(result.content.contains("criterion_fulfilled") && result.content.contains("UNKNOWN_REQUIRES_REVIEW"))
        #expect(f.rules[0].outcomes.isEmpty && f.rules[0].revision==1)
    }
    @Test func anotherMattersLinkCannotAuthorizeAssociation() async throws {
        let f=EvidenceFixture();f.linkMessage(target:.personal(UUID()));f.backend.messages=[f.backend.message(text:"完全不同事项")]
        let result=try await f.check()
        #expect(result.followupChecks.first?.candidateCount==0 && result.remoteSources.isEmpty && !result.content.contains("完全不同事项"))
    }
    @Test func emptyOrOldOnlyIsScopedAndSevenDayGapStaysUnknown() async throws {
        let f=EvidenceFixture();f.backend.messages=[]
        #expect(try await f.check().followupChecks.first?.state=="no_new_evidence")
        f.rule.updatedAt=Date().addingTimeInterval(-8*86400);f.rules=[f.rule]
        #expect(try await f.check().followupChecks.first?.state=="insufficient_coverage")
        f.rule.updatedAt=Date().addingTimeInterval(-3600);f.rules=[f.rule];f.backend.partial=true
        #expect(try await f.check().followupChecks.first?.state=="insufficient_coverage")
    }
    @Test func documentNeedsBodyAndModifiedDateNeverProvesParagraphNovelty() async throws {
        let f=EvidenceFixture()
        let result=try await f.check(source:"documents")
        #expect(result.followupChecks.first?.state=="document_changed_excerpt_unverified")
        #expect(result.content.contains("准备接口评审方案") && result.content.contains("评估组织") && result.content.contains("松石三十七") && result.content.contains("\"paragraph_novelty_verified\":false"))
        #expect(f.backend.calls.count==2 && result.remoteSources.first?.coverage.contains("局部") == true)
    }
    @Test func oldUnknownAndMultipleDocumentsDoNotFetchArbitraryBody() async throws {
        for mode in ["old","unknown","multiple","future"] {
            let f=EvidenceFixture();f.backend.docMode=mode
            let result=try await f.check(source:"documents")
            #expect(f.backend.calls.count==1 && !result.content.contains("松石三十七") && result.remoteSources.isEmpty)
            #expect(result.followupChecks.first?.state == (mode=="multiple" ? "source_selection_required" : "insufficient_coverage"))
        }
    }
    @Test func truncatedMessageWithoutVisibleMatterIdentityCannotProveAbsence() async throws {
        let f=EvidenceFixture();f.backend.messages=[f.backend.message(text:String(repeating:"甲",count:2100)+f.rule.title)]
        let result=try await f.check()
        #expect(result.followupChecks.first?.state=="insufficient_coverage" && result.remoteSources.isEmpty)
    }
    @Test func failedSourcesStopAndCancellationPropagates() async throws {
        let f=EvidenceFixture();f.backend.error=DingTalkCLIError.timedOut
        let bad=try await f.check()
        #expect(bad.remoteSucceeded==false && bad.followupChecks.first?.state=="failed" && bad.remoteSources.isEmpty)
        f.backend.error=CancellationError()
        do { _=try await f.check();Issue.record("Cancellation swallowed") } catch is CancellationError { }
    }
    @Test func changedRuleTargetScopeAndLinkInvalidatesInflightResults() async throws {
        for mode in ["rule","target","scope","link"] {
            let f=EvidenceFixture()
            f.backend.onRun={
                switch mode {
                case "rule": f.rules[0].revision+=1
                case "target": f.targets=[]
                case "scope": f.selected=[]
                default: f.linkMessage()
                }
            }
            let result=try await f.check()
            #expect(result.remoteSucceeded==false && result.remoteSources.isEmpty && !result.content.contains("灰雀七号"))
        }
    }
    @Test func invalidOrEndedFollowupDoesNotReachRemoteAndArbitraryArgumentsAreRejected() async throws {
        let f=EvidenceFixture()
        for args: [String:Any] in [["followup_id":UUID().uuidString,"source":"messages"],["followup_id":f.rule.id.uuidString,"source":"messages","query":"绕过原事项"],["followup_id":f.rule.id.uuidString,"source":"messages","keyword":"关键词"],["followup_id":f.rule.id.uuidString,"source":"all"]] {
            let result=try await f.reader().execute(f.call(args),timeout:3)
            #expect(result.readRepairRequired && result.remoteSucceeded==nil)
        }
        f.rule.status="resolved";f.rules=[f.rule]
        #expect(try await f.check().remoteSucceeded==false)
        #expect(f.backend.calls.isEmpty)
    }
    @Test func optionalNullIsOmittedAndInvalidInputCannotTriggerRemote() async throws {
        let f=EvidenceFixture()
        let invalid=try await f.reader().execute(f.call(["followup_id":f.rule.reference.id,"source":"messages"]),timeout:3)
        #expect(invalid.readRepairRequired && f.backend.calls.isEmpty)
        let result=try await f.reader().execute(f.call(["followup_id":f.rule.id.uuidString,"source":"messages","keyword":NSNull(),"profile_id":NSNull()]),timeout:3)
        #expect(!result.readRepairRequired && result.followupChecks.first?.state=="new_candidates")
    }
    @Test func readArgumentRepairIsBoundedAndCannotBeFollowedByWriteWithoutCheck() async throws {
        for repair in [false,true] {
            let f=EvidenceFixture()
            func tool(_ name:String,_ args:[String:Any]) throws -> [String:Any] { ["id":UUID().uuidString,"type":"function","function":["name":name,"arguments":String(decoding:try JSONSerialization.data(withJSONObject:args),as:UTF8.self)]] }
            let invalid=try tool(FollowupEvidenceReader.name,["followup_id":"bad-id","source":"messages"])
            let next=try tool(repair ? FollowupEvidenceReader.name : "create_personal_todo",repair ? ["followup_id":f.rule.id.uuidString,"source":"messages"] : ["title":"不能提案"])
            RepairLoopProtocol.responses=[[invalid],[next],[]]
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[RepairLoopProtocol.self]
            let session=URLSession(configuration:config);defer {session.invalidateAndCancel()}
            let result=try await DeepSeekClient(session:session).assistantTurn(to:[.init(role:"user",content:"先核对跟进，再决定是否创建任务")],enabledSkillIDs:["todo-priority"],apiKey:"unused",readContext:.init(followupReader:f.reader()),budget:.init(maxSeconds:3))
            #expect(result.toolCalls.isEmpty)
            if repair { #expect(result.followupChecks.first?.state=="new_candidates" && result.modelRounds==3 && f.backend.calls.count==1) }
            else { #expect(result.stopReason=="followup_arguments_unresolved" && f.backend.calls.isEmpty) }
        }
    }
    @Test func explicitOriginalFollowupCannotBeReplacedByAnotherKnownID() async throws {
        let f=EvidenceFixture();let other=MatterFollowup(reference:.personal(UUID()),title:"另一个接口任务",waitingFor:"小林",criterion:"口令",nextStep:"核对",checkAt:Date(),quote:"测试",sourceMessageID:nil)
        f.rules.append(other);f.targets.append(.init(reference:other.reference,title:other.title))
        let research=AssistantResearchReader(client:f.backend,selected:f.selected,request:"核对跟进",scope:{f.selected})
        let reader=FollowupEvidenceReader(research:research,rules:f.rules,targets:f.targets,links:[],request:"只读核对跟进编号"+f.rule.id.uuidString,scope:{(f.rules,f.targets,f.links)})
        let result=try await reader.execute(f.call(["followup_id":other.id.uuidString,"source":"messages"]),timeout:3)
        #expect(result.readRepairRequired && f.backend.calls.isEmpty)
    }
    @Test func shortMatterTitleStillReturnsOnlyUnconfirmedCandidates() async throws {
        let f=EvidenceFixture()
        f.rule=MatterFollowup(reference:f.rule.reference,title:"报销",waitingFor:"小林",criterion:"确认票据",nextStep:"核对",checkAt:Date(),quote:"跟进报销",sourceMessageID:nil)
        f.rule.updatedAt=Date().addingTimeInterval(-3600);f.rules=[f.rule];f.targets=[.init(reference:f.rule.reference,title:f.rule.title)]
        f.backend.messages=[f.backend.message(text:"报销：票据已反馈")]
        let result=try await f.check()
        #expect(result.followupChecks.first?.state=="new_candidates" && result.content.contains("UNKNOWN_REQUIRES_REVIEW"))
    }
    @Test func localLookupIncludesBeyondInitialPrefixWithoutRemoteIO() throws {
        var targets:[MatterTarget]=[];var rules:[MatterFollowup]=[]
        for i in 0..<45 {
            let ref=MatterReference.personal(UUID());targets.append(.init(reference:ref,title:"任务\(i)"))
            rules.append(.init(reference:ref,title:"任务\(i)",waitingFor:"小林",criterion:"确认方案",nextStep:"核对",checkAt:Date(),quote:"合成跟进",sourceMessageID:nil))
        }
        let todos=targets.map { PersonalTodo(id:UUID(uuidString:$0.reference.id)!,title:$0.title,importance:.normal) }
        let context=AssistantReadContext(todos:todos,followups:rules)
        let result=context.execute(.init(id:"find",function:.init(name:"find_followups",arguments:"{\"query\":\"任务44\"}")))
        #expect(result.content.contains(rules[44].id.uuidString) && !result.content.contains(rules[0].id.uuidString))
    }
    @Test func persistedCheckRoundTripsAndLegacyConversationRemainsReadable() async throws {
        let f=EvidenceFixture();let result=try await f.check()
        let message=AssistantMessage(text:"核对结果",isUser:false,remoteSources:result.remoteSources,followupChecks:result.followupChecks)
        let restored=try JSONDecoder().decode(AssistantMessage.self,from:JSONEncoder().encode(message))
        #expect(restored.followupChecks==message.followupChecks && restored.followupChecks?.first?.isValid==true)
        var object=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(message)) as? [String:Any]);object.removeValue(forKey:"followupChecks")
        let old=try JSONDecoder().decode(AssistantMessage.self,from:JSONSerialization.data(withJSONObject:object))
        #expect(old.followupChecks==nil && old.text==message.text)
    }
}

@MainActor private final class EvidenceFixture {
    let backend=FollowupResearchStub()
    var rule=MatterFollowup(reference:.personal(UUID()),title:"准备接口评审",waitingFor:"小林",criterion:"口令",nextStep:"核对确认后安排联调",checkAt:Date().addingTimeInterval(3600),quote:"等待小林确认口令",sourceMessageID:nil)
    var rules:[MatterFollowup]=[];var targets:[MatterTarget]=[];var links:[DingTalkEvidenceLink]=[];var selected:Set<String>=[]
    init() {rule.updatedAt=Date().addingTimeInterval(-3600);rules=[rule];targets=[.init(reference:rule.reference,title:rule.title)];selected=[backend.profile.id]}
    func reader() -> FollowupEvidenceReader {
        let research=AssistantResearchReader(client:backend,selected:selected,request:"只读核对评估组织跟进的新进展",scope:{self.selected})
        return FollowupEvidenceReader(research:research,rules:rules,targets:targets,links:links,scope:{(self.rules,self.targets,self.links)})
    }
    func call(_ args:[String:Any]) throws -> DeepSeekToolCall { .init(id:"check",function:.init(name:FollowupEvidenceReader.name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:args),as:UTF8.self))) }
    func check(source:String="messages") async throws -> AssistantReadResult { try await reader().execute(call(["followup_id":rule.id.uuidString,"source":source]),timeout:3) }
    func linkMessage(target:MatterReference?=nil) {
        let item=DingTalkResearchItem(kind:"message",profile:backend.profile,sourceID:"m-new",containerID:"c-a",title:"小林",excerpt:"准备接口评审",sourceURL:nil,sourceTime:Date().addingTimeInterval(-60),fingerprint:DingTalkResearchItem.digest(["test"]))
        links=[.init(target:target ?? rule.reference,item:item,linkedAt:Date())]
    }
}
@MainActor private final class FollowupResearchStub: AssistantResearchReading {
    let profile=DingTalkProfile(corpID:"evaluation",userID:"self",corpName:"评估组织",userName:nil,isOrgCurrent:true)
    var calls:[AssistantResearchOperation]=[];var partial=false;var docMode="one";var error:Error?;var onRun:(()->Void)?
    lazy var messages:[[String:Any]]=[message()]
    func message(id:String="m-new",text:String="准备接口评审：小林确认口令为灰雀七号",date:Date=Date().addingTimeInterval(-60)) -> [String:Any] { ["messageId":id,"conversationId":"c-a","sender":"小林","text":text,"createTime":date.ISO8601Format()] }
    func profiles(timeout:TimeInterval) async throws -> [DingTalkProfile] { [profile] }
    func run(_ operation:AssistantResearchOperation,profileID:String,timeout:TimeInterval) async throws -> DingTalkCLIResult {
        if let error {throw error};calls.append(operation);onRun?()
        var value:[String:Any]=["complete":!partial,"hasMore":partial,"failures":[],"status":"success"]
        switch operation {
        case let .messages(_,start,end):value.merge(["contractVersion":"im.message-list.v1","paginationKnown":true,"count":messages.count,"queryRange":["startTime":start,"endTime":end],"messages":messages]) {_,new in new}
        case .documents:
            var row:[String:Any]=["nodeId":"doc-a","name":"准备接口评审方案","docType":"adoc","url":"https://alidocs.dingtalk.com/i/nodes/doc-a"]
            if docMode != "unknown" {row["modifiedTime"]=Date().addingTimeInterval(docMode=="old" ? -7200 : docMode=="future" ? 60 : -60).ISO8601Format()}
            let rows=docMode=="multiple" ? [row,["nodeId":"doc-b","name":"准备接口评审备选","docType":"adoc"]] : [row]
            value.merge(["contractVersion":"doc.list.v1","count":rows.count,"documents":rows]) {_,new in new}
        case let .document(node,_):value.merge(["contractVersion":"doc.content.v1","target":["canonicalId":node,"product":"doc"],"content":["count":1,"matches":[["content":"口令：松石三十七；并不说明新增时间","truncated":false]]]]) {_,new in new}
        }
        return .init(data:try JSONSerialization.data(withJSONObject:value),exitCode:0)
    }
}

private final class RepairLoopProtocol: URLProtocol, @unchecked Sendable {
    static var responses:[[[String:Any]]]=[]
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let calls=Self.responses.isEmpty ? [] : Self.responses.removeFirst()
        let body:[String:Any]=["choices":[["message":["role":"assistant","content":"已按核对结果回答","tool_calls":calls]]],"usage":["prompt_tokens":10,"completion_tokens":5,"total_tokens":15]]
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
