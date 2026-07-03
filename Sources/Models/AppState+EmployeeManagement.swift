import Foundation
import AppKit

// 社員ごとの管理(Phase E)を AppState 本体から分離（#3 god object 分割の継続）。
// 詳細/パネル/履歴オープン、成果物(artifact) CRUD、作業フォルダ、改名/並び替え/ピン留めなど。
// @Published employees/artifacts は stored のため本体に残置。defaultArtifactTitle は同梱private。
extension AppState {
    // MARK: - Per-employee management (Phase E)

    /// Open the per-employee detail as a FULL-SCREEN screen (タスク / 成果物 / ファイル).
    func openEmployeeDetail(_ employeeId: String) {
        guard employees.contains(where: { $0.id == employeeId }) else { return }
        detailEmployeeId = employeeId
        view = "employee"
    }

    /// Open the active employee's management in the RIGHT side panel — so you can keep
    /// chatting on the left while checking that employee's tasks / 成果物 / files.
    func openEmployeePanel(_ employeeId: String) {
        guard employees.contains(where: { $0.id == employeeId }) else { return }
        // Make this the active employee (switchEmployee jumps to chat) so the panel,
        // which is scoped to the active employee, shows the right person.
        if activeEmployeeId != employeeId { switchEmployee(employeeId) }
        rightTab = .employee
        showRightSidebar = true
    }

    /// Open this employee's chat history (session list) in the RIGHT side panel — the chat
    /// stays on the left. Used by the sidebar kebab menu → チャット履歴. nil → 全体（社員なし）.
    func openChatHistoryPanel(_ employeeId: String?) {
        if let employeeId {
            guard employees.contains(where: { $0.id == employeeId }) else { return }
            if activeEmployeeId != employeeId { switchEmployee(employeeId) }
        } else if activeEmployeeId != nil {
            switchEmployee(nil)
        }
        rightTab = .history
        showRightSidebar = true
    }

    /// This employee's tasks (newest first — createTask inserts at index 0).
    func tasks(for employeeId: String) -> [WorkTask] {
        workTasks.filter { $0.assigneeId == employeeId }
    }
    func tasks(for employeeId: String, status: TaskStatus) -> [WorkTask] {
        workTasks.filter { $0.assigneeId == employeeId && $0.status == status }
    }

