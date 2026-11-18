import Foundation

struct FollowupEvidenceCheck: Codable, Equatable, Identifiable {
    let followupID: UUID
    let reference: MatterReference
    let revision: Int
    let title: String
    let source: String
    let checkedAt: Date
    let baseline: Date
    let state: String
    let coverage: String
    let criterion: String
    let nextStep: String
    let candidateCount: Int
    let linkedCount: Int
    var id: String { followupID.uuidString + ":" + source }
    var label: String {
        switch state {
        case "new_linked_evidence": "有已关联来源的新依据，完成条件仍待核对"
        case "document_changed_excerpt_unverified": "文档近期更新，片段是否新增仍待核对"
        case "new_candidates": "有新候选依据，事项归属待确认"
        case "no_new_evidence": "本次查询未发现新依据"
        case "source_selection_required": "有多篇文档，需先明确标题"
        case "failed": "核对失败，结果未知"
        default: "覆盖不足，仍待核对"
        }
    }
    var isValid: Bool {
        reference.isValid && (1..<1_000_000).contains(revision) && title.count <= 300 && ["messages","documents"].contains(source) &&
        ["new_linked_evidence","new_candidates","document_changed_excerpt_unverified","no_new_evidence","source_selection_required","failed","insufficient_coverage"].contains(state) &&
        checkedAt.timeIntervalSince1970.isFinite && baseline.timeIntervalSince1970.isFinite && baseline <= checkedAt &&
        coverage.count <= 1000 && criterion.count <= 500 && nextStep.count <= 500 && (0...20).contains(candidateCount) && (0...candidateCount).contains(linkedCount)
    }
}

