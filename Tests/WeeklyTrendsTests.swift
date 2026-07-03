import XCTest
@testable import HermesCustom

final class WeeklyTrendsTests: XCTestCase {

    private func day(_ key: String, sleep: Double? = nil, mac: Double? = nil,
                     steps: Int? = nil, mood: Int? = nil) -> DayRecord {
        var r = DayRecord(dateKey: key)
        r.metrics.sleepHours = sleep
        r.metrics.macHours = mac
        r.metrics.steps = steps
        r.metrics.moodScore = mood
        return r
    }

    func testSleepDeltaReported() {
        let prev = (0..<7).map { day("p\($0)", sleep: 7.0) }
        let recent = (0..<7).map { day("r\($0)", sleep: 6.0) }
        let lines = WeeklyTrends.lines(recent: recent, previous: prev)
        XCTAssertTrue(lines.contains { $0.contains("睡眠") && $0.contains("-1.0h") }, "\(lines)")
    }

    func testFlatIsLabeledFlat() {
        let prev = (0..<7).map { day("p\($0)", mac: 5.0) }
        let recent = (0..<7).map { day("r\($0)", mac: 5.3) }
        let lines = WeeklyTrends.lines(recent: recent, previous: prev)
        XCTAssertTrue(lines.contains { $0.contains("Mac作業") && $0.contains("横ばい") }, "\(lines)")
    }

    func testStepsRatioThreshold() {
        let prev = (0..<7).map { day("p\($0)", steps: 8000) }
        let recent = (0..<7).map { day("r\($0)", steps: 5600) }   // -30%
        let lines = WeeklyTrends.lines(recent: recent, previous: prev)
        XCTAssertTrue(lines.contains { $0.contains("歩数") && $0.contains("-30%") }, "\(lines)")
    }

    func testInsufficientDataProducesNothing() {
        XCTAssertTrue(WeeklyTrends.lines(history: [day("a", sleep: 7)]).isEmpty)
        // 各指標2日未満なら行を出さない
        let lines = WeeklyTrends.lines(recent: [day("r0", sleep: 6)], previous: [])
        XCTAssertTrue(lines.isEmpty)
    }

    func testHistorySplitUsesLast7AsRecent() {
        let history = (0..<7).map { day("p\($0)", sleep: 7.5) }
             + (0..<7).map { day("r\($0)", sleep: 6.5) }
        let lines = WeeklyTrends.lines(history: history)
        XCTAssertTrue(lines.contains { $0.contains("平均6.5h") && $0.contains("前週7.5h") }, "\(lines)")
    }
}
