import XCTest
import HermesShared
@testable import HermesCustom

/// WeekSummaryContext（週サマリーの純粋な文脈組み立て）のテスト。
/// AI呼び出し（runBriefPrompt）やネットワークには触れない。
final class WeekSummaryServiceTests: XCTestCase {

    // MARK: - previousWeekStart

    func testPreviousWeekStart() {
        XCTAssertEqual(WeekSummaryContext.previousWeekStart("2026-07-06"), "2026-06-29")
        // 月またぎ・年またぎ
        XCTAssertEqual(WeekSummaryContext.previousWeekStart("2026-01-05"), "2025-12-29")
    }

    func testPreviousWeekStartInvalid() {
        XCTAssertNil(WeekSummaryContext.previousWeekStart("not-a-date"))
    }

    func testPreviousWeekStartChainsWithWeekKeys() {
        // 前週の7キーが今週の開始日の直前で終わること
        let prev = WeekSummaryContext.previousWeekStart("2026-07-06")!
        let keys = WeekSummaryRules.weekKeys(start: prev)!
        XCTAssertEqual(keys.count, 7)
        XCTAssertEqual(keys.first, "2026-06-29")
        XCTAssertEqual(keys.last, "2026-07-05")
    }

    // MARK: - dayLine

    private func event(kind: String, title: String, place: String? = nil) -> LifeEvent {
        LifeEvent(id: UUID().uuidString, kind: kind, start: 0, title: title, place: place)
    }

    func testDayLineIncludesMetricsVisitsAndMemos() {
        var r = DayRecord(dateKey: "2026-07-06")
        r.metrics.steps = 8200
        r.metrics.sleepHours = 6.5
        r.metrics.moodScore = 4
        r.metrics.macHours = 3.2
        r.events = [
            event(kind: "visit", title: "自宅", place: "自宅"),
            event(kind: "visit", title: "サウナしきじ", place: "サウナしきじ"),
            event(kind: "memo", title: "体重70.5kg"),
        ]
        let line = WeekSummaryContext.dayLine(r)
        XCTAssertTrue(line.hasPrefix("7/6("), line)   // M/d(曜)ラベル
        XCTAssertTrue(line.contains("歩数8200"), line)
        XCTAssertTrue(line.contains("睡眠6.5h"), line)
        XCTAssertTrue(line.contains("気分4/5"), line)
        XCTAssertTrue(line.contains("Mac 3.2h"), line)
        XCTAssertTrue(line.contains("訪問: 自宅・サウナしきじ"), line)
        XCTAssertTrue(line.contains("メモ: 体重70.5kg"), line)
    }

    func testDayLineEmptyRecord() {
        let line = WeekSummaryContext.dayLine(DayRecord(dateKey: "2026-07-07"))
        XCTAssertTrue(line.contains("指標なし"), line)
        XCTAssertFalse(line.contains("訪問:"), line)
        XCTAssertFalse(line.contains("メモ:"), line)
    }

    func testDayLineMemoTruncatedTo40CharsAndMax3() {
        var r = DayRecord(dateKey: "2026-07-08")
        let long = String(repeating: "あ", count: 60)
        r.events = [
            event(kind: "memo", title: long),
            event(kind: "memo", title: "メモ2"),
            event(kind: "memo", title: "メモ3"),
            event(kind: "memo", title: "メモ4は出ない"),
        ]
        let line = WeekSummaryContext.dayLine(r)
        XCTAssertTrue(line.contains(String(repeating: "あ", count: 40)), line)
        XCTAssertFalse(line.contains(String(repeating: "あ", count: 41)), line)
        XCTAssertTrue(line.contains("メモ3"), line)
        XCTAssertFalse(line.contains("メモ4"), line)
    }

    func testDayLineDeduplicatesVisits() {
        var r = DayRecord(dateKey: "2026-07-09")
        r.events = [
            event(kind: "visit", title: "自宅", place: "自宅"),
            event(kind: "visit", title: "駅前カフェ", place: "駅前カフェ"),
            event(kind: "visit", title: "自宅", place: "自宅"),
        ]
        let line = WeekSummaryContext.dayLine(r)
        XCTAssertTrue(line.contains("訪問: 自宅・駅前カフェ"), line)
        // 「自宅」は1回だけ
        XCTAssertEqual(line.components(separatedBy: "自宅").count - 1, 1, line)
    }

    func testDayLineInvalidDateKeyFallsBackToRawKey() {
        let line = WeekSummaryContext.dayLine(DayRecord(dateKey: "broken-key"))
        XCTAssertTrue(line.hasPrefix("broken-key: "), line)
    }
}