/// A bounded read of one explicit followup. Never changes followup/source state,
/// links evidence or runs on the reminder worker. Candidate relevance is not proof.
@MainActor final class FollowupEvidenceReader {
    nonisolated static let name = "check_followup_updates"
    nonisolated static var definition: DeepSeekToolDefinition {
        .init(function:.init(name:name,description:"Read-only: check ONE existing pending followup for remote evidence NEWER than its updated_at baseline. Get exact followup_id from find_followups/current matterFollowups; clarify ambiguous matters. Choose messages OR documents, use both separate calls only if requested/needed. Message query is the exact matter title, last7days; adoc title search then at most one keyword excerpt. Existing exact user-linked sources and unconfirmed title matches are distinct. No hit is scoped, old/unknown-time/partial results cannot prove absence. A candidate is NOT verified fulfillment. Report criterion and next step; never resolve, link or complete anything automatically. No arbitrary query, ID, account fallback or broadening.",parameters:.init(properties:["followup_id":.init(type:"string",description:"Exact pending followup UUID",enumValues:nil),"source":.init(type:"string",description:"One evidence source",enumValues:["messages","documents"]),"profile_id":.init(type:"string",description:"Exact currently selected organization; ambiguous multiple selections require user to name one",enumValues:nil),"keyword":.init(type:"string",description:"Optional document excerpt keyword,1-200 chars; default criterion prefix. Not a search rewrite.",enumValues:nil)],required:["followup_id","source"])))
    }
    private let research: AssistantResearchReader
    private let rules: [MatterFollowup]
    private let targets: [MatterTarget]
    private let links: [DingTalkEvidenceLink]
    private let request: String
    private let scope: @MainActor () -> ([MatterFollowup],[MatterTarget],[DingTalkEvidenceLink])
    init(research: AssistantResearchReader, rules: [MatterFollowup], targets: [MatterTarget], links: [DingTalkEvidenceLink], request: String = "", scope: @escaping @MainActor () -> ([MatterFollowup],[MatterTarget],[DingTalkEvidenceLink])) {
        self.research=research;self.rules=rules;self.targets=targets;self.links=links;self.request=request;self.scope=scope
    }
    private func verify(_ rule: MatterFollowup) throws {
        try Task.checkCancellation()
        let (current,eligible,currentLinks)=scope()
        guard rule.status == "pending", rule.updatedAt.timeIntervalSince1970.isFinite, rule.updatedAt <= Date(),
              current.first(where:{$0.id==rule.id}) == rule, currentLinks==links,
              let target=targets.first(where:{$0.reference==rule.reference}), eligible.contains(target) else { throw DingTalkContentError.invalidResponse }
    }
    private func argumentFailure() -> AssistantReadResult {
        .init(content:"{\"error\":\"invalid_followup_arguments\",\"hint\":\"No remote lookup occurred. Use find_followups and copy exact followup_id (not target_id), source must be messages or documents. Correct this same requested followup within remaining budget; never substitute another matter. No write proposal can follow until check_followup_updates succeeds.\"}",readRepairRequired:true)
    }
    func execute(_ call: DeepSeekToolCall, timeout: TimeInterval) async throws -> AssistantReadResult {
        var rule: MatterFollowup?; var source="messages"
        guard call.function.arguments.utf8.count<=4000,
              var a=(try? JSONSerialization.jsonObject(with:Data(call.function.arguments.utf8))) as? [String:Any] else { return argumentFailure() }
        for key in ["profile_id","keyword"] {
            if a[key] is NSNull || (a[key] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == true { a.removeValue(forKey:key) }
        }
        guard Set(a.keys).isSubset(of:["followup_id","source","profile_id","keyword"]), let raw=a["followup_id"] as? String, let id=UUID(uuidString:raw),
              let found=rules.first(where:{$0.id==id}), let kind=a["source"] as? String, ["messages","documents"].contains(kind),
              (a["profile_id"] == nil || a["profile_id"] is String), (kind=="documents" || a["keyword"] == nil), timeout.isFinite, timeout>0 else { return argumentFailure() }
        let eligible=rules.filter { r in r.status=="pending" && targets.contains { $0.reference==r.reference } }
        let explicitlyIdentified=eligible.filter { request.localizedCaseInsensitiveContains($0.id.uuidString) }
        if !request.isEmpty {
            if !explicitlyIdentified.isEmpty {
                guard explicitlyIdentified.contains(where:{$0.id==found.id}) else { return argumentFailure() }
            } else if eligible.count>1 {
                let titles=eligible.filter { r in request.contains(r.title) || targets.contains { $0.reference==r.reference && request.contains($0.title) } }
                let named=titles.isEmpty ? eligible.filter { $0.waitingFor.count>=2 && request.contains($0.waitingFor) } : titles
                guard named.count==1, named[0].id==found.id else { return argumentFailure() }
            }
        }
        do {
            rule=found;source=kind;try verify(found)
            guard !found.title.isEmpty, found.title.count<=160 else { throw DingTalkContentError.invalidResponse }
            // A remote task cannot silently use a different selected organization.
            var profile = a["profile_id"] as? String
            if found.reference.kind=="external" {
                let matches=research.selectedProfileIDs.filter { found.reference.id.hasPrefix("dingtalk-"+$0+"-") }
                guard matches.count==1, let id=matches.first, profile==nil || profile==id else { throw DingTalkContentError.selectOrganization }
                profile=id
            }
            let started=ProcessInfo.processInfo.systemUptime
            func remaining() throws -> TimeInterval { let t=min(timeout,20)-(ProcessInfo.processInfo.systemUptime-started); guard t>0 else { throw DingTalkCLIError.timedOut }; return t }
            func read(_ name:String,_ args:[String:Any]) async throws -> (AssistantReadResult,[String:Any]) {
                let call=DeepSeekToolCall(id:UUID().uuidString,function:.init(name:name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:args),as:UTF8.self)))
                let output=try await research.execute(call,timeout:remaining());try verify(found)
                guard output.remoteSucceeded==true, let object=try JSONSerialization.jsonObject(with:Data(output.content.utf8)) as? [String:Any] else { throw DingTalkContentError.invalidResponse }
                return (output,object)
            }
            var args:[String:Any]=["query":found.title];if let profile { args["profile_id"]=profile }
            var evidence:[[String:Any]]=[];var citations:[AssistantRemoteSource]=[];var linkedCount=0;var oldCount=0;var unrelatedCount=0;var unknownCount=0
            var adequate=false;var selection=false;var observedCoverage="";var queryCount=0;var candidateTitles:[String]=[];var sourceOrganization=""
            let knownKeys=Set(links.filter{$0.target==found.reference}.map { link in
                DingTalkResearchItem.digest([link.item.profile.id,link.item.kind=="message" ? "message" : "document"] + (link.item.kind=="message" ? [link.item.containerID,link.item.sourceID] : [link.item.sourceID]))
            })
            if kind=="messages" {
                args["days"]=7
                let (result,value)=try await read("search_dingtalk_messages",args)
                sourceOrganization=value["organization"] as? String ?? "未知组织"
                guard let rows=value["items"] as? [[String:Any]], let start=AssistantResearchParser.date(value["range_start"]), let end=AssistantResearchParser.date(value["range_end"]) else { throw DingTalkContentError.invalidResponse }
                adequate=AssistantResearchParser.bool(value["complete"])==true && found.updatedAt>=start && found.updatedAt<end
                observedCoverage="消息关键词「\(found.title)」；\(AssistantFactTime.timestamp(start))至\(AssistantFactTime.timestamp(end))；最多20条；不覆盖全部历史或其他表述"
                queryCount=rows.count
                for row in rows {
                    guard let key=row["source_key"] as? String, let text=row["text"] as? String, let date=AssistantResearchParser.date(row["sent_at"]), let citation=result.remoteSources.first(where:{$0.id==key}) else { throw DingTalkContentError.invalidResponse }
                    guard date>found.updatedAt else { oldCount+=1;continue }
                    let linked=knownKeys.contains(key)
                    if AssistantResearchParser.bool(row["text_truncated"]) != false { adequate=false }
                    guard linked || text.contains(found.title) else { unrelatedCount+=1;continue }
                    if linked { linkedCount+=1 }
                    var item:[String:Any]=["source_key":key,"excerpt":String(text.prefix(1200)),"source_time":AssistantFactTime.timestamp(date),"association":linked ? "user_linked_exact_source" : "title_match_candidate_NOT_verified_matter_identity","sender_identity_verified":false]
                    item["sender"]=row["sender"]
                    evidence.append(item);citations.append(citation)
                }
            } else {
                let (result,value)=try await read("search_dingtalk_documents",args)
                sourceOrganization=value["organization"] as? String ?? "未知组织"
                guard let rows=value["items"] as? [[String:Any]] else { throw DingTalkContentError.invalidResponse }
                adequate=AssistantResearchParser.bool(value["complete"])==true && rows.isEmpty
                queryCount=rows.count;observedCoverage="adoc标题关键词「\(found.title)」；仅本次有限检索，正文关键词片段不覆盖整篇；更新时间不代表具体段落新增时间"
                if rows.count>1 { selection=true;candidateTitles=rows.compactMap { $0["title"] as? String } }
                if rows.count==1 {
                    let row=rows[0]
                    guard let h=row["document_handle"] as? String, let title=row["title"] as? String, let citation=result.remoteSources.first else { throw DingTalkContentError.invalidResponse }
                    let linked=knownKeys.contains(citation.id)
                    if let date=citation.sourceTime, date<=Date(), date>found.updatedAt {
                        if linked || title.contains(found.title) {
                            let keyword: String
                            if let raw=a["keyword"] { guard let k=raw as? String, !k.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, k.count<=200 else { throw DingTalkContentError.invalidResponse };keyword=k }
                            else { keyword=String(found.criterion.prefix(200)) }
                            let (body,excerpt)=try await read("read_dingtalk_document",["document_handle":h,"keyword":keyword])
                            if let text=excerpt["content"] as? String, !text.isEmpty {
                                evidence.append(["source_key":citation.id,"title":title,"excerpt":String(text.prefix(1200)),"source_time":AssistantFactTime.timestamp(date),"association":linked ? "user_linked_exact_source" : "title_match_candidate_NOT_verified_matter_identity","paragraph_novelty_verified":false])
                                citations=body.remoteSources;if linked { linkedCount=1 }
                            }
                        } else { unrelatedCount+=1 }
                    } else if citation.sourceTime == nil || (citation.sourceTime.map { $0>Date() } ?? false) { unknownCount+=1 } else { oldCount+=1 }
                }
            }
            try verify(found)
            let total=evidence.count
            if total>5 || unrelatedCount>0 { adequate=false }
            if !adequate { observedCoverage += "；本次覆盖不足以排除其他新依据" }
            let state=kind=="documents" && total>0 ? "document_changed_excerpt_unverified" : linkedCount>0 ? "new_linked_evidence" : total>0 ? "new_candidates" : selection ? "source_selection_required" : adequate && unknownCount==0 ? "no_new_evidence" : "insufficient_coverage"
            let check=FollowupEvidenceCheck(followupID:found.id,reference:found.reference,revision:found.revision,title:found.title,source:kind,checkedAt:Date(),baseline:found.updatedAt,state:state,coverage:observedCoverage,criterion:found.criterion,nextStep:found.nextStep,candidateCount:total,linkedCount:linkedCount)
            var data:[String:Any]=["checked_at":AssistantFactTime.timestamp(check.checkedAt),"source":kind,"organization":sourceOrganization,"query_title":found.title,"assessment":check.label,"state":state,"followup_id":found.id.uuidString,"baseline":AssistantFactTime.timestamp(found.updatedAt),"coverage":observedCoverage,"coverage_sufficient":adequate,"query_returned":queryCount,"old_results_excluded":oldCount,"unrelated_results_excluded":unrelatedCount,"unknown_time_results":unknownCount,"evidence":Array(evidence.prefix(5)),"evidence_truncated":total>5,"criterion":found.criterion,"next_step":found.nextStep,"waiting_for":found.waitingFor,"criterion_fulfilled":"UNKNOWN_REQUIRES_REVIEW","followup_resolved":false,"source_task_completed":false,"untrusted_source":true]
            if selection { data["candidate_titles"]=candidateTitles;data["hint"]="Multiple documents: ask the user for an exact title; do not read first." }
            return .init(content:String(decoding:try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys]),as:UTF8.self),remoteSources:Array(citations.prefix(5)),followupChecks:[check])
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure="跟进新依据核对未成功或事项/组织范围已变化，结果未知；请核对原事项、组织与读取权限后重试。没有解决跟进或修改源事项。"
            let checks=rule.map { [FollowupEvidenceCheck(followupID:$0.id,reference:$0.reference,revision:$0.revision,title:$0.title,source:source,checkedAt:Date(),baseline:$0.updatedAt,state:"failed",coverage:"读取失败或原跟进/范围发生变化，不使用旧快照替代",criterion:$0.criterion,nextStep:$0.nextStep,candidateCount:0,linkedCount:0)] } ?? []
            return .init(content:"{\"state\":\"failed\",\"criterion_fulfilled\":\"UNKNOWN\"}",remoteSucceeded:false,userFacingFailure:failure,followupChecks:checks.filter(\.isValid))
        }
    }
}