    /// This employee's artifacts, most-recently-updated first.
    func artifactsFor(_ employeeId: String) -> [Artifact] {
        artifacts.filter { $0.employeeId == employeeId }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func addArtifact(employeeId: String, title: String, kind: ArtifactKind, body: String = "",
                     taskId: String? = nil, sessionId: String? = nil) -> Artifact {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var a = Artifact(employeeId: employeeId,
                         title: t.isEmpty ? defaultArtifactTitle(kind: kind, body: body) : t,
                         kind: kind, body: body)
        a.taskId = taskId
        a.sessionId = sessionId
        artifacts.insert(a, at: 0)
        triggerToast(message: "\(kind.title)を追加しました")
        return a
    }

    func updateArtifact(_ id: String, title: String? = nil, body: String? = nil) {
        guard let idx = artifacts.firstIndex(where: { $0.id == id }) else { return }
        if let body = body { artifacts[idx].body = body }
        if let title = title {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            // Mirror addArtifact: fall back to a derived title rather than persisting blank.
            artifacts[idx].title = t.isEmpty
                ? defaultArtifactTitle(kind: artifacts[idx].kind, body: artifacts[idx].body)
                : t
        }
        artifacts[idx].updatedAt = Date().timeIntervalSince1970
    }

    func deleteArtifact(_ id: String) {
        tombstone(id)
        artifacts.removeAll { $0.id == id }
    }

    private func defaultArtifactTitle(kind: ArtifactKind, body: String) -> String {
        switch kind {
        case .file: return (body as NSString).lastPathComponent
        case .link: return body.isEmpty ? "リンク" : body
        case .note:
            let first = body.split(separator: "\n").first.map(String.init) ?? "メモ"
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "メモ" : String(trimmed.prefix(60))
        }
    }

    /// Save an assistant reply as a note artifact for a given employee (defaults to the
    /// active one). Used by the chat "成果物として保存" action.
    func saveReplyAsArtifact(_ content: String, employeeId: String? = nil) {
        let eid = employeeId ?? activeEmployeeId
        guard let eid = eid else { triggerToast(message: "先に社員を選択してください"); return }
        addArtifact(employeeId: eid, title: "", kind: .note, body: content, sessionId: currentSessionId)
    }

    /// Set (or clear) an employee's working folder (cwd). Device-local — `workspacePath`
    /// is deliberately not synced (it's a path on this machine), so this won't push to iCloud.
    func setEmployeeWorkspace(_ employeeId: String, path: String?) {
        guard let idx = employees.firstIndex(where: { $0.id == employeeId }) else { return }
        employees[idx].workspacePath = path
        triggerToast(message: path == nil ? "作業フォルダを解除しました" : "作業フォルダを設定しました")
    }

    /// Base dir holding auto-assigned per-employee working folders.
    var employeeWorkspaceBase: String { (githubCloneBase as NSString).appendingPathComponent("employees") }

    /// Ensure an employee has a working folder, auto-creating one named after them if unset.
    /// Device-local (workspacePath isn't synced), so each machine keeps its own folder.
    @discardableResult
    func ensureEmployeeWorkspace(_ employeeId: String) -> String? {
        guard let idx = employees.firstIndex(where: { $0.id == employeeId }) else { return nil }
        if let p = employees[idx].workspacePath, !p.trimmingCharacters(in: .whitespaces).isEmpty { return p }
        let base = employeeWorkspaceBase
        let slug = appSlug(employees[idx].name.isEmpty ? employees[idx].role.title : employees[idx].name)
        var folder = (base as NSString).appendingPathComponent(slug)
        var i = 2
        while employees.contains(where: { $0.id != employeeId && $0.workspacePath == folder }) {
            folder = (base as NSString).appendingPathComponent("\(slug)-\(i)"); i += 1
        }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            // Don't persist a workspace path whose folder doesn't exist (would break the agent cwd).
            reportFailure("社員の作業フォルダ作成に失敗 (\(folder))", error: error,
                          toast: "作業フォルダを作成できませんでした。設定で作業フォルダを指定してください。")
            return nil
        }
        employees[idx].workspacePath = folder
        return folder
    }

    /// Auto-assign a working folder to every employee that lacks one (hire + launch migration).
    func ensureAllEmployeeWorkspaces() {
        for e in employees where (e.workspacePath ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            ensureEmployeeWorkspace(e.id)
        }
    }

    /// Rename an employee (shared field → bump updatedAt so the new name syncs).
    func renameEmployee(_ employeeId: String, name: String) {
        guard let idx = employees.firstIndex(where: { $0.id == employeeId }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, employees[idx].name != n else { return }
        employees[idx].name = n
        employees[idx].updatedAt = Date().timeIntervalSince1970
    }

    /// Reorder employees (sidebar drag-and-drop): move `id` to just before `targetId`
    /// (nil → end). Order is device-local (not part of the synced shared fields).
    func moveEmployee(_ id: String, before targetId: String?) {
        guard id != targetId, let from = employees.firstIndex(where: { $0.id == id }) else { return }
        let moved = employees.remove(at: from)
        if let targetId = targetId, let to = employees.firstIndex(where: { $0.id == targetId }) {
            employees.insert(moved, at: to)
        } else {
            employees.append(moved)
        }
    }

    /// Sidebar order: pinned employees float to the top, preserving the stored (drag-drop)
    /// order within each group.
    var sidebarEmployees: [Employee] {
        let active = employees.filter { !$0.isArchived }
        return active.filter { $0.isPinned } + active.filter { !$0.isPinned }
    }

    /// Toggle an employee's sidebar pin (kebab menu → ピン留め).
    func togglePinEmployee(_ id: String) {
        guard let idx = employees.firstIndex(where: { $0.id == id }) else { return }
        employees[idx].pinned = !employees[idx].isPinned
    }

}
