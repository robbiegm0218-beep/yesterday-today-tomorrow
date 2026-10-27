import AppKit

final class AssistantApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--daily-plan-worker"),
              let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        // AppKit installs its initial application icon during launch. Assigning
        // this from App.init happens too early and can be overwritten.
        NSApplication.shared.applicationIconImage = icon
    }

    static func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationName: "昨天今天明天"]
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            options[.applicationIcon] = image
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }
}
