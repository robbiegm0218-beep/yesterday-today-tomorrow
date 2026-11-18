import Foundation

/// Literal original-list corrections can be bound without asking a model to guess IDs.
/// The ordinary model reference interpreter remains available for other expressions.
enum ReferenceExclusion {
    struct Plan {
        let excluded:[Int]
        let included:Int?
        let question:String
        let explicitOriginal:Bool
    }
    enum Parsed { case none, plan(Plan), invalid(String) }
    private static let ordinal = "第[一二三四五六七八九十0-9]+[个项条]"
    private static func prefix(_ pattern:String,_ text:String)->String? {
        guard let regex=try? NSRegularExpression(pattern:pattern),let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),match.range.location==0,let range=Range(match.range,in:text) else {return nil}
        return String(text[range])
    }
    private static func positions(_ text:String)->[Int]? {
        guard let regex=try? NSRegularExpression(pattern:ordinal) else {return nil}
        let matches=regex.matches(in:text,range:NSRange(text.startIndex...,in:text))
        var values:[Int]=[]
        for match in matches {
            guard let range=Range(match.range,in:text) else {return nil}
            var token=String(text[range]);token.removeLast();token += "个"
            guard let value=AssistantConversationFocus.ordinal(token),(1...6).contains(value) else {return nil}
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }
    private static func trim(_ text:String)->String {text.trimmingCharacters(in:CharacterSet(charactersIn:" ，,；;：:。\n"))}
    static func parse(_ request:String)->Parsed {
        var rest=trim(request),excluded:[Int]=[],explicitOriginal=false
        if let header=prefix("^原列表(?:里|中|的)?[，,：: ]*",rest) {rest=trim(String(rest.dropFirst(header.count)));explicitOriginal=true}
        let negative="^(?:也不是|不是|不要|不选|别选|排除|除了)(?:原列表(?:中|里|的)?|列表(?:中|里|的)?)?"+ordinal+"(?:(?:和|与|、|以及)"+ordinal+")*(?:以外|之外|后)?"
        while let part=prefix(negative,rest) {
            guard let numbers=positions(part) else {return .invalid("排除编号须为原列表的1—6项，未忽略无效编号。")}
            excluded += numbers;explicitOriginal = explicitOriginal || part.contains("原列表")
            rest=trim(String(rest.dropFirst(part.count)))
        }
        guard !excluded.isEmpty else {
            if prefix("^(?:不是|不要|不选|别选|排除|除了).{0,12}"+ordinal,rest) != nil {return .invalid("请明确排除原列表的哪一项；状态子集和原列表的编号不能混用。")}
            return .none
        }
        guard Set(excluded).count==excluded.count,excluded.count<=5 else {return .invalid("排除项重复或过多，请明确原列表中不同的编号。")}
        var included:Int?
        if let part=prefix("^(?:是|问|看看|换成|改成|改为|我说的是|要的是)(?:原列表(?:中|里|的)?)?"+ordinal,rest) {
            guard let number=positions(part)?.first else {return .invalid("改选编号须为原列表的1—6项，未忽略无效编号。")}
            included=number
            rest=trim(String(rest.dropFirst(part.count)))
            if rest.hasPrefix("的") {rest=String(rest.dropFirst())}
        }
        if prefix(".*"+ordinal,rest) != nil {return .invalid("本句仍含未明确的编号或排除条件，请明确一个目标；没有忽略其余编号。")}
        if let included,excluded.contains(included) {return .invalid("同一项同时被排除和选中，请明确要讨论哪一项。")}
        let open=request.contains("未完成") || request.contains("没完成")
        if (open || request.contains("已完成")) && !explicitOriginal {return .invalid("请说明排除/改选的是原列表编号，还是未完成子集编号；未默认选择。")}
        if open && request.contains("已完成") {return .invalid("完成状态条件相互冲突，请明确保留哪些项。")}
        return .plan(.init(excluded:excluded,included:included,question:rest,explicitOriginal:explicitOriginal))
    }
    static func staysInOriginalList(messages:[AssistantMessage],context:AssistantReadContext)->Bool {
        guard let user=messages.last,user.isUser,!GoalStagePlanning.requested(user.text) else {return false}
        if case .none=parse(user.text) {return false}
        let targets=MatterContextPolicy.targets(todos:context.todos,projects:context.projects,external:context.external.filter{!$0.isPersonal && !context.hidden.contains($0.id) && WorkbenchArchivePolicy.belongsToSelectedOrganization($0.id,selected:context.selected)})
        // Explicitly naming a different matter retains the original discovery path.
        guard !targets.contains(where:{user.text.contains($0.reference.id) || ($0.title.count>=2 && user.text.contains($0.title))}) else {return false}
        return SemanticReferenceContext.make(messages:messages,context:context) != nil
    }
    static func questionTail(_ request:String)->String? {
        guard case let .plan(plan)=parse(request),!plan.question.isEmpty else {return nil};return plan.question
    }
    static func resolution(_ plan:Plan,reference:SemanticReferenceContext)->SemanticReferenceResolution {
        func result(_ status:String,_ rows:[SemanticReferenceCandidate],_ reason:String)->SemanticReferenceResolution {.init(status:status,candidates:rows,original:reference.rows.map(\.reference),reason:reason)}
        guard !reference.unavailable,!reference.rows.isEmpty,plan.excluded.allSatisfy({p in reference.rows.contains{$0.position==p}}),plan.included.map({p in reference.rows.contains{$0.position==p}}) ?? true else {return result("unknown",[],"原列表过期、范围变化、原ID不可用或编号不在原列表内；没有按剩余顺序滑位。")}
        let request=reference.request
        let state=request.contains("未完成") || request.contains("没完成") ? false : request.contains("已完成") ? true : nil
        if state != nil,reference.rows.contains(where:{$0.localComplete==nil}) {return result("unknown",[],"列表含未核实当前完成字段的来源，不能当作本地完成状态筛选。")}
        let matches=reference.rows.filter{!plan.excluded.contains($0.position) && (plan.included==nil || plan.included==$0.position) && (state==nil || $0.localComplete==state)}
        return result(matches.count==1 ? "resolved":matches.isEmpty ? "unknown":"ambiguous",matches,matches.count==1 ? "已按原列表编号排除/改选并核对原ID。":matches.isEmpty ? "没有同时满足原编号与状态条件的事项。":"排除后仍有多项，请按下面新的澄清列表选择；原问题已保留。")
    }
}
