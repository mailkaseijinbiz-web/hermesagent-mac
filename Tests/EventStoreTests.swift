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

    private func cleanup(_ day: Date) async {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        PrivateStore.remove(key: "events-\(f.string(from: day))")
        await EventStore.shared.invalidate(on: day)
    }

    func testUpsertPersistsAndRoundTripsThroughPrivateStore() async {
        let day = Date(timeIntervalSince1970: 1_557_100_000) // 2019-05-06
        await EventStore.shared.upsert([ev("a", day: day, offset: 10)])

        let out = await EventStore.shared.events(on: day)
        XCTAssertEqual(out.map(\.id), ["a"])
        await cleanup(day)
    }

    func testIdempotentUpsertDoesNotDuplicate() async {
        let day = Date(timeIntervalSince1970: 1_557_964_000) // 2019-05-16
        let e = ev("a", day: day, offset: 10)
        await EventStore.shared.upsert([e])
        await EventStore.shared.upsert([e])

        let out = await EventStore.shared.events(on: day)
        XCTAssertEqual(out.count, 1)
        await cleanup(day)
    }

    func testUpsertAppliesLastWriteWinsOnConflict() async {
        let day = Date(timeIntervalSince1970: 1_558_828_000) // 2019-05-26
        await EventStore.shared.upsert([ev("a", day: day, offset: 10, updated: 1)])
        var stale = ev("a", day: day, offset: 10, updated: 0)
        stale.title = "古い方"
        await EventStore.shared.upsert([stale])

        let out = await EventStore.shared.events(on: day)
        XCTAssertEqual(out.first?.title, "t") // 新しい方(updatedAt: 1)が勝つ
        await cleanup(day)
    }

    func testTombstoneHidesFromEventsButRawCountKeepsIt() async {
        let day = Date(timeIntervalSince1970: 1_559_692_000) // 2019-06-05
        let start = Calendar.current.startOfDay(for: day).timeIntervalSince1970 + 10
        await EventStore.shared.upsert([ev("a", day: day, offset: 10)])
        await EventStore.shared.tombstone(id: "a", start: start)

        let out = await EventStore.shared.events(on: day)
        XCTAssertTrue(out.isEmpty)
        let raw = await EventStore.shared.rawCount(on: day)
        XCTAssertEqual(raw, 1) // 墓石として残存(フィルタ前件数には含まれる)
        await cleanup(day)
    }

    func testEventsOnlyReturnsRequestedDay() async {
        let day = Date(timeIntervalSince1970: 1_560_556_000) // 2019-06-15
        let otherDay = Date(timeIntervalSince1970: 1_551_916_000) // 2019-03-07 (他テストと非衝突)
        await EventStore.shared.upsert([
            ev("today", day: day, offset: 10),
            ev("yesterday", day: otherDay, offset: 10)
        ])

        let out = await EventStore.shared.events(on: day)
        XCTAssertEqual(out.map(\.id), ["today"])
        await cleanup(day)
        await cleanup(otherDay)
    }

    func testDoubleWriteFromMacActivityAndMemoMirrorsToEventStore() async {
        let day = Date(timeIntervalSince1970: 1_561_420_000) // 2019-06-25
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
        await cleanup(day)
    }

    /// 07-10発見の懸念（cacheがPrivateStore.remove()で無効化されない）に対する回帰テスト。
    /// invalidate(on:)を呼ばずにファイルだけ消すと、actor内cacheが残って古いデータが返り続けることを確認し、
    /// invalidate(on:)を呼べば同一プロセス内でも正しく空に戻ることを確認する。
    func testInvalidateClearsStaleCacheAfterExternalFileRemoval() async {
        let day = Date(timeIntervalSince1970: 1_562_284_000) // 2019-07-05
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let key = "events-\(f.string(from: day))"

        await EventStore.shared.upsert([ev("a", day: day, offset: 10)])
        let before = await EventStore.shared.events(on: day)
        XCTAssertEqual(before.map(\.id), ["a"])

        // ファイルだけ外部から削除（invalidateを呼ばない）→ actor内cacheは残留する。
        PrivateStore.remove(key: key)
        let stillCached = await EventStore.shared.events(on: day)
        XCTAssertEqual(stillCached.map(\.id), ["a"], "invalidateを呼ぶまではcacheが残るのが既知の挙動")

        // invalidateを呼べばcacheが破棄され、ディスク上には既に何もないため空になる。
        await EventStore.shared.invalidate(on: day)
        let afterInvalidate = await EventStore.shared.events(on: day)
        XCTAssertTrue(afterInvalidate.isEmpty)

        await cleanup(day)
    }
}
