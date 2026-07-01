import XCTest
@testable import HermesCustom

final class LiveActivityPushPayloadTests: XCTestCase {
    func testStartPayloadShape() throws {
        let payload = LiveActivityPushPayload.start(
            employeeEmoji: "✨",
            employeeName: "アシスタント",
            preview: "おはよう",
            toolLabel: "チェックイン",
            timestamp: 1_700_000_000
        )
        let aps = try XCTUnwrap(payload["aps"] as? [String: Any])
        XCTAssertEqual(aps["event"] as? String, "start")
        XCTAssertEqual(aps["timestamp"] as? Int, 1_700_000_000)
        XCTAssertEqual(aps["attributes-type"] as? String, "HermesActivityAttributes")
        let attrs = try XCTUnwrap(aps["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["employeeEmoji"] as? String, "✨")
        XCTAssertEqual(attrs["employeeName"] as? String, "アシスタント")
        let state = try XCTUnwrap(aps["content-state"] as? [String: Any])
        XCTAssertEqual(state["preview"] as? String, "おはよう")
        XCTAssertEqual(state["toolLabel"] as? String, "チェックイン")
        XCTAssertEqual(state["isStreaming"] as? Bool, false)
    }
}
