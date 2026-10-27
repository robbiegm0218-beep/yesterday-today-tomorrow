import Foundation

struct DingTalkMinute: Identifiable {
    let taskID: String
    let title: String
    let startsAt: Date?
    let sourceURL: URL?
    let organizationName: String?
    let profile: DingTalkProfile
    var id: String { profile.id + ":" + taskID }
}

struct DingTalkDocument: Identifiable {
    let nodeID: String
    let title: String
    let sourceURL: URL?
    var updatedAt: Date?
    let documentType: String
    let profile: DingTalkProfile
    var id: String { profile.id + ":" + nodeID }
}

struct DingTalkDocumentSearch {
    let recommendations: [DingTalkDocument]
    let returnedCount: Int
    let complete: Bool
}

enum DingTalkContentError: LocalizedError {
    case selectOrganization, invalidResponse, incomplete, emptySummary

    var errorDescription: String? {
        switch self {
        case .selectOrganization: "请先在钉钉接入中选择组织。"
        case .invalidResponse: "钉钉返回的数据无法完整核对。请检查组织权限后重试。"
        case .incomplete: "这次查询未完整返回，当前结果不能用于确认全部内容。请缩小日期范围或重试。"
        case .emptySummary: "这条听记没有可读取的摘要。可以在钉钉中查看，或将正文导入纪要提取工具。"
        }
    }
}

enum DingTalkJSON {
    static func decode(_ response: DingTalkCLIResult) throws -> [String: Any] {
        guard response.exitCode == 0,
              let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              root["ok"] as? Bool != false,
              root["success"] as? Bool != false,
              root["success"] as? String != "false",
              root["error"] == nil || root["error"] is NSNull,
              !["failure", "partial_success"].contains(root["outcome"] as? String ?? ""),
              !["failed", "partial_success", "unknown"].contains(root["status"] as? String ?? ""),
              (root["failures"] as? [Any] ?? []).isEmpty else { throw DingTalkContentError.invalidResponse }
        return root
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, number.doubleValue > 0 {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        if let string = value as? String {
            if let raw = Double(string) { return date(NSNumber(value: raw)) }
            let formatter = ISO8601DateFormatter()
            if let parsed = formatter.date(from: string) { return parsed }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string)
        }
        return nil
    }

    static func webURL(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
}

struct DingTalkContentService {
    let client: any DingTalkReading
    init(client: any DingTalkReading = DingTalkCLIClient()) { self.client = client }

    func profiles(selectedIDs: Set<String>) throws -> [DingTalkProfile] {
        guard !selectedIDs.isEmpty else { throw DingTalkContentError.selectOrganization }
        let profiles = try client.listProfiles().filter { selectedIDs.contains($0.id) }
        guard Set(profiles.map(\.id)) == selectedIDs else { throw DingTalkContentError.selectOrganization }
        return profiles
    }

    func minutes(from start: Date, to end: Date, selectedIDs: Set<String>) throws -> [DingTalkMinute] {
        var minutes: [DingTalkMinute] = []
        var seen = Set<String>()
        for profile in try profiles(selectedIDs: selectedIDs) {
            let response = try client.run(.minutes(start: start.ISO8601Format(), end: end.ISO8601Format()), profile: profile)
            let root = try DingTalkJSON.decode(response)
            guard let data = root["data"] as? [String: Any],
                  let records = data["minutes"] as? [[String: Any]], data["complete"] as? Bool == true else { throw DingTalkContentError.incomplete }
            for record in records {
                guard let id = record["taskUuid"] as? String, !id.isEmpty,
                      let title = record["title"] as? String else { throw DingTalkContentError.invalidResponse }
                let minute = DingTalkMinute(taskID: id, title: title.isEmpty ? "未命名听记" : title, startsAt: DingTalkJSON.date(record["startTime"]), sourceURL: DingTalkJSON.webURL(record["url"]), organizationName: record["orgName"] as? String, profile: profile)
                if seen.insert(minute.id).inserted { minutes.append(minute) }
            }
        }
        return minutes.sorted { ($0.startsAt ?? .distantPast) > ($1.startsAt ?? .distantPast) }
    }

    func summary(for minute: DingTalkMinute) throws -> String {
        let response = try client.run(.minutesSummary(id: minute.taskID), profile: minute.profile)
        let root = try DingTalkJSON.decode(response)
        guard root["complete"] as? Bool == true else { throw DingTalkContentError.incomplete }
        // The CLI returns an artifact object for --id and a results array
        // for --ids. Both must still resolve to the requested source exactly.
        let results = (root["results"] as? [[String: Any]]) ?? [root]
        let matches = results.filter { $0["taskUuid"] as? String == minute.taskID }
        guard matches.count == 1, matches[0]["complete"] as? Bool == true,
              let summary = matches[0]["summary"] as? [String: Any],
              summary["success"] as? Bool == true || summary["success"] as? String == "true",
              let data = summary["result"] as? [String: Any], let content = data["fullSummary"] as? String else { throw DingTalkContentError.invalidResponse }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DingTalkContentError.emptySummary }
        return content
    }

    func documents(query: String, selectedIDs: Set<String>) throws -> DingTalkDocumentSearch {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw DingTalkContentError.invalidResponse }
        var documents: [DingTalkDocument] = []
        var seen = Set<String>()
        var complete = true
        for profile in try profiles(selectedIDs: selectedIDs) {
            let response = try client.run(.searchDocuments(query: query), profile: profile)
            let root = try DingTalkJSON.decode(response)
            guard let records = root["documents"] as? [[String: Any]], let finished = root["complete"] as? Bool else { throw DingTalkContentError.invalidResponse }
            complete = complete && finished && root["hasMore"] as? Bool != true
            for record in records {
                guard let id = record["nodeId"] as? String, !id.isEmpty, let title = record["name"] as? String else { throw DingTalkContentError.invalidResponse }
                let document = DingTalkDocument(nodeID: id, title: title, sourceURL: DingTalkJSON.webURL(record["url"]), updatedAt: DingTalkJSON.date(record["modifiedTime"]), documentType: record["docType"] as? String ?? "", profile: profile)
                if seen.insert(document.id).inserted { documents.append(document) }
            }
        }
        var recommendations = Array(documents.prefix(3))
        for index in recommendations.indices where recommendations[index].updatedAt == nil {
            let document = recommendations[index]
            // Search can omit modifiedTime. Enrich metadata for only the three
            // displayed recommendations; failure leaves an explicit unknown.
            if let response = try? client.run(.documentInfo(node: document.nodeID), profile: document.profile),
               let root = try? DingTalkJSON.decode(response), let data = root["result"] as? [String: Any],
               data["nodeId"] as? String == document.nodeID {
                recommendations[index].updatedAt = DingTalkJSON.date(data["updateTime"])
            }
        }
        return DingTalkDocumentSearch(recommendations: recommendations, returnedCount: documents.count, complete: complete)
    }
}
