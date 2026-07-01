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
        XCTAssertTrue(PrivateStoreKeys.all.contains("failedDeliveries"))
    }

    func testDailyTextSnapshotRoundTrip() throws {
        let key = "test-daily-\(UUID().uuidString)"
        defer { PrivateStore.remove(key: key) }
        let snap = AppState.DailyTextSnapshot(text: "自宅 → カフェ", updatedAt: 1_700_000_000)
        try PrivateStore.save(snap, key: key)
        let loaded: AppState.DailyTextSnapshot? = PrivateStore.load(AppState.DailyTextSnapshot.self, key: key)
        XCTAssertEqual(loaded, snap)
    }

    func testMigrateLegacyUserDefaultsPersonalProfile() throws {
        let key = "personalProfile"
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            PrivateStore.remove(key: key)
        }
        PrivateStore.remove(key: key)
        let profile = AppState.PersonalProfile(likes: "サウナ", goals: "健康", values: "", notes: "")
        let data = try JSONEncoder().encode(profile)
        UserDefaults.standard.set(data, forKey: key)

        PrivateStore.migrateLegacyUserDefaults()

        XCTAssertNil(UserDefaults.standard.data(forKey: key))
        XCTAssertTrue(PrivateStore.hasEncryptedFile(key: key))
        let loaded: AppState.PersonalProfile? = PrivateStore.load(AppState.PersonalProfile.self, key: key)
        XCTAssertEqual(loaded?.likes, "サウナ")
        XCTAssertEqual(loaded?.goals, "健康")
    }

    func testMigrateLegacyUserDefaultsLocationPoints() throws {
        let key = "locationPoints"
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            PrivateStore.remove(key: key)
        }
        PrivateStore.remove(key: key)
        let points = [AppState.LocationPoint(name: "自宅", lat: 35.68, lon: 139.76)]
        let data = try JSONEncoder().encode(points)
        UserDefaults.standard.set(data, forKey: key)

        PrivateStore.migrateLegacyUserDefaults()

        XCTAssertNil(UserDefaults.standard.data(forKey: key))
        XCTAssertTrue(PrivateStore.hasEncryptedFile(key: key))
        let loaded: [AppState.LocationPoint]? = PrivateStore.load([AppState.LocationPoint].self, key: key)
        XCTAssertEqual(loaded?.count, 1)
        XCTAssertEqual(loaded?.first?.name, "自宅")
    }
}
