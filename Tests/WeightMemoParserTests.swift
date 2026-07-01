import XCTest
@testable import HermesCustom

final class WeightMemoParserTests: XCTestCase {

    func testParseWeightWithKgSuffix() {
        XCTAssertEqual(WeightMemoParser.parse("65.2kg"), 65.2)
        XCTAssertEqual(WeightMemoParser.parse("今日 68kg"), 68.0)
    }

    func testParseWeightWithLabel() {
        XCTAssertEqual(WeightMemoParser.parse("体重 72.5"), 72.5)
        XCTAssertEqual(WeightMemoParser.parse("体重:63.0kg"), 63.0)
    }

    func testRejectsOutOfRange() {
        XCTAssertNil(WeightMemoParser.parse("15kg"))
        XCTAssertNil(WeightMemoParser.parse("体重 350"))
    }

    @MainActor
    func testAppendToStoreAndDedupeMemoId() {
        let memoId = "memo-test-1"
        XCTAssertNotNil(WeightRecordStore.append(kg: 65.4, memoId: memoId))
        XCTAssertNil(WeightRecordStore.append(kg: 66.0, memoId: memoId))
        XCTAssertEqual(WeightRecordStore.latest()?.kg, 65.4)
    }
}
