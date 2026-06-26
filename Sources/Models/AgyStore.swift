import Foundation

/// Writable store for Antigravity (`agy`) chat turns. agy runs as a one-shot backend
/// outside the Hermes CLI, so its turns never land in the read-only Hermes state.db
/// (see `StateDB`). This records them so agy chats appear in the session list / history
/// and sync to mobile — unioned with the Hermes sessions by the read paths.
///
/// JSON-backed and lock-guarded so it's safe to read from both the main actor and the
/// nonisolated `MobileServer` handlers (mirrors `StateDB`'s Sendable contract).
final class AgyStore: @unchecked Sendable {
    static let shared = AgyStore()

    /// Session ids are prefixed so the read paths can route unambiguously to this store
    /// vs. the Hermes state.db without a lookup.
    static let idPrefix = "agy-"
    static func isAgySession(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    struct Msg: Codable { let role: String; let content: String; let ts: Double }
    struct Session: Codable {
        let id: String
        var title: String
        var employeeId: String?
        var createdAt: Double
        var updatedAt: Double
        var messages: [Msg]
    }

    private let lock = NSLock()
    private let path: String
    private var store: [String: Session]

    /// `path` is injectable so unit tests can use a temp file instead of ~/.hermes.
    init(path: String? = nil) {
        self.path = path ?? (NSHomeDirectory() as NSString).appendingPathComponent(".hermes/agy-sessions.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: self.path)),
           let decoded = try? JSONDecoder().decode([String: Session].self, from: data) {
            store = decoded
        } else {
            store = [:]
        }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func newSessionId() -> String { "\(Self.idPrefix)\(UUID().uuidString)" }

    /// Append one agy turn (user + assistant). Creates the session when `sessionId` is
    /// nil/unknown; returns the id used. The title is taken from the first user line.
    @discardableResult
    func record(sessionId: String?, employeeId: String?, userText: String, assistantText: String, timestamp: Double) -> String {
        lock.lock(); defer { lock.unlock() }
        let id: String
        if let s = sessionId, store[s] != nil {
            id = s
        } else if let s = sessionId, Self.isAgySession(s) {
            id = s   // honor a pre-allocated agy id even before its first turn
        } else {
            id = "\(Self.idPrefix)\(UUID().uuidString)"
        }
        var session = store[id] ?? Session(id: id, title: "", employeeId: employeeId,
                                            createdAt: timestamp, updatedAt: timestamp, messages: [])
        if session.title.isEmpty {
            let firstLine = userText.split(separator: "\n").first.map(String.init) ?? userText
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            session.title = String(trimmed.prefix(40))
        }
        if session.employeeId == nil { session.employeeId = employeeId }
        if !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.messages.append(Msg(role: "user", content: userText, ts: timestamp))
        }
        session.messages.append(Msg(role: "assistant", content: assistantText, ts: timestamp + 0.001))
        session.updatedAt = timestamp
        store[id] = session
        persistLocked()
        return id
    }

    func sessions() -> [Session] {
        lock.lock(); defer { lock.unlock() }
        return store.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func session(_ id: String) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return store[id]
    }

    func messages(_ id: String) -> [Msg] {
        lock.lock(); defer { lock.unlock() }
        return store[id]?.messages ?? []
    }

    func delete(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        store[id] = nil
        persistLocked()
    }

    /// Thread-safe accumulator for capturing a streamed agy reply server-side (the
    /// mobile relay forwards raw chunks to the client while collecting the full text here).
    final class ReplyAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    /// Change-detection token (mixed into the mobile SSE digest so other devices refresh
    /// when an agy turn lands).
    func version() -> String {
        lock.lock(); defer { lock.unlock() }
        var h: UInt64 = 5381
        for s in store.values.sorted(by: { $0.id < $1.id }) {
            for b in "\(s.id)|\(s.updatedAt)|\(s.messages.count);".utf8 { h = (h &* 33) ^ UInt64(b) }
        }
        return String(h, radix: 36)
    }
}
