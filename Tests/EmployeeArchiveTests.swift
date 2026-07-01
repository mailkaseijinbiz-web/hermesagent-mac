import XCTest
@testable import HermesCustom

@MainActor
final class EmployeeArchiveTests: XCTestCase {
    func testActiveEmployeesExcludesArchived() {
        var mgr = Employee.make(name: "M", role: .manager)
        var eng = Employee.make(name: "E", role: .engineer)
        eng.archived = true
        let state = AppState.shared
        let backup = state.employees
        defer { state.employees = backup }
        state.employees = [mgr, eng]
        XCTAssertEqual(state.activeEmployees.count, 1)
        XCTAssertEqual(state.activeEmployees.first?.name, "M")
        XCTAssertEqual(state.archivedEmployees.count, 1)
        XCTAssertEqual(state.archivedEmployees.first?.name, "E")
    }

    func testSidebarEmployeesExcludesArchived() {
        var a = Employee.make(name: "A", role: .assistant)
        var b = Employee.make(name: "B", role: .engineer)
        b.archived = true
        a.pinned = true
        let state = AppState.shared
        let backup = state.employees
        defer { state.employees = backup }
        state.employees = [a, b]
        XCTAssertEqual(state.sidebarEmployees.map(\.name), ["A"])
    }
}

final class EmployeeProactivePromptTests: XCTestCase {
    func testCheckInIncludesRoleAndGreeting() {
        let emp = Employee.make(name: "ハル", role: .engineer)
        let prompt = EmployeeProactivePrompt.checkIn(for: emp, pendingTasks: [], hour: 9)
        XCTAssertTrue(prompt.contains("ハル"))
        XCTAssertTrue(prompt.contains("エンジニア"))
        XCTAssertTrue(prompt.contains("おはよう"))
        XCTAssertTrue(prompt.contains("能動"))
    }

    func testCheckInIncludesPendingTasks() {
        let emp = Employee.make(name: "T", role: .assistant)
        var task = WorkTask(title: "レポート作成")
        task.assigneeId = emp.id
        let prompt = EmployeeProactivePrompt.checkIn(for: emp, pendingTasks: [task], hour: 14)
        XCTAssertTrue(prompt.contains("レポート作成"))
        XCTAssertTrue(prompt.contains("こんにちは"))
    }
}
