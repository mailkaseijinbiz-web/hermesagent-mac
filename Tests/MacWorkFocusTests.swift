import XCTest
@testable import HermesCustom

final class MacWorkFocusTests: XCTestCase {

    private func entry(
        app: String,
        title: String?,
        url: String? = nil,
        kind: String = "app",
        label: String? = nil
    ) -> MacActivityEntry {
        var e = MacActivityEntry()
        e.kind = kind
        e.appName = app
        e.windowTitle = title
        e.url = url
        e.label = label ?? (title.map { "\(app) — \($0)" } ?? app)
        return e
    }

    func testWorkTitleUsesDocumentName() {
        let e = entry(app: "Cursor", title: "HomeView.swift — hermesagent-ios")
        XCTAssertEqual(MacWorkFocus.workTitle(for: e), "HomeView.swift — hermesagent-ios")
        XCTAssertEqual(MacWorkFocus.subtitle(for: e), "Cursor")
    }

    func testWorkTitleStripsBrowserSuffix() {
        let e = entry(app: "Google Chrome", title: "Swift.org - Google Chrome")
        XCTAssertEqual(MacWorkFocus.workTitle(for: e), "Swift.org")
    }

    func testHermesUsesSessionTitle() {
        var e = MacActivityEntry()
        e.kind = "hermes"
        e.appName = "アシスタント"
        e.label = "ライフログUIの改善"
        XCTAssertEqual(MacWorkFocus.workTitle(for: e), "ライフログUIの改善")
    }
}
