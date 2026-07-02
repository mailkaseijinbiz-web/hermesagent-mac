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

    func testLifeLogStartPayloadShape() throws {
        let payload = LiveActivityPushPayload.lifeLogStart(
            headline: "写真2枚。歩数6200歩。",
            detail: "6,200歩 · カフェ",
            statusLabel: "今日",
            timestamp: 1_700_000_000
        )
        let aps = try XCTUnwrap(payload["aps"] as? [String: Any])
        XCTAssertEqual(aps["event"] as? String, "start")
        XCTAssertEqual(aps["attributes-type"] as? String, "LifeLogActivityAttributes")
        let attrs = try XCTUnwrap(aps["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["title"] as? String, "ライフログ")
        let state = try XCTUnwrap(aps["content-state"] as? [String: Any])
        XCTAssertEqual(state["headline"] as? String, "写真2枚。歩数6200歩。")
        XCTAssertEqual(state["detail"] as? String, "6,200歩 · カフェ")
    }
}
