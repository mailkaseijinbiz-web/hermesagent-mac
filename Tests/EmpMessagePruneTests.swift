import XCTest
@testable import HermesCustom

final class EmpMessagePruneTests: XCTestCase {

    func testNoPruneWhenUnderCap() {
        let keys = (1...10).map { "emp\($0)" }
        let touch = Dictionary(uniqueKeysWithValues: keys.map { ($0, Date()) })
        let result = AppState.empMessageShadowKeysToPrune(
            keys: keys, lastTouch: touch,
            busyIds: [], streamingIds: [], activeId: nil
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testPruneOldestIdleKeys() {
        let keys = (1...14).map { "emp\($0)" }
        var touch: [String: Date] = [:]
        for (i, k) in keys.enumerated() {
            touch[k] = Date(timeIntervalSince1970: Double(i))
        }
        let result = AppState.empMessageShadowKeysToPrune(
            keys: keys, lastTouch: touch,
            busyIds: ["emp3"], streamingIds: ["emp7"], activeId: "emp1"
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.contains("emp1"))
        XCTAssertFalse(result.contains("emp3"))
        XCTAssertFalse(result.contains("emp7"))
        XCTAssertEqual(result, ["emp2", "emp4"])
    }

    func testPruneUsesDistantPastForMissingTouch() {
        let keys = (1...13).map { "emp\($0)" }
        let touch = ["emp1": Date(timeIntervalSince1970: 100)]
        let result = AppState.empMessageShadowKeysToPrune(
            keys: keys, lastTouch: touch,
            busyIds: [], streamingIds: [], activeId: "emp1"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.contains("emp2"))
    }

    func testProtectedKeysNeverPrunedEvenWhenOverCap() {
        let keys = (1...15).map { "emp\($0)" }
        let busy = Set(keys)
        let result = AppState.empMessageShadowKeysToPrune(
            keys: keys, lastTouch: [:],
            busyIds: busy, streamingIds: [], activeId: nil
        )
        XCTAssertTrue(result.isEmpty)
    }
}
