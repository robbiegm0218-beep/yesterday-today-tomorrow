import Foundation
import Testing
@testable import PersonalAssistant

struct KnowledgeFileImportTests {
    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    @Test func selectedFileDoesNotReadSiblingAndRefreshesChangedText() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let selected = folder.appendingPathComponent("selected.md")
        try "资料验收：第一版规划".write(to: selected, atomically: true, encoding: .utf8)
        try "不应导入的相邻文件".write(to: folder.appendingPathComponent("private.txt"), atomically: true, encoding: .utf8)
        let first = try LocalDocumentIndexer.indexWithReport(folderPath: selected.path, singleFile: true)
        #expect(first.documents.count == 1)
        #expect(first.documents.first?.urlPath == selected.path)
        try "资料验收：第二版规划，内容发生变化".write(to: selected, atomically: true, encoding: .utf8)
        let second = try LocalDocumentIndexer.indexWithReport(folderPath: selected.path, existing: first.documents, singleFile: true)
        #expect(second.documents.first?.content.contains("第二版") == true)
        let base = LocalKnowledgeBase(name: "单篇", folderPath: selected.path, documents: second.documents, isSingleFile: true)
        #expect(LocalKnowledgeSearch.search(for: "第二版规划", bases: [base]).sources.count == 1)
    }
    @Test func unsupportedFileOrMissingSourceCannotPretendSuccessfulImport() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("unsupported.pdf")
        try Data("unsupported".utf8).write(to: pdf)
        #expect(throws: (any Error).self) { try LocalDocumentIndexer.indexWithReport(folderPath: pdf.path, singleFile: true) }
        #expect(throws: (any Error).self) { try LocalDocumentIndexer.indexWithReport(folderPath: folder.appendingPathComponent("missing.md").path, singleFile: true) }
    }
    @Test func wordCanBeSelectedAsOneFile() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/minutes.docx")
        let report = try LocalDocumentIndexer.indexWithReport(folderPath: fixture.path, singleFile: true)
        #expect(report.documents.count == 1)
        #expect(report.documents.first?.content.isEmpty == false)
    }
    @Test func oldFolderAndNewSingleFileRoundTripWithoutExportingAuthorization() throws {
        let base = LocalKnowledgeBase(name: "文档", folderPath: "/materials/test.md", folderBookmark: Data("private authorization".utf8), isSingleFile: true)
        let roundTrip = try JSONDecoder().decode(LocalKnowledgeBase.self, from: JSONEncoder().encode(base))
        #expect(roundTrip.isSingleFile == true)
        let exported = try JSONEncoder().encode(LocalAssistantDataExport.KnowledgeBase(base))
        let object = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        #expect(object["isSingleFile"] as? Bool == true)
        #expect(object["folderBookmark"] == nil)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        old.removeValue(forKey: "isSingleFile")
        let decoded = try JSONDecoder().decode(LocalKnowledgeBase.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.isSingleFile == nil)
    }
}
