import XCTest
import HermesShared
@testable import HermesCustom

/// 統一イベントストア(H1)の回帰テスト。日付は実データと衝突しない過去日を専有し、
/// 各テストで別日を使ってactor内キャッシュの干渉を避ける。
final class EventStoreTests: XCTestCase {

    private func ev(_ id: String, day: Date, offset: TimeInterval = 0,
                     updated: Double = 1, deleted: Bool? = nil) -> HermesEvent {
        let start = Calendar.current.startOfDay(for: day).timeIntervalSince1970 + offset
        return HermesEvent(id: id, kind: "memo", start: start, title: "t",
                            source: "mac", updatedAt: updated, deleted: deleted)
    }

    private func cleanup(_ day: Date) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        PrivateStore.remove(key: "events-\(f.string(from: day))")
    }

    func testUpsertPersistsAndRoundTripsThroughPrivateStore() async {
        let day = Date(timeIntervalSince1970: 1_557_100_000) // 2019-05-06
        defer { cleanup(day) }
        await EventStore.shared.upsert([ev("a", day: day, offset: 10)])

        let out = await EventStore.shared.events(on: day)
        XCTAssertEqual(out.map(\.id), ["a"])
    }

    func testIdempotentUpsertDoesNotDuplicate() async {
        let day = Date(timeIntervalSince1970: 1_557_964_000) // 2019-05-16
        defer { cleanup(day) }
        let e = ev("a", day: day, offset: 10)
        await EventStore.shared.upsert([e])
        await EventStore.shared.upsert([e])

        let out = await EventStore.shared.events(on: day)
        XCTAssertEqual(out.count, 1)
    }

    func testUpsertAppliesLastWriteWinsOnConflict() async {
        let day = Date(timeIntervalSince1970: 1_558_828_000) // 2019-05-26
        defer { cleanup(day) }
        await EventStore.shared.upsert([ev("a", day: day, offset: 10, updated: 1)])
        var stale = ev("a", day: day, offset: 10, updated: 0)
        stale.title = "古い方"
        await EventStore.shared.upsert([stale])

        let out = await EventStore.shared.events(on: day)
        XCTAssertEqual(out.first?.title, "t") // 新しい方(updatedAt: 1)が勝つ
    }

    func testTombstoneHidesFromEventsButRawCountKeepsIt() async {
        let day = Date(timeIntervalSince1970: 1_559_692_000) // 2019-06-05
        defer { cleanup(day) }
        let start = Calendar.current.startOfDay(for: day).timeIntervalSince1970 + 10
        await EventStore.shared.upsert([ev("a", day: day, offset: 10)])
        await EventStore.shared.tombstone(id: "a", start: start)

        let out = await EventStore.shared.events(on: day)
        XCTAssertTrue(out.isEmpty)
        let raw = await EventStore.shared.rawCount(on: day)
        XCTAssertEqual(raw, 1) // 墓石として残存(フィルタ前件数には含まれる)
    }

    func testEventsOnlyReturnsRequestedDay() async {
        let day = Date(timeIntervalSince1970: 1_560_556_000) // 2019-06-15
        let otherDay = Date(timeIntervalSince1970: 1_551_916_000) // 2019-03-07 (他テストと非衝突)
        defer { cleanup(day); cleanup(otherDay) }
        await EventStore.shared.upsert([
            ev("today", day: day, offset: 10),
            ev("yesterday", day: otherDay, offset: 10)
        ])

        let out = await EventStore.shared.events(on: day)
        XCTAssertEqual(out.map(\.id), ["today"])
    }

    func testDoubleWriteFromMacActivityAndMemoMirrorsToEventStore() async {
        let day = Date(timeIntervalSince1970: 1_561_420_000) // 2019-06-25
        defer { cleanup(day) }
        let start = Calendar.current.startOfDay(for: day).timeIntervalSince1970 + 10
        var macEntry = MacActivityEntry()
        macEntry.id = "x1"
        macEntry.appName = "Xcode"
        macEntry.startTime = start
        macEntry.endTime = start + 60
        let memo = MacMemo(id: "m1", text: "メモ", time: Date(timeIntervalSince1970: start))

        await EventStore.shared.upsert([HermesEvent.from(macEntry)])
        await EventStore.shared.upsert([HermesEvent.from(memo)])

        let out = await EventStore.shared.events(on: day)
        XCTAssertEqual(Set(out.map(\.id)), ["mac:x1", "memo:m1"])
    }
}
