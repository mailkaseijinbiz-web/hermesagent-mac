import XCTest
@testable import HermesCustom

final class LifelogTests: XCTestCase {

    @MainActor
    func testLifelogSummaryMigrationFromUserDefaults() {
        let storeKey = "lifelogDaily"
        let legacyTextKey = "lifelogSummary"
        let legacyAtKey = "lifelogSummaryAt"
        defer {
            UserDefaults.standard.removeObject(forKey: legacyTextKey)
            UserDefaults.standard.removeObject(forKey: legacyAtKey)
            PrivateStore.remove(key: storeKey)
        }
        PrivateStore.remove(key: storeKey)
        UserDefaults.standard.set("今日はサウナに行った", forKey: legacyTextKey)
        UserDefaults.standard.set(1_700_000_000.0, forKey: legacyAtKey)

        let snap = AppState.loadDailyText(
            storeKey: storeKey, legacyTextKey: legacyTextKey, legacyAtKey: legacyAtKey
        )
        XCTAssertEqual(snap.text, "今日はサウナに行った")
        XCTAssertEqual(snap.updatedAt, 1_700_000_000.0)
        XCTAssertNil(UserDefaults.standard.string(forKey: legacyTextKey))
        XCTAssertNotNil(PrivateStore.loadData(key: storeKey))
    }

    @MainActor
    func testResolvedLocationSummaryReplacesHomeKeyword() {
        let state = AppState.shared
        let saved = state.homeLocationKeyword
        defer { state.homeLocationKeyword = saved }
        state.homeLocationKeyword = "渋谷マンション"
        XCTAssertEqual(
            state.resolvedLocationSummary("10:00 渋谷マンション → 12:00 カフェ"),
            "10:00 自宅 → 12:00 カフェ"
        )
    }

    @MainActor
    func testWeeklyReviewContextFormatsDayRecords() {
        let state = AppState.shared
        let saved = state.dailyHistory
        defer { state.dailyHistory = saved }
        state.dailyHistory = [
            AppState.DayRecord(date: "2026-06-30", steps: 8000, locations: "自宅→オフィス")
        ]
        let ctx = state.weeklyReviewContext(days: 7)
        XCTAssertTrue(ctx.contains("2026-06-30"))
        XCTAssertTrue(ctx.contains("歩8000"))
        XCTAssertTrue(ctx.contains("場所[自宅→オフィス]"))
    }
}
