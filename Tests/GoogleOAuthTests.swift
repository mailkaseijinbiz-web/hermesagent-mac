import XCTest
@testable import HermesCustom

final class GoogleOAuthTests: XCTestCase {

    func testMigrateClientSecretPrefersKeychain() {
        var written: String?
        var cleared = false
        let result = GoogleOAuth.migrateClientSecret(
            keychainValue: "from-kc",
            userDefaultsValue: "from-ud",
            writeKeychain: { written = $0 },
            clearUserDefaults: { cleared = true }
        )
        XCTAssertEqual(result, "from-kc")
        XCTAssertNil(written)
        XCTAssertTrue(cleared)
    }

    func testMigrateClientSecretFromUserDefaultsWhenKeychainEmpty() {
        var written: String?
        var cleared = false
        let result = GoogleOAuth.migrateClientSecret(
            keychainValue: nil,
            userDefaultsValue: "  legacy-secret  ",
            writeKeychain: { written = $0 },
            clearUserDefaults: { cleared = true }
        )
        XCTAssertEqual(result, "legacy-secret")
        XCTAssertEqual(written, "legacy-secret")
        XCTAssertTrue(cleared)
    }

    func testMigrateClientSecretEmptyWhenBothMissing() {
        XCTAssertEqual(GoogleOAuth.migrateClientSecret(keychainValue: "", userDefaultsValue: nil), "")
    }
}