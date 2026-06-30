import Foundation

/// Gmail API v1 sync. Fetches inbox threads, decodes message bodies.
@MainActor
final class GmailSync: ObservableObject {
    static let shared = GmailSync()

    @Published var threads: [GmailThread] = []
    @Published var isSyncing: Bool = false
    @Published var lastSyncStatus: String = ""

    private let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    private var syncTask: Task<Void, Never>? = nil

    private init() {}

    // MARK: - Periodic sync

    func startPeriodicSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(nanoseconds: 3 * 60 * 1_000_000_000)  // 3 min
            }
        }
    }

    func stopPeriodicSync() { syncTask?.cancel(); syncTask = nil }

    func sync() async {
        guard GoogleOAuth.shared.isConnected else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            threads = try await fetchThreads()
            lastSyncStatus = "同期完了（\(threads.count) スレッド）"
        } catch {
            lastSyncStatus = "同期失敗: \(error.localizedDescription)"
            // UI を開いていなくても診断できるよう、失敗は app.log にも残す。
            Log.failure("sync", "Gmail 同期に失敗", error)
        }
    }

    // MARK: - Detail

    func loadThread(_ id: String) async throws -> GmailThread {
        let token = try await GoogleOAuth.shared.validToken()
        var req = URLRequest(url: URL(string: "\(base)/threads/\(id)?format=full")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailError.invalidResponse
        }
        return mapThread(json)
    }

    // MARK: - Send / Reply

    /// Compose and send a new email.
    func sendEmail(to: String, subject: String, body: String) async throws {
        let token = try await GoogleOAuth.shared.validToken()
        let from = GoogleOAuth.shared.email ?? ""
        let raw = buildRawEmail(from: from, to: to, subject: subject, body: body)
        var req = URLRequest(url: URL(string: "\(base)/messages/send")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["raw": raw])
        let (data, _) = try await URLSession.shared.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = json["error"] as? [String: Any] {
            throw GmailError.apiError((e["message"] as? String) ?? "unknown")
        }
    }

    /// Mark a message as read.
    func markRead(_ messageId: String) async throws {
        let token = try await GoogleOAuth.shared.validToken()
        var req = URLRequest(url: URL(string: "\(base)/messages/\(messageId)/modify")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["removeLabelIds": ["UNREAD"]])
        _ = try await URLSession.shared.data(for: req)
        // Update local state
        for i in threads.indices {
            for j in threads[i].messages.indices where threads[i].messages[j].id == messageId {
                threads[i].messages[j].isUnread = false
            }
        }
    }

    // MARK: - Private

    private func fetchThreads() async throws -> [GmailThread] {
        let token = try await GoogleOAuth.shared.validToken()
        var comps = URLComponents(string: "\(base)/threads")!
        comps.queryItems = [
            .init(name: "labelIds",   value: "INBOX"),
            .init(name: "maxResults", value: "50"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailError.invalidResponse
        }
        if let e = json["error"] as? [String: Any] {
            throw GmailError.apiError((e["message"] as? String) ?? "unknown")
        }
        let ids = (json["threads"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        // Fetch each thread (parallel, limit concurrency)
        var result: [GmailThread] = []
        for batch in stride(from: 0, to: ids.count, by: 5).map({ Array(ids[$0..<min($0+5, ids.count)]) }) {
            await withTaskGroup(of: GmailThread?.self) { group in
                for id in batch {
                    group.addTask { [weak self] in try? await self?.loadThread(id) }
                }
                for await t in group { if let t { result.append(t) } }
            }
        }
        result.sort { $0.lastDate > $1.lastDate }
        return result
    }

    private func mapThread(_ json: [String: Any]) -> GmailThread {
        let id = json["id"] as? String ?? UUID().uuidString
        let msgs = (json["messages"] as? [[String: Any]] ?? []).map { mapMessage($0) }
        let subject = msgs.first.flatMap { $0.subject } ?? "（件名なし）"
        return GmailThread(id: id, subject: subject, messages: msgs)
    }

    private func mapMessage(_ json: [String: Any]) -> GmailMessage {
        let id = json["id"] as? String ?? UUID().uuidString
        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = (payload["headers"] as? [[String: Any]] ?? [])
            .reduce(into: [String: String]()) {
                if let n = $1["name"] as? String, let v = $1["value"] as? String { $0[n.lowercased()] = v }
            }
        let from    = headers["from"] ?? ""
        let subject = headers["subject"]
        let dateStr = headers["date"] ?? ""
        let date    = parseRFC2822(dateStr) ?? Date()
        let labelIds = json["labelIds"] as? [String] ?? []
        let isUnread = labelIds.contains("UNREAD")
        let snippet  = json["snippet"] as? String ?? ""
        let body     = extractBody(payload: payload)
        return GmailMessage(id: id, from: from, subject: subject, date: date,
                            isUnread: isUnread, snippet: snippet, body: body)
    }

    private func extractBody(payload: [String: Any]) -> String {
        // Try plain text part first
        if let body = payload["body"] as? [String: Any],
           let data = body["data"] as? String, !data.isEmpty {
            return decodeBase64URL(data)
        }
        let parts = payload["parts"] as? [[String: Any]] ?? []
        for part in parts {
            let mime = part["mimeType"] as? String ?? ""
            if mime == "text/plain", let b = (part["body"] as? [String: Any])?["data"] as? String {
                return decodeBase64URL(b)
            }
        }
        // Fallback: try html
        for part in parts {
            let mime = part["mimeType"] as? String ?? ""
            if mime == "text/html", let b = (part["body"] as? [String: Any])?["data"] as? String {
                return decodeBase64URL(b).replacingOccurrences(of: "<[^>]+>",
                    with: "", options: .regularExpression)
            }
        }
        return ""
    }

    private func decodeBase64URL(_ s: String) -> String {
        var base64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = base64.count % 4
        if pad > 0 { base64 += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: base64) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseRFC2822(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        for f in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z"] {
            fmt.dateFormat = f
            if let d = fmt.date(from: s) { return d }
        }
        return nil
    }

    private func buildRawEmail(from: String, to: String, subject: String, body: String) -> String {
        let mime = """
        From: \(from)\r\nTo: \(to)\r\nSubject: =?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?=\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(Data(body.utf8).base64EncodedString())
        """
        return Data(mime.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    enum GmailError: LocalizedError {
        case invalidResponse
        case apiError(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "無効なレスポンス"
            case .apiError(let m): return m
            }
        }
    }
}

// MARK: - Models

struct GmailThread: Identifiable {
    let id: String
    var subject: String
    var messages: [GmailMessage]
    var lastDate: Date { messages.map(\.date).max() ?? .distantPast }
    var hasUnread: Bool { messages.contains(where: \.isUnread) }
    var from: String { messages.last?.from ?? "" }
    var snippet: String { messages.last?.snippet ?? "" }
}

struct GmailMessage: Identifiable {
    let id: String
    var from: String
    var subject: String?
    var date: Date
    var isUnread: Bool
    var snippet: String
    var body: String
}
