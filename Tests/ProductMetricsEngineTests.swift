import XCTest
@testable import HermesCustom

final class ProductMetricsEngineTests: XCTestCase {

    func testAgencyDays7d() {
        let now = Date()
        let ts = now.timeIntervalSince1970
        let events = [
            ProductMetricsEvent(
                name: "intention.card_confirmed",
                ts: ts,
                props: ["kind": "rest", "vitality_mode": "depleted"]
            ),
            ProductMetricsEvent(
                name: "intention.card_confirmed",
                ts: ts - 86_400,
                props: ["kind": "focus", "vitality_mode": "peak"]
            ),
        ]
        let summary = ProductMetricsEngine.summarize(events: events, windowDays: 7, now: now)
        XCTAssertEqual(summary.agencyDays7d, 2)
        XCTAssertEqual(summary.nsmPerWeek, 2)
    }

    func testGuardrailFilterStripsFocusOnDepleted() {
        let none = IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
        let cards = [
            IntentionCard(id: "f", title: "集中", subtitle: "s", icon: "checklist", kind: "focus", action: none),
            IntentionCard(id: "r", title: "休む", subtitle: "s", icon: "moon", kind: "rest", action: none),
        ]
        let result = ProductMetricsEngine.guardrailFilterCards(cards, vitalityMode: "depleted")
        XCTAssertEqual(result.cards.count, 1)
        XCTAssertEqual(result.cards.first?.kind, "rest")
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testIntentionFitRate() {
        let now = Date()
        let ts = now.timeIntervalSince1970
        let events = [
            ProductMetricsEvent(
                name: "intention.card_confirmed",
                ts: ts,
                props: ["kind": "rest", "vitality_mode": "depleted"]
            ),
            ProductMetricsEvent(
                name: "intention.card_confirmed",
                ts: ts,
                props: ["kind": "focus", "vitality_mode": "depleted"]
            ),
        ]
        let summary = ProductMetricsEngine.summarize(events: events, windowDays: 7, now: now)
        XCTAssertEqual(summary.intentionFitRate, 0.5, accuracy: 0.001)
    }
}
