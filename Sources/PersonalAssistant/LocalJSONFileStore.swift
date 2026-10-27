import Foundation

struct LocalDataFileDiagnostic: Identifiable, Equatable {
    enum Kind: Equatable { case recovered, restoreWriteFailed, unrecoverable, writeBlocked }

    let fileName: String
    let kind: Kind

    var id: String { "\(kind)-\(fileName)" }

    var message: String {
        switch kind {
        case .recovered:
            "「\(fileName)」无法读取，已从最近有效副本恢复。建议确认内容后导出一份备份。"
        case .restoreWriteFailed:
            "「\(fileName)」的恢复副本可读取，但暂时无法写回主文件；本次启动仍可读取副本。请检查磁盘空间或文件权限后重启重试。"
        case .unrecoverable:
            "「\(fileName)」和恢复副本均无法读取。原文件已保留；相关内容可能暂时不可用，请先导出仍可读取的数据，再联系开发者恢复。"
        case .writeBlocked:
            "「\(fileName)」存在无法读取的数据，予安已阻止覆盖以保留原文件。相关修改暂未保存。"
        }
    }
}

/// Atomic JSON persistence with a last-known-good recovery copy.
/// A corrupt primary file is never promoted over the backup.
enum LocalJSONFileStore {
    private static let diagnosticBuffer = LocalDataDiagnosticBuffer()

    static func load<Value: Decodable>(from url: URL, as type: Value.Type = Value.self) -> Value? {
        let backupURL = backupURL(for: url)
        if let data = try? Data(contentsOf: url) {
            if let value = try? JSONDecoder().decode(type, from: data) { return value }
            NSLog("Local data file is unreadable; checking recovery copy: %@", url.path)
        } else if !FileManager.default.fileExists(atPath: url.path) {
            return restoreBackup(at: backupURL, to: url, as: type)
        }

        guard let value = restoreBackup(at: backupURL, to: url, as: type) else {
            NSLog("No valid recovery copy was found for local data: %@", url.path)
            diagnosticBuffer.append(LocalDataFileDiagnostic(fileName: url.lastPathComponent, kind: .unrecoverable))
            return nil
        }
        return value
    }

    static func save<Value: Codable>(_ value: Value, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        let backupURL = backupURL(for: url)

        if let previousData = try? Data(contentsOf: url) {
            if (try? JSONDecoder().decode(Value.self, from: previousData)) == nil {
                guard let backupData = try? Data(contentsOf: backupURL),
                      (try? JSONDecoder().decode(Value.self, from: backupData)) != nil else {
                    diagnosticBuffer.append(LocalDataFileDiagnostic(fileName: url.lastPathComponent, kind: .writeBlocked))
                    throw LocalJSONFileStoreError.unrecoverableExistingData(url.lastPathComponent)
                }
                try backupData.write(to: url, options: .atomic)
                diagnosticBuffer.append(LocalDataFileDiagnostic(fileName: url.lastPathComponent, kind: .recovered))
                try backupData.write(to: backupURL, options: .atomic)
            } else {
                // Preserve the previous state only when it is known to be valid.
                try previousData.write(to: backupURL, options: .atomic)
            }
        }
        try data.write(to: url, options: .atomic)
    }

    static func takeDiagnostics() -> [LocalDataFileDiagnostic] {
        diagnosticBuffer.takeAll()
    }

    private static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("backup")
    }

    private static func restoreBackup<Value: Decodable>(at backupURL: URL, to url: URL, as type: Value.Type) -> Value? {
        guard let data = try? Data(contentsOf: backupURL),
              let value = try? JSONDecoder().decode(type, from: data) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            NSLog("Recovered local data from backup: %@", url.path)
            diagnosticBuffer.append(LocalDataFileDiagnostic(fileName: url.lastPathComponent, kind: .recovered))
        } catch {
            NSLog("Could not restore local data backup %@: %@", url.path, error.localizedDescription)
            diagnosticBuffer.append(LocalDataFileDiagnostic(fileName: url.lastPathComponent, kind: .restoreWriteFailed))
        }
        return value
    }
}

enum LocalJSONFileStoreError: LocalizedError {
    case unrecoverableExistingData(String)

    var errorDescription: String? {
        switch self {
        case let .unrecoverableExistingData(fileName):
            "本机文件「\(fileName)」无法读取且没有有效恢复副本；为避免覆盖原始数据，本次保存已取消。"
        }
    }
}

private final class LocalDataDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var diagnostics: [LocalDataFileDiagnostic] = []

    func append(_ diagnostic: LocalDataFileDiagnostic) {
        lock.lock()
        defer { lock.unlock() }
        if !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
    }

    func takeAll() -> [LocalDataFileDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        let result = diagnostics
        diagnostics.removeAll()
        return result
    }
}
