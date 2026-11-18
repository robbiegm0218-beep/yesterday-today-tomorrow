import Testing
@testable import PersonalAssistant

struct WorkbenchNavigationTests {
    private func task(_ id: String, _ title: String, personal: Bool = true, project: String? = nil) -> TaskItem {
        .init(id: id, title: title, due: "无截止日期", reason: nil, isOverdue: false,
              sourceURL: nil, isPersonal: personal, owner: nil, dueText: nil, sourceQuote: nil, projectName: project)
    }

    @Test func combinedPoolPreservesOrderAndDifferentSourceIdentitiesDespiteSameTitle() {
        let personal = task("personal-a", "准备评审")
        let external = task("dingtalk-org-a", "准备评审", personal: false)
        let remainder = task("personal-b", "补充记录")
        let result = WorkbenchTaskPolicy.visible(priority: [personal], other: [external, personal, remainder], query: "")
        #expect(result.map(\.id) == [personal.id, external.id, remainder.id])
        #expect(WorkbenchTaskPolicy.visible(priority: [personal], other: [external, remainder], query: "", source: .external).map(\.id) == [external.id])
    }

    @Test func searchCanFindAnItemOutsideTopThreeWithoutChangingTheSourcePools() {
        let priority = [task("a", "一"), task("b", "二"), task("c", "三")]
        let remaining = [task("d", "确认字段", project: "LCA接口")]
        let result = WorkbenchTaskPolicy.visible(priority: priority, other: remaining, query: " lca ")
        #expect(result.map(\.id) == ["d"])
        #expect(priority.count == 3 && remaining.count == 1)
    }
}
