import XCTest
@testable import HermesCustom

final class NewsProseParserTests: XCTestCase {

    func testParseParagraphAndBullets() {
        let text = """
        今日はPC作業が中心でした。

        今日の提案
        ・午前中に集中作業を入れる
        ・睡眠時間を7時間確保する
        """
        let blocks = NewsProseParser.parse(text)
        XCTAssertEqual(blocks, [
            .paragraph("今日はPC作業が中心でした。"),
            .spacer,
            .heading("今日の提案"),
            .bullet("午前中に集中作業を入れる"),
            .bullet("睡眠時間を7時間確保する"),
        ])
    }

    func testParseHyphenBulletsAndHeadings() {
        let text = """
        気づき
        - 夜更かしが続いている
        - 運動時間が少ない

        来週への提案：
        - 22時にはPCを閉じる
        """
        let blocks = NewsProseParser.parse(text)
        XCTAssertTrue(blocks.contains(.heading("気づき")))
        XCTAssertTrue(blocks.contains(.heading("来週への提案")))
        XCTAssertEqual(blocks.filter { if case .bullet = $0 { return true }; return false }.count, 3)
    }

    func testParseSerendipitySectionInWeeklyReview() {
        let text = """
        振り返り
        今週は会議が多かった。

        今週の意外なつながり
        サウナの記録と健康目標が重なっていた。
        ・散歩ログと読書メモのテーマが一致
        """
        let blocks = NewsProseParser.parse(text, context: .weeklyReview)
        XCTAssertTrue(blocks.contains(.heading("振り返り")))
        XCTAssertTrue(blocks.contains(.serendipityHeading("今週の意外なつながり")))
        XCTAssertTrue(blocks.contains(.serendipityCard("サウナの記録と健康目標が重なっていた。")))
        XCTAssertTrue(blocks.contains(.serendipityCard("散歩ログと読書メモのテーマが一致")))
        XCTAssertFalse(blocks.contains(.heading("今週の意外なつながり")))
    }

    func testSerendipityHeadingNotDetectedInBriefContext() {
        let text = """
        つながり
        昨日の会議と今日のタスク
        """
        let blocks = NewsProseParser.parse(text, context: .brief)
        XCTAssertTrue(blocks.contains(.heading("つながり")))
        XCTAssertFalse(blocks.contains(where: { if case .serendipityHeading = $0 { return true }; return false }))
    }

    func testIsSerendipityHeading() {
        XCTAssertTrue(NewsProseParser.isSerendipityHeading("今週の意外なつながり", context: .weeklyReview))
        XCTAssertTrue(NewsProseParser.isSerendipityHeading("意外なつながり", context: .weeklyReview))
        XCTAssertTrue(NewsProseParser.isSerendipityHeading("つながり", context: .weeklyReview))
        XCTAssertFalse(NewsProseParser.isSerendipityHeading("つながり", context: .brief))
    }
}
