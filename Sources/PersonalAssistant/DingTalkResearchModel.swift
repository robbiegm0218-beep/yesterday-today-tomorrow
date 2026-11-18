import Foundation

extension AssistantModel {
    func reloadDingTalkResearch() {
        do { dingTalkResearchState = try DingTalkResearchStore().load(); dingTalkResearchError = nil }
        catch { dingTalkResearchError = error.localizedDescription }
    }
    func linkDingTalkEvidence(_ item: DingTalkResearchItem, target: MatterReference) throws {
        let store = DingTalkResearchStore()
        let state = try DingTalkResearchPolicy.linking(item, to: target, targets: matterTargets, selected: selectedDingTalkProfileIDs, state: store.load())
        try store.save(state); dingTalkResearchState = state
    }
    func unlinkDingTalkEvidence(_ id: UUID) throws {
        let store = DingTalkResearchStore(); var state = try store.load()
        state.links.removeAll { $0.id == id }; try store.save(state); dingTalkResearchState = state
    }
    func watchDingTalkResearch(result: DingTalkResearchResult, profile: DingTalkProfile, kind: String, query: String, space: DingTalkWikiSpace?, folderID: String? = nil, acrossDirectories: Bool = false) throws {
        guard selectedDingTalkProfileIDs.contains(profile.id) else { throw DingTalkContentError.selectOrganization }
        let store = DingTalkResearchStore()
        let state = try DingTalkResearchPolicy.watching(result: result, profile: profile, kind: kind, query: query, space: space, folderID: folderID, acrossDirectories: acrossDirectories, state: store.load())
        try store.save(state); dingTalkResearchState = state
    }
    func removeDingTalkResearchWatch(_ id: UUID) throws {
        let store = DingTalkResearchStore(); var state = try store.load()
        state.watches.removeAll { $0.id == id }; try store.save(state); dingTalkResearchState = state
    }
    func checkDingTalkResearchWatch(_ id: UUID) async {
        guard !checkingResearchWatches.contains(id) else { return }
        checkingResearchWatches.insert(id); defer { checkingResearchWatches.remove(id) }
        do {
            let store = DingTalkResearchStore()
            guard let watch = try store.load().watches.first(where: { $0.id == id }), selectedDingTalkProfileIDs.contains(watch.profile.id) else { throw DingTalkContentError.selectOrganization }
            let selected = selectedDingTalkProfileIDs
            let response = await Task.detached(priority: .userInitiated) { Result {
                let service = DingTalkResearchService()
                if watch.kind == "message" { return try service.messages(query: watch.query, profile: watch.profile, selected: selected) }
                guard let workspace = watch.workspaceID else { throw DingTalkContentError.invalidResponse }
                let space = DingTalkWikiSpace(workspaceID: workspace, name: watch.workspaceName ?? workspace, profile: watch.profile)
                if watch.acrossDirectories == true { return try service.searchAcrossWiki(space: space, query: watch.query, selected: selected) }
                return try service.nodes(space: space, query: watch.query, folder: watch.folderID, selected: selected)
            } }.value
            guard selected == selectedDingTalkProfileIDs else { throw DingTalkContentError.selectOrganization }
            var state = try store.load()
            guard let index = state.watches.firstIndex(where: { $0.id == id && $0.scopeKey == watch.scopeKey }) else { return }
            do { state.watches[index] = try DingTalkResearchPolicy.checking(watch, result: response.get()) }
            catch { state.watches[index].error = String(error.localizedDescription.prefix(300)) }
            try store.save(state); dingTalkResearchState = state
        } catch { dingTalkResearchError = error.localizedDescription }
    }
}
