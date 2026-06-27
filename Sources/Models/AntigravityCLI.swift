import Foundation

/// Lock-guarded UTF-8 accumulator for a subprocess pipe. Pipe reads split at arbitrary
/// byte offsets, so a multi-byte char (Japanese = 3 bytes, emoji = 4) can straddle two
/// reads; decoding each raw chunk alone would drop the straddling character. We append
/// to a buffer and only emit when it decodes cleanly, keeping the incomplete tail. The
/// lock makes it safe to share across the concurrent readability/termination handlers.
final class UTF8StreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    /// Append a read; return the decoded text when the buffer is a complete UTF-8
    /// sequence (clearing it), else nil (keeping bytes for the next read).
    func append(_ incoming: Data) -> String? {
        lock.lock(); defer { lock.unlock() }
        data.append(incoming)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        data.removeAll(keepingCapacity: true)
        return text.isEmpty ? nil : text
    }

    /// Final flush at EOF: append remaining bytes and best-effort decode whatever's left.
    func flush(_ incoming: Data) -> String? {
        lock.lock(); defer { lock.unlock() }
        data.append(incoming)
        let text = String(data: data, encoding: .utf8)
        data.removeAll(keepingCapacity: true)
        return (text?.isEmpty == false) ? text : nil
    }
}

/// Runs Google's **Antigravity CLI** (`agy`) as a standalone coding-agent backend —
/// the same family as `codex` / `claude-code`, NOT a Hermes inference provider.
///
/// Selected when the active provider is `AntigravityCLI.providerId`. Each turn is a
/// one-shot, non-interactive run: `agy -p '<prompt>' --model '<model>'`. Antigravity
/// manages its own auth (OS keyring / browser sign-in), so no API key flows from here.
@MainActor
final class AntigravityCLI {
    static let shared = AntigravityCLI()

    /// The provider id used throughout the app (settings picker, employee.provider).
    static let providerId = "antigravity"

    /// Curated `--model` display strings. The authoritative list comes from `agy models`;
    /// users can also type a custom string in settings. Kept loose since Antigravity
    /// rev's its lineup often.
    static let presetModels: [String] = [
        "Gemini 3 Pro (High)",
        "Gemini 3 Pro (Low)",
        "Gemini 3 Deep Think",
        "Claude Sonnet 4.5 (Thinking)",
        "Claude Opus 4.6 (Thinking)",
        "GPT-5.1 (High)"
    ]

    static let defaultModel = presetModels[0]

    /// One-line install hint shown in settings / errors when `agy` is missing.
    static let installHint = "Antigravity CLI が見つかりません。`curl -fsSL https://antigravity.google/cli/install.sh | bash` でインストールしてください。"

    private init() {}

    // MARK: - Binary discovery

    /// Cached successful resolution — the path won't move within a session. A miss is
    /// NOT cached, so installing `agy` mid-session is still picked up on the next check.
    private var cachedBinary: String?

    /// Pure, actor-free lookup: common install dirs, then PATH via the login shell.
    /// Runs the (potentially slow) login-shell probe, so callers must keep it OFF the
    /// main actor (see `resolveBinaryAsync`).
    nonisolated private static func locate() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "\(home)/.gemini/antigravity-cli/bin/agy"
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        // PATH-installed: ask the user's login shell where `agy` is.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v agy"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (!path.isEmpty && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }

    /// Resolve the `agy` binary without blocking the main thread (login-shell probe runs
    /// off-actor). Caches a hit; a miss is re-probed so a mid-session install is detected.
    func resolveBinaryAsync() async -> String? {
        if let cached = cachedBinary, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        let hit = await Task.detached { AntigravityCLI.locate() }.value
        if let hit = hit { cachedBinary = hit }
        return hit
    }

    /// Async installed-check that never stalls the UI thread.
    var isInstalledAsync: Bool { get async { await resolveBinaryAsync() != nil } }

    // MARK: - Execution

    /// Stream a one-shot `agy -p` run with a pre-resolved binary path (see
    /// `resolveBinaryAsync`). Output is streamed via `onData`; `onEnd` carries the exit
    /// code. Returns the launched Process (or nil + `onEnd(-1)` if launch throws).
    func streamPrompt(bin: String,
                      prompt: String,
                      model: String,
                      cwd: String,
                      onData: @escaping @Sendable (String) -> Void,
                      onEnd: @escaping @Sendable (Int32) -> Void) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        var args = ["-p", prompt]
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { args.append(contentsOf: ["--model", m]) }
        // Scope agy's workspace to the (employee's) working folder so file operations
        // ("このフォルダ" / relative paths) land there instead of agy's own default scratch
        // (~/.gemini/antigravity-cli/scratch). Setting the OS cwd alone is NOT honored by agy —
        // `--add-dir` is its native way to add a directory to the session workspace.
        // Skip when cwd is the home dir (employee has no dedicated folder) so we don't add all
        // of $HOME to the workspace.
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespaces)
        var isDir: ObjCBool = false
        if !trimmedCwd.isEmpty, trimmedCwd != NSHomeDirectory(),
           FileManager.default.fileExists(atPath: trimmedCwd, isDirectory: &isDir), isDir.boolValue {
            args.append(contentsOf: ["--add-dir", trimmedCwd])
        }
        process.arguments = args
        // Reuse Hermes' merged shell env (PATH, etc.) so `agy` resolves its own deps.
        process.environment = HermesCLI.shared.mergedEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Accumulate bytes so a multi-byte UTF-8 char split across two pipe reads isn't
        // dropped (see UTF8StreamBuffer). Shared safely across the two handlers via lock.
        let buffer = UTF8StreamBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = buffer.append(data) { onData(text) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData   // drain; agy chrome/progress goes to stderr
        }

        process.terminationHandler = { proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if let text = buffer.flush(outPipe.fileHandleForReading.readDataToEndOfFile()) {
                onData(text)
            }
            onEnd(proc.terminationStatus)
        }

        do {
            try process.run()
            return process
        } catch {
            onEnd(-1)
            return nil
        }
    }

    /// Strip ANSI/CSI escapes from `agy` output (no Hermes banner parsing applies here).
    /// Non-raw string so `\u{1B}` becomes a real ESC byte for the regex engine.
    nonisolated static func clean(_ text: String) -> String {
        let pattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
