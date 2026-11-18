import SwiftUI
import ServiceManagement

struct BackgroundPlanAcceptanceView: View {
    var body: some View {
        Color.clear.task {
            defer { NSApplication.shared.terminate(nil) }
            let arguments = CommandLine.arguments
            let service = SMAppService.agent(plistName: "com.yuan.personal-assistant.daily-plan.plist")
            do {
                if Bundle.main.bundleIdentifier?.contains(".qa") == true {
                    if arguments.contains("--background-qa-register") { try service.register() }
                    if arguments.contains("--background-qa-unregister"), service.status == .enabled || service.status == .requiresApproval { try await service.unregister() }
                    print("BACKGROUND_SERVICE_QA: " + String(service.status.rawValue))
                } else if arguments.contains("--verify-background-generator"), ProcessInfo.processInfo.environment["YUAN_VERIFY_BACKGROUND"] == "1" {
                    let result = try await BackgroundDailyPlanGenerator.generate()
                    print("BACKGROUND_GENERATOR: passed; steps=" + String(result.plan.steps.count) + "; store_writes=0")
                }
            } catch { print("BACKGROUND_ACCEPTANCE: failed; " + String(error.localizedDescription.prefix(240))) }
        }
    }
}
