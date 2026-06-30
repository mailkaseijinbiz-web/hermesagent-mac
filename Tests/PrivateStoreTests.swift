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
        XCTAssertTrue(PrivateStoreKeys.all.contains("locationPoints"))
    }
}
