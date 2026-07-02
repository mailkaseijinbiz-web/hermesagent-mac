import XCTest
@testable import HermesCustom

final class HealthTrendQueryTests: XCTestCase {
    func testDetectsWeightTrendQuestion() {
        XCTAssertEqual(HealthTrendQuery.metric(in: "体重の推移を見せて"), .weight)
        XCTAssertEqual(HealthTrendQuery.metric(in: "最近の体重グラフ"), .weight)
        XCTAssertNil(HealthTrendQuery.metric(in: "今日の天気"))
    }

    func testDetectsHbA1cTrendQuestion() {
        XCTAssertEqual(HealthTrendQuery.metric(in: "HbA1cの推移"), .hba1c)
        XCTAssertEqual(HealthTrendQuery.metric(in: "ヘモグロビンのグラフ"), .hba1c)
    }
}
