import Foundation
import Testing
@testable import PersonalAssistant

struct ContextSelectionTests {
    @Test func onlyCompleteSocialRequestsQualifyAndProtectedContextWins() {
        for text in ["你好", "你好！", "  Thanks! ", "晚安。", "谢谢你"] {
            #expect(AssistantContextSelection.isSocialOnly(text, hasProtectedContext: false))
            #expect(!AssistantContextSelection.isSocialOnly(text, hasProtectedContext: true))
        }
        for text in ["你好，今天几个会议", "谢谢，继续本任务", "好的", "确认", "谢谢，完成那个", "你好？", "什么是缓存", "仅以本条为准：你好"] {
            #expect(!AssistantContextSelection.isSocialOnly(text, hasProtectedContext: false))
        }
    }
    @Test func socialSelectionPreservesCurrentHistoryPreferenceAndReceipts() {
        let names = ["recent_history", "workbench", "temporary_preference", "dialogue_receipts_focus", "original_run_receipts", "memory_actions", "external_mutation_targets", "remote_research", "current_request"]
        let messages = names.map { DeepSeekChatMessage(role: $0 == "current_request" ? "user" : "system", content: "exact-" + $0) }
        let result = AssistantContextSelection.select(messages: messages, names: names, social: true)
        #expect(result.metric.omittedOptionalMessages == 3 && result.messages.count == 6)
        #expect(result.names == Array(names.prefix(5)) + ["current_request"])
        #expect(result.messages.last?.content == messages.last?.content)
        #expect(result.names.contains("workbench") && result.names.contains("original_run_receipts"))
        #expect(messages.count == 9)
    }
    @Test func exactOptionalDuplicatesOnlyNeverMergeProtectedOrHistoryMessages() {
        let m: [DeepSeekChatMessage] = [.init(role:"system",content:"same"),.init(role:"system",content:"same"),.init(role:"system",content:"same"),.init(role:"user",content:"same"),.init(role:"system",content:"same ")]
        let r = AssistantContextSelection.select(messages:m,names:["memory_actions","remote_research","original_run_receipts","current_request","external_mutation_targets"],social:false)
        #expect(r.metric.duplicateOptionalMessages == 1 && r.messages.count == 4)
        #expect(r.names.contains("original_run_receipts") && r.names.contains("current_request"))
        #expect(r.messages.last?.content == "same ")
    }
    @Test func toolMetadataAndUnlabelledMessagesAreNeverDiscarded() {
        let messages: [DeepSeekChatMessage] = [.init(role:"system",content:"same",toolCallID:"original-tool-id"),.init(role:"system",content:"same",toolCalls:[])]
        let result = AssistantContextSelection.select(messages:messages,names:["memory_actions","memory_actions"],social:true)
        #expect(result.messages.count == 2 && result.metric.omittedOptionalMessages == 0)
        let fallback = AssistantContextSelection.select(messages:messages,names:[],social:true)
        #expect(fallback.messages.count == 2 && fallback.metric.policy == "unlabelled_full_fallback")
    }
    @Test func businessAndUncertainTurnsKeepAllDistinctFacts() {
        let names = ["workbench","stage_facts","original_run_receipts","memory_actions","remote_research"]
        let m = names.map { DeepSeekChatMessage(role:"system",content:$0) }
        let r = AssistantContextSelection.select(messages:m,names:names,social:false)
        #expect(r.names == names && r.metric.omittedUTF8Bytes == 0 && r.metric.policy == "full_business_context")
    }
    @Test func compactWorkbenchIsSmallerAndExplicitlyUnknownRatherThanEmpty() {
        let now = Date(timeIntervalSince1970:1_700_000_000)
        let todos = (0..<40).map { PersonalTodo(title:"synthetic-private-title-\($0)",dueAt:nil,importance:.normal) }
        let full = AssistantChatWorkbenchContext.message(personalTodos:todos,projects:[],externalSnapshot:nil,lastSync:nil,isSyncing:false,syncError:nil,now:now)
        let compact = AssistantContextSelection.socialWorkbench(now:now)
        #expect(compact.content.utf8.count < full.content.utf8.count / 2)
        #expect(compact.content.contains("不代表没有待办") && compact.content.contains("历史答复不能"))
        #expect(!compact.content.contains(todos[0].id.uuidString) && !compact.content.contains(todos[0].title))
    }
    @Test func metricsContainNoContentAndRetainExactByteAccounting() throws {
        let secret = "private-id-秘密🙂"
        let m: [DeepSeekChatMessage] = [.init(role:"system",content:secret),.init(role:"system",content:secret)]
        let r = AssistantContextSelection.select(messages:m,names:["memory_actions","remote_research"],social:false)
        #expect(r.metric.omittedUTF8Bytes == secret.utf8.count)
        let encoded = try JSONEncoder().encode(r.metric)
        #expect(!String(decoding:encoded,as:UTF8.self).contains(secret))
        #expect(try JSONDecoder().decode(AssistantContextSelectionMetric.self,from:encoded) == r.metric)
    }
}
