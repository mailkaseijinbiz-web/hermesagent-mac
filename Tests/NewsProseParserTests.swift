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
}
