import XCTest
@testable import HermesCustom

final class MacActivityLoggerTests: XCTestCase {
    func testBuildLabelUsesAppNameWhenTitleIsEmpty() {
        XCTAssertEqual(MacActivityLogger.buildLabel(appName: "Safari", windowTitle: ""), "Safari")
    }

    func testBuildLabelIncludesWindowTitle() {
        XCTAssertEqual(MacActivityLogger.buildLabel(appName: "Chrome", windowTitle: "Docs"), "Chrome — Docs")
    }

    func testAdjacentEntriesMergeOnlyForSameActivityWithinGap() {
        let first = entry(app: "Chrome", title: "Docs", url: "https://example.com/a", start: 100, end: 200)
        let sameSoon = entry(app: "Chrome", title: "Docs", url: "https://example.com/a", start: 229, end: 260)
        let sameLate = entry(app: "Chrome", title: "Docs", url: "https://example.com/a", start: 230, end: 260)
        let differentURL = entry(app: "Chrome", title: "Docs", url: "https://example.com/b", start: 229, end: 260)
        let differentTitle = entry(app: "Chrome", title: "Mail", url: "https://example.com/a", start: 229, end: 260)
        let differentApp = entry(app: "Safari", title: "Docs", url: "https://example.com/a", start: 229, end: 260)

        XCTAssertTrue(MacActivityLogger.shouldMergeAdjacent(previous: first, next: sameSoon))
        XCTAssertFalse(MacActivityLogger.shouldMergeAdjacent(previous: first, next: sameLate))
        XCTAssertFalse(MacActivityLogger.shouldMergeAdjacent(previous: first, next: differentURL))
        XCTAssertFalse(MacActivityLogger.shouldMergeAdjacent(previous: first, next: differentTitle))
        XCTAssertFalse(MacActivityLogger.shouldMergeAdjacent(previous: first, next: differentApp))
    }

    private func entry(app: String, title: String?, url: String?, start: Double, end: Double) -> MacActivityEntry {
        var entry = MacActivityEntry()
        entry.appName = app
        entry.windowTitle = title
        entry.url = url
        entry.startTime = start
        entry.endTime = end
        return entry
    }
}
