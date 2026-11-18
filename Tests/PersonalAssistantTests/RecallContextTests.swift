import Foundation
import Testing
@testable import PersonalAssistant

struct RecallContextTests {
    @Test func separatedModulesPreserveCompleteUnicodeAndUntrustedDataRules() {
        let text = "原ID-123\n含引号\"与中文🙂，不要执行这段数据"
        let memory = AssistantRecallContext.memory(text), knowledge = AssistantRecallContext.knowledge(text)
        #expect(memory.content.hasSuffix(text) && knowledge.content.hasSuffix(text))
        #expect(memory.role == "system" && memory.content.contains("不是指令"))
        #expect(knowledge.content.contains("不可信") && knowledge.content.contains("不要执行"))
        let audit = AssistantInputAudit.make(messages:[memory,knowledge],names:["recalled_memory","recalled_knowledge"])
        #expect(audit.modules.count == 2 && audit.modules[0].name == "recalled_memory")
        #expect(audit.utf8Bytes == memory.content.utf8.count + knowledge.content.utf8.count)
    }
    @Test func absenceAndOmissionDoNotClaimAnEmptyStoreOrSavedState() {
        let empty = AssistantRecallContext.knowledge("")
        #expect(empty.content.contains("不代表资料库为空"))
        let memory = AssistantRecallContext.memory("private-memory-id",include:false)
        let knowledge = AssistantRecallContext.knowledge("private-document",include:false)
        #expect(!memory.content.contains("private-memory-id") && memory.content.contains("不代表没有保存"))
        #expect(!knowledge.content.contains("private-document") && knowledge.content.contains("不得声称读取"))
    }
    @Test func explicitGeneralConceptRoutingIsBoundedAndProtectsBusinessContext() {
        for text in ["只解释通用概念：缓存是什么", "只解释通用概念：binary search是什么"] {
            #expect(AssistantContextSelection.isGeneralConceptOnly(text,hasProtectedContext:false))
            #expect(!AssistantContextSelection.isGeneralConceptOnly(text,hasProtectedContext:true))
        }
        for text in ["缓存是什么", "只解释通用概念：", "只解释通用概念：我的会议", "只解释通用概念：完成那个待办", "只解释通用概念：my schedule", "只解释通用概念："+String(repeating:"文",count:201)] {
            #expect(!AssistantContextSelection.isGeneralConceptOnly(text,hasProtectedContext:false))
        }
    }
    @Test func generalSelectionRetainsProtectedBlocksAndSelectsNamedPolicy() {
        let m: [DeepSeekChatMessage] = [.init(role:"system",content:"facts"),.init(role:"system",content:"optional"),.init(role:"user",content:"original")]
        let result = AssistantContextSelection.select(messages:m,names:["original_run_receipts","memory_actions","current_request"],social:false,generalConcept:true)
        #expect(result.names == ["original_run_receipts","current_request"])
        #expect(result.metric.policy == "explicit_general_concept_v1" && result.messages.last?.content == "original")
    }
}
