import XCTest
@testable import HermesCustom

final class IntentionCardTests: XCTestCase {

    func testParseJSONFromFence() {
        let raw = """
        ```json
        {"vitalHint":"睡眠 5.2h","vitalityMode":"recovering","cards":[
          {"id":"a","title":"軽く回復","subtitle":"散歩15分","icon":"leaf","kind":"recover",
           "action":{"type":"none"}},
          {"id":"b","title":"今日の1つ","subtitle":"資料作成","icon":"checklist","kind":"focus",
           "action":{"type":"task","taskTitle":"資料作成"}}
        ]}
        ```
        """
        let parsed = IntentionJSON.parse(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.vitalityMode, "recovering")
        XCTAssertEqual(parsed?.cards.count, 2)
        XCTAssertEqual(parsed?.cards[0].title, "軽く回復")
        XCTAssertEqual(parsed?.cards[1].action.type, "task")
    }

    func testParseCapsAtThreeCards() {
        let raw = """
        {"vitalHint":"","vitalityMode":"steady","cards":[
          {"id":"1","title":"A","subtitle":"a","icon":"a","kind":"focus","action":{"type":"none"}},
          {"id":"2","title":"B","subtitle":"b","icon":"b","kind":"focus","action":{"type":"none"}},
          {"id":"3","title":"C","subtitle":"c","icon":"c","kind":"focus","action":{"type":"none"}},
          {"id":"4","title":"D","subtitle":"d","icon":"d","kind":"focus","action":{"type":"none"}}
        ]}
        """
        let parsed = IntentionJSON.parse(raw)
        XCTAssertEqual(parsed?.cards.count, 3)
    }

    @MainActor
    func testComputedIntentionIncludesRest() {
        let result = AppState.shared.computedIntentionCards()
        XCTAssertFalse(result.cards.isEmpty)
        XCTAssertTrue(result.cards.contains(where: { $0.kind == "rest" }))
        XCTAssertFalse(result.vitalHint.isEmpty)
    }

    @MainActor
    func testVitalityModeDepletedOnLowSleep() {
        let state = AppState.shared
        var snap = HealthSnapshot()
        snap.sleepHours = 4.5
        state.latestHealth = snap
        XCTAssertEqual(state.vitalityMode(), "depleted")
    }
}
