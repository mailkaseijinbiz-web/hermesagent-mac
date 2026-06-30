import XCTest
@testable import HermesCustom

final class DayTimelineGraphTests: XCTestCase {

    func testBuildSortsByTime() {
        let base = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var mac = MacActivityEntry()
        mac.id = "a"; mac.appName = "Xcode"; mac.label = "Code"
        mac.startTime = base + 3600; mac.endTime = base + 4000

        var memo = MacMemo(text: "ランチ", time: Date(timeIntervalSince1970: base + 4200))

        let events = DayTimelineGraph.build(
            macEntries: [mac],
            memos: [memo],
            healthUpdatedAt: base + 28800,
            healthLine: "歩数 5000",
            locationUpdatedAt: base + 32400,
            locationLine: "自宅 → オフィス",
            photoUpdatedAt: nil,
            photoLine: nil
        )
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events.map(\.time), events.map(\.time).sorted())
        XCTAssertTrue(events.contains { $0.kind == "location" })
    }

    func testFormatForContextLimitsLines() {
        let events = (0..<20).map { i in
            DayTimelineEvent(id: "\(i)", time: Double(3600 + i * 60), kind: "mac",
                             label: "App", detail: "work \(i)")
        }
        let text = DayTimelineGraph.formatForContext(events, max: 5)
        XCTAssertEqual(text.components(separatedBy: "\n").count, 5)
    }
}
