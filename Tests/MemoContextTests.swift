import XCTest
@testable import HermesCustom

final class MemoContextTests: XCTestCase {

    func testFormatURLMemo() {
        let m = MacMemo(
            text: "Example Article",
            time: Date(),
            source: nil,
            link: "https://example.com/article",
            pageTitle: "Example Article",
            mediaKind: "url"
        )
        let line = MemoContext.line(for: m)
        XCTAssertTrue(line.contains("🔗"))
        XCTAssertTrue(line.contains("Example Article"))
        XCTAssertTrue(line.contains("https://example.com"))
    }

    func testFormatTruncatesLongText() {
        let long = String(repeating: "あ", count: 200)
        let m = MacMemo(text: long, time: Date(), mediaKind: "text")
        let line = MemoContext.line(for: m, maxChars: 40)
        XCTAssertTrue(line.hasPrefix("📝"))
        XCTAssertTrue(line.count < 50)
    }

    func testFormatEmptyReturnsEmpty() {
        XCTAssertEqual(MemoContext.format([]), "")
    }

    func testMemoTimelineLabel() {
        let m = MacMemo(text: "test", time: Date(), mediaKind: "video")
        let (label, _) = DayTimelineGraph.memoLabelAndDetail(m)
        XCTAssertEqual(label, "動画")
    }
}
