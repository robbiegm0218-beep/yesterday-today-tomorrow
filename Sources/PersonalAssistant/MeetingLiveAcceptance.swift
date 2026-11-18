import SwiftUI

/// Only reachable with an explicit QA bundle command. Never used for production records.
enum MeetingFollowupQAFixture {
    static let source = "评审纪要：小林周五整理接口字段清单。小周准备产品演示材料。"
    static var actions: [ExtractedMeetingAction] { [
        .init(title: "整理接口字段清单", owner: "小林", dueText: "周五", sourceQuote: "小林周五整理接口字段清单", confidence: "高"),
        .init(title: "准备产品演示材料", owner: "小周", dueText: "", sourceQuote: "小周准备产品演示材料", confidence: "高")
    ] }
}

struct MeetingLiveAcceptanceView: View {
    var body: some View {
        Color.clear.task {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_MEETING_ACCEPTANCE"] == "1" else {
                NSApplication.shared.terminate(nil)
                return
            }
            var checks: [String: Bool] = [:]
            var failure = ""
            if let key = DeepSeekCredentialStore.load(), !key.isEmpty {
                do {
                    let source = "评审纪要：行动项只有一条，小林周五整理接口字段清单。"
                    let extracted = try await DeepSeekClient().extractMeetingActions(from: source, apiKey: key)
                    let verified = MeetingActionEvidenceValidator.verified(extracted, against: source)
                    checks["grounded_action_extracted"] = extracted.count == 1 && verified.count == 1
                    if let action = verified.first {
                        let evidence = try MeetingActionEvidence.make(action: action, source: source, title: "合成评审", url: nil)
                        let created = try MeetingFollowupPolicy.saving(action: action, evidence: evidence, targetID: nil, projectName: nil, todos: [])
                        checks["created_with_provenance"] = created.count == 1 && created[0].meetingEvidence == [evidence]
                        var repeated = action
                        repeated.id = UUID()
                        checks["reextraction_idempotent"] = try MeetingFollowupPolicy.saving(action: repeated, evidence: evidence, targetID: nil, projectName: nil, todos: created) == created
                        var done = created[0]
                        done.meetingEvidence = nil
                        done.isComplete = true
                        let linked = try MeetingFollowupPolicy.saving(action: action, evidence: evidence, targetID: done.id, projectName: nil, todos: [done])
                        checks["link_preserves_completed_task"] = linked.count == 1 && linked[0].id == done.id && linked[0].isComplete
                    }
                } catch { failure = error.localizedDescription.replacingOccurrences(of: key, with: "[hidden]") }
            } else { failure = "Saved credential unavailable" }
            let report: [String: Any] = ["checks": checks, "passed": checks.count == 4 && checks.values.allSatisfy { $0 }, "error": failure, "user_store_writes": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("MEETING_ACCEPTANCE: " + text) }
            NSApplication.shared.terminate(nil)
        }
    }
}
