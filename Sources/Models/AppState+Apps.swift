import Foundation
import AppKit

// アプリ案件(Phase F)を AppState 本体から分離（#3 god object 分割の継続）。
// @Published apps は stored property のため本体に残し、案件CRUD・開発開始・フォルダ/ターミナル
// /プレビュー導線を集約。appSlug は ensureEmployeeWorkspace(本体)からも使うため internal に。
extension AppState {
    // MARK: - Apps (Phase F — AI-developed app projects)

    /// Filesystem-safe folder slug for an app name (keeps JP characters; HFS+ allows them).
    func appSlug(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop control characters / newlines that would make hostile or unusable folder names.
        s = String(s.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        })
        for ch in ["/", " ", "\t", ":", "\\", "?", "%", "*", "|", "\"", "<", ">"] {
            s = s.replacingOccurrences(of: ch, with: "-")
        }
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }   // collapse runs
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))   // no hidden/dotfolder, no edge dashes
        if s.count > 60 { s = String(s.prefix(60)) }
        return s.isEmpty ? "app-\(Int(Date().timeIntervalSince1970))" : s
    }

    /// Resolve an app's project folder for THIS device. The synced `folderPath` is an
    /// absolute path from the originating Mac; re-derive it under the local dev base by
    /// folder name so develop/open target a sane local path cross-device (mirrors how
    /// workspacePath/.file-artifacts are kept device-local).
    func appFolder(_ app: AppProject) -> String {
        let name = (app.folderPath as NSString).lastPathComponent
        return (githubCloneBase as NSString).appendingPathComponent(name.isEmpty ? appSlug(app.name) : name)
    }

    /// Create an app project: auto-make a folder under the shared dev base (collision-safe),
    /// seed a README from the spec, and register it (newest first).
    @discardableResult
    func createApp(name: String, detail: String, assigneeId: String?,
                   previewURL: String = "", runCommand: String = "") -> AppProject? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = n.isEmpty ? "新しいアプリ" : n
        let slug = appSlug(display)
        var folder = (githubCloneBase as NSString).appendingPathComponent(slug)
        var i = 2
        while FileManager.default.fileExists(atPath: folder) {
            folder = (githubCloneBase as NSString).appendingPathComponent("\(slug)-\(i)"); i += 1
        }
        // Surface failure instead of registering an app whose folder doesn't exist.
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            triggerToast(message: "フォルダを作成できませんでした: \(error.localizedDescription)")
            return nil
        }
        let spec = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spec.isEmpty {
            let readme = "# \(display)\n\n\(spec)\n"
            let readmePath = (folder as NSString).appendingPathComponent("README.md")
            do {
                try readme.write(toFile: readmePath, atomically: true, encoding: .utf8)
            } catch {
                Log.failure("app", "README.md の書き込みに失敗 (\(readmePath))", error)   // 非致命: アプリ登録は継続
            }
        }
        var a = AppProject(name: display, detail: detail, folderPath: folder)
        a.assigneeId = assigneeId
        a.previewURL = previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        a.runCommand = runCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        apps.insert(a, at: 0)
        triggerToast(message: "アプリを作成しました：\(a.name)")
        return a
    }

    func updateApp(_ id: String, name: String? = nil, detail: String? = nil,
                   previewURL: String? = nil, runCommand: String? = nil) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        if let v = name?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { apps[idx].name = v }
        if let v = detail { apps[idx].detail = v }
        if let v = previewURL { apps[idx].previewURL = v.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let v = runCommand { apps[idx].runCommand = v.trimmingCharacters(in: .whitespacesAndNewlines) }
        apps[idx].updatedAt = Date().timeIntervalSince1970
    }
    func setAppStatus(_ id: String, _ s: AppStatus) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[idx].status = s; apps[idx].updatedAt = Date().timeIntervalSince1970
    }
    func assignApp(_ id: String, to assigneeId: String?) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[idx].assigneeId = assigneeId; apps[idx].updatedAt = Date().timeIntervalSince1970
    }
    func deleteApp(_ id: String) {
        if runningAppIds.contains(id) { stopApp(id) }   // don't orphan a running dev-server
        tombstone(id); apps.removeAll { $0.id == id }
    }

    func app(_ id: String) -> AppProject? { apps.first { $0.id == id } }

    /// Start developing an app: run the agent in the app folder (via a transient cwd
    /// override, so the employee's own workspace is untouched), in a FRESH chat thread, in
    /// code mode, with a build instruction prefilled. (Never deletes the folder.)
    func developApp(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        guard !isStreaming else { triggerToast(message: "応答中は開始できません"); return }
        let folder = appFolder(app)   // device-local resolution (cross-device safe)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        // Switch to the developer (or 全体) and start a clean thread for this build.
        // Guard against a dangling assigneeId (e.g. fired) so we don't set an unresolvable active id.
        let validAssignee = app.assigneeId.flatMap { aid in employees.contains { $0.id == aid } ? aid : nil }
        switchEmployee(validAssignee)
        handleNewChat()                  // fresh isolated session for the app

        cwdOverride = folder             // agent cwd = the app folder, just for this thread
        agentMode = .code
        terminalCwd = folder
        if app.status == .idea { setAppStatus(id, .building) }

        let spec = app.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = spec.isEmpty
            ? "「\(app.name)」というアプリをこのフォルダ（\(folder)）で開発してください。まず構成案を出し、最小構成から実装を進めてください。"
            : "「\(app.name)」というアプリを開発します。次の仕様でこのフォルダ（\(folder)）に実装してください。\n\n【仕様】\n\(spec)\n\nまず構成案を出し、最小構成から実装してください。"
        inputValue = base + "\n\n" + AppState.chatControllableRequirement
        view = "chat"
        triggerToast(message: "「\(app.name)」の開発を開始します")
    }

    /// Standard requirement baked into every app build so the finished app can be operated —
    /// and have data written to it — from this app's chat WITHOUT needing an MCP server: the
    /// agent already has file + terminal access in the app folder, so file-based data + a
    /// curl-able HTTP API are enough.
    static let chatControllableRequirement = """
    【チャット連携の必須要件】このアプリは、後からこのアプリのチャットで操作・データ書き込みができるように作ってください：
    1. データはこのフォルダ内のファイル（例: data/*.json）に保存し、外部DBに依存しないこと（エージェントが直接読み書きできるように）。
    2. 主要な操作（作成・更新・取得など）を HTTP API（例: POST /api/items）として公開し、`curl` から実行できるようにすること。
    3. README.md に「データの保存場所」「起動コマンド」「API一覧と curl の使用例」を必ず記載すること。
    """

    /// Reveal the app folder in Finder (creating it locally if it doesn't exist here).
    func openAppFolder(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        let folder = appFolder(app)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    /// Open the app folder in the side terminal panel (cwd set to the project folder).
    func openAppInTerminal(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        terminalCwd = appFolder(app)
        rightTab = .terminal
        showRightSidebar = true
    }

    /// Preview the app's URL in the internal browser side panel.
    func previewApp(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        let url = app.previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { triggerToast(message: "プレビューURLが未設定です（アプリの編集で指定してください）"); return }
        BrowserModel.shared.load(url)
        rightTab = .browser
        showRightSidebar = true
    }

}
