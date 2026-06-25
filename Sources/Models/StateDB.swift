import Foundation
import SQLite3

/// Read-only access to the Hermes session store (~/.hermes/state.db).
/// Opened read-only with a busy timeout so reads never block the CLI writer
/// (which uses WAL). This is the source of truth for session sync.
/// Stateless (only immutable config + per-call local handles), hence Sendable.
final class StateDB: Sendable {
    static let shared = StateDB()

    private let path = (NSHomeDirectory() as NSString).appendingPathComponent(".hermes/state.db")
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct SessionRow {
        let id: String
        let title: String
        let preview: String
        let source: String
        let archived: Bool
        let messageCount: Int
        let lastMessageId: Int64
        let updatedAt: Double
    }

    struct MessageRow {
        let id: Int64
        let role: String
        let content: String
        let timestamp: Double
        let tokenCount: Int
    }

    private func open() -> OpaquePointer? {
        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 5000)
        return db
    }

    // MARK: - Sessions

    func sessions(limit: Int = 200) -> [SessionRow] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT s.id,
               COALESCE(s.title,''),
               COALESCE(s.source,''),
               COALESCE(s.archived,0),
               COALESCE(s.message_count,0),
               (SELECT COALESCE(MAX(m.id),0) FROM messages m WHERE m.session_id=s.id),
               (SELECT m.content FROM messages m
                  WHERE m.session_id=s.id AND m.role IN ('user','assistant')
                        AND m.content IS NOT NULL AND m.content<>''
                  ORDER BY m.id DESC LIMIT 1),
               (SELECT COALESCE(MAX(m.timestamp), s.started_at) FROM messages m WHERE m.session_id=s.id)
        FROM sessions s
        WHERE COALESCE(s.archived,0)=0
        ORDER BY 8 DESC
        LIMIT ?1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var rows: [SessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(SessionRow(
                id: text(stmt, 0),
                title: text(stmt, 1),
                preview: text(stmt, 6),
                source: text(stmt, 2),
                archived: sqlite3_column_int(stmt, 3) != 0,
                messageCount: Int(sqlite3_column_int(stmt, 4)),
                lastMessageId: sqlite3_column_int64(stmt, 5),
                updatedAt: sqlite3_column_double(stmt, 7)
            ))
        }
        return rows
    }

    // MARK: - Messages

    /// Visible (user/assistant, active) messages for a session, optionally only those after `after`.
    func messages(sessionId: String, after: Int64? = nil) -> [MessageRow] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }

        var sql = """
        SELECT id, role, COALESCE(content,''), timestamp, COALESCE(token_count,0)
        FROM messages
        WHERE session_id=?1 AND active=1 AND role IN ('user','assistant')
              AND content IS NOT NULL AND content<>''
        """
        if after != nil { sql += " AND id > ?2" }
        sql += " ORDER BY id;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        if let after = after { sqlite3_bind_int64(stmt, 2, after) }

        var rows: [MessageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(MessageRow(
                id: sqlite3_column_int64(stmt, 0),
                role: text(stmt, 1),
                content: text(stmt, 2),
                timestamp: sqlite3_column_double(stmt, 3),
                tokenCount: Int(sqlite3_column_int(stmt, 4))
            ))
        }
        return rows
    }

    /// sessionId → summed assistant token_count (for per-employee cost/usage stats).
    /// Pass `since` (epoch seconds) to count only messages at/after that time (e.g. this month).
    func tokenTotalsBySession(since: Double? = nil) -> [String: Int] {
        guard let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        var sql = "SELECT session_id, COALESCE(SUM(token_count),0) FROM messages WHERE role='assistant' AND active=1"
        if since != nil { sql += " AND timestamp >= ?1" }
        sql += " GROUP BY session_id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        if let since = since { sqlite3_bind_double(stmt, 1, since) }
        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[text(stmt, 0)] = Int(sqlite3_column_int(stmt, 1))
        }
        return out
    }

    /// Count of visible (user/assistant) messages — used for shrink detection.
    func visibleMessageCount(sessionId: String) -> Int {
        guard let db = open() else { return 0 }
        defer { sqlite3_close(db) }
        let sql = "SELECT COUNT(*) FROM messages WHERE session_id=?1 AND active=1 AND role IN ('user','assistant') AND content IS NOT NULL AND content<>'';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// The most recent visible assistant message globally (for push notifications).
    func latestAssistantMessage() -> (id: Int64, sessionId: String, content: String)? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT id, session_id, COALESCE(content,'')
        FROM messages
        WHERE role='assistant' AND active=1 AND content IS NOT NULL AND content<>''
        ORDER BY id DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int64(stmt, 0), text(stmt, 1), text(stmt, 2))
    }

    // MARK: - Digest (cheap change-detection)

    /// (maxMessageId, sessionCount, token). `token` changes on any session id/title/archived/count change
    /// so renames/deletes/compaction are detectable even when MAX(id) doesn't move.
    func digest() -> (maxMessageId: Int64, sessionCount: Int, token: String) {
        guard let db = open() else { return (0, 0, "") }
        defer { sqlite3_close(db) }

        var maxId: Int64 = 0
        var count = 0
        if let s = prepare(db, "SELECT COALESCE(MAX(id),0) FROM messages;") {
            if sqlite3_step(s) == SQLITE_ROW { maxId = sqlite3_column_int64(s, 0) }
            sqlite3_finalize(s)
        }
        var concat = ""
        if let s = prepare(db, "SELECT id, COALESCE(title,''), COALESCE(archived,0), COALESCE(message_count,0) FROM sessions ORDER BY id;") {
            while sqlite3_step(s) == SQLITE_ROW {
                count += 1
                concat += "\(text(s,0))|\(text(s,1))|\(sqlite3_column_int(s,2))|\(sqlite3_column_int(s,3));"
            }
            sqlite3_finalize(s)
        }
        return (maxId, count, "\(maxId)-\(count)-\(djb2(concat))")
    }

    // MARK: - Helpers

    private func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK ? stmt : nil
    }

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private func djb2(_ s: String) -> String {
        var hash: UInt64 = 5381
        for byte in s.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return String(hash, radix: 36)
    }
}
