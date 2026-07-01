import XCTest
@testable import HermesCustom

final class PrivateStoreTests: XCTestCase {

    private let testKey = "test-roundtrip-\(UUID().uuidString)"

    override func tearDown() {
        PrivateStore.remove(key: testKey)
        super.tearDown()
    }

    func testEncryptDecryptRoundTrip() throws {
        struct Payload: Codable, Equatable {
            var secret: String
            var n: Int
        }
        let original = Payload(secret: "サウナ好き", n: 42)
        try PrivateStore.save(original, key: testKey)
        let loaded: Payload? = PrivateStore.load(Payload.self, key: testKey)
        XCTAssertEqual(loaded, original)
        XCTAssertNil(UserDefaults.standard.data(forKey: testKey))
    }

    func testEncryptedKeyListIncludesHealth() {
        XCTAssertTrue(PrivateStoreKeys.all.contains("latestHealth"))
        XCTAssertTrue(PrivateStoreKeys.all.contains("weightRecords"))
        XCTAssertTrue(PrivateStoreKeys.all.contains("locationPoints"))
        XCTAssertTrue(PrivateStoreKeys.all.contains("locationDaily"))
        XCTAssertTrue(PrivateStoreKeys.all.contains("photoDaily"))
        XCTAssertTrue(PrivateStoreKeys.all.contains("lifelogDaily"))
    }

    func testDailyTextSnapshotRoundTrip() throws {
        let key = "test-daily-\(UUID().uuidString)"
        defer { PrivateStore.remove(key: key) }
        let snap = AppState.DailyTextSnapshot(text: "自宅 → カフェ", updatedAt: 1_700_000_000)
        try PrivateStore.save(snap, key: key)
        let loaded: AppState.DailyTextSnapshot? = PrivateStore.load(AppState.DailyTextSnapshot.self, key: key)
        XCTAssertEqual(loaded, snap)
    }
}
