import Foundation

// チーム/社員並び(Phase A)を AppState 本体から分離（#3 god object 分割の継続）。
// @Published employees / teams は stored property のため本体に残し、チームCRUD・配属・
// 並び替えヘルパー(managersFirst/sortedEmployees 等)をここへ集約。すべて internal なので
// 各 View からも従来どおり参照可能。
extension AppState {
    // MARK: - Teams (Phase A)

    /// Display ordering for any employee list: マネージャー float to the top, everyone
    /// else keeps their existing (insertion) relative order. Routed through every
    /// roster / picker / switcher so managers always appear first.
    func managersFirst(_ list: [Employee]) -> [Employee] {
        list.filter { $0.role == .manager } + list.filter { $0.role != .manager }
    }

    /// All employees with managers ordered first (see `managersFirst`).
    var sortedEmployees: [Employee] { managersFirst(employees) }

    func employees(inTeam teamId: String) -> [Employee] { managersFirst(employees.filter { $0.teamId == teamId }) }
    var unassignedEmployees: [Employee] { managersFirst(employees.filter { $0.teamId == nil }) }

    @discardableResult
    func createTeam(name: String) -> Team {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var t = Team(name: n.isEmpty ? "新しいチーム" : n)
        t.updatedAt = Date().timeIntervalSince1970
        teams.append(t)
        return t
    }
    func assignEmployee(_ empId: String, toTeam teamId: String?) {
        guard let idx = employees.firstIndex(where: { $0.id == empId }) else { return }
        employees[idx].teamId = teamId
        employees[idx].updatedAt = Date().timeIntervalSince1970
        if cloudSyncEnabled { Task { await pushEmployees() } }
    }
    func setTeamManager(_ teamId: String, managerId: String?) {
        guard let idx = teams.firstIndex(where: { $0.id == teamId }) else { return }
        teams[idx].managerId = managerId
        teams[idx].updatedAt = Date().timeIntervalSince1970
    }
    func renameTeam(_ teamId: String, name: String) {
        guard let idx = teams.firstIndex(where: { $0.id == teamId }) else { return }
        teams[idx].name = name
        teams[idx].updatedAt = Date().timeIntervalSince1970
    }
    func deleteTeam(_ teamId: String) {
        tombstone(teamId)
        teams.removeAll { $0.id == teamId }
        for i in employees.indices where employees[i].teamId == teamId {
            employees[i].teamId = nil
            employees[i].updatedAt = Date().timeIntervalSince1970
        }
    }

}
