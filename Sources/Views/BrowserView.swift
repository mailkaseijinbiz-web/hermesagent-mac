import SwiftUI
import WebKit

/// Holds the WKWebView + its observable navigation state for the SwiftUI controls.
@MainActor
final class BrowserModel: ObservableObject {
    static let shared = BrowserModel()
    let webView: WKWebView

    @Published var urlText: String = "https://www.google.com"
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var pageTitle = ""

    private var coordinator: Coordinator?

    private init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        let c = Coordinator(self)
        coordinator = c
        webView.navigationDelegate = c
        load(urlText)
    }

    /// Navigate to whatever is in the URL bar (adds https:// or searches if needed).
    func go() {
        load(urlText)
    }

    func load(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            // Looks like a domain → prepend https; otherwise Google-search it.
            if s.contains(".") && !s.contains(" ") {
                s = "https://\(s)"
            } else if let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                s = "https://www.google.com/search?q=\(q)"
            }
        }
        guard let url = URL(string: s) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var model: BrowserModel?
        init(_ model: BrowserModel) { self.model = model }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model?.isLoading = true
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            sync(webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            sync(webView)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            sync(webView)
        }
        private func sync(_ webView: WKWebView) {
            guard let model else { return }
            model.isLoading = false
            model.canGoBack = webView.canGoBack
            model.canGoForward = webView.canGoForward
            model.pageTitle = webView.title ?? ""
            if let u = webView.url?.absoluteString { model.urlText = u }
        }
    }
}

/// SwiftUI wrapper around the shared WKWebView.
private struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Right-sidebar browser panel: URL bar + back/forward/reload + WKWebView.
struct BrowserView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var model = BrowserModel.shared
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).disabled(!model.canGoBack)
                    .foregroundColor(model.canGoBack ? .primary : .secondary.opacity(0.4))
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).disabled(!model.canGoForward)
                    .foregroundColor(model.canGoForward ? .primary : .secondary.opacity(0.4))
                Button { model.reload() } label: {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }.buttonStyle(.plain).foregroundColor(.secondary)

                TextField("URL または検索", text: $model.urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($urlFocused)
                    .onSubmit { model.go(); urlFocused = false }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button { appState.showRightSidebar = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 10)

            if model.isLoading {
                ProgressView().progressViewStyle(.linear).frame(height: 2)
            }
            Divider()

            WebViewRepresentable(webView: model.webView)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity),
            alignment: .leading
        )
    }
}
