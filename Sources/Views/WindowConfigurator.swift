import SwiftUI
import AppKit

/// Insets the macOS window's traffic-light buttons (close/min/zoom) by a fixed
/// offset so they sit slightly lower and to the right — a more padded, modern look.
/// Re-applies on resize/key changes since AppKit re-lays them out.
struct WindowConfigurator: NSViewRepresentable {
    var dx: CGFloat = 8     // move right
    var dy: CGFloat = 6     // move down

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(dx: dx, dy: dy) }

    @MainActor
    final class Coordinator {
        let dx: CGFloat
        let dy: CGFloat
        weak var window: NSWindow?
        private var originals: [ObjectIdentifier: CGPoint] = [:]

        init(dx: CGFloat, dy: CGFloat) { self.dx = dx; self.dy = dy }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                self.window = window
                let nc = NotificationCenter.default
                for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    nc.addObserver(self, selector: #selector(reposition), name: name, object: window)
                }
            }
            reposition()
        }

        @objc func reposition() {
            guard let window else { return }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let b = window.standardWindowButton(type) else { continue }
                let key = ObjectIdentifier(b)
                // Capture the AppKit default once, then always place at default + inset
                // (avoids drift/accumulation across re-layouts).
                if originals[key] == nil { originals[key] = b.frame.origin }
                guard let orig = originals[key] else { continue }
                // Titlebar coords are not flipped: smaller y = lower on screen.
                b.setFrameOrigin(CGPoint(x: orig.x + dx, y: orig.y - dy))
            }
        }
    }
}
