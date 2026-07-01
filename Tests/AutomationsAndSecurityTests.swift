import XCTest
@testable import HermesCustom

/// Regression tests for pure-logic helpers added during the roadmap work:
/// cron→Japanese, delivery-target display (UID hidden), run-time formatting, and the
/// MobileServer security primitives (constant-time compare, public-IPv4 classification).
final class AutomationsAndSecurityTests: XCTestCase {

    // MARK: - CronJobRow.humanSchedule

    func testHumanScheduleWeekdaysMultipleTimes() {
        XCTAssertEqual(CronJobRow.humanSchedule("30 8,15 * * 1-5"), "平日 8:30・15:30")
    }
    func testHumanScheduleDaily() {
        XCTAssertEqual(CronJobRow.humanSchedule("0 9 * * *"), "毎日 9:00")
        XCTAssertEqual(CronJobRow.humanSchedule("0 8 * * *"), "毎日 8:00")
    }
    func testHumanScheduleIntervals() {
        XCTAssertEqual(CronJobRow.humanSchedule("*/30 * * * *"), "30分ごと")
        XCTAssertEqual(CronJobRow.humanSchedule("0 */2 * * *"), "2時間ごと")
        XCTAssertEqual(CronJobRow.humanSchedule("0 * * * *"), "毎時0分")
    }
    func testHumanScheduleWeeklyAndMonthlyAndWeekend() {
        XCTAssertEqual(CronJobRow.humanSchedule("0 9 * * 1"), "毎週月曜 9:00")
        XCTAssertEqual(CronJobRow.humanSchedule("0 9 1 * *"), "毎月1日 9:00")
        XCTAssertEqual(CronJobRow.humanSchedule("0 9 * * 0,6"), "週末 9:00")
    }
    func testHumanScheduleNonStandardPassesThrough() {
        XCTAssertEqual(CronJobRow.humanSchedule("not a cron"), "not a cron")
    }

    // MARK: - CronJobRow.humanDeliver (never expose the channel UID)

    func testHumanDeliverLocal() {
        XCTAssertEqual(CronJobRow.humanDeliver("local", channels: []), "このMac（ローカル）")
        XCTAssertEqual(CronJobRow.humanDeliver("", channels: []), "このMac（ローカル）")
    }
    func testHumanDeliverHidesUIDWhenUnregistered() {
        XCTAssertEqual(CronJobRow.humanDeliver("line:U752e3d6440ab40545735d1a1e0246584", channels: []), "LINE")
    }
    func testHumanDeliverHidesUIDWhenNameEqualsId() {
        let id = "U752e3d6440ab40545735d1a1e0246584"
        let ch = HermesChannel(platform: "line", channelId: id, name: id, type: "dm")
        XCTAssertEqual(CronJobRow.humanDeliver("line:\(id)", channels: [ch]), "LINE")
    }
    func testHumanDeliverShowsFriendlyName() {
        let ch = HermesChannel(platform: "line", channelId: "Uabc", name: "家族グループ", type: "group")
        XCTAssertEqual(CronJobRow.humanDeliver("line:Uabc", channels: [ch]), "LINE（家族グループ）")
    }

    // MARK: - CronJobRow.friendlyTime (timezone-independent assertions)

    func testFriendlyTimeReformatsAndKeepsStatus() {
        let out = CronJobRow.friendlyTime("2026-06-28T01:31:18.497948+09:00 ok")
        XCTAssertNotEqual(out, "2026-06-28T01:31:18.497948+09:00 ok")  // reformatted
        XCTAssertTrue(out.hasSuffix(" ok"))                            // trailing status preserved
        XCTAssertFalse(out.contains("T"))                              // no raw ISO 'T'
    }
    func testFriendlyTimeGarbagePassesThrough() {
        XCTAssertEqual(CronJobRow.friendlyTime("n/a"), "n/a")
    }

    // MARK: - MobileServer.constantTimeEquals

    func testConstantTimeEquals() {
        XCTAssertTrue(MobileServer.constantTimeEquals("loc_abc123", "loc_abc123"))
        XCTAssertTrue(MobileServer.constantTimeEquals("", ""))
        XCTAssertFalse(MobileServer.constantTimeEquals("loc_abc123", "loc_abc124"))
        XCTAssertFalse(MobileServer.constantTimeEquals("loc_abc123", "loc_abc12"))   // length differs
        XCTAssertFalse(MobileServer.constantTimeEquals("Abc", "abc"))                 // case-sensitive
        XCTAssertFalse(MobileServer.constantTimeEquals("secret", ""))
    }

    // MARK: - MobileServer.isRoutablePublicIPv4

    func testRoutablePublicIPv4TrustsLocalAndTailscaleAndPrivate() {
        for ip in ["127.0.0.1", "::1", "fd7a:115c:a1e0::1", "fe80::1",
                   "100.64.1.5", "100.127.0.1", "10.0.0.5", "192.168.1.5",
                   "172.16.0.1", "172.31.255.1", "169.254.1.1",
                   "::ffff:192.168.1.5", "100.64.1.5%en0"] {
            XCTAssertFalse(MobileServer.isRoutablePublicIPv4(ip), "expected trusted: \(ip)")
        }
    }
    func testRoutablePublicIPv4RejectsPublic() {
        for ip in ["8.8.8.8", "1.2.3.4", "172.32.0.1", "100.128.0.1", "::ffff:8.8.8.8"] {
            XCTAssertTrue(MobileServer.isRoutablePublicIPv4(ip), "expected public: \(ip)")
        }
    }

    // MARK: - LINE delivery 401 detection

    func testIsLineDeliveryAuthError() {
        XCTAssertTrue(AppState.isLineDeliveryAuthError("⚠ Delivery failed: LINE push 401: invalid token"))
        XCTAssertTrue(AppState.isLineDeliveryAuthError("line api returned 401"))
        XCTAssertFalse(AppState.isLineDeliveryAuthError("LINE timeout"))
        XCTAssertFalse(AppState.isLineDeliveryAuthError("push 401 to slack"))
        XCTAssertFalse(AppState.isLineDeliveryAuthError(nil))
    }
}
