import Foundation

enum LocalAssistantPaths {
    /// QA bundles use a disposable data root so manual acceptance never touches
    /// the production app's local profile or task data.
    static var dataDirectory: URL {
        let fileManager = FileManager.default
        if let bundleID = Bundle.main.bundleIdentifier, bundleID.contains(".qa") {
            let safeBundleID = bundleID.replacingOccurrences(of: "/", with: "-")
            return fileManager.temporaryDirectory
                .appendingPathComponent("YuanPersonalAssistant-QA-\(safeBundleID)", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YuanPersonalAssistant", isDirectory: true)
    }
}
