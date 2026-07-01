import XCTest
@testable import HermesCustom

final class FailedDeliveryStoreTests: XCTestCase {

    private func record(
        jobId: String = "aaa0cf18ec8e",
        error: String = "Delivery failed: LINE push 401",
        at date: Date
    ) -> FailedDeliveryRecord {
        FailedDeliveryRecord(
            id: UUID().uuidString,
            jobId: jobId,
            jobName: "test",
            deliver: "line:Uabc",
            error: error,
            recordedAt: date
        )
    }

    func testShouldAppendAllowsFreshError() {
        let now = Date()
        XCTAssertTrue(FailedDeliveryLogic.shouldAppend(existing: [], jobId: "a", error: "err", now: now))
    }

    func testShouldAppendDedupesSameJobAndErrorWithinOneHour() {
        let now = Date()
        let existing = [record(jobId: "job1", error: "LINE 401", at: now.addingTimeInterval(-600))]
        XCTAssertFalse(FailedDeliveryLogic.shouldAppend(existing: existing, jobId: "job1", error: "LINE 401", now: now))
    }

    func testShouldAppendAllowsSameJobDifferentError() {
        let now = Date()
        let existing = [record(jobId: "job1", error: "LINE 401", at: now.addingTimeInterval(-600))]
        XCTAssertTrue(FailedDeliveryLogic.shouldAppend(existing: existing, jobId: "job1", error: "timeout", now: now))
    }

    func testShouldAppendAllowsDuplicateAfterOneHour() {
        let now = Date()
        let existing = [record(jobId: "job1", error: "LINE 401", at: now.addingTimeInterval(-3700))]
        XCTAssertTrue(FailedDeliveryLogic.shouldAppend(existing: existing, jobId: "job1", error: "LINE 401", now: now))
    }

    func testCapKeepsNewestFirst() {
        let records = (0..<35).map { i in
            record(error: "e\(i)", at: Date(timeIntervalSince1970: Double(i)))
        }
        let capped = FailedDeliveryLogic.cap(records)
        XCTAssertEqual(capped.count, 30)
        XCTAssertEqual(capped.first?.error, "e0")
        XCTAssertEqual(capped.last?.error, "e29")
    }
}
