import Foundation
import Testing
@testable import PersonalAssistant
struct TimeoutRetryTests {
    func run()->AssistantRun {var r=AssistantRun(originalMessageID:UUID(),requestHash:AssistantRun.digest("prompt"),goal:"prompt",scopeHash:AssistantRun.digest("scope"),messageIDs:[]);r.state = .failed;r.elapsedMilliseconds=90_000;return r}
    @Test func freshRequestOnlyForExplicitFailedRootWithoutReceipts() {
        var r=run();#expect(AssistantChatRetryPolicy.allowsFreshRequest(r))
        r.elapsedMilliseconds=45_000;#expect(!AssistantChatRetryPolicy.allowsFreshRequest(r))
        r.elapsedMilliseconds=90_000;r.parentRunID=UUID();#expect(!AssistantChatRetryPolicy.allowsFreshRequest(r))
        r.parentRunID=nil;r.inFlight=true;#expect(!AssistantChatRetryPolicy.allowsFreshRequest(r))
    }
    @Test func anyOperationReceiptPreventsFreshReplay() {
        for state in ["pending","completed","dismissed","unverified"] {
            var r=run();r.receipts=[.init(actionID:UUID(),messageID:UUID(),key:AssistantRun.digest("op"),summary:"确认卡片",state:state)]
            #expect(!AssistantChatRetryPolicy.allowsFreshRequest(r))
        }
    }
}
