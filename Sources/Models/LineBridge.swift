import Foundation

/// Supervises the LINE bridge (`~/.hermes/line-bridge/run_bridge.sh` → `bridge.py` on :8650).
/// The app keeps it running so LINE send/receive always works — same idea as MobileServer.
/// Idempotent: never double-starts if something already listens on the port (ours or an
/// externally launched / launchd-managed bridge), and only stops a process we ourselves started.
final class LineBridge: @unchecked Sendable {
    static let shared = LineBridge()

    private let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".hermes/line-bridge")
    private var runScript: String { (dir as NSString).appendingPathComponent("run_bridge.sh") }
    private var logPath: String { (dir as NSString).appendingPathComponent("bridge.log") }
    let port: UInt16 = 8650

    private let lock = NSLock()
    private var process: Process?

    /// The bridge files exist, so it can be started.
    var isInstalled: Bool { FileManager.default.fileExists(atPath: runScript) }

    /// True if something is listening on 127.0.0.1:port (a quick localhost TCP connect).
    func isPortUp() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    /// Start the bridge if it isn't already running. Idempotent. Returns a status string.
    @discardableResult
    func ensureRunning() -> String {
        lock.lock(); defer { lock.unlock() }
        guard isInstalled else { return "未インストール（~/.hermes/line-bridge が見つかりません）" }
        if isPortUp() { return "稼働中（:\(port)）" }
        let p = Process()
        // Invoke `bash <script>` directly (script path as a real argv element, NOT spliced into a
        // `bash -c "…"` string) so a home/.hermes path containing quotes/spaces/metacharacters can't
        // inject. Using `bash <script>` (not exec'ing it) runs it even without the +x bit; run_bridge.sh
        // execs `python bridge.py` with a relative path → cwd must be the bridge dir.
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [runScript]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        // Append output to bridge.log via a FileHandle (replaces the shell `>> '…'` redirect, which
        // was the other injection vector). The fd is inherited across run_bridge.sh's exec of python.
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let logFH = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            logFH.seekToEndOfFile()
            p.standardOutput = logFH
            p.standardError = logFH
        }
        do {
            try p.run()
            process = p
            return "起動しました（:\(port)）"
        } catch {
            return "起動失敗: \(error.localizedDescription)"
        }
    }

    /// Stop only the process we started (leaves an externally launched bridge alone).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate()
        process = nil
    }
}
