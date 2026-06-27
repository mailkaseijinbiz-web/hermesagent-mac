import AppKit
import WebKit

/// Opens an app's preview URL in its OWN resizable macOS window — separate from the in-app
/// side browser panel — so a running app can be used like a standalone window. Each window
/// owns its WKWebView; closing it releases everything (tracked in `live` to retain it).
@MainActor
final class AppPreviewWindow: NSObject, NSWindowDelegate {
    /// Retains open windows (an NSWindow with isReleasedWhenClosed=false would otherwise
    /// deallocate once this controller goes out of scope).
    private static var live: [AppPreviewWindow] = []

    private let window: NSWindow
    private let web: WKWebView
    private let appId: String?

    /// Show `url` in a new window titled `title`. If a window for `appId` is already open,
    /// it's focused (and reloaded) instead of opening a duplicate.
    static func show(url: String, title: String, appId: String? = nil) {
        guard let u = normalize(url) else { return }
        if let id = appId, let existing = live.first(where: { $0.appId == id }) {
            existing.web.load(URLRequest(url: u))
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        live.append(AppPreviewWindow(url: u, title: title, appId: appId))
    }

    private init(url: URL, title: String, appId: String?) {
        self.appId = appId
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.contentView = web
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("AppPreview-\(appId ?? title)")
        window.center()
        web.load(URLRequest(url: url))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        web.stopLoading()
        AppPreviewWindow.live.removeAll { $0 === self }
    }

    /// Accept a bare host:port / domain too (prepend http:// for localhost dev servers).
    private static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "http://\(s)" }
        return URL(string: s)
    }
}
