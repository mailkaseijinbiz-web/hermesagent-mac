import Foundation
import AppKit

/// In-app auto version-up for HermesCustom. The app is run from `<repo>/release/
/// HermesCustom.app` and built from source (see build_signed.sh), so an "update" is:
/// `git pull → build_signed.sh → relaunch`. This manager detects new commits on the
/// remote (via `git fetch`) and, on the user's click (or the auto toggle), applies them.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var status: String = ""
    @Published var updateAvailable = false
    @Published var behindCount = 0
    @Published var latestLog: String = ""        // recent commit subjects (newest first)
    @Published var branch: String = "main"
    @Published var isChecking = false
    @Published var isUpdating = false
    @Published var lastCheck: Date? = nil
    @Published var autoUpdate: Bool = UserDefaults.standard.bool(forKey: "autoUpdate") {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
    }

    private var periodicStarted = false

    private init() {}

    // MARK: - Repo discovery (derive from the running bundle's location)

    /// `<repo>/release/HermesCustom.app` → `<repo>`, validated as the git source tree.
    var repoPath: String? {
        let repo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        if fm.fileExists(atPath: repo.appendingPathComponent(".git").path),
           fm.fileExists(atPath: repo.appendingPathComponent("build_signed.sh").path) {
            return repo.path
        }
        return nil
    }

    private func readRepoFile(_ rel: String) -> String? {
        guard let repo = repoPath else { return nil }
        let s = try? String(contentsOfFile: "\(repo)/\(rel)", encoding: .utf8)
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }

    /// The commit the running binary was built from (written by build_signed.sh).
    var builtCommit: String? { readRepoFile("release/.build-commit") }

    /// Display label, e.g. "v1.0 (a1b2c3d)".
    var currentVersion: String {
        let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let c = String((builtCommit ?? "").prefix(7))
        return c.isEmpty ? "v\(v)" : "v\(v) (\(c))"
    }

    // MARK: - Subprocess (login shell for Terminal-parity env: PATH, SSH, signing)

    nonisolated private static func sh(_ command: String, cwd: String) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        // パイプバッファ(64KB)超えで waitUntilExit がデッドロックするため、
        // readabilityHandler で並行読み出しし、終了後に結合する。
        var chunks: [Data] = []
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty {
                fh.readabilityHandler = nil
            } else {
                lock.lock(); chunks.append(d); lock.unlock()
            }
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        // 残りのバッファを回収
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { chunks.append(tail) }
        let data = chunks.reduce(Data(), +)
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Check

    func startPeriodic() {
        guard !periodicStarted else { return }
        periodicStarted = true
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)   // every 6h
                await self?.checkForUpdates(auto: true)
            }
        }
    }

    /// Fetch the remote and compare against the built commit. `auto: true` lets the
    /// auto-update toggle apply silently; manual checks pass `auto: false`.
    func checkForUpdates(auto: Bool) async {
        guard let repo = repoPath else {
            status = "更新元のリポジトリが見つかりません（release/ から起動してください）"
            updateAvailable = false
            return
        }
        guard !isChecking, !isUpdating else { return }
        isChecking = true
        status = "確認中…"
        let fileBranch = readRepoFile("release/.build-branch")
        let builtFromFile = builtCommit

        let result = await Task.detached { () -> (ok: Bool, available: Bool, log: String, behind: Int, branch: String, dirty: Bool) in
            var branch = fileBranch ?? Self.sh("git rev-parse --abbrev-ref HEAD", cwd: repo).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if branch.isEmpty || branch == "HEAD" { branch = "main" }

            guard Self.sh("git fetch origin \(branch) --quiet", cwd: repo).code == 0 else {
                return (false, false, "", 0, branch, false)
            }
            let remote = Self.sh("git rev-parse origin/\(branch)", cwd: repo).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remote.isEmpty else { return (false, false, "", 0, branch, false) }

            var built = (builtFromFile ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if built.isEmpty {
                built = Self.sh("git rev-parse HEAD", cwd: repo).out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // `behind` = commits on the remote the built binary lacks. Gate on this, NOT on
            // `remote != built`: when the local build is AHEAD of (or diverged from) the
            // remote, `remote != built` stays true forever, so auto-update rebuilds the same
            // source and relaunches in an infinite loop. A real update means behind > 0.
            let behind = Int(Self.sh("git rev-list --count \(built)..\(remote)", cwd: repo).out
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let dirty = !Self.sh("git status --porcelain", cwd: repo).out
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let available = behind > 0
            var log = ""
            if available {
                log = Self.sh("git log --oneline --no-decorate \(built)..\(remote)", cwd: repo).out
                    .split(separator: "\n").prefix(15).joined(separator: "\n")
            }
            return (true, available, log, behind, branch, dirty)
        }.value

        isChecking = false
        lastCheck = Date()
        branch = result.branch
        guard result.ok else { status = "確認に失敗しました（ネットワーク/SSHを確認）"; return }
        updateAvailable = result.available
        behindCount = result.behind
        latestLog = result.log
        status = result.available
            ? "新しいバージョンがあります（\(result.behind)件）"
            : (result.dirty ? "ローカルに未コミットの変更があります（自動更新は保留中）" : "最新です")

        // Never auto-apply with a dirty working tree: `git pull --ff-only` would fail/clobber
        // and we'd rebuild the same source repeatedly (the relaunch loop).
        if result.available && !result.dirty && autoUpdate && auto { await performUpdate() }
    }

    // MARK: - Apply (git pull → rebuild → relaunch)

    func performUpdate() async {
        guard let repo = repoPath, !isUpdating else { return }
        isUpdating = true

        // Refuse to update over uncommitted local work — `git pull` would fail/clobber and,
        // rebuilding the same source, relaunch in a loop. The developer commits/stashes first.
        let dirty = await Task.detached {
            !Self.sh("git status --porcelain", cwd: repo).out
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.value
        if dirty {
            isUpdating = false
            status = "未コミットの変更があるため更新を中止しました（先にコミット/退避してください）"
            return
        }

        status = "更新を取得中…（git pull）"
        let pull = await Task.detached { Self.sh("git pull --ff-only", cwd: repo) }.value
        if pull.code != 0 {
            isUpdating = false
            let tail = pull.out.split(separator: "\n").last.map(String.init) ?? ""
            status = "git pull に失敗しました: \(tail)"
            return
        }

        status = "再ビルド中…（数十秒かかります）"
        let build = await Task.detached { Self.sh("./build_signed.sh", cwd: repo) }.value
        let builtApp = "\(repo)/release/HermesCustom.app"
        if build.code != 0 || !FileManager.default.fileExists(atPath: builtApp) {
            isUpdating = false
            status = "再ビルドに失敗しました（署名/キーチェーンを確認してください）"
            return
        }

        status = "再起動中…"
        // Background a detached relauncher (reparented to launchd) that reopens the new
        // bundle once this instance has quit, then terminate.
        _ = Self.sh("(sleep 1; open '\(builtApp)') >/dev/null 2>&1 &", cwd: repo)
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSApplication.shared.terminate(nil)
    }
}
