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

    func testCompactMergesAdjacentSameApp() {
        let base: Double = 3600
        let events = [
            DayTimelineEvent(id: "1", time: base, kind: "mac", label: "Chrome",
                             detail: "Docs", duration: 600, sessionCount: 1),
            DayTimelineEvent(id: "2", time: base + 900, kind: "mac", label: "Chrome",
                             detail: "GitHub", duration: 300, sessionCount: 1),
            DayTimelineEvent(id: "m", time: base + 2000, kind: "memo", label: "メモ", detail: "ランチ"),
        ]
        let compact = DayTimelineGraph.compactForDisplay(events, maxMacApps: 16)
        XCTAssertEqual(compact.filter { $0.kind == "mac" }.count, 1)
        XCTAssertEqual(compact.first(where: { $0.label == "Chrome" })?.sessionCount, 2)
        XCTAssertEqual(compact.count, 2)
    }

    func testCompactCapsToTopAppsWithOtherBundle() {
        let base: Double = 3600
        var events: [DayTimelineEvent] = []
        for (i, app) in ["A", "B", "C", "D", "E", "F", "G", "H"].enumerated() {
            events.append(DayTimelineEvent(
                id: app, time: base + Double(i * 100),
                kind: "mac", label: app, detail: app,
                duration: Double(3600 - i * 300), sessionCount: 1
            ))
        }
        let compact = DayTimelineGraph.compactForDisplay(events, maxMacApps: 6)
        XCTAssertEqual(compact.filter { $0.kind == "mac" }.count, 7)
        XCTAssertTrue(compact.contains { $0.label.hasPrefix("その他") })
    }

    func testCompactSummarizesByAppWhenOverMax() {
        let base: Double = 3600
        let apps = ["Chrome", "Safari", "Xcode", "Slack", "Mail"]
        var events: [DayTimelineEvent] = []
        for (ai, app) in apps.enumerated() {
            for block in 0..<2 {
                events.append(DayTimelineEvent(
                    id: "\(app)-\(block)", time: base + Double(ai * 100 + block * 4000),
                    kind: "mac", label: app, detail: "\(app) \(block)", duration: 600, sessionCount: 1
                ))
            }
        }
        events.append(DayTimelineEvent(id: "memo", time: base + 500, kind: "memo", label: "メモ", detail: "メモ"))
        let compact = DayTimelineGraph.compactForDisplay(events, maxMacApps: 8)
        XCTAssertLessThanOrEqual(compact.count, 9)
        XCTAssertEqual(compact.filter { $0.kind == "mac" }.count, 5)
        XCTAssertTrue(compact.allSatisfy { $0.sessionCount > 1 || $0.kind != "mac" || $0.id.hasPrefix("bundle-") })
    }

    func testTimelineEventsForPastDayUsesHistory() {
        let base = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: base)!
        let key = LifeLogDay.key(yesterday)
        var record = AppState.DayRecord(date: key, steps: 8000, locations: "カフェ")
        let events = DayTimelineGraph.build(
            macEntries: [],
            memos: [],
            healthUpdatedAt: LifeLogDay.noonTimestamp(on: yesterday),
            healthLine: "健康データ: 歩数 8000歩",
            locationUpdatedAt: LifeLogDay.noonTimestamp(on: yesterday) + 60,
            locationLine: record.locations,
            photoUpdatedAt: nil,
            photoLine: nil,
            day: yesterday
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains { $0.kind == "health" })
        XCTAssertTrue(events.contains { $0.kind == "location" })
    }
}
