import AppKit
import UserNotifications

final class AssistantApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var foregroundRevealObserver: NSObjectProtocol?
    // Keep the SwiftUI action after the last window closes: a running process
    // is not evidence that the user has an accessible main window.
    @MainActor static var openMainWindow: (() -> Void)?
    @MainActor static func revealMainWindow() {
        guard !CommandLine.arguments.contains("--daily-plan-worker"),
              !CommandLine.arguments.contains("--dingtalk-event-worker") else { return }
        let app = NSApplication.shared
        if let window = app.windows.first(where: { $0.identifier?.rawValue.hasPrefix("assistant-main") == true && !($0 is NSPanel) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else { openMainWindow?() }
        app.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.revealMainWindow()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        foregroundRevealObserver = DistributedNotificationCenter.default().addObserver(forName: .init("yuan.foreground.reveal"), object: Bundle.main.bundleIdentifier, queue: .main) { _ in
            MainActor.assumeIsolated {
                Self.revealMainWindow()
                if AssistantRuntime.preferences.bool(forKey: "pendingNotificationWorkbench") {
                    NotificationCenter.default.post(name: .init("yuan.notification.workbench"), object: nil)
                }
            }
        }
        if !CommandLine.arguments.contains("--daily-plan-worker") && !CommandLine.arguments.contains("--dingtalk-event-worker") { UNUserNotificationCenter.current().delegate = self }
        guard !CommandLine.arguments.contains("--daily-plan-worker") && !CommandLine.arguments.contains("--dingtalk-event-worker"),
              let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        // AppKit installs its initial application icon during launch. Assigning
        // this from App.init happens too early and can be overwritten.
        NSApplication.shared.applicationIconImage = icon
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier.hasPrefix(ActiveReminderPolicy.prefix) {
            DispatchQueue.main.async {
                AssistantRuntime.preferences.set(true, forKey: "pendingNotificationWorkbench")
                Self.revealMainWindow()
                NotificationCenter.default.post(name: Notification.Name("yuan.notification.workbench"), object: nil)
            }
        }
        completionHandler()
    }

    static func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationName: "昨天今天明天"]
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            options[.applicationIcon] = image
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }
}
