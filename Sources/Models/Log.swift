import Foundation
import os

/// Categorized structured logging (replaces scattered `print`). Goes to BOTH the unified system
/// log (Console.app / `log stream --predicate 'subsystem == "com.custom.hermesmac"'`) AND a plain
/// file at `~/.hermes/logs/app.log` that the user — or an agent — can `tail`/`grep`. The file is
/// the durable sink for surfacing the many previously-silent `try?` failures.
enum Log {
    private static let subsystem = "com.custom.hermesmac"

    static let acp = Logger(subsystem: subsystem, category: "acp")
    static let server = Logger(subsystem: subsystem, category: "server")
    static let push = Logger(subsystem: subsystem, category: "push")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let app = Logger(subsystem: subsystem, category: "app")

    // MARK: - File log (~/.hermes/logs/app.log)

    private static let fileQueue = DispatchQueue(label: "\(subsystem).filelog")
    private static let maxBytes = 2_000_000   // ~2 MB, then keep the most recent half.

    static var fileURL: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// Append one structured line `<iso8601> [LEVEL] [category] message` to the file log.
    /// Serialized on a private queue; the file is size-capped so it can't grow unbounded.
    static func event(_ category: String, _ level: String, _ message: String) {
        let line = "\(iso.string(from: Date())) [\(level)] [\(category)] \(message)\n"
        fileQueue.async {
            let url = fileURL
            guard let data = line.data(using: .utf8) else { return }
            if let fh = try? FileHandle(forWritingTo: url) {
                defer { try? fh.close() }
                fh.seekToEndOfFile()
                fh.write(data)
            } else {
                try? data.write(to: url)
            }
            rotateIfNeeded(url)
        }
    }

    /// Record a failure: ERROR line in the file + the unified log. `context` = what was being done;
    /// pass the caught `error` for its description. Replacement for silently-swallowing `try?`.
    static func failure(_ category: String, _ context: String, _ error: Error? = nil) {
        let msg = error.map { "\(context): \($0.localizedDescription)" } ?? context
        app.error("\(msg, privacy: .public)")
        event(category, "ERROR", msg)
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > maxBytes, let data = try? Data(contentsOf: url) else { return }
        try? data.suffix(maxBytes / 2).write(to: url)   // keep recent context, drop the oldest half
    }
}
