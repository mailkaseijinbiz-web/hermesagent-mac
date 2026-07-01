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

    func testParseRationaleField() {
        let raw = """
        {"vitalHint":"","vitalityMode":"steady","cards":[
          {"id":"a","title":"意外","subtitle":"保存と目標","icon":"sparkles","kind":"explore",
           "rationale":"🎯 目標「健康」× 保存","action":{"type":"none"}}
        ]}
        """
        let parsed = IntentionJSON.parse(raw)
        XCTAssertEqual(parsed?.cards.first?.rationale, "🎯 目標「健康」× 保存")
    }

    @MainActor
    func testComputedIntentionIncludesRest() {
        let state = AppState.shared
        state.intentionDismissedKinds = []
        let result = state.computedIntentionCards()
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

    @MainActor
    func testDismissTracksKind() {
        let state = AppState.shared
        let card = IntentionCard(
            id: "test-dismiss", title: "T", subtitle: "S", icon: "moon", kind: "rest",
            action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
        )
        state.intentionCards = [card]
        state.intentionDismissedIds = []
        state.intentionDismissedKinds = []
        state.dismissIntentionCard("test-dismiss")
        XCTAssertTrue(state.intentionDismissedKinds.contains("rest"))
        XCTAssertTrue(state.intentionIsSilent)
    }

    @MainActor
    func testExerciseSoftensDepletedMode() {
        let state = AppState.shared
        var snap = HealthSnapshot()
        snap.sleepHours = 4.5
        snap.exerciseMinutes = 25
        state.latestHealth = snap
        XCTAssertEqual(state.vitalityMode(), "recovering")
    }

    @MainActor
    func testDismissedRestKindExcludedFromComputed() {
        let state = AppState.shared
        state.intentionDismissedKinds = ["rest"]
        let result = state.computedIntentionCards()
        XCTAssertFalse(result.cards.contains(where: { $0.kind == "rest" }))
    }

    @MainActor
    func testIntentionContextIncludesDismissedKinds() {
        let state = AppState.shared
        state.intentionDismissedKinds = ["recover"]
        let ctx = state.intentionContext()
        XCTAssertTrue(ctx.contains("recover"))
    }
}
