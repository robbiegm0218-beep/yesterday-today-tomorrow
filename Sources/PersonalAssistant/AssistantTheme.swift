import SwiftUI
import AppKit

/// Every surface follows the same appearance as its text. Fixed white fills
/// otherwise leave the system's dark-mode white text invisible.
enum AssistantTheme {
    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }

    static let canvas = adaptive("YuanCanvas", light: 0xFFFFFF, dark: 0x212121)
    static let sidebar = adaptive("YuanSidebar", light: 0xF7F7F8, dark: 0x181818)
    static let surface = adaptive("YuanSurface", light: 0xFFFFFF, dark: 0x2C2C2C)
    static let userMessage = adaptive("YuanUserMessage", light: 0xF0F0F2, dark: 0x303030)
    static let selection = adaptive("YuanSelection", light: 0xE8E8EC, dark: 0x303034)
    static let inset = adaptive("YuanInset", light: 0xF5F5F7, dark: 0x27272B)
    static let accent = adaptive("YuanAccent", light: 0x5355C5, dark: 0xADAFFF)
    static let text = adaptive("YuanText", light: 0x202124, dark: 0xECECEF)
    static let secondaryText = adaptive("YuanSecondary", light: 0x62646B, dark: 0xB0B0B8)
    static let border = adaptive("YuanBorder", light: 0xDEDEE4, dark: 0x45454A)
    static let inspectorTop = adaptive("InspectorTop", light: 0xD2E2EE, dark: 0x293444)
    static let inspectorBottom = adaptive("InspectorBottom", light: 0xF4E4D8, dark: 0x302A30)
    static let brand = Color(red: 0.36, green: 0.35, blue: 0.77)
}

struct AssistantBrandMark: View {
    var size: CGFloat = 34
    private static let artwork: NSImage? = Bundle.main.url(forResource: "AppIconArtwork", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        Group {
            if let image = Self.artwork {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "book.closed.fill").resizable().scaledToFit()
                    .padding(size * 0.2).foregroundStyle(AssistantTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .accessibilityLabel("昨天今天明天")
    }
}

struct ConversationInitialScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content
        }
    }
}
