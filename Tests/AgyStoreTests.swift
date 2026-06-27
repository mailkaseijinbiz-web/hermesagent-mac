import XCTest
@testable import HermesCustom

/// Tests for the writable agy session store (records one-shot agy turns so they appear
/// in history / sync). Uses a temp file path so the real ~/.hermes store is untouched.
final class AgyStoreTests: XCTestCase {
    private func tempStore() -> AgyStore {
        let p = NSTemporaryDirectory() + "agy-test-\(UUID().uuidString).json"
        return AgyStore(path: p)
    }

    func testRecordCreatesSessionWithTitleFromFirstUserLine() {
        let s = tempStore()
        let id = s.record(sessionId: nil, employeeId: "emp1",
                          userText: "サウナの最新情報を教えて\n（詳しく）", assistantText: "了解しました。", timestamp: 1000)
        XCTAssertTrue(AgyStore.isAgySession(id), "new id should carry the agy- prefix")
        let session = s.session(id)
        XCTAssertEqual(session?.title, "サウナの最新情報を教えて")   // first line, trimmed
        XCTAssertEqual(session?.employeeId, "emp1")
        XCTAssertEqual(s.messages(id).map { $0.role }, ["user", "assistant"])
        XCTAssertEqual(s.messages(id).last?.content, "了解しました。")
    }

    func testSecondTurnAppendsToSameSession() {
        let s = tempStore()
        let id = s.record(sessionId: nil, employeeId: "e", userText: "一通目", assistantText: "返信1", timestamp: 1)
        let id2 = s.record(sessionId: id, employeeId: "e", userText: "二通目", assistantText: "返信2", timestamp: 2)
        XCTAssertEqual(id, id2, "same session id should be reused")
        XCTAssertEqual(s.messages(id).count, 4)   // 2 user + 2 assistant
        XCTAssertEqual(s.session(id)?.title, "一通目", "title stays the first turn's")
    }

    func testPersistenceAcrossInstances() {
        let p = NSTemporaryDirectory() + "agy-persist-\(UUID().uuidString).json"
        let id = AgyStore(path: p).record(sessionId: nil, employeeId: nil,
                                          userText: "残るか確認", assistantText: "残ります", timestamp: 5)
        // A fresh instance over the same file must see the recorded turn.
        let reopened = AgyStore(path: p)
        XCTAssertEqual(reopened.session(id)?.messages.count, 2)
        XCTAssertEqual(reopened.messages(id).last?.content, "残ります")
    }

    func testDeleteRemovesSession() {
        let s = tempStore()
        let id = s.record(sessionId: nil, employeeId: nil, userText: "x", assistantText: "y", timestamp: 1)
        s.delete(id)
        XCTAssertNil(s.session(id))
        XCTAssertTrue(s.sessions().isEmpty)
    }

    func testVersionChangesOnRecord() {
        let s = tempStore()
        let v0 = s.version()
        _ = s.record(sessionId: nil, employeeId: nil, userText: "a", assistantText: "b", timestamp: 1)
        XCTAssertNotEqual(v0, s.version(), "version must change so clients re-pull")
    }

    func testSessionsSortedNewestFirst() {
        let s = tempStore()
        let old = s.record(sessionId: nil, employeeId: nil, userText: "old", assistantText: "r", timestamp: 100)
        let new = s.record(sessionId: nil, employeeId: nil, userText: "new", assistantText: "r", timestamp: 200)
        XCTAssertEqual(s.sessions().first?.id, new)
        XCTAssertEqual(s.sessions().last?.id, old)
    }
}
