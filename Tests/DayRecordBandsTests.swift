import XCTest
@testable import HermesCustom

/// 24時間バンド分類（自宅/外出/移動/睡眠）の回帰テスト。
/// deriveBandsは内部で`Date()`から当日境界を求めるため、テストも同じ基準で組み立てる。
final class DayRecordBandsTests: XCTestCase {

    private var dayStart: Double { Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 }

    private func visit(_ title: String, place: String? = nil, startOffset: Double, endOffset: Double) -> LifeEvent {
        LifeEvent(id: "v-\(title)-\(startOffset)", kind: "visit",
                  start: dayStart + startOffset, end: dayStart + endOffset,
                  title: title, place: place)
    }

    func testHomeOutTransitSleepClassification() {
        let events = [
            visit("自宅", place: "自宅", startOffset: 0, endOffset: 3600),
            visit("渋谷駅", startOffset: 3600, endOffset: 5400),          // 駅 → transit
            visit("カフェ", startOffset: 5400, endOffset: 9000),          // 駅でも自宅でもない → out
        ]
        let sleep = HubSleepRecord(start: dayStart - 7200, end: dayStart, hours: 2)
        let bands = DayRecordBuilder.deriveBands(events: events, sleep: sleep, homeKeyword: "")
        XCTAssertEqual(bands.map(\.kind), ["sleep", "home", "transit", "out"])
    }

    func testHomeKeywordMatchClassifiesAsHome() {
        let events = [visit("マイホーム東京", startOffset: 0, endOffset: 1800)]
        let bands = DayRecordBuilder.deriveBands(events: events, sleep: nil, homeKeyword: "マイホーム")
        XCTAssertEqual(bands.map(\.kind), ["home"])
    }

    func testMacEventsProduceNoBand() {
        // Mac作業は別次元の指標なのでこの帯には出ない（macHours等は別途集計）。
        let events = [
            LifeEvent(id: "m1", kind: "mac", start: dayStart + 100, end: dayStart + 200, title: "Xcode"),
            visit("自宅", place: "自宅", startOffset: 300, endOffset: 600),
        ]
        let bands = DayRecordBuilder.deriveBands(events: events, sleep: nil, homeKeyword: "")
        XCTAssertEqual(bands.map(\.kind), ["home"])
        XCTAssertFalse(bands.contains { $0.kind == "mac" })
    }

    func testIsTransitMatchesStationAirportBus() {
        XCTAssertTrue(DayRecordBuilder.isTransit("新宿駅"))
        XCTAssertTrue(DayRecordBuilder.isTransit("羽田空港"))
        XCTAssertTrue(DayRecordBuilder.isTransit("高速バス乗り場"))
        XCTAssertFalse(DayRecordBuilder.isTransit("スターバックス"))
    }

    func testVisitTagsUsesTransitForStationNames() {
        XCTAssertEqual(DayRecordBuilder.visitTags(name: "東京駅", isHome: false), ["外出", "移動"])
        XCTAssertEqual(DayRecordBuilder.visitTags(name: "自宅", isHome: true), ["自宅"])
    }

    // 駅visitが次の訪問まで数時間続いても「移動」は30分で打ち切り、残りは外出になる
    func testLongTransitVisitIsCappedAt30Minutes() {
        let events = [
            visit("自宅", place: "自宅", startOffset: 0, endOffset: 14 * 3600),
            visit("新中野駅", startOffset: 14 * 3600, endOffset: 18 * 3600),   // 4時間ぶんのvisit
        ]
        let bands = DayRecordBuilder.deriveBands(events: events, sleep: nil, homeKeyword: "自宅")
        let transit = bands.filter { $0.kind == "transit" }
        let out = bands.filter { $0.kind == "out" }
        XCTAssertEqual(transit.count, 1)
        XCTAssertEqual(transit[0].end - transit[0].start, 30 * 60, accuracy: 1)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, transit[0].end, accuracy: 1)
        XCTAssertEqual(out[0].end, dayStart + 18 * 3600, accuracy: 1)
    }

    // 20分以内の駅visitはそのまま移動帯
    func testShortTransitVisitStaysTransit() {
        let events = [visit("渋谷駅", startOffset: 3600, endOffset: 3600 + 10 * 60)]
        let bands = DayRecordBuilder.deriveBands(events: events, sleep: nil, homeKeyword: "自宅")
        XCTAssertEqual(bands.filter { $0.kind == "transit" }.count, 1)
        XCTAssertEqual(bands.filter { $0.kind == "out" }.count, 0)
    }

    // 帰宅後にiOSの訪問検知が来なくても、Mac作業が始まった時点で外出帯を打ち切り自宅にする
    func testOutVisitEndsWhenMacActivityStarts() {
        let events = [
            visit("カレーハウスCoCo壱番屋", startOffset: 15 * 3600, endOffset: 20 * 3600),
            LifeEvent(id: "mac1", kind: "mac",
                      start: dayStart + 17 * 3600, end: dayStart + 17.5 * 3600,
                      title: "作業"),
        ]
        let bands = DayRecordBuilder.deriveBands(events: events, sleep: nil, homeKeyword: "自宅")
        let out = bands.filter { $0.kind == "out" }
        let home = bands.filter { $0.kind == "home" }
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].end, dayStart + 17 * 3600, accuracy: 1)     // Mac開始で打ち切り
        XCTAssertEqual(home.count, 1)
        XCTAssertEqual(home[0].start, dayStart + 17 * 3600, accuracy: 1)  // 以降は自宅
        XCTAssertEqual(home[0].end, dayStart + 20 * 3600, accuracy: 1)
    }

    // 外出中の短いMac記録（5分未満）や外出直後(10分以内)の開始では切らない
    func testShortOrImmediateMacDoesNotEndOutVisit() {
        let events = [
            visit("カフェ", startOffset: 15 * 3600, endOffset: 18 * 3600),
            LifeEvent(id: "mac2", kind: "mac",
                      start: dayStart + 15 * 3600 + 5 * 60, end: dayStart + 15 * 3600 + 8 * 60,
                      title: "短い"),
        ]
        let bands = DayRecordBuilder.deriveBands(events: events, sleep: nil, homeKeyword: "自宅")
        XCTAssertEqual(bands.filter { $0.kind == "out" }.count, 1)
        XCTAssertEqual(bands.filter { $0.kind == "home" }.count, 0)
    }
}
