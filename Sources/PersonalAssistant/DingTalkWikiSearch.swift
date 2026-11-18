import Foundation

extension DingTalkResearchService {
    /// The shortcut's search rows omit workspaceId; independently verify every
    /// displayed row against node metadata before exposing it as an in-space hit.
    func searchAcrossWiki(space: DingTalkWikiSpace, query: String, selected: Set<String>, now: Date = Date()) throws -> DingTalkResearchResult {
        try validate(space.profile, selected: selected)
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 200 else { throw ProjectUpdateError.invalid("请输入1–200字的跨目录检索关键词。") }
        let root = try DingTalkJSON.decode(client.run(.searchWiki(workspace: space.workspaceID, query: cleaned), profile: space.profile))
        guard let data = root["data"] as? [String: Any], let rows = data["nodes"] as? [[String: Any]], data["count"] as? Int == rows.count,
              let complete = data["autoPageComplete"] as? Bool else { throw DingTalkContentError.invalidResponse }
        var items: [DingTalkResearchItem] = []; var seen = Set<String>()
        for row in rows.prefix(50) {
            guard let id = row["nodeId"] as? String, !id.isEmpty, seen.insert(id).inserted else { throw DingTalkContentError.invalidResponse }
            let detail = try DingTalkJSON.decode(client.run(.wikiNodeInfo(node: id), profile: space.profile))
            guard let node = detail["data"] as? [String: Any], node["nodeId"] as? String == id,
                  node["workspaceId"] as? String == space.workspaceID, node["success"] as? Bool == true,
                  let name = node["name"] as? String, let searchedName = row["name"] as? String, name == searchedName else { throw ProjectUpdateError.invalid("搜索结果的知识库归属或标题已变化，未将未核对资料显示为库内命中。请重新检索。") }
            let type = node["extension"] as? String ?? node["type"] as? String ?? "未知类型"
            let time = DingTalkJSON.date(node["updateTime"])
            let url = DingTalkJSON.webURL(node["url"] ?? node["docUrl"])
            items.append(.init(kind: "wiki", profile: space.profile, sourceID: id, containerID: space.workspaceID, title: String(name.prefix(500)), excerpt: "知识库：\(space.name) · 类型：\(type)", sourceURL: url, sourceTime: time,
                fingerprint: DingTalkResearchItem.digest([name, type, time.map { String($0.timeIntervalSince1970) } ?? "unknown", url?.absoluteString ?? ""]), isFolder: type == "folder" || node["hasChildren"] as? Bool == true))
        }
        return .init(items: items, returnedCount: rows.count, complete: complete && data["hasMore"] as? Bool == false && rows.count <= 50,
                     checkedAt: now, start: nil, end: nil)
    }
}
