import SwiftUI
import AppKit

/// Observe AppKit's actual clip bounds. SwiftUI coordinate-space preferences
/// can stay unchanged while an NSScrollView scrolls on supported macOS versions.
struct ConversationScrollObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.attached = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }; coordinator?.attach(view)
        }
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        context.coordinator.onChange = onChange
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }; coordinator?.attach(view)
        }
    }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) { coordinator.detach() }
    final class Probe: NSView {
        var attached: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attached?() }
    }
    final class Coordinator {
        var onChange: (Bool) -> Void
        weak var scroll: NSScrollView?
        var observations: [NSObjectProtocol] = []
        var lastValue: Bool?
        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
        func attach(_ view: NSView) {
            guard let scrollView = view.enclosingScrollView else { return }
            if scroll !== scrollView {
                detach(); scroll = scrollView
                let clip = scrollView.contentView
                clip.postsBoundsChangedNotifications = true
                clip.postsFrameChangedNotifications = true
                scrollView.documentView?.postsFrameChangedNotifications = true
                for (name, object) in [(NSView.boundsDidChangeNotification, clip), (NSView.frameDidChangeNotification, clip), (NSView.frameDidChangeNotification, scrollView.documentView)] {
                    if let object {
                        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.report() })
                    }
                }
            }
            report()
        }
        func report() {
            guard let scroll, let document = scroll.documentView else { return }
            guard document.bounds.height > 0, scroll.contentView.bounds.height > 0 else { return }
            let visible = scroll.documentVisibleRect
            let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            let bottom = distance <= 40
            guard bottom != lastValue else { return }
            lastValue = bottom
            DispatchQueue.main.async { [weak self] in self?.onChange(bottom) }
        }
        func detach() { observations.forEach(NotificationCenter.default.removeObserver); observations = []; scroll = nil; lastValue = nil }
        deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
}
