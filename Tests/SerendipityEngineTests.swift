import XCTest
@testable import HermesCustom

final class SerendipityEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func testMatchesCollectionToGoalKeyword() {
        var item = CollectionItem(kind: "url", title: "サウナの科学", source: "share")
        item.createdAt = now.addingTimeInterval(-3 * 86400)
        let hints = SerendipityEngine.hints(
            from: [item],
            likes: "サウナ, コーヒー",
            goals: "健康",
            now: now
        )
        XCTAssertFalse(hints.isEmpty)
        XCTAssertTrue(hints[0].line.contains("サウナ"))
        XCTAssertTrue(hints[0].rationale.contains("🎯"))
    }

    func testEmptyWhenNoNorthStar() {
        let item = CollectionItem(kind: "text", text: "メモ", source: "share")
        XCTAssertTrue(SerendipityEngine.hints(from: [item], likes: "", goals: "").isEmpty)
    }

    func testCapsHintCount() {
        var items: [CollectionItem] = []
        for i in 0..<5 {
            var item = CollectionItem(kind: "text", text: "健康メモ\(i)", source: "share")
            item.createdAt = now.addingTimeInterval(-Double(i + 1) * 86400)
            items.append(item)
        }
        let hints = SerendipityEngine.hints(from: items, likes: "", goals: "健康", now: now, maxHints: 2)
        XCTAssertEqual(hints.count, 2)
    }

    func testHintMatchingCardId() {
        var item = CollectionItem(kind: "text", text: "健康についてのメモ", source: "share")
        item.createdAt = now.addingTimeInterval(-2 * 86400)
        let hints = SerendipityEngine.hints(from: [item], likes: "", goals: "健康", now: now)
        guard let first = hints.first else { return XCTFail("expected hint") }
        let cardId = "serendipity-\(first.relatedNorthStar.hashValue)"
        let matched = SerendipityEngine.hint(
            matchingCardId: cardId, from: [item], likes: "", goals: "健康", now: now
        )
        XCTAssertEqual(matched?.itemId, item.id)
        XCTAssertEqual(matched?.itemLabel, "健康についてのメモ")
    }

    func testDeepDivePrompt() {
        let hint = SerendipityHint(
            line: "x", rationale: "y", relatedNorthStar: "健康",
            itemLabel: "サウナ記事", itemId: "a"
        )
        XCTAssertEqual(
            SerendipityEngine.deepDivePrompt(for: hint),
            "保存した「サウナ記事」と目標「健康」のつながりを深掘りしたい"
        )
    }
}
