import XCTest
@testable import HermesCustom

final class BriefEncryptionTests: XCTestCase {

    @MainActor
    func testBriefDailyMigrationFromUserDefaults() {
        let storeKey = "briefDaily"
        let legacyTextKey = "dailyBrief"
        let legacyAtKey = "dailyBriefAt"
        defer {
            UserDefaults.standard.removeObject(forKey: legacyTextKey)
            UserDefaults.standard.removeObject(forKey: legacyAtKey)
            PrivateStore.remove(key: storeKey)
        }
        PrivateStore.remove(key: storeKey)
        UserDefaults.standard.set("今日のブリーフ本文", forKey: legacyTextKey)
        UserDefaults.standard.set(1_700_100_000.0, forKey: legacyAtKey)

        let snap = AppState.loadDailyText(
            storeKey: storeKey, legacyTextKey: legacyTextKey, legacyAtKey: legacyAtKey
        )
        XCTAssertEqual(snap.text, "今日のブリーフ本文")
        XCTAssertEqual(snap.updatedAt, 1_700_100_000.0)
        XCTAssertNil(UserDefaults.standard.string(forKey: legacyTextKey))
        XCTAssertNotNil(PrivateStore.loadData(key: storeKey))
    }

    @MainActor
    func testBriefDailyRoundTrip() {
        let storeKey = "briefDaily"
        defer { PrivateStore.remove(key: storeKey) }
        PrivateStore.remove(key: storeKey)

        AppState.saveDailyText(text: "round-trip brief", at: 1_700_200_000.0, storeKey: storeKey)
        let snap = AppState.loadDailyText(
            storeKey: storeKey, legacyTextKey: "dailyBrief", legacyAtKey: "dailyBriefAt"
        )
        XCTAssertEqual(snap.text, "round-trip brief")
        XCTAssertEqual(snap.updatedAt, 1_700_200_000.0)
    }

    @MainActor
    func testWeeklyReviewDailyMigrationFromUserDefaults() {
        let storeKey = "weeklyReviewDaily"
        let legacyTextKey = "weeklyReview"
        let legacyAtKey = "weeklyReviewAt"
        defer {
            UserDefaults.standard.removeObject(forKey: legacyTextKey)
            UserDefaults.standard.removeObject(forKey: legacyAtKey)
            PrivateStore.remove(key: storeKey)
        }
        PrivateStore.remove(key: storeKey)
        UserDefaults.standard.set("週次レビュー本文", forKey: legacyTextKey)
        UserDefaults.standard.set(1_700_300_000.0, forKey: legacyAtKey)

        let snap = AppState.loadDailyText(
            storeKey: storeKey, legacyTextKey: legacyTextKey, legacyAtKey: legacyAtKey
        )
        XCTAssertEqual(snap.text, "週次レビュー本文")
        XCTAssertEqual(snap.updatedAt, 1_700_300_000.0)
        XCTAssertNil(UserDefaults.standard.string(forKey: legacyTextKey))
        XCTAssertNotNil(PrivateStore.loadData(key: storeKey))
    }

    @MainActor
    func testWeeklyReviewDailyRoundTrip() {
        let storeKey = "weeklyReviewDaily"
        defer { PrivateStore.remove(key: storeKey) }
        PrivateStore.remove(key: storeKey)

        AppState.saveDailyText(text: "round-trip review", at: 1_700_400_000.0, storeKey: storeKey)
        let snap = AppState.loadDailyText(
            storeKey: storeKey, legacyTextKey: "weeklyReview", legacyAtKey: "weeklyReviewAt"
        )
        XCTAssertEqual(snap.text, "round-trip review")
        XCTAssertEqual(snap.updatedAt, 1_700_400_000.0)
    }
}
