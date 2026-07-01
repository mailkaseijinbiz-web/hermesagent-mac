import XCTest
@testable import HermesCustom

final class LocationRouteParserTests: XCTestCase {
    func testStopsFromArrowSummary() {
        let stops = LocationRouteParser.stops(from: "曙町1丁目 → 公園 → 自宅")
        XCTAssertEqual(stops, ["曙町1丁目", "公園", "自宅"])
    }

    func testStripsEmptySegments() {
        let stops = LocationRouteParser.stops(from: "A →  → B")
        XCTAssertEqual(stops, ["A", "B"])
    }
}
