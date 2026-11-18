import Foundation
import Testing
@testable import PersonalAssistant

struct AssistantReadToolsTests {
    func call(_ name: String, _ args: [String: Any]) throws -> DeepSeekToolCall {
        .init(id: "synthetic", function: .init(name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
    }
    @Test func mattersBeyondInitialPrefixUseExactIDsAndConfirmedHistory() throws {
        let todos = (0..<60).map { PersonalTodo(title: "合成任务\($0)", dueAt: nil, importance: .normal) }
        let target = todos[59]
        let entry = MatterContextEntry(reference: .personal(target.id), category: "阻塞", content: "等待字段确认", quote: "等待字段确认", sourceMessageID: nil, recordedAt: Date())
        let context = AssistantReadContext(todos: todos, entries: [entry])
        let found = try context.execute(call("find_matter", ["query": "任务59"]))
        #expect(found.content.contains(target.id.uuidString))
        let read = try context.execute(call("read_matter", ["kind": "personal", "target_id": target.id.uuidString]))
        #expect(read.content.contains("等待字段确认") && read.content.contains("未完成"))
        let denied = try context.execute(call("read_matter", ["kind": "personal", "target_id": "合成任务59"]))
        #expect(denied.content.contains("target_unavailable"))
        let remote = try context.execute(call("read_matter", ["kind": "external", "target_id": "dingtalk-other-secret"]))
        #expect(remote.content.contains("target_unavailable"))
    }
    @Test func indexedDocumentsArePagedAndCannotReadArbitraryPaths() throws {
        let document = KnowledgeDocument(urlPath: "/synthetic/only-index.md", title: "合成索引", content: "唯一字段 " + String(repeating: "文", count: 5000), indexedAt: Date(), modifiedAt: nil, fileSize: nil)
        let context = AssistantReadContext(bases: [.init(name: "合成库", folderPath: "/synthetic", documents: [document])])
        let search = try context.execute(call("search_local_knowledge", ["query": "唯一字段"]))
        #expect(search.sources.count == 1)
        let key = DingTalkResearchItem.digest([document.urlPath])
        let page = try context.execute(call("read_local_knowledge", ["document_key": key]))
        let body = try #require(JSONSerialization.jsonObject(with: Data(page.content.utf8)) as? [String: Any])
        #expect((body["content"] as? String)?.count == 4000 && body["next_offset"] as? Int == 4000)
        #expect(page.sources == search.sources)
        let denied = try context.execute(call("read_local_knowledge", ["document_key": "/etc/passwd"]))
        #expect(denied.content.contains("document_unavailable"))
        let invalid = try context.execute(call("read_local_knowledge", ["document_key": key, "offset": -1]))
        #expect(invalid.content.contains("invalid_offset"))
    }
    @Test func remoteScopeHidingAndFreshnessRemainExplicit() throws {
        let allowed = TodoRecord(id: "dingtalk-org:user-one", title: "授权事项", dueAt: nil, importance: .normal, projectName: nil, sourceURL: nil, isComplete: false)
        let hidden = TodoRecord(id: "dingtalk-org:user-two", title: "隐藏事项", dueAt: nil, importance: .normal, projectName: nil, sourceURL: nil, isComplete: false)
        let other = TodoRecord(id: "dingtalk-other:user-three", title: "未选组织事项", dueAt: nil, importance: .normal, projectName: nil, sourceURL: nil, isComplete: false)
        let context = AssistantReadContext(external: [allowed, hidden, other], selected: ["org:user"], hidden: [hidden.id], externalFailed: true)
        let found = try context.execute(call("find_matter", ["query": ""]))
        #expect(found.content.contains("授权事项") && !found.content.contains("隐藏事项") && !found.content.contains("未选组织事项"))
        let read = try context.execute(call("read_matter", ["kind": "external", "target_id": allowed.id]))
        #expect(read.content.contains("synchronized_snapshot_not_live") && read.content.contains("requires_refresh"))
        for id in [hidden.id, other.id] {
            let result = try context.execute(call("read_matter", ["kind": "external", "target_id": id]))
            #expect(result.content.contains("target_unavailable"))
        }
    }

}
