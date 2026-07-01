import XCTest
@testable import HermesCustom

final class HermesExecPolicyTests: XCTestCase {

    func testBackoffIncreasesWithAttempt() {
        XCTAssertEqual(HermesExecPolicy.backoffDelay(attempt: 0), 0)
        XCTAssertEqual(HermesExecPolicy.backoffDelay(attempt: 1), 2)
        XCTAssertEqual(HermesExecPolicy.backoffDelay(attempt: 2), 4)
        XCTAssertEqual(HermesExecPolicy.backoffDelay(attempt: 5), 32)
    }

    func testBackoffCapsAtSixtySeconds() {
        XCTAssertEqual(HermesExecPolicy.backoffDelay(attempt: 10), 60)
    }

    func testReconcileDropsResolvedJobs() {
        let rec = FailedDeliveryRecord(
            id: "r1", jobId: "job1", jobName: "A", deliver: "local",
            error: "timeout", recordedAt: Date()
        )
        let okJob = HermesCronJob(
            id: "job1", name: "A", schedule: "0 9 * * *", repeatCount: "0",
            nextRun: "", deliver: "local", status: "active", script: nil, mode: nil,
            lastRun: nil, lastError: nil
        )
        let pruned = HermesExecPolicy.reconcileDeadLetters(records: [rec], jobs: [okJob])
        XCTAssertTrue(pruned.isEmpty)
    }

    func testReconcileKeepsStillFailingJobs() {
        let rec = FailedDeliveryRecord(
            id: "r1", jobId: "job1", jobName: "A", deliver: "line:x",
            error: "LINE 401", recordedAt: Date()
        )
        let badJob = HermesCronJob(
            id: "job1", name: "A", schedule: "0 9 * * *", repeatCount: "0",
            nextRun: "", deliver: "line:x", status: "active", script: nil, mode: nil,
            lastRun: nil, lastError: "LINE push 401"
        )
        let kept = HermesExecPolicy.reconcileDeadLetters(records: [rec], jobs: [badJob])
        XCTAssertEqual(kept.count, 1)
    }
}
