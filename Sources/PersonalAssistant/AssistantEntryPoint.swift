import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

/// Route real background jobs before SwiftUI can restore or construct a window.
@main
@MainActor
enum AssistantEntryPoint {
    static func main() {
        if let role = AssistantWorkerRole.resolve(CommandLine.arguments) {
            AssistantHeadlessHost.run(role)
        } else {
            PersonalAssistantApp.main()
        }
    }
}

enum AssistantWorkerRole: String, Codable {
    case dailyPlan = "daily-plan"
    case dingTalkEvents = "dingtalk-events"
    case dialogueAcceptance = "dialogue-acceptance"
    case recallAcceptance = "recall-acceptance"
    case agentScenario = "agent-scenario"

    static func resolve(_ arguments: [String]) -> Self? {
        if arguments.contains("--dingtalk-event-worker") { return .dingTalkEvents }
        if arguments.contains("--daily-plan-worker") { return .dailyPlan }
        if arguments.contains("--verify-dialogue-context") { return .dialogueAcceptance }
        if arguments.contains("--verify-context-recall") { return .recallAcceptance }
        if arguments.contains("--verify-agent-scenario") { return .agentScenario }
        return nil
    }
}

struct AssistantWorkerDiagnostic: Codable {
    let role: AssistantWorkerRole
    let pid: Int32
    let startedAt: Date
    var finishedAt: Date?
    var windowCountAtStart: Int
    var windowCountAtFinish: Int?
    var activationPolicy: Int
    var outcome: String?
}

@MainActor
private enum AssistantHeadlessHost {
    static func run(_ role: AssistantWorkerRole) {
        if role == .agentScenario {
            guard ProcessInfo.processInfo.environment["YUAN_RUN_AGENT_ACCEPTANCE"] == "1" else { return }
            do { _ = try AssistantRuntime.beginEvaluation() }
            catch { print("AGENT_EVALUATION: isolation_rejected"); return }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = AssistantHeadlessDelegate(role: role)
        app.delegate = delegate
        // No SwiftUI App, scene, Window or AssistantModel is initialized here.
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class AssistantHeadlessDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let role: AssistantWorkerRole
    private var diagnostic: AssistantWorkerDiagnostic
    private var task: Task<Void, Never>?
    private var openingForeground = false
    private var isQA: Bool { Bundle.main.bundleIdentifier?.contains(".qa") == true }

    init(role: AssistantWorkerRole) {
        self.role = role
        diagnostic = .init(role: role, pid: ProcessInfo.processInfo.processIdentifier, startedAt: Date(), windowCountAtStart: 0, activationPolicy: NSApplication.ActivationPolicy.prohibited.rawValue)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        diagnostic.windowCountAtStart = NSApplication.shared.windows.count
        writeDiagnostic()
        if role == .dailyPlan { UNUserNotificationCenter.current().delegate = self }
        task = Task {
            let outcome: String
            switch role {
            case .agentScenario:
                let passed = await AgentScenarioAcceptance.run()
                outcome = AgentScenarioAcceptance.didCheckpoint ? "checkpoint" : passed ? "passed" : "failed"
            case .recallAcceptance:
                outcome = await RecallLiveAcceptance.run() ? "passed" : "failed"
            case .dialogueAcceptance:
                outcome = await DialogueLiveAcceptance.run() ? "passed" : "failed"
            case .dailyPlan:
                outcome = await runDailyPlan()
            case .dingTalkEvents:
                if !isQA && (Bundle.main.bundleIdentifier == "com.yuan.personal-assistant.event-worker" || SMAppService.agent(plistName: "com.yuan.personal-assistant.message-receiver.plist").status == .enabled) {
                    await DingTalkEventWorker().run()
                    outcome = "stopped"
                } else { outcome = "not-registered" }
            }
            // Only isolated QA bundles may hold the event loop for window observations.
            if isQA, let seconds = Int(ProcessInfo.processInfo.environment["YUAN_HEADLESS_QA_HOLD_SECONDS"] ?? ""), (1...15).contains(seconds) {
                try? await Task.sleep(for: .seconds(seconds))
            }
            diagnostic.finishedAt = Date()
            diagnostic.windowCountAtFinish = NSApplication.shared.windows.count
            diagnostic.activationPolicy = NSApplication.shared.activationPolicy().rawValue
            diagnostic.outcome = outcome
            writeDiagnostic()
            print("HEADLESS_WORKER_RESULT: " + outcome)
            fflush(stdout)
            NSApplication.shared.terminate(nil)
        }
    }

    private func runDailyPlan() async -> String {
        let qaFixture = isQA && ProcessInfo.processInfo.environment["YUAN_BACKGROUND_QA_GENERATOR"] == "1"
        guard qaFixture || SMAppService.agent(plistName: "com.yuan.personal-assistant.daily-plan.plist").status == .enabled else { return "not-registered" }
        let outcome: String
        if qaFixture {
            outcome = await BackgroundDailyPlanRunner.shared.run(trigger: "launchd", generate: {
                let now = Date()
                return .init(generatedAt: now, sourceLabel: "隔离系统定时验收", plan: .init(day: DailyPlanSchedulePolicy.dayKey(for: now), timeZone: TimeZone.current.identifier, steps: [.init(title: "后台定时验收")]))
            })
        } else {
            outcome = await BackgroundDailyPlanRunner.shared.run(trigger: "launchd")
        }
        print("BACKGROUND_PLAN_RESULT: " + outcome)
        // Keep the existing main-bundle notification identity, permission and quota.
        if !isQA { print("ACTIVE_REMINDER_RESULT: " + (await ActiveReminderRunner.shared.synchronize())) }
        return outcome
    }

    private func writeDiagnostic() {
        let url = LocalAssistantPaths.dataDirectory.appendingPathComponent("worker-\(role.rawValue)-diagnostic.json")
        do { try LocalJSONFileStore.save(diagnostic, to: url) }
        catch { NSLog("Could not save background worker diagnostic: %@", error.localizedDescription) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealForeground()
        return false
    }

    private func revealForeground() {
        guard role == .dailyPlan, !isQA, !openingForeground else { return }
        let identifier = Bundle.main.bundleIdentifier ?? "com.yuan.personal-assistant"
        if let foreground = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular && $0.bundleURL == Bundle.main.bundleURL }) {
            DistributedNotificationCenter.default().postNotificationName(.init("yuan.foreground.reveal"), object: identifier, userInfo: nil, deliverImmediately: true)
            foreground.activate(options: [.activateIgnoringOtherApps])
        } else {
            openingForeground = true
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, _ in
                Task { @MainActor in self?.openingForeground = false }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier.hasPrefix(ActiveReminderPolicy.prefix) {
            Task { @MainActor in
                AssistantRuntime.preferences.set(true, forKey: "pendingNotificationWorkbench")
                revealForeground()
            }
        }
        completionHandler()
    }
}
