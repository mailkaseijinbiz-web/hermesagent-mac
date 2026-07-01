import XCTest
@testable import HermesCustom

final class HermesCronJobParserTests: XCTestCase {

    private let sampleStdout = """
    Scheduled jobs:

      aaa0cf18ec8e [active]
        Name: daily_news
        Schedule: 0 8 * * *
        Repeat: -
        Next run: 2026-07-02T08:00:00+09:00
        Deliver: line:Uabc123
        Last run: 2026-07-01T08:00:00+09:00 ok
      bbb1de29fd9f [paused]
        Name: stock_alert
        Schedule: 30 8,15 * * 1-5
        Deliver: local
        ⚠ Delivery failed: delivery error: LINE push 401: {"message":"authentication failed"}
    """

    func testParseListTwoJobs() {
        let jobs = HermesCronJobParser.parseList(stdout: sampleStdout)
        XCTAssertEqual(jobs.count, 2)

        XCTAssertEqual(jobs[0].id, "aaa0cf18ec8e")
        XCTAssertEqual(jobs[0].name, "daily_news")
        XCTAssertEqual(jobs[0].schedule, "0 8 * * *")
        XCTAssertEqual(jobs[0].deliver, "line:Uabc123")
        XCTAssertEqual(jobs[0].status, "active")
        XCTAssertEqual(jobs[0].lastRun, "2026-07-01T08:00:00+09:00 ok")
        XCTAssertNil(jobs[0].lastError)

        XCTAssertEqual(jobs[1].id, "bbb1de29fd9f")
        XCTAssertEqual(jobs[1].name, "stock_alert")
        XCTAssertEqual(jobs[1].status, "paused")
        XCTAssertEqual(jobs[1].lastError, "Delivery failed: delivery error: LINE push 401: {\"message\":\"authentication failed\"}")
    }

    func testParseListEmptyStdout() {
        XCTAssertTrue(HermesCronJobParser.parseList(stdout: "").isEmpty)
        XCTAssertTrue(HermesCronJobParser.parseList(stdout: "No jobs scheduled.").isEmpty)
    }

    func testParseListDeliveryFailedWithoutWarningSymbol() {
        let stdout = """
          ccc2ef30ge0g [active]
            Name: test_job
            Schedule: 0 9 * * *
            Deliver: line:Uxyz
            Delivery failed: timeout
        """
        let jobs = HermesCronJobParser.parseList(stdout: stdout)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].lastError, "Delivery failed: timeout")
    }
}
