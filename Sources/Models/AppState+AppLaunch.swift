import Foundation
import AppKit

// アプリのワンクリック起動/停止・プレビュー(Phase F)を AppState 本体から分離（#3 分割の継続）。
// appProcesses(live dev-server)/empKey は internal 化済み。appFolder/triggerToast も internal。
extension AppState {
    // MARK: - One-click app launch (Phase F: 起動 / 停止)

    /// True if this app's dev-server is currently running.
    func isAppRunning(_ id: String) -> Bool { runningAppIds.contains(id) }

    /// Detect "〇〇（アプリ）を開いて/起動して" in a chat prompt and return the registered app to
    /// launch. Returns nil for develop/edit intents (those go through 開発する), or when no
    /// registered app name appears, so the prompt falls through to the AI.
    func parseAppLaunchCommand(_ text: String) -> AppProject? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, t.count < 200, !t.contains("\n"), !apps.isEmpty else { return nil }
        // Develop/edit intents are not "launch" — let those go elsewhere.
        for dev in ["開発", "実装", "作って", "作成して", "修正", "直して", "編集", "デバッグ", "ビルド"] where t.contains(dev) {
            return nil
        }
        let launchVerbs = ["開いて", "ひらいて", "起動", "立ち上げ", "たちあげ", "表示して", "見せて", "ひらく", "開く", "プレビュー", "launch", "open", "run", "start"]
        guard launchVerbs.contains(where: { t.localizedCaseInsensitiveContains($0) }) else { return nil }
        // Match a registered app whose name appears in the text; prefer the longest name.
        let candidates = apps.filter { $0.name.count >= 2 && t.contains($0.name) }
        return candidates.max(by: { $0.name.count < $1.name.count })
    }

    /// Detect "〇〇アプリで〜を作成/更新/削除して" — a real data operation inside a registered
    /// app — and return the target app + whether it's destructive (delete/overwrite → needs
    /// confirmation). Excludes how-to questions and develop/code-fix intents. nil → AI.
    func parseAppActionCommand(_ text: String) -> (app: AppProject, action: String, destructive: Bool)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4, t.count < 600, !apps.isEmpty else { return nil }
        let quoted = t.contains("「") || t.contains("『")
        // How-to / explanation questions are NOT commands (unless an explicit quote is given).
        if !quoted {
            for q in ["教えて", "方法", "流れ", "説明", "手順", "使い方", "とは", "どうやって", "作り方", "やり方", "?", "？"] where t.contains(q) { return nil }
        }
        // Develop / code-fix intents go through 開発する (edit code), not a data op.
        for dev in ["開発", "実装", "デバッグ", "ビルド", "リファクタ", "修正", "直して", "なおして",
                    "バグ", "不具合", "コードを", "ソースを", "編集"] where t.contains(dev) { return nil }
        // Additive verbs run immediately; destructive/overwriting verbs require confirmation.
        let additive = ["作成", "作って", "つくって", "追加", "登録", "発行", "記録", "入力", "書き込",
                        "書いて", "セット", "設定して", "集計", "計算して", "出力", "エクスポート", "create", "add"]
        let destructive = ["削除", "消して", "更新", "変更", "上書き", "リセット", "delete", "update", "remove"]
        let isAdd = additive.contains { t.localizedCaseInsensitiveContains($0) }
        let isDel = destructive.contains { t.localizedCaseInsensitiveContains($0) }
        guard isAdd || isDel else { return nil }
        // Require app-referential framing ("会計アプリで…" / "…に" / prefix) so an unrelated
        // sentence merely containing a common-word app name can't hijack into a data op.
        let app = apps
            .filter { $0.name.count >= 2 }
            .filter { a in t.hasPrefix(a.name) || ["で", "に", "を", "へ", "の", "アプリ"].contains { t.contains(a.name + $0) } }
            .max(by: { $0.name.count < $1.name.count })
        guard let app = app else { return nil }
        return (app, t, isDel && !isAdd)
    }

    /// Perform a data operation inside an app via the AI agent: point it at the app folder
    /// (cwd), start the dev-server, and forward the instruction — the agent uses the app's HTTP
    /// API (curl) or data files to actually create/update the data, then reports back.
    func runAppAction(app: AppProject, command: String) {
        let folder = appFolder(app)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            messages.append(Message(role: .user, content: command))
            messages.append(Message(role: .system, content: "⚠️ 「\(app.name)」のフォルダが見つかりません。先に「開発する」で作成してください。"))
            return
        }
        let validAssignee = app.assigneeId.flatMap { aid in employees.contains { $0.id == aid } ? aid : nil }
        // Don't destroy / collide with an in-flight turn (the current view's or the target
        // employee's) — guard BEFORE any side effect (switch / launch / send).
        if streamingEmployeeIds.contains(empKey()) || streamingEmployeeIds.contains(empKey(validAssignee)) {
            messages.append(Message(role: .system, content: "⚠️ 応答中のため実行できません。完了後にもう一度お試しください。"))
            triggerToast(message: "応答中のため実行できませんでした")
            return
        }
        // Context: the app's developer, fresh thread, cwd = app folder, code mode.
        switchEmployee(validAssignee)
        handleNewChat()
        cwdOverride = folder
        agentMode = .code
        terminalCwd = folder
        view = "chat"
        // Start the dev-server (idempotent) so a curl-able API is available + the preview
        // reflects the change. Safe: launchApp doesn't reset the chat or cwdOverride.
        launchApp(app.id)

        let runHint = app.runCommand.isEmpty ? "適切な起動コマンドで起動し" : "`\(app.runCommand)` で起動し"
        inputValue = """
        \(command)

        【実行指示】上記は、このフォルダにある「\(app.name)」アプリでの実データ操作の依頼です。説明だけで終わらせず、実際にデータを作成・更新してください。手順:
        1. README とソース（API ルート / データ保存先）を確認し、操作方法を把握する。
        2. 開発サーバーが起動していなければ \(runHint)、必要なら少し待つ。
        3. アプリの HTTP API を `curl` で呼ぶ、またはデータファイル（例: data/*.json）を直接編集して、実際にデータを作成/更新する。金額や項目は依頼の内容に合わせる。
        4. 請求書・帳票など印刷可能なものを作成した場合は、PDF生成APIがあれば `curl` でPDFを生成してファイルに保存し（例: `curl -s "http://localhost:<PORT>/api/pdf/invoice/<id>" -o ~/Downloads/invoice-<番号>.pdf`）、保存した**PDFの絶対パスを1行で明記**してください。
        5. 反映を確認し、「何を・どこに・どのAPI/ファイルで」作成したか、PDFがあればその絶対パスを簡潔に報告する。
        対象フォルダ: \(folder)
        """
        bypassCommandIntercept = true
        handleSendMessage()
        bypassCommandIntercept = false
        triggerToast(message: "「\(app.name)」で操作を実行します…")
    }

    /// ONE-CLICK LAUNCH: run the app's start command as a live background process in its
    /// folder, stream output to the side terminal, and auto-open the preview the moment the
    /// server announces its localhost URL. Re-launch just surfaces the running app's panels.
    func launchApp(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        let folder = appFolder(app)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            triggerToast(message: "フォルダが見つかりません。先に「開発する」で作成してください。"); return
        }
        // Already running → just bring the output + preview forward.
        if runningAppIds.contains(id) {
            rightTab = .terminal; showRightSidebar = true
            let pv = effectiveAppURL(app)
            if !pv.isEmpty { BrowserModel.shared.load(pv); rightTab = .browser }
            return
        }
        // Resolve the command: explicit runCommand, else auto-detect from the project files.
        let serverCmd = {
            let c = app.runCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return c.isEmpty ? (autoDetectRunCommand(folder) ?? "") : c
        }()
        guard !serverCmd.isEmpty else {
            triggerToast(message: "起動コマンドを判定できませんでした。アプリの編集で「起動コマンド」を設定してください。"); return
        }
        // Resolve a dependency-install prefix (+ a venv PATH prefix for Python).
        var installPrefix = ""
        let fm = FileManager.default
        func projHas(_ f: String) -> Bool { fm.fileExists(atPath: (folder as NSString).appendingPathComponent(f)) }

        // Node: install deps if missing so a freshly-built app "just runs".
        if serverCmd.hasPrefix("npm ") || serverCmd.hasPrefix("pnpm ") || serverCmd.hasPrefix("yarn") {
            if !projHas("node_modules") {
                let installer = serverCmd.hasPrefix("pnpm") ? "pnpm install" : (serverCmd.hasPrefix("yarn") ? "yarn" : "npm install")
                installPrefix = "\(installer) && "
            }
        }
        // Python (not the stdlib http.server fallback): run inside a virtualenv so deps install
        // cleanly (no system pollution / PEP 668). Reuse an existing venv/.venv, else create
        // .venv + install requirements.txt on first run. Prepend the venv's bin to PATH (rather
        // than rewriting just the `python3` token) so venv-backed runners — uvicorn, gunicorn,
        // flask, streamlit, … — resolve there too.
        // The venv's bin dir to prepend to PATH — passed via the process ENVIRONMENT (not the
        // shell string) so an app folder path with spaces/quotes can't break or inject.
        var venvBinPath: String? = nil
        if (serverCmd.hasPrefix("python") || serverCmd.hasPrefix("uvicorn") || serverCmd.hasPrefix("gunicorn")
            || serverCmd.hasPrefix("flask") || serverCmd.hasPrefix("streamlit")), !serverCmd.contains("http.server") {
            func venvHasPython(_ name: String) -> Bool { fm.isExecutableFile(atPath: (folder as NSString).appendingPathComponent("\(name)/bin/python")) }
            let venvName = venvHasPython("venv") ? "venv" : ".venv"
            venvBinPath = (folder as NSString).appendingPathComponent("\(venvName)/bin")
            if !venvHasPython(venvName) {
                installPrefix = "python3 -m venv \(venvName) && \(venvName)/bin/python -m pip install --upgrade pip -q && "
                if projHas("requirements.txt") {
                    installPrefix += "\(venvName)/bin/python -m pip install -q -r requirements.txt && "
                }
            }
        }
        // `exec` the long-running server so the tracked PID IS the server (not the wrapping
        // shell) — terminate() then reliably kills it once the install prefix (if any) has
        // finished. (During install the whole subtree is killed via terminateTree on stop.)
        let shellCmd = "\(installPrefix)exec \(serverCmd)"
        // A static-server default has a known URL even though it prints no banner.
        var preview = app.previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isEmpty, serverCmd.contains("http.server 8000") { preview = "http://localhost:8000" }

        terminalCwd = folder
        rightTab = .terminal
        showRightSidebar = true
        terminalOutput += "\n\(folder) $ \(installPrefix)\(serverCmd)\n"
        appPreviewOpened.remove(id)
        detectedAppURL[id] = preview.isEmpty ? nil : preview
        // Only mark the app running once the process actually spawned (see streamAppProcess).
        guard streamAppProcess(id: id, cmd: shellCmd, folder: folder, pathPrepend: venvBinPath) else {
            triggerToast(message: "「\(app.name)」の起動に失敗しました"); return
        }
        // If a preview URL is known but the server prints no detectable banner, open it once it
        // becomes reachable (poll, not a blind fixed delay → never loads a dead page).
        if !preview.isEmpty {
            let gen = appGenerations[id]
            Task { @MainActor in
                let opened = await self.waitAndOpenPreview(id: id, url: preview, gen: gen)
                if !opened { /* server never came up in the window — auto-repair handles the exit */ }
            }
        }
        triggerToast(message: "「\(app.name)」を起動しています…")
    }

    /// Poll the preview URL until it answers (server bound the port), then open it in the
    /// side panel. Bails if the app was stopped/relaunched or already previewed. Returns
    /// whether it opened.
    private func waitAndOpenPreview(id: String, url: String, gen: Int?) async -> Bool {
        for _ in 0..<50 {   // ~25s max (50 × 500ms)
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard appGenerations[id] == gen, runningAppIds.contains(id) else { return false }
            if appPreviewOpened.contains(id) { return false }   // detected-URL path already opened it
            if await AppState.urlReachable(url) {
                guard appGenerations[id] == gen, runningAppIds.contains(id), !appPreviewOpened.contains(id) else { return false }
                appPreviewOpened.insert(id)
                BrowserModel.shared.load(url)
                rightTab = .browser
                return true
            }
        }
        return false
    }

    /// True if an HTTP request to `urlStr` gets ANY response (the server is up — a 404/500
    /// still counts; only a refused/timed-out connection is "not up yet").
    nonisolated static func urlReachable(_ urlStr: String) async -> Bool {
        guard let u = URL(string: urlStr) else { return false }
        var req = URLRequest(url: u); req.httpMethod = "HEAD"; req.timeoutInterval = 1.5
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do { _ = try await URLSession.shared.data(for: req); return true }
        catch let e as URLError {
            // A response with an HTTP error still means the server is up.
            return e.code != .cannotConnectToHost && e.code != .timedOut && e.code != .networkConnectionLost
        } catch { return true }
    }

    /// Stop a running app's dev-server (and any in-flight install/child processes).
    func stopApp(_ id: String) {
        // Bump the generation so the dying process's handlers become stale no-ops (a relaunch
        // under the same id can't be clobbered by the old terminationHandler).
        appGenerations[id] = (appGenerations[id] ?? 0) + 1
        if let p = appProcesses[id] {
            let pid = p.processIdentifier
            p.terminate()                       // SIGTERM the tracked (exec'd) server
            if pid > 0 { AppState.terminateTree(pid) }   // + any install/children still running
        }
        appProcesses.removeValue(forKey: id)
        runningAppIds.remove(id)
        appPreviewOpened.remove(id)
        appRepairAttempts[id] = 0   // a manual stop ends any auto-repair cycle
        if let app = apps.first(where: { $0.id == id }) {
            terminalOutput += "\n[\(app.name)] 停止しました\n"
        }
    }

    /// SIGTERM a process and all of its descendants (bounded). Foundation's `terminate()` only
    /// signals the tracked PID, so a still-running `npm install`/`pip` child (before the server
    /// `exec`s) would orphan — this walks `pgrep -P` and kills the whole subtree.
    nonisolated static func terminateTree(_ pid: Int32) {
        func children(of p: Int32) -> [Int32] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["-P", String(p)]
            let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
            do { try task.run(); task.waitUntilExit() } catch { return [] }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return out.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        }
        var frontier = [pid], all: [Int32] = [], depth = 0
        while !frontier.isEmpty, depth < 6 {
            let next = frontier.flatMap { children(of: $0) }
            all.append(contentsOf: next); frontier = next; depth += 1
        }
        // Kill leaves first (children before parents) so they don't get reparented mid-kill.
        for c in all.reversed() where c > 1 { kill(c, SIGTERM) }
    }

    /// AUTO-REPAIR: hand a failed launch's error to the assigned AI in a fresh code-mode
    /// thread, auto-send it (no click), and flag the app to re-launch when that turn finishes.
    func autoRepairApp(_ id: String, errorTail: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        let folder = appFolder(app)
        let validAssignee = app.assigneeId.flatMap { aid in employees.contains { $0.id == aid } ? aid : nil }
        // Don't hijack the user mid-conversation: if any turn is streaming (the user is busy),
        // offer the fix via a toast instead of switching employees + view out from under them.
        if !streamingEmployeeIds.isEmpty {
            self.appRepairAttempts[id] = max(0, (self.appRepairAttempts[id] ?? 1) - 1)   // don't burn an attempt
            triggerToast(message: "「\(app.name)」の起動に失敗しました。AIに修復を依頼できます。",
                         actionLabel: "AIに修復を依頼") { [weak self] in self?.requestAppFix(id) }
            return
        }
        switchEmployee(validAssignee)
        handleNewChat()
        cwdOverride = folder
        agentMode = .code
        terminalCwd = folder
        pendingRelaunchAppId = id   // re-launch automatically once this fix turn completes
        let runHint = app.runCommand.isEmpty ? "（起動コマンドは未設定。適切なものを判断してください）" : "`\(app.runCommand)`"
        inputValue = """
        「\(app.name)」をこのフォルダ（\(folder)）で起動したところ、次のエラーで失敗しました。原因を特定し、不足している依存の追加（requirements.txt / package.json の修正と実際のインストール）やコードの修正を行い、\(runHint) で起動できる状態にしてください。修正が終わったら簡潔に何を直したか教えてください。

        【エラー出力】
        \(errorTail)
        """
        view = "chat"
        triggerToast(message: "「\(app.name)」をAIが自動修復しています…")
        handleSendMessage()   // auto-send — no user click needed
    }

    /// Detect a PDF the agent saved (an absolute `.pdf` path named in its reply) and open it
    /// so it "comes back" to the user. Only opens a path that actually exists on disk (so a
    /// passing mention can't pop a window); a localhost PDF URL is opened in the side browser.
    func openReferencedPDF(in text: String) {
        // Absolute local .pdf paths (handles ~ and spaces up to the .pdf extension).
        if let re = try? NSRegularExpression(pattern: #"(/[^\s"'`]+?\.pdf|~/[^\s"'`]+?\.pdf)"#, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..., in: text)
            for m in re.matches(in: text, range: range) {
                guard let r = Range(m.range, in: text) else { continue }
                let path = (String(text[r]) as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    triggerToast(message: "PDFを開きました：\((path as NSString).lastPathComponent)")
                    return
                }
            }
        }
        // A localhost PDF URL → open in the internal browser panel.
        if let re = try? NSRegularExpression(pattern: #"https?://(?:localhost|127\.0\.0\.1)(?::\d+)?/[^\s"'`]*pdf[^\s"'`]*"#, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..., in: text)
            if let m = re.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                BrowserModel.shared.load(String(text[r]))
                rightTab = .browser; showRightSidebar = true
                triggerToast(message: "PDFをプレビューで開きました")
            }
        }
    }

    /// Open the app's preview in its OWN macOS window (separate from the side browser).
    /// Uses the app's preview URL, else the URL the running server actually bound to.
    func openAppInWindow(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        let url = effectiveAppURL(app)
        guard !url.isEmpty else {
            triggerToast(message: "URLが不明です。先に「起動」するか、アプリ編集でプレビューURLを設定してください。"); return
        }
        AppPreviewWindow.show(url: url, title: app.name, appId: app.id)
    }

    /// The best URL to open for an app: its configured preview URL, else the live-detected one.
    private func effectiveAppURL(_ app: AppProject) -> String {
        let pv = app.previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pv.isEmpty { return pv }
        return detectedAppURL[app.id] ?? ""
    }

    /// Hand a failed launch to the assigned AI employee to fix (e.g. missing deps / wrong
    /// requirements.txt). Opens a fresh code-mode thread in the app folder with a fix prompt.
    func requestAppFix(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        // The user explicitly asked for the fix — route through autoRepairApp so it also
        // auto-sends and re-launches when done. Reset the attempt counter for a fresh cycle.
        appRepairAttempts[id] = 0
        let errorTail = String(terminalOutput.suffix(1600))
        // If the user is busy on another turn, still honor the click but warn it'll switch.
        autoRepairApp(id, errorTail: errorTail.isEmpty ? "（直近のエラー出力は取得できませんでした。フォルダ内のコードと依存定義を確認してください）" : errorTail)
    }

    /// Spawn the app's command as a long-running process, streaming output LIVE (unlike
    /// `runShell`, which waits for termination — useless for a dev-server that never exits).
    /// Returns true only if the process actually spawned (so the caller marks it running).
    /// Uses DispatchQueue.main.async (strict FIFO) so the "[終了]" line + dep-scan land AFTER
    /// the last streamed output, and a generation token so a stale process can't clobber a
    /// relaunch's state.
    @discardableResult
    private func streamAppProcess(id: String, cmd: String, folder: String, pathPrepend: String? = nil) -> Bool {
        let gen = (appGenerations[id] ?? 0) + 1
        appGenerations[id] = gen

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        var env = HermesCLI.shared.mergedEnvironment
        if let pp = pathPrepend, !pp.isEmpty {   // venv bin → resolve python/uvicorn/etc there
            env["PATH"] = pp + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self = self, self.appGenerations[id] == gen else { return }
                self.terminalOutput += text
                let lines = self.terminalOutput.components(separatedBy: .newlines)
                if lines.count > 1200 { self.terminalOutput = lines.suffix(1200).joined(separator: "\n") }
                // The instant the dev-server prints its URL: remember it (for 別ウィンドウ),
                // auto-open the in-app preview, and treat the successful bind as "repaired".
                if let url = self.detectLocalURL(text), self.runningAppIds.contains(id) {
                    self.detectedAppURL[id] = url
                    self.appRepairAttempts[id] = 0   // came up cleanly → reset the auto-repair counter
                    if !self.appPreviewOpened.contains(id) {
                        self.appPreviewOpened.insert(id)
                        BrowserModel.shared.load(url)
                        self.rightTab = .browser
                    }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                // Stale (the app was stopped/relaunched under the same id) → don't touch state.
                guard let self = self, self.appGenerations[id] == gen else { return }
                if !rest.isEmpty, let t = String(data: rest, encoding: .utf8) { self.terminalOutput += t }
                self.terminalOutput += "\n[終了: code \(proc.terminationStatus)]\n"
                let wasRunning = self.runningAppIds.contains(id)
                self.runningAppIds.remove(id)
                self.appProcesses.removeValue(forKey: id)
                self.appPreviewOpened.remove(id)
                // A non-clean exit → AUTO-REPAIR: hand the error to the assigned AI to fix, then
                // re-launch. Capped at 2 attempts per app so it can't loop forever.
                guard wasRunning, proc.terminationStatus != 0 else { return }
                let errorTail = String(self.terminalOutput.suffix(1600))
                let attempts = self.appRepairAttempts[id, default: 0]
                if attempts < 2 {
                    self.appRepairAttempts[id] = attempts + 1
                    self.terminalOutput += "\n🔧 起動に失敗しました。AIが自動で修復します（試行 \(attempts + 1)/2）…\n"
                    self.autoRepairApp(id, errorTail: errorTail)
                } else {
                    self.terminalOutput += "\n⚠️ 自動修復を2回試みましたが起動できませんでした。チャットで担当社員に相談してください。\n"
                    self.triggerToast(message: "自動修復に失敗しました。手動で確認してください。",
                                      actionLabel: "チャットを開く") { [weak self] in self?.requestAppFix(id) }
                    self.appRepairAttempts[id] = 0   // allow a fresh cycle on the next manual launch
                }
            }
        }
        do {
            try p.run()
            appProcesses[id] = p
            runningAppIds.insert(id)   // only NOW is the app truly running
            return true
        } catch {
            terminalOutput += "起動失敗: \(error.localizedDescription)\n"
            return false
        }
    }

    /// Pull the first http://localhost:PORT (or 127.0.0.1) URL out of a dev-server banner.
    private func detectLocalURL(_ text: String) -> String? {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d+)?(?:/[^\s"']*)?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { return nil }
        // 0.0.0.0 isn't browsable — normalize to localhost.
        return String(text[r]).replacingOccurrences(of: "0.0.0.0", with: "localhost")
    }

    /// Best-effort run command from the project's files (used when runCommand is unset).
    private func autoDetectRunCommand(_ folder: String) -> String? {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: (folder as NSString).appendingPathComponent(f)) }
        if has("package.json") {
            if let data = fm.contents(atPath: (folder as NSString).appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let scripts = json["scripts"] as? [String: Any] {
                if scripts["dev"] != nil { return "npm run dev" }
                if scripts["start"] != nil { return "npm start" }
                if scripts["serve"] != nil { return "npm run serve" }
                if scripts["preview"] != nil { return "npm run preview" }
            }
            return "npm start"
        }
        if has("Cargo.toml") { return "cargo run" }
        if has("manage.py") { return "python3 manage.py runserver" }
        if has("app.py") { return "python3 app.py" }
        if has("main.py") { return "python3 main.py" }
        if has("index.html") { return "python3 -m http.server 8000" }
        return nil
    }

}
