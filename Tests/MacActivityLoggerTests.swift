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

    func testActivityEntriesEncryptRoundTrip() throws {
        let key = "test-activity-\(UUID().uuidString)"
        defer { PrivateStore.remove(key: key) }
        var entry = MacActivityEntry()
        entry.appName = "Safari"
        entry.label = "Safari — Example"
        entry.url = "https://example.com"
        entry.startTime = 100
        entry.endTime = 200
        let data = try JSONEncoder().encode([entry])
        try PrivateStore.saveData(data, key: key)
        let loaded = PrivateStore.loadData(key: key)
        XCTAssertEqual(loaded, data)
    }

    func testLegacyJSONFileMigratesToEncryptedStore() throws {
        let storeKey = MacActivityLogger.activityStoreKey()
        let todayLegacy = MacActivityLogger.legacyActivityPath()
        defer {
            PrivateStore.remove(key: storeKey)
            try? FileManager.default.removeItem(atPath: todayLegacy)
        }
        try? PrivateStore.remove(key: storeKey)
        try? FileManager.default.removeItem(atPath: todayLegacy)

        var entry = MacActivityEntry()
        entry.appName = "Chrome"
        entry.label = "Chrome — Docs"
        entry.url = "https://example.com/doc"
        entry.startTime = 500
        entry.endTime = 600
        let data = try JSONEncoder().encode([entry])
        try data.write(to: URL(fileURLWithPath: todayLegacy))

        let migrated = MacActivityLogger.loadEntries()
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].appName, "Chrome")
        XCTAssertEqual(migrated[0].url, "https://example.com/doc")
        XCTAssertNotNil(PrivateStore.loadData(key: storeKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: todayLegacy))
    }

    func testStoredActivityDayKeysFindsEncryptedAndLegacy() throws {
        let day = "2099-01-15"
        let encKey = "mac-activity-\(day)"
        defer { PrivateStore.remove(key: encKey) }
        try PrivateStore.saveData(Data("[]".utf8), key: encKey)

        let legacyPath = "\(NSHomeDirectory())/.hermes/mac-activity-2099-01-16.json"
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }
        try Data("[]".utf8).write(to: URL(fileURLWithPath: legacyPath))

        let keys = Set(MacActivityLogger.storedActivityDayKeys())
        XCTAssertTrue(keys.contains(day))
        XCTAssertTrue(keys.contains("2099-01-16"))
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