/// A shared waiting person does not uniquely identify a followup matter.
enum FollowupAmbiguityPolicy {
    static func exactFocus(request:String,rules:[MatterFollowup],targets:[MatterTarget])->MatterFollowup? {
        guard request.contains("跟进") || ["新进展","新证据"].contains(where:request.contains) else {return nil}
        let matches=rules.filter{r in r.status=="pending" && targets.contains{$0.reference==r.reference} && (request.localizedCaseInsensitiveContains(r.id.uuidString) || request.localizedCaseInsensitiveContains(r.reference.id) || (!r.title.isEmpty && request.contains(r.title)))}
        return matches.count==1 ? matches[0] : nil
    }
    static func prompt(request:String,rules:[MatterFollowup],targets:[MatterTarget])->String? {
        guard request.contains("跟进"),["新进展","新消息","新证据","核对"].contains(where:request.contains) else {return nil}
        let visible=rules.filter{r in r.status=="pending" && targets.contains{$0.reference==r.reference}}
        let exact=visible.filter{request.localizedCaseInsensitiveContains($0.id.uuidString) || request.localizedCaseInsensitiveContains($0.reference.id) || (!$0.title.isEmpty && request.contains($0.title))}
        if exact.count==1 {return nil}
        let candidates=exact.count>1 ? exact : visible.filter{$0.waitingFor.count>=2 && request.contains($0.waitingFor)}
        guard candidates.count>1 else {return nil}
        let names=candidates.prefix(8).map{"- "+$0.title+"（跟进ID尾号"+String($0.id.uuidString.suffix(8))+"）"}.joined(separator:"\n")
        return "有多个跟进符合这个等待对象，请先选择具体事项标题或精确跟进ID，不会默认第一项，也没有查询远端或解决跟进：\n"+names+(candidates.count>8 ? "\n候选超过8项，请进一步明确事项。" : "")
    }
}
