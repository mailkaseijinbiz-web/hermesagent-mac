import XCTest
@testable import HermesCustom

final class PushPreviewFormatterTests: XCTestCase {

    func testStripsJsonFenceAndUsesCardSubtitle() {
        let raw = """
        ```json
        {"vitalHint":"睡眠が浅め","vitalityMode":"recover","cards":[{"id":"1","title":"15分仮眠","subtitle":"午後の集中力を取り戻す","icon":"bed","kind":"recover","action":{"type":"none"}}]}
        ```
        """
        let body = PushPreviewFormatter.body(from: raw)
        XCTAssertEqual(body, "午後の集中力を取り戻す")
    }

    func testPlainProsePassesThrough() {
        let raw = "本日の予定は3件です。午後に会議があるので、午前中に集中作業を。"
        let body = PushPreviewFormatter.body(from: raw)
        XCTAssertTrue(body.contains("集中作業"))
    }

    func testRawJsonBlobFallsBackToSessionTitle() {
        let raw = #"{"status":"ok","meta":{"run":1}}"#
        let body = PushPreviewFormatter.body(from: raw, sessionTitle: "週次レビュー")
        XCTAssertEqual(body, "週次レビューから新しい応答")
    }

    func testEmptyAfterJsonUsesDefault() {
        let body = PushPreviewFormatter.body(from: #"{"debug":true}"#)
        XCTAssertEqual(body, "新しい応答があります")
    }
}
