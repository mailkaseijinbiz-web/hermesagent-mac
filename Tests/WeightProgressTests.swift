import XCTest
@testable import HermesCustom

final class WeightProgressTests: XCTestCase {
    private func rec(_ date: String, _ kg: Double?) -> AppState.DayRecord {
        var r = AppState.DayRecord(date: date); r.bodyMassKg = kg; return r
    }

    func testWeekAndMonthDeltas() {
        let h = [rec("2026-06-03", 86.0), rec("2026-06-26", 85.5), rec("2026-07-03", 84.8)]
        let line = WeightProgress.line(history: h)
        XCTAssertEqual(line, "体重 84.8kg（7日前比-0.7kg・30日前比-1.2kg）")
    }

    func testShortHistoryFallsBackToSpan() {
        let h = [rec("2026-07-01", 85.0), rec("2026-07-03", 84.6)]
        let line = WeightProgress.line(history: h)
        XCTAssertEqual(line, "体重 84.6kg（2日間で-0.4kg）")
    }

    func testSingleRecord() {
        XCTAssertEqual(WeightProgress.line(history: [rec("2026-07-03", 84.8)]),
                       "体重 84.8kg（比較できる過去記録なし）")
    }

    func testNoWeightData() {
        XCTAssertNil(WeightProgress.line(history: [rec("2026-07-03", nil)]))
    }

    func testUnsortedInput() {
        let h = [rec("2026-07-03", 84.8), rec("2026-06-26", 85.5)]
        XCTAssertEqual(WeightProgress.line(history: h), "体重 84.8kg（7日前比-0.7kg）")
    }
}
