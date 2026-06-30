import Foundation
import Network

/// Lightweight HTTP server for iOS mobile app connectivity.
/// Uses NWListener from the Network framework — zero external dependencies.
@MainActor
class MobileServer {
    static let shared = MobileServer()
    
    private var listener: NWListener?
    private(set) var isRunning = false
    private(set) var port: UInt16 = AppConfig.mobilePort
    
    // Active SSE connections for chat streaming
    private var activeStreamConnections: [NWConnection] = []

    // Long-lived SSE connections subscribed to /api/events (change notifications)
    private var eventConnections: [NWConnection] = []
    private var lastBroadcastToken: String = ""
    private var eventTimer: Task<Void, Never>? = nil

    private init() {}
    
    func start(port: UInt16 = AppConfig.mobilePort) {
        self.port = port
        
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("[MobileServer] Failed to create listener: \(error)")
            return
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[MobileServer] Server ready on port \(port)")
                Task { @MainActor in
                    self?.isRunning = true
                }
            case .failed(let error):
                print("[MobileServer] Server failed: \(error)")
                Task { @MainActor in
                    self?.isRunning = false
                }
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        listener?.start(queue: .global(qos: .userInitiated))
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false

        for conn in activeStreamConnections {
            conn.cancel()
        }
        activeStreamConnections.removeAll()

        eventTimer?.cancel()
        eventTimer = nil
        for conn in eventConnections {
            conn.cancel()
        }
        eventConnections.removeAll()
    }
    
    // MARK: - Connection Handling
    
    private nonisolated func handleConnection(_ connection: NWConnection) {
        // Defense-in-depth: the listener binds all interfaces (0.0.0.0), so on a public/guest
        // network the API could be probed from the internet. Drop connections from clearly-public
        // IPv4 peers before doing any work — legitimate clients reach the hub over loopback,
        // Tailscale (100.64/10 or IPv6 ULA), or the private LAN. The Google/local-key auth gate
        // still applies to everything that passes. Conservative on purpose: anything we can't
        // classify as routable-public IPv4 (incl. all IPv6) is allowed so we never break a real client.
        if isPublicPeer(connection) {
            Log.server.notice("rejected connection from public peer: \(self.peerIP(connection) ?? "?", privacy: .public)")
            connection.cancel()
            return
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection: connection, accumulated: Data())
    }

    /// The remote peer's IP (the client), or nil if it can't be read.
    private nonisolated func peerIP(_ connection: NWConnection) -> String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        switch host {
        case let .ipv4(a): return "\(a)"
        case let .ipv6(a): return "\(a)"
        case let .name(n, _): return n
        @unknown default: return nil
        }
    }

    private nonisolated func isPublicPeer(_ connection: NWConnection) -> Bool {
        guard let ip = peerIP(connection) else { return false }   // unknown → allow (auth still gates)
        return Self.isRoutablePublicIPv4(ip)
    }

    /// True only for a routable public IPv4 address. Private/CGNAT/loopback/link-local IPv4 and
    /// any IPv6 (Tailscale uses IPv6 ULA) return false → treated as trusted. (static → unit-testable)
    nonisolated static func isRoutablePublicIPv4(_ raw: String) -> Bool {
        var ip = raw
        if let z = ip.firstIndex(of: "%") { ip = String(ip[..<z]) }      // strip %en0 zone id
        if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst("::ffff:".count)) }  // IPv4-mapped IPv6
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }                    // not IPv4 (e.g. IPv6) → trusted
        let o = parts.map { Int($0) ?? -1 }
        guard !o.contains(-1), o.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = o[0], b = o[1]
        if a == 0 || a == 127 || a == 10 || a == 169 { return false }   // unspecified/loopback/private/link-local
        if a == 192 && b == 168 { return false }                        // private
        if a == 172 && (16...31).contains(b) { return false }           // private
        if a == 100 && (64...127).contains(b) { return false }          // Tailscale CGNAT 100.64/10
        return true                                                     // routable public IPv4 → reject
    }

    /// Accumulate data across reads until the full HTTP request (headers + body
    /// per Content-Length) has arrived. Required for image uploads, which exceed
    /// a single 64KB read.
    // Reject requests whose total size exceeds this (defensive cap; image uploads
    // are downscaled well under this).
    private nonisolated static let maxRequestBytes = 50 * 1024 * 1024

    private nonisolated func receiveRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            var buffer = accumulated
            if let data = data { buffer.append(data) }

            if error != nil {
                connection.cancel()
                return
            }

            if buffer.count > Self.maxRequestBytes {
                self.sendResponse(connection: connection, status: 400, body: "{\"error\":\"Payload too large\"}")
                return
            }

            if self.isRequestComplete(buffer) || isComplete {
                if let request = String(data: buffer, encoding: .utf8) {
                    self.routeRequest(request, connection: connection)
                } else {
                    connection.cancel()
                }
            } else {
                // Need more bytes (large body still arriving).
                self.receiveRequest(connection: connection, accumulated: buffer)
            }
        }
    }

    /// True once the headers are present and (for POST) the body matches Content-Length.
    private nonisolated func isRequestComplete(_ data: Data) -> Bool {
        let sep = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: sep) else { return false }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return false }

        let lines = headerStr.components(separatedBy: "\r\n")
        let isPost = (lines.first ?? "").uppercased().hasPrefix("POST")
        if !isPost { return true }

        var contentLength = 0
        for line in lines where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyReceived = data.count - headerEnd.upperBound
        return bodyReceived >= contentLength
    }
    
    /// Extract the `Origin` request header (browsers send it; native URLSession clients don't).
    private nonisolated func originHeader(_ raw: String) -> String? {
        for line in raw.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("origin:") {
            let v = line.dropFirst("origin:".count).trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// Returns the origin to echo in `Access-Control-Allow-Origin`, or nil to deny CORS.
    /// Trusted = loopback, Tailscale CGNAT (100.64.0.0/10), or private LAN (10/172.16-31/192.168).
    /// Anything else (e.g. a public website) is denied so it can't read API responses cross-origin.
    private nonisolated func corsAllowedOrigin(_ origin: String?) -> String? {
        guard let origin, let url = URL(string: origin), let host = url.host else { return nil }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return origin }
        // Tailscale MagicDNS / Bonjour hostnames — what updateDashboardURL prefers for the QR URL.
        if host.hasSuffix(".ts.net") || host.hasSuffix(".local") { return origin }
        let octets = host.split(separator: ".").map { Int($0) }
        func octet(_ i: Int) -> Int? { (octets.count == 4 && octets[i] != nil) ? octets[i] : nil }
        // Tailscale 100.64.0.0/10  →  100.64.x.x – 100.127.x.x
        if octet(0) == 100, let b = octet(1), (64...127).contains(b) { return origin }
        // Private LAN
        if octet(0) == 10 { return origin }
        if octet(0) == 192, octet(1) == 168 { return origin }
        if octet(0) == 172, let b = octet(1), (16...31).contains(b) { return origin }
        return nil
    }

    private nonisolated func routeRequest(_ raw: String, connection: NWConnection) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad Request\"}")
            return
        }
        
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad Request\"}")
            return
        }
        
        let method = String(parts[0])
        let path = String(parts[1])
        
        // Extract body for POST requests
        var body = ""
        if method == "POST" {
            if let bodyStart = raw.range(of: "\r\n\r\n") {
                body = String(raw[bodyStart.upperBound...])
            }
        }
        
        // CORS: echo the request Origin only when it's trusted (loopback / Tailscale / LAN),
        // never a blanket "*". A wildcard let any public web page script the local API; an
        // allow-list blocks tabnabbing/CSRF-style abuse while still permitting the QR dashboard.
        // Native iOS/iPad clients send no Origin, so CORS doesn't gate them (URLSession ≠ browser).
        let methodsHeaders = "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization"
        let corsHeaders: String
        if let allowed = corsAllowedOrigin(originHeader(raw)) {
            corsHeaders = "Access-Control-Allow-Origin: \(allowed)\r\nVary: Origin\r\n" + methodsHeaders
        } else {
            corsHeaders = "Vary: Origin\r\n" + methodsHeaders
        }

        // Handle OPTIONS (CORS preflight) — no auth needed
        if method == "OPTIONS" {
            let response = "HTTP/1.1 204 No Content\r\n\(corsHeaders)\r\n\r\n"
            sendRaw(connection: connection, text: response)
            return
        }

        // Authorize (Google Sign-In access gate) then dispatch.
        Task { [weak self] in
            guard let self = self else { return }
            let authorized = await self.authorize(raw: raw)
            if !authorized {
                self.sendResponse(connection: connection, status: 401, body: "{\"error\":\"Unauthorized\"}", corsHeaders: corsHeaders)
                return
            }
            self.dispatch(method: method, path: path, body: body, connection: connection, corsHeaders: corsHeaders)
        }
    }

    private nonisolated func dispatch(method: String, path rawPath: String, body: String, connection: NWConnection, corsHeaders: String) {
        // Split path and query string
        let pathOnly: String
        let query: [String: String]
        if let qIdx = rawPath.firstIndex(of: "?") {
            pathOnly = String(rawPath[..<qIdx])
            query = Self.parseQuery(String(rawPath[rawPath.index(after: qIdx)...]))
        } else {
            pathOnly = rawPath
            query = [:]
        }

        switch (method, pathOnly) {
        case ("GET", "/api/status"):
            handleStatus(connection: connection, corsHeaders: corsHeaders)
        case ("GET", "/api/sessions"):
            handleSessions(connection: connection, corsHeaders: corsHeaders)
        case ("GET", "/api/config"):
            handleConfig(connection: connection, corsHeaders: corsHeaders)
        case ("GET", "/api/employees"):
            handleEmployees(connection: connection, corsHeaders: corsHeaders)
        case ("GET", "/api/sync/digest"):
            handleDigest(connection: connection, corsHeaders: corsHeaders)
        case ("GET", "/api/events"):
            handleEvents(connection: connection, corsHeaders: corsHeaders)
        case ("GET", _) where pathOnly.hasPrefix("/api/sessions/") && pathOnly.hasSuffix("/messages"):
            let id = String(pathOnly.dropFirst("/api/sessions/".count).dropLast("/messages".count))
            let after = query["after"].flatMap { Int64($0) }
            handleSessionMessages(connection: connection, sessionId: id, after: after, corsHeaders: corsHeaders)
        case ("POST", "/api/chat"):
            handleChat(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("POST", "/api/sessions/select"):
            handleSelectSession(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("POST", "/api/sessions/new"):
            handleNewSession(connection: connection, corsHeaders: corsHeaders)
        case ("POST", "/api/push/register"):
            handlePushRegister(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("POST", "/api/presence"):
            handlePresence(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("POST", "/api/badge/clear"):
            handleBadgeClear(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("POST", "/api/dashboard/brief"):
            handleBriefUpdate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("GET", "/api/profile"):
            handleProfileGet(connection: connection, corsHeaders: corsHeaders)
        case ("POST", "/api/profile"):
            handleProfileUpdate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("GET", "/api/self"):
            handleSelfGet(connection: connection, corsHeaders: corsHeaders)
        case ("POST", "/api/self"):
            handleSelfUpdate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("POST", "/api/location"):
            handleLocationUpdate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("POST", "/api/photos"):
            handlePhotosUpdate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("POST", "/api/memo"):
            handleMemoAdd(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("GET", "/api/memos"):
            handleMemosList(connection: connection, corsHeaders: corsHeaders)
        case ("POST", "/api/ingest"):
            handleIngest(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("GET", "/api/review"):
            handleReviewGet(connection: connection, corsHeaders: corsHeaders)
        case ("POST", "/api/review"):
            handleReviewRegenerate(connection: connection, corsHeaders: corsHeaders)
        case ("GET", "/api/cron"):
            handleCronList(connection: connection, corsHeaders: corsHeaders)
        case ("POST", "/api/cron"):
            handleCronCreate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("POST", "/api/cron/toggle"):
            handleCronToggle(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("DELETE", _) where pathOnly.hasPrefix("/api/cron/"):
            let id = String(pathOnly.dropFirst("/api/cron/".count))
            handleCronDelete(connection: connection, id: id, corsHeaders: corsHeaders)
        case ("DELETE", _) where pathOnly.hasPrefix("/api/sessions/"):
            let sessionId = String(pathOnly.dropFirst("/api/sessions/".count))
            handleDeleteSession(connection: connection, sessionId: sessionId, corsHeaders: corsHeaders)

        // MARK: iOS parity — Dashboard / Schedule / Apps / EmployeeDetail / Gmail
        case ("GET", "/api/dashboard"):
            handleDashboard(connection: connection, corsHeaders: corsHeaders)
        case ("GET", "/api/calendar"):
            handleCalendarList(connection: connection, month: query["month"], corsHeaders: corsHeaders)
        case ("POST", "/api/calendar"):
            handleCalendarCreate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("PUT", _) where pathOnly.hasPrefix("/api/calendar/"):
            handleCalendarUpdate(connection: connection, id: String(pathOnly.dropFirst("/api/calendar/".count)), body: body, corsHeaders: corsHeaders)
        case ("DELETE", _) where pathOnly.hasPrefix("/api/calendar/"):
            handleCalendarDelete(connection: connection, id: String(pathOnly.dropFirst("/api/calendar/".count)), corsHeaders: corsHeaders)
        case ("GET", "/api/apps"):
            handleAppsList(connection: connection, corsHeaders: corsHeaders)
        case ("POST", "/api/apps"):
            handleAppCreate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("PUT", _) where pathOnly.hasPrefix("/api/apps/"):
            handleAppUpdate(connection: connection, id: String(pathOnly.dropFirst("/api/apps/".count)), body: body, corsHeaders: corsHeaders)
        case ("DELETE", _) where pathOnly.hasPrefix("/api/apps/"):
            handleAppDelete(connection: connection, id: String(pathOnly.dropFirst("/api/apps/".count)), corsHeaders: corsHeaders)
        case ("POST", _) where pathOnly.hasPrefix("/api/apps/") && pathOnly.hasSuffix("/launch"):
            let appId = String(pathOnly.dropFirst("/api/apps/".count).dropLast("/launch".count))
            handleAppLaunch(connection: connection, id: appId, corsHeaders: corsHeaders)
        case ("GET", "/api/tasks"):
            handleTasksList(connection: connection, employeeId: query["employeeId"], corsHeaders: corsHeaders)
        case ("POST", "/api/tasks"):
            handleTaskCreate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("PUT", _) where pathOnly.hasPrefix("/api/tasks/"):
            handleTaskUpdate(connection: connection, id: String(pathOnly.dropFirst("/api/tasks/".count)), body: body, corsHeaders: corsHeaders)
        case ("DELETE", _) where pathOnly.hasPrefix("/api/tasks/"):
            handleTaskDelete(connection: connection, id: String(pathOnly.dropFirst("/api/tasks/".count)), corsHeaders: corsHeaders)
        case ("POST", "/api/health"):
            handleHealthUpdate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("GET", "/api/health"):
            handleHealthGet(connection: connection, corsHeaders: corsHeaders)
        case ("GET", "/api/artifacts"):
            handleArtifactsList(connection: connection, employeeId: query["employeeId"], corsHeaders: corsHeaders)
        case ("POST", "/api/artifacts"):
            handleArtifactCreate(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("PUT", _) where pathOnly.hasPrefix("/api/artifacts/"):
            handleArtifactUpdate(connection: connection, id: String(pathOnly.dropFirst("/api/artifacts/".count)), body: body, corsHeaders: corsHeaders)
        case ("DELETE", _) where pathOnly.hasPrefix("/api/artifacts/"):
            handleArtifactDelete(connection: connection, id: String(pathOnly.dropFirst("/api/artifacts/".count)), corsHeaders: corsHeaders)
        case ("GET", _) where pathOnly.hasPrefix("/api/employees/") && pathOnly.hasSuffix("/file"):
            let id = String(pathOnly.dropFirst("/api/employees/".count).dropLast("/file".count))
            handleEmployeeFile(connection: connection, employeeId: id, relPath: query["path"] ?? "", corsHeaders: corsHeaders)
        case ("GET", _) where pathOnly.hasPrefix("/api/employees/") && pathOnly.hasSuffix("/files"):
            let id = String(pathOnly.dropFirst("/api/employees/".count).dropLast("/files".count))
            handleEmployeeFiles(connection: connection, employeeId: id, corsHeaders: corsHeaders)
        case ("POST", "/api/gmail/send"):
            handleGmailSend(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("GET", "/api/gmail"):
            handleGmailList(connection: connection, corsHeaders: corsHeaders)
        case ("GET", _) where pathOnly.hasPrefix("/api/gmail/"):
            handleGmailThread(connection: connection, threadId: String(pathOnly.dropFirst("/api/gmail/".count)), corsHeaders: corsHeaders)
        case ("GET", "/api/self-graph"):
            handleSelfGraphGet(connection: connection, corsHeaders: corsHeaders)
        case ("POST", "/api/self-graph/nodes"):
            handleSelfGraphNodeUpsert(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("DELETE", _) where pathOnly.hasPrefix("/api/self-graph/nodes/"):
            handleSelfGraphNodeDelete(connection: connection, id: String(pathOnly.dropFirst("/api/self-graph/nodes/".count)), corsHeaders: corsHeaders)
        case ("POST", "/api/self-graph/links"):
            handleSelfGraphLinkUpsert(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("DELETE", "/api/self-graph/links"):
            handleSelfGraphLinkDelete(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("GET", "/api/stocks"):
            handleStocks(connection: connection, corsHeaders: corsHeaders)
        case ("GET", "/api/sauna-news"):
            handleSaunaNews(connection: connection, corsHeaders: corsHeaders)
        case ("GET", "/api/mac-activity"):
            handleMacActivity(connection: connection, corsHeaders: corsHeaders)
        default:
            sendResponse(connection: connection, status: 404, body: "{\"error\":\"Not Found\"}", corsHeaders: corsHeaders)
        }
    }

    private nonisolated static func parseQuery(_ q: String) -> [String: String] {
        var dict: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                dict[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return dict
    }

    // MARK: - Authorization (Google Sign-In gate)

    /// Returns true when the request is allowed: either auth is disabled, or the
    /// request carries a valid Google ID token for the allowed account.
    private nonisolated func authorize(raw: String) async -> Bool {
        let (require, email, clientID, localKey) = await MainActor.run {
            (AppState.shared.requireMobileAuth,
             AppState.shared.mobileAllowedEmail,
             AppState.shared.mobileAllowedClientID,
             AppState.shared.localAutomationKey)
        }
        guard require else { return true }
        guard let token = extractBearerToken(raw) else { return false }
        // ローカル自動化キー（同一マシンの cron）— 一致なら Google 検証をスキップ。
        // 比較は定数時間で（== の早期 return による文字単位のタイミング側チャネルを防ぐ）。
        if !localKey.isEmpty, Self.constantTimeEquals(token, localKey) { return true }
        return await GoogleTokenVerifier.shared.verify(
            idToken: token,
            allowedEmail: email,
            allowedClientID: clientID
        )
    }

    /// Length-independent, early-exit-free byte comparison for secret tokens.
    nonisolated static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = UInt8(ab.count == bb.count ? 0 : 1)
        let n = Swift.max(ab.count, bb.count, 1)
        for i in 0..<n {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= (x ^ y)
        }
        return diff == 0
    }

    private nonisolated func extractBearerToken(_ raw: String) -> String? {
        let lines = raw.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("authorization:") {
                let value = line.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
                if value.lowercased().hasPrefix("bearer ") {
                    return String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    // MARK: - API Handlers
    
    private nonisolated func handleStatus(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let state = AppState.shared
            let json: [String: Any] = [
                "status": "ok",
                "provider": state.provider,
                "model": state.defaultModel,
                "personality": state.personality
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let str = String(data: data, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: str, corsHeaders: corsHeaders)
            }
        }
    }
    
    private nonisolated func handleSessions(connection: NWConnection, corsHeaders: String) {
        // Read the sessions table directly (covers cli/slack/whatsapp/cron uniformly,
        // and avoids the fragile CLI column-scraping used by the Mac UI).
        let rows = StateDB.shared.sessions()
        let agy = AgyStore.shared.sessions()
        let iso = ISO8601DateFormatter()
        // Union Hermes + agy sessions (agy turns aren't in the read-only state.db), newest first.
        let hermesItems = rows.map { r -> (dict: [String: Any], updatedAt: Double) in
            let title = r.title.isEmpty ? (r.preview.isEmpty ? "(無題)" : String(r.preview.prefix(40))) : r.title
            return ([
                "id": r.id, "title": title, "preview": String(r.preview.prefix(80)),
                "lastActive": iso.string(from: Date(timeIntervalSince1970: r.updatedAt)),
                "source": r.source, "messageCount": r.messageCount, "lastMessageId": r.lastMessageId
            ], r.updatedAt)
        }
        let agyItems = agy.map { s -> (dict: [String: Any], updatedAt: Double) in
            let preview = s.messages.last?.content ?? ""
            return ([
                "id": s.id, "title": s.title.isEmpty ? "(無題)" : s.title, "preview": String(preview.prefix(80)),
                "lastActive": iso.string(from: Date(timeIntervalSince1970: s.updatedAt)),
                "source": "antigravity", "messageCount": s.messages.count, "lastMessageId": 0
            ], s.updatedAt)
        }
        let sorted = (hermesItems + agyItems).sorted { $0.updatedAt > $1.updatedAt }
        Task { @MainActor in
            let state = AppState.shared
            // Build sessionId → owning-employee map (so iOS can filter chats per employee
            // exactly like the Mac sidebar, `AppState.visibleSessions`). "" = unowned (全体).
            // Computed inline in the actor context (a nested func wouldn't be MainActor-isolated).
            var ownerBySession = state.sessionOwner
            for e in state.employees {
                if let sid = e.sessionId, ownerBySession[sid] == nil { ownerBySession[sid] = e.id }
            }
            var sessionsArray: [[String: Any]] = []
            for item in sorted {
                var d = item.dict
                if let sid = d["id"] as? String { d["employeeId"] = ownerBySession[sid] ?? "" }
                sessionsArray.append(d)
            }
            let json: [String: Any] = [
                "sessions": sessionsArray,
                "currentSessionId": state.currentSessionId ?? ""
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let str = String(data: data, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: str, corsHeaders: corsHeaders)
            }
        }
    }

    /// Full (or delta via ?after=) message history for one session, read from state.db.
    private nonisolated func handleSessionMessages(connection: NWConnection, sessionId: String, after: Int64?, corsHeaders: String) {
        // Session ids are UUIDs (hyphenated). The allow-list MUST include '-' or every
        // real session id is rejected and message sync silently breaks. '-' is last in
        // the class so it's a literal, not a range.
        guard sessionId.range(of: "^[0-9A-Za-z_-]+$", options: .regularExpression) != nil else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid session id\"}", corsHeaders: corsHeaders)
            return
        }
        // agy sessions: serve from the AgyStore with synthetic incrementing ids (full
        // history each time; `after` deltas don't apply to the JSON store).
        if AgyStore.isAgySession(sessionId) {
            let stored = AgyStore.shared.messages(sessionId)
            let msgs = stored.enumerated().map { (i, m) -> [String: Any] in
                ["id": i + 1, "role": m.role, "content": m.content, "timestamp": m.ts]
            }
            let json: [String: Any] = ["sessionId": sessionId, "messages": msgs, "messageCount": stored.count]
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let str = String(data: data, encoding: .utf8) {
                sendResponse(connection: connection, status: 200, body: str, corsHeaders: corsHeaders)
            } else {
                sendResponse(connection: connection, status: 500, body: "{\"error\":\"encode failed\"}", corsHeaders: corsHeaders)
            }
            return
        }
        let rows = StateDB.shared.messages(sessionId: sessionId, after: after)
        let totalCount = StateDB.shared.visibleMessageCount(sessionId: sessionId)
        let msgs = rows.map { r -> [String: Any] in
            ["id": r.id, "role": r.role, "content": r.content, "timestamp": r.timestamp]
        }
        let json: [String: Any] = ["sessionId": sessionId, "messages": msgs, "messageCount": totalCount]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let str = String(data: data, encoding: .utf8) {
            sendResponse(connection: connection, status: 200, body: str, corsHeaders: corsHeaders)
        } else {
            sendResponse(connection: connection, status: 500, body: "{\"error\":\"encode failed\"}", corsHeaders: corsHeaders)
        }
    }

    /// Combined change token: Hermes state.db digest + agy store version, so agy turns
    /// (which never touch state.db) still nudge clients to re-pull.
    nonisolated func changeToken() -> String {
        StateDB.shared.digest().token + "~" + AgyStore.shared.version()
    }

    /// Cheap change-detection token for clients to decide whether to pull.
    private nonisolated func handleDigest(connection: NWConnection, corsHeaders: String) {
        let d = StateDB.shared.digest()
        let json: [String: Any] = ["maxMessageId": d.maxMessageId, "sessionCount": d.sessionCount, "token": changeToken()]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let str = String(data: data, encoding: .utf8) {
            sendResponse(connection: connection, status: 200, body: str, corsHeaders: corsHeaders)
        }
    }

    /// Long-lived SSE stream that pushes a "changed" event whenever state.db changes.
    private nonisolated func handleEvents(connection: NWConnection, corsHeaders: String) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\(corsHeaders)\r\n\r\n"
        sendRaw(connection: connection, text: headers)
        let token = changeToken()
        sendRaw(connection: connection, text: "data: {\"type\":\"changed\",\"token\":\"\(token)\"}\n\n")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.eventConnections.removeAll { $0 === connection } }
            default:
                break
            }
        }

        Task { @MainActor in
            self.eventConnections.append(connection)
            self.startEventTimerIfNeeded()
        }
    }

    @MainActor
    private func startEventTimerIfNeeded() {
        guard eventTimer == nil else { return }
        eventTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self?.tickEvents()
            }
        }
    }

    @MainActor
    private func tickEvents() {
        guard !eventConnections.isEmpty else { return }
        let token = changeToken()
        if token != lastBroadcastToken {
            lastBroadcastToken = token
            let msg = "data: {\"type\":\"changed\",\"token\":\"\(token)\"}\n\n"
            for conn in eventConnections { sendRaw(connection: conn, text: msg) }
        } else {
            // Heartbeat keeps the socket alive across Tailscale/NAT idle timeouts.
            for conn in eventConnections { sendRaw(connection: conn, text: ": ping\n\n") }
        }
    }
    
    private nonisolated func handleConfig(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let state = AppState.shared
            let json: [String: Any] = [
                "provider": state.provider,
                "model": state.defaultModel,
                "personality": state.personality,
                "isStreaming": state.isStreaming
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let str = String(data: data, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: str, corsHeaders: corsHeaders)
            }
        }
    }

    /// The AI-employee roster (iOS company parity) — shared fields only.
    private nonisolated func handleEmployees(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let emps: [[String: Any]] = AppState.shared.sortedEmployees.map { e in
                [
                    "id": e.id,
                    "name": e.name,
                    "role": e.role.rawValue,
                    "roleTitle": e.role.title,
                    "emoji": e.role.emoji,
                    "accent": e.role.accentHex,
                    "model": e.model,
                    "mode": e.mode.rawValue,
                    "blurb": e.role.blurb
                ]
            }
            let json: [String: Any] = ["employees": emps]
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let str = String(data: data, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: str, corsHeaders: corsHeaders)
            }
        }
    }

    private nonisolated func handleChat(connection: NWConnection, body: String, corsHeaders: String) {
        // Parse request body
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = json["prompt"] as? String else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing prompt\"}", corsHeaders: corsHeaders)
            return
        }

        let sessionId = json["sessionId"] as? String
        // Chat vs code mode (behavioral). Absent → .code preserves prior behavior.
        let mode = AgentMode(rawValue: (json["mode"] as? String) ?? "") ?? .code
        // Optional AI employee to talk to (iOS company parity) — wraps with its persona.
        let employeeId = json["employeeId"] as? String

        // Optional image: decode base64 → temp file → pass to the CLI via --image.
        let imagePath: String? = {
            guard let imageB64 = json["image"] as? String, !imageB64.isEmpty,
                  let imageData = Data(base64Encoded: imageB64) else { return nil }
            let ext = (json["imageType"] as? String) == "png" ? "png" : "jpg"
            let tmp = NSTemporaryDirectory() + "hermes_upload_\(UUID().uuidString).\(ext)"
            guard (try? imageData.write(to: URL(fileURLWithPath: tmp))) != nil else { return nil }
            return tmp
        }()
        // An image with no text still needs a query for the CLI.
        let effectivePrompt = (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imagePath != nil)
            ? "添付した画像について説明してください。"
            : prompt
        // Send SSE headers
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\(corsHeaders)\r\n\r\n"
        sendRaw(connection: connection, text: headers)

        Task { @MainActor in
            self.activeStreamConnections.append(connection)
            // Run the agent in the selected workspace (GitHub repo) if any, else home.
            let cwd = AppState.shared.effectiveCwd
            // Wrap with the chosen employee's persona (if any) + mode; the iOS bubble
            // shows the user's own text and the sentinel is stripped on the Mac.
            let sentPrompt = AppState.shared.wrapForMobile(effectivePrompt, mode: mode, employeeId: employeeId)

            // The client controls its own session: an explicit id resumes it; no id
            // means a NEW session (do NOT fall back to the Mac's currently-open session,
            // which would merge a phone's new chat into whatever the Mac has open).
            let effectiveSessionId: String? = (sessionId?.isEmpty == false) ? sessionId : nil

            // Backend routing (provider→backend) via the shared AgentBackend abstraction.
            // The relay uses ACPClient.mobile; per-kind bookkeeping (agy image guard +
            // AgyStore, ACP tokens, CLI session reconcile) stays here.
            let mobileEmployee = employeeId.flatMap { id in AppState.shared.employees.first { $0.id == id } }
            let kind = BackendRouter.selectKind(provider: AppState.shared.provider,
                                                useACP: AppState.shared.useACPTransport)
            let rawText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

            // Close the SSE connection after a brief flush delay (shared across kinds).
            func teardown() {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    connection.cancel()
                    Task { @MainActor in self.activeStreamConnections.removeAll { $0 === connection } }
                }
            }

            // agy is text-only: handle its image guard / install check / persona prompt here
            // (it shapes the user text and surfaces errors before the backend runs).
            var agyPrompt = ""
            if kind == .antigravity {
                if let imagePath = imagePath { try? FileManager.default.removeItem(atPath: imagePath) }
                if rawText.isEmpty {
                    self.writeSSEJSON(connection: connection, ["type": "error", "content": "Antigravity CLI (agy) は画像入力に対応していません。テキストで指定してください。"])
                    self.writeSSEJSON(connection: connection, ["type": "done", "tokens": 0]); teardown(); return
                }
                guard await AntigravityCLI.shared.resolveBinaryAsync() != nil else {
                    self.writeSSEJSON(connection: connection, ["type": "error", "content": AntigravityCLI.installHint])
                    self.writeSSEJSON(connection: connection, ["type": "done", "tokens": 0]); teardown(); return
                }
                let userText = imagePath != nil ? rawText + "\n\n（注: 添付画像は Antigravity CLI では無視されます）" : rawText
                agyPrompt = AppState.shared.antigravityPrompt(userText, employee: mobileEmployee, mode: mode)
            }

            let req = AgentRequest(
                prompt: sentPrompt, agyPrompt: agyPrompt,
                imagePath: (kind == .antigravity ? nil : imagePath),   // agy already cleaned the temp image
                cwd: cwd, sessionId: effectiveSessionId, startFresh: effectiveSessionId == nil,
                agyModel: AppState.shared.modelForFixedProvider(mobileEmployee))

            let backend = BackendRouter.make(kind, acp: .mobile)
            let agyAcc = AgyStore.ReplyAccumulator()

            let result = await backend.send(req, onStart: { _ in }) { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .chunk(let t):
                    if kind == .antigravity { agyAcc.append(t) }   // raw; client strips ANSI/noise
                    self.writeSSEJSON(connection: connection, ["type": "chunk", "content": t])
                case .thought(let t):
                    self.writeSSEJSON(connection: connection, ["type": "thought", "content": t])
                case .toolActivity(let calls):
                    self.writeSSEJSON(connection: connection, ["type": "tool_activity", "calls": calls.map { $0.sseDict }])
                }
            }

            // Per-kind terminal handling (persistence / session reconcile / errors).
            // Capture the resolved session id so a phone-created employee chat is recorded
            // under that employee (drives per-employee filtering on iOS AND the Mac sidebar).
            var ownedSessionId: String? = nil
            switch kind {
            case .antigravity:
                let reply = AntigravityCLI.clean(agyAcc.value)
                if !reply.isEmpty {
                    ownedSessionId = AgyStore.shared.record(sessionId: effectiveSessionId, employeeId: employeeId,
                                               userText: rawText, assistantText: reply,
                                               timestamp: Date().timeIntervalSince1970)
                } else {
                    ownedSessionId = effectiveSessionId
                }
                self.writeSSEJSON(connection: connection, ["type": "done", "tokens": 0])
            case .acp:
                if let imagePath = imagePath { try? FileManager.default.removeItem(atPath: imagePath) }
                if !result.ok { self.writeSSEJSON(connection: connection, ["type": "error", "content": "ACP応答に失敗しました"]) }
                self.writeSSEJSON(connection: connection, ["type": "done", "tokens": result.tokens ?? 0])
                await AppState.shared.fetchSessions()
                ownedSessionId = result.hermesSessionId ?? effectiveSessionId
            case .hermesCLI:
                if let imagePath = imagePath { try? FileManager.default.removeItem(atPath: imagePath) }
                if !result.ok { self.writeSSEJSON(connection: connection, ["type": "error", "content": "Failed to start chat process"]) }
                self.writeSSEJSON(connection: connection, ["type": "done"])
                await AppState.shared.fetchSessions()
                if AppState.shared.currentSessionId == nil, let first = AppState.shared.sessions.first {
                    AppState.shared.currentSessionId = first.id
                }
                ownedSessionId = effectiveSessionId ?? AppState.shared.sessions.first?.id
            }
            // Bind the (new) session to the employee the phone is talking as, so it appears
            // under that employee on every device. recordSessionOwner is idempotent.
            if let eid = employeeId, let sid = ownedSessionId {
                AppState.shared.recordSessionOwner(sid, eid)
            }
            teardown()
        }
    }
    
    private nonisolated func handleSelectSession(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = json["sessionId"] as? String else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing sessionId\"}", corsHeaders: corsHeaders)
            return
        }
        
        Task { @MainActor in
            await AppState.shared.handleSelectSession(sessionId: sessionId)
            let messages = AppState.shared.messages.map { msg -> [String: Any] in
                return [
                    "role": msg.role == .user ? "user" : (msg.role == .assistant ? "assistant" : "system"),
                    "content": msg.content,
                    "isError": msg.isError
                ]
            }
            let responseJson: [String: Any] = [
                "sessionId": sessionId,
                "messages": messages
            ]
            if let responseData = try? JSONSerialization.data(withJSONObject: responseJson),
               let str = String(data: responseData, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: str, corsHeaders: corsHeaders)
            }
        }
    }
    
    private nonisolated func handlePushRegister(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing token\"}", corsHeaders: corsHeaders)
            return
        }
        Task { @MainActor in
            AppState.shared.addPushToken(token)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    /// A device reports which session it's viewing in the foreground, so the Mac can
    /// skip pushing that session's updates to it. Body: {token, sessionId?, active}.
    private nonisolated func handlePresence(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing token\"}", corsHeaders: corsHeaders)
            return
        }
        let sessionId = json["sessionId"] as? String
        let active = (json["active"] as? Bool) ?? false
        Task { @MainActor in
            AppState.shared.updatePresence(token: token, sessionId: sessionId, active: active)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    /// A device foregrounded and consumed its updates — reset its app-icon badge counter.
    /// Body: {token}.
    private nonisolated func handleBadgeClear(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing token\"}", corsHeaders: corsHeaders)
            return
        }
        Task { @MainActor in
            AppState.shared.clearBadge(token: token)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    /// Modify the dashboard daily brief from the mobile client. Body: {instruction} to
    /// have the AI rewrite it ("チャットで修正"), or {text} to set it directly. Returns the
    /// updated {brief, briefAt}.
    private nonisolated func handleBriefUpdate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad body\"}", corsHeaders: corsHeaders)
            return
        }
        let text = (json["text"] as? String) ?? ""
        let instruction = (json["instruction"] as? String) ?? ""
        let regenerate = (json["regenerate"] as? Bool) ?? false
        Task { @MainActor in
            // An AI brief is already being written — tell the client to back off rather than
            // silently no-op and return a stale brief as if it succeeded.
            if (regenerate || !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
               AppState.shared.isGeneratingBrief {
                self.sendResponse(connection: connection, status: 409,
                                  body: "{\"error\":\"brief is being generated\"}", corsHeaders: corsHeaders)
                return
            }
            if regenerate {
                await AppState.shared.generateDailyBrief()
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AppState.shared.setDailyBrief(text)
            } else if !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await AppState.shared.reviseDailyBrief(instruction: instruction)
            } else {
                self.sendResponse(connection: connection, status: 400,
                                  body: "{\"error\":\"Missing text, instruction or regenerate\"}", corsHeaders: corsHeaders)
                return
            }
            let resp: [String: Any] = ["brief": AppState.shared.dailyBrief, "briefAt": AppState.shared.dailyBriefAt]
            if let d = try? JSONSerialization.data(withJSONObject: resp), let s = String(data: d, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: s, corsHeaders: corsHeaders)
            } else {
                self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
            }
        }
    }

    /// GET /api/profile — return the user's personal profile (likes/goals/values/notes).
    private nonisolated func handleProfileGet(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let json = AppState.shared.profileJSON
            if let d = try? JSONSerialization.data(withJSONObject: json), let s = String(data: d, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: s, corsHeaders: corsHeaders)
            } else {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"encode failed\"}", corsHeaders: corsHeaders)
            }
        }
    }

    /// POST /api/profile — update the personal profile. Body: {likes?, goals?, values?, notes?}.
    private nonisolated func handleProfileUpdate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad body\"}", corsHeaders: corsHeaders)
            return
        }
        Task { @MainActor in
            AppState.shared.setProfileFields(likes: json["likes"] as? String,
                                             goals: json["goals"] as? String,
                                             values: json["values"] as? String,
                                             notes: json["notes"] as? String)
            let resp = AppState.shared.profileJSON
            if let d = try? JSONSerialization.data(withJSONObject: resp), let s = String(data: d, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: s, corsHeaders: corsHeaders)
            } else {
                self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
            }
        }
    }

    /// GET /api/self — return the user's self-model (memory allocations + work hours).
    private nonisolated func handleSelfGet(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            self.sendResponse(connection: connection, status: 200,
                              body: AppState.shared.selfModelJSONString, corsHeaders: corsHeaders)
        }
    }

    /// POST /api/self — replace the self-model. Body: full SelfModel JSON.
    private nonisolated func handleSelfUpdate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8), !body.isEmpty else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad body\"}", corsHeaders: corsHeaders)
            return
        }
        Task { @MainActor in
            guard AppState.shared.updateSelfModel(jsonData: data) else {
                self.sendResponse(connection: connection, status: 400,
                                  body: "{\"error\":\"Invalid self-model JSON\"}", corsHeaders: corsHeaders)
                return
            }
            self.sendResponse(connection: connection, status: 200,
                              body: AppState.shared.selfModelJSONString, corsHeaders: corsHeaders)
        }
    }

    /// POST /api/location — iOSから今日の「足あと」サマリ（場所名＋時刻）を受け取る。
    /// 生の座標は受け取らない（プライバシー）。Body: {summary}.
    private nonisolated func handleLocationUpdate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = json["summary"] as? String else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing summary\"}", corsHeaders: corsHeaders)
            return
        }
        let points = (json["points"] as? [[String: Any]])?.compactMap { d -> AppState.LocationPoint? in
            guard let name = d["name"] as? String,
                  let lat = (d["lat"] as? NSNumber)?.doubleValue,
                  let lon = (d["lon"] as? NSNumber)?.doubleValue else { return nil }
            return AppState.LocationPoint(name: name, lat: lat, lon: lon)
        } ?? []
        Task { @MainActor in
            AppState.shared.updateLocation(summary: summary, points: points)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    /// POST /api/photos — iOSから今日の写真の要約（枚数/内訳/撮影場所など）を受け取る。
    /// 写真そのものは受け取らない（プライバシー）。Body: {summary}.
    private nonisolated func handlePhotosUpdate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = json["summary"] as? String else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing summary\"}", corsHeaders: corsHeaders)
            return
        }
        Task { @MainActor in
            AppState.shared.updatePhotoSummary(summary)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    /// 共有/メモ用：base64（data: 接頭辞や URL-safe も許容）配列を `[Data]` に復号。
    private nonisolated func decodeImages(_ json: [String: Any]) -> [Data] {
        var raw: [String] = []
        if let arr = json["images"] as? [String] { raw = arr }
        if let one = json["image"] as? String { raw.append(one) }
        return raw.compactMap { s -> Data? in
            var b64 = s
            if let comma = b64.range(of: ","), b64.hasPrefix("data:") { b64 = String(b64[comma.upperBound...]) }
            b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let pad = b64.count % 4
            if pad > 0 { b64 += String(repeating: "=", count: 4 - pad) }
            return Data(base64Encoded: b64)
        }
    }

    /// POST /api/memo — メモを追加。Body: {text, images?:[base64], source?}.
    private nonisolated func handleMemoAdd(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid JSON\"}", corsHeaders: corsHeaders)
            return
        }
        let text = (json["text"] as? String) ?? ""
        let images = decodeImages(json)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Empty memo\"}", corsHeaders: corsHeaders)
            return
        }
        let source = json["source"] as? String
        Task { @MainActor in
            let memo = MacMemoStore.shared.addMemo(text, images: images, source: source)
            let resp: [String: Any] = ["status": "ok", "id": memo.id, "imageCount": memo.imagePaths?.count ?? 0]
            if let d = try? JSONSerialization.data(withJSONObject: resp), let s = String(data: d, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: s, corsHeaders: corsHeaders)
            } else {
                self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
            }
        }
    }

    /// GET /api/memos — 今日のメモ一覧（添付画像は枚数のみ、画像本体は配信しない）。
    private nonisolated func handleMemosList(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let memos = MacMemoStore.shared.todayMemos.map { m -> [String: Any] in
                ["id": m.id, "text": m.text, "time": m.time.timeIntervalSince1970,
                 "imageCount": m.imagePaths?.count ?? 0, "source": m.source ?? ""]
            }
            if let d = try? JSONSerialization.data(withJSONObject: ["memos": memos]),
               let s = String(data: d, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: s, corsHeaders: corsHeaders)
            } else {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"encode failed\"}", corsHeaders: corsHeaders)
            }
        }
    }

    /// POST /api/ingest — iOS 共有シート等から「Hermes に学習させる」対象を受け取る。
    /// Web ページ・写真・テキストをメモ化し、パーソナル AI の文脈（今日のメモ）に取り込む。
    /// Body: {kind:"url"|"image"|"text", url?, title?, text?, note?, image?/images?:[base64]}.
    private nonisolated func handleIngest(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid JSON\"}", corsHeaders: corsHeaders)
            return
        }
        let kind   = (json["kind"] as? String)?.lowercased() ?? "text"
        let url     = (json["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title   = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text    = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note    = (json["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let images  = decodeImages(json)

        // 共有内容を 1 本のメモ本文に整形（先頭にユーザーのメモ書き、続いて素材）。
        var lines: [String] = []
        if !note.isEmpty { lines.append(note) }
        switch kind {
        case "url":
            lines.append("🔗 " + (title.isEmpty ? url : title))
            if !url.isEmpty { lines.append(url) }
            if !text.isEmpty { lines.append(String(text.prefix(2000))) }   // 本文抜粋は上限を設ける
        case "image":
            if note.isEmpty && title.isEmpty { lines.append("📷 共有された写真") }
            if !title.isEmpty { lines.append(title) }
            if !text.isEmpty { lines.append(String(text.prefix(2000))) }
        default: // text
            if !title.isEmpty { lines.append(title) }
            if !text.isEmpty { lines.append(String(text.prefix(4000))) }
        }
        let memoText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memoText.isEmpty || !images.isEmpty else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Nothing to ingest\"}", corsHeaders: corsHeaders)
            return
        }
        let source = kind == "url" ? "web" : "share"
        Task { @MainActor in
            let memo = MacMemoStore.shared.addMemo(memoText, images: images, source: source)
            Log.event("app", "INFO", "ingested \(kind) → memo \(memo.id) (\(memo.imagePaths?.count ?? 0) img)")
            let resp: [String: Any] = ["status": "ok", "id": memo.id]
            if let d = try? JSONSerialization.data(withJSONObject: resp), let s = String(data: d, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: s, corsHeaders: corsHeaders)
            } else {
                self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
            }
        }
    }

    /// GET /api/review — return the latest weekly metacognitive review {review, reviewAt}.
    private nonisolated func handleReviewGet(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let resp: [String: Any] = ["review": AppState.shared.weeklyReview, "reviewAt": AppState.shared.weeklyReviewAt]
            if let d = try? JSONSerialization.data(withJSONObject: resp), let s = String(data: d, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: s, corsHeaders: corsHeaders)
            } else {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"encode failed\"}", corsHeaders: corsHeaders)
            }
        }
    }

    /// POST /api/review — (re)generate the weekly review from daily history. Returns the result.
    private nonisolated func handleReviewRegenerate(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            if AppState.shared.isGeneratingReview {
                self.sendResponse(connection: connection, status: 409,
                                  body: "{\"error\":\"review is being generated\"}", corsHeaders: corsHeaders)
                return
            }
            await AppState.shared.generateWeeklyReview()
            let resp: [String: Any] = ["review": AppState.shared.weeklyReview, "reviewAt": AppState.shared.weeklyReviewAt]
            if let d = try? JSONSerialization.data(withJSONObject: resp), let s = String(data: d, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: s, corsHeaders: corsHeaders)
            } else {
                self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
            }
        }
    }

    // MARK: - Cron / automations (mobile)

    private nonisolated func handleCronList(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let jobs = await AppState.shared.cronJobsJSON()
            let json: [String: Any] = ["jobs": jobs]
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let str = String(data: data, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: str, corsHeaders: corsHeaders)
            } else {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"encode failed\"}", corsHeaders: corsHeaders)
            }
        }
    }

    private nonisolated func handleCronCreate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schedule = json["schedule"] as? String, !schedule.isEmpty else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing schedule\"}", corsHeaders: corsHeaders)
            return
        }
        let prompt = json["prompt"] as? String ?? ""
        let name = json["name"] as? String ?? ""
        let deliver = json["deliver"] as? String ?? "local"
        let script = json["script"] as? String ?? ""
        let noAgent = (json["noAgent"] as? Bool) ?? false
        Task { @MainActor in
            let ok = await AppState.shared.cronCreate(schedule: schedule, prompt: prompt, name: name, deliver: deliver, script: script, noAgent: noAgent)
            self.sendResponse(connection: connection, status: ok ? 200 : 500,
                              body: ok ? "{\"status\":\"ok\"}" : "{\"error\":\"create failed\"}", corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleCronToggle(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing id\"}", corsHeaders: corsHeaders)
            return
        }
        let paused = (json["paused"] as? Bool) ?? true
        Task { @MainActor in
            let ok = await AppState.shared.cronSetPaused(id: id, paused: paused)
            self.sendResponse(connection: connection, status: ok ? 200 : 500,
                              body: ok ? "{\"status\":\"ok\"}" : "{\"error\":\"toggle failed\"}", corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleCronDelete(connection: NWConnection, id: String, corsHeaders: String) {
        Task { @MainActor in
            let ok = await AppState.shared.cronDelete(id: id)
            self.sendResponse(connection: connection, status: ok ? 200 : 500,
                              body: ok ? "{\"status\":\"ok\"}" : "{\"error\":\"delete failed\"}", corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleNewSession(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            AppState.shared.handleNewChat()
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }
    
    private nonisolated func handleDeleteSession(connection: NWConnection, sessionId: String, corsHeaders: String) {
        Task { @MainActor in
            await AppState.shared.handleDeleteSession(id: sessionId)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }
    
    // MARK: - iOS parity handlers (Dashboard / Calendar / Apps / Tasks / Artifacts / Files / Gmail)

    /// Shared JSON 200 responder (encodes a dict; 500 on failure).
    private nonisolated func sendJSON(connection: NWConnection, _ obj: [String: Any], corsHeaders: String) {
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            sendResponse(connection: connection, status: 200, body: str, corsHeaders: corsHeaders)
        } else {
            sendResponse(connection: connection, status: 500, body: "{\"error\":\"encode failed\"}", corsHeaders: corsHeaders)
        }
    }

    /// Parse a POST/PUT JSON body into a dict (nil on failure).
    private nonisolated func parseBody(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    // ScheduleEvent → JSON (device-safe; google events keep their "gcal:" id so iOS marks them read-only).
    @MainActor private func eventDict(_ e: ScheduleEvent) -> [String: Any] {
        var d: [String: Any] = [
            "id": e.id, "title": e.title, "detail": e.detail, "date": e.date,
            "allDay": e.allDay, "createdAt": e.createdAt, "updatedAt": e.updatedAt,
            "source": e.id.hasPrefix("gcal:") ? "google" : "local"
        ]
        if let a = e.assigneeId { d["assigneeId"] = a }
        return d
    }

    @MainActor private func taskDict(_ t: WorkTask, _ empById: [String: Employee]) -> [String: Any] {
        var d: [String: Any] = [
            "id": t.id, "title": t.title, "detail": t.detail, "status": t.status.rawValue,
            "createdAt": t.createdAt, "updatedAt": t.updatedAt
        ]
        if let a = t.assigneeId { d["assigneeId"] = a
            if let e = empById[a] { d["assigneeName"] = e.name; d["assigneeEmoji"] = e.role.emoji } }
        return d
    }

    // AppProject → JSON. folderPath (device-local) is NEVER sent; only the folder name.
    @MainActor private func appDict(_ a: AppProject, _ empById: [String: Employee]) -> [String: Any] {
        var d: [String: Any] = [
            "id": a.id, "name": a.name, "detail": a.detail, "status": a.status.rawValue,
            "previewURL": a.previewURL, "runCommand": a.runCommand,
            "folderName": (a.folderPath as NSString).lastPathComponent,
            "isRunning": AppState.shared.isAppRunning(a.id),
            "createdAt": a.createdAt, "updatedAt": a.updatedAt
        ]
        if let id = a.assigneeId { d["assigneeId"] = id
            if let e = empById[id] { d["assigneeName"] = e.name; d["assigneeEmoji"] = e.role.emoji } }
        return d
    }

    private nonisolated func handleDashboard(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let s = AppState.shared
            let empById = Dictionary(s.employees.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let cal = Calendar.current
            let todayLocal = s.todayEvents
            let todayGoogle = GoogleCalendarSync.shared.events.filter {
                cal.isDateInToday(Date(timeIntervalSince1970: $0.date))
            }
            let todayEvents = (todayLocal + todayGoogle).sorted { $0.date < $1.date }
            let pending = s.workTasks.filter { $0.status == .todo || $0.status == .doing }
            let json: [String: Any] = [
                "brief": s.dailyBrief,
                "briefAt": s.dailyBriefAt,
                "events": todayEvents.map { self.eventDict($0) },
                "tasks": pending.prefix(20).map { self.taskDict($0, empById) },
                "apps": s.sortedApps.prefix(12).map { self.appDict($0, empById) }
            ]
            self.sendJSON(connection: connection, json, corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleCalendarList(connection: NWConnection, month: String?, corsHeaders: String) {
        Task { @MainActor in
            let all = AppState.shared.events + GoogleCalendarSync.shared.events
            let cal = Calendar.current
            let filtered: [ScheduleEvent]
            if let month = month, !month.isEmpty {
                filtered = all.filter { ev in
                    let c = cal.dateComponents([.year, .month], from: Date(timeIntervalSince1970: ev.date))
                    return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0) == month
                }
            } else {
                filtered = all
            }
            let arr = filtered.sorted { $0.date < $1.date }.map { self.eventDict($0) }
            self.sendJSON(connection: connection, ["events": arr], corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleCalendarCreate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let json = parseBody(body), let title = json["title"] as? String else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing title\"}", corsHeaders: corsHeaders); return
        }
        let date = (json["date"] as? Double) ?? Date().timeIntervalSince1970
        let allDay = (json["allDay"] as? Bool) ?? true
        let detail = (json["detail"] as? String) ?? ""
        let assigneeId = json["assigneeId"] as? String
        Task { @MainActor in
            let e = AppState.shared.addEvent(title: title, date: date, allDay: allDay, detail: detail, assigneeId: assigneeId)
            self.sendJSON(connection: connection, ["event": self.eventDict(e)], corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleCalendarUpdate(connection: NWConnection, id: String, body: String, corsHeaders: String) {
        if id.hasPrefix("gcal:") {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Google events are read-only from mobile\"}", corsHeaders: corsHeaders); return
        }
        guard let json = parseBody(body) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad body\"}", corsHeaders: corsHeaders); return
        }
        // assigneeId is String?? on updateEvent: absent → leave unchanged; present → set (incl. nil to clear).
        let assignee: String?? = json.keys.contains("assigneeId") ? .some(json["assigneeId"] as? String) : nil
        Task { @MainActor in
            AppState.shared.updateEvent(id, title: json["title"] as? String, date: json["date"] as? Double,
                                        allDay: json["allDay"] as? Bool, detail: json["detail"] as? String,
                                        assigneeId: assignee)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleCalendarDelete(connection: NWConnection, id: String, corsHeaders: String) {
        if id.hasPrefix("gcal:") {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Google events are read-only from mobile\"}", corsHeaders: corsHeaders); return
        }
        Task { @MainActor in
            AppState.shared.deleteEvent(id)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleAppsList(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let s = AppState.shared
            let empById = Dictionary(s.employees.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.sendJSON(connection: connection, ["apps": s.sortedApps.map { self.appDict($0, empById) }], corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleAppCreate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let json = parseBody(body), let name = json["name"] as? String else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing name\"}", corsHeaders: corsHeaders); return
        }
        let detail = (json["detail"] as? String) ?? ""
        let assigneeId = json["assigneeId"] as? String
        let previewURL = (json["previewURL"] as? String) ?? ""
        let runCommand = (json["runCommand"] as? String) ?? ""
        Task { @MainActor in
            let s = AppState.shared
            guard let a = s.createApp(name: name, detail: detail, assigneeId: assigneeId, previewURL: previewURL, runCommand: runCommand) else {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"create failed\"}", corsHeaders: corsHeaders); return
            }
            let empById = Dictionary(s.employees.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.sendJSON(connection: connection, ["app": self.appDict(a, empById)], corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleAppUpdate(connection: NWConnection, id: String, body: String, corsHeaders: String) {
        guard let json = parseBody(body) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad body\"}", corsHeaders: corsHeaders); return
        }
        Task { @MainActor in
            let s = AppState.shared
            s.updateApp(id, name: json["name"] as? String, detail: json["detail"] as? String,
                        previewURL: json["previewURL"] as? String, runCommand: json["runCommand"] as? String)
            if let st = json["status"] as? String, let status = AppStatus(rawValue: st) { s.setAppStatus(id, status) }
            if json.keys.contains("assigneeId") { s.assignApp(id, to: json["assigneeId"] as? String) }
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleAppDelete(connection: NWConnection, id: String, corsHeaders: String) {
        Task { @MainActor in
            AppState.shared.deleteApp(id)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleAppLaunch(connection: NWConnection, id: String, corsHeaders: String) {
        Task { @MainActor in
            let s = AppState.shared
            guard s.apps.contains(where: { $0.id == id }) else {
                self.sendResponse(connection: connection, status: 404, body: "{\"error\":\"not found\"}", corsHeaders: corsHeaders)
                return
            }
            if !s.isAppRunning(id) { s.launchApp(id) }
            let empById = Dictionary(s.employees.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            if let a = s.apps.first(where: { $0.id == id }) {
                self.sendJSON(connection: connection, ["status": "launching", "app": self.appDict(a, empById)], corsHeaders: corsHeaders)
            } else {
                self.sendJSON(connection: connection, ["status": "launching"], corsHeaders: corsHeaders)
            }
        }
    }

    private nonisolated func handleTasksList(connection: NWConnection, employeeId: String?, corsHeaders: String) {
        Task { @MainActor in
            let s = AppState.shared
            let empById = Dictionary(s.employees.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let tasks = (employeeId?.isEmpty == false)
                ? s.workTasks.filter { $0.assigneeId == employeeId }
                : s.workTasks
            self.sendJSON(connection: connection, ["tasks": tasks.map { self.taskDict($0, empById) }], corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleTaskCreate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let json = parseBody(body), let title = json["title"] as? String else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing title\"}", corsHeaders: corsHeaders); return
        }
        let assigneeId = json["assigneeId"] as? String
        Task { @MainActor in
            let s = AppState.shared
            let t = s.createTask(title: title, assigneeId: assigneeId)
            let empById = Dictionary(s.employees.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.sendJSON(connection: connection, ["task": self.taskDict(t, empById)], corsHeaders: corsHeaders)
        }
    }

    /// POST /api/health — iOS(HealthKit)から健康スナップショットを受け取り保存。
    private nonisolated func handleHealthUpdate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let json = parseBody(body) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad body\"}", corsHeaders: corsHeaders); return
        }
        func i(_ k: String) -> Int? { (json[k] as? Int) ?? (json[k] as? Double).map { Int($0) } }
        func d(_ k: String) -> Double? { (json[k] as? Double) ?? (json[k] as? Int).map(Double.init) }
        Task { @MainActor in
            var snap = HealthSnapshot()
            snap.steps = i("steps")
            snap.distanceKm = d("distanceKm")
            snap.activeEnergyKcal = d("activeEnergyKcal")
            snap.exerciseMinutes = i("exerciseMinutes")
            snap.heartRate = i("heartRate")
            snap.restingHeartRate = i("restingHeartRate")
            snap.sleepHours = d("sleepHours")
            snap.bodyMassKg = d("bodyMassKg")
            snap.date = json["date"] as? String
            snap.source = json["source"] as? String
            AppState.shared.updateHealth(snap)
            self.sendJSON(connection: connection,
                          ["ok": true, "summary": AppState.shared.healthSummaryLine ?? ""],
                          corsHeaders: corsHeaders)
        }
    }

    /// GET /api/health — 保存済みの最新健康スナップショットを返す。
    private nonisolated func handleHealthGet(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            var dict: [String: Any] = ["summary": AppState.shared.healthSummaryLine ?? ""]
            if let h = AppState.shared.latestHealth {
                func put(_ k: String, _ v: Any?) { if let v = v { dict[k] = v } }
                put("steps", h.steps); put("distanceKm", h.distanceKm); put("activeEnergyKcal", h.activeEnergyKcal)
                put("exerciseMinutes", h.exerciseMinutes); put("heartRate", h.heartRate)
                put("restingHeartRate", h.restingHeartRate); put("sleepHours", h.sleepHours)
                put("bodyMassKg", h.bodyMassKg); put("date", h.date); put("source", h.source)
                dict["updatedAt"] = h.updatedAt
            }
            self.sendJSON(connection: connection, dict, corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleTaskUpdate(connection: NWConnection, id: String, body: String, corsHeaders: String) {
        guard let json = parseBody(body) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad body\"}", corsHeaders: corsHeaders); return
        }
        Task { @MainActor in
            let s = AppState.shared
            if let st = json["status"] as? String, let status = TaskStatus(rawValue: st) { s.setTaskStatus(id, status) }
            if json.keys.contains("assigneeId") { s.assignTask(id, to: json["assigneeId"] as? String) }
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleTaskDelete(connection: NWConnection, id: String, corsHeaders: String) {
        Task { @MainActor in
            AppState.shared.deleteTask(id)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    // Artifacts: file artifacts are device-local (body is an absolute path) → never synced.
    @MainActor private func artifactDict(_ a: Artifact) -> [String: Any] {
        [
            "id": a.id, "employeeId": a.employeeId, "title": a.title, "kind": a.kind.rawValue,
            "body": a.kind == .file ? "" : a.body,
            "createdAt": a.createdAt, "updatedAt": a.updatedAt
        ]
    }

    private nonisolated func handleArtifactsList(connection: NWConnection, employeeId: String?, corsHeaders: String) {
        Task { @MainActor in
            let s = AppState.shared
            let list = (employeeId?.isEmpty == false) ? s.artifactsFor(employeeId!) : s.artifacts
            // Note/link sync with body; file artifacts are listed (title/date) but carry no body.
            self.sendJSON(connection: connection, ["artifacts": list.map { self.artifactDict($0) }], corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleArtifactCreate(connection: NWConnection, body: String, corsHeaders: String) {
        guard let json = parseBody(body),
              let employeeId = json["employeeId"] as? String,
              let kindRaw = json["kind"] as? String, let kind = ArtifactKind(rawValue: kindRaw) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing employeeId/kind\"}", corsHeaders: corsHeaders); return
        }
        if kind == .file {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"File artifacts cannot be created from mobile\"}", corsHeaders: corsHeaders); return
        }
        let title = (json["title"] as? String) ?? ""
        let artBody = (json["body"] as? String) ?? ""
        Task { @MainActor in
            let a = AppState.shared.addArtifact(employeeId: employeeId, title: title, kind: kind, body: artBody)
            self.sendJSON(connection: connection, ["artifact": self.artifactDict(a)], corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleArtifactUpdate(connection: NWConnection, id: String, body: String, corsHeaders: String) {
        guard let json = parseBody(body) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Bad body\"}", corsHeaders: corsHeaders); return
        }
        Task { @MainActor in
            AppState.shared.updateArtifact(id, title: json["title"] as? String, body: json["body"] as? String)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleArtifactDelete(connection: NWConnection, id: String, corsHeaders: String) {
        Task { @MainActor in
            AppState.shared.deleteArtifact(id)
            self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
        }
    }

    /// Read-only flat listing of an employee's workspace folder. The absolute path is
    /// NEVER exposed (device-local); only the folder name + entries (name/isDir/size/modified).
    private nonisolated func handleEmployeeFiles(connection: NWConnection, employeeId: String, corsHeaders: String) {
        Task { @MainActor in
            guard let emp = AppState.shared.employees.first(where: { $0.id == employeeId }),
                  let path = emp.workspacePath, !path.isEmpty else {
                self.sendJSON(connection: connection, ["hasWorkspace": false, "workspace": "", "files": []], corsHeaders: corsHeaders); return
            }
            let folderName = (path as NSString).lastPathComponent
            let fm = FileManager.default
            var files: [[String: Any]] = []
            if let entries = try? fm.contentsOfDirectory(atPath: path) {
                for name in entries.sorted() where !name.hasPrefix(".") {
                    let full = (path as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &isDir)
                    let attrs = try? fm.attributesOfItem(atPath: full)
                    let size = (attrs?[.size] as? Int) ?? 0
                    let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    files.append(["name": name, "isDir": isDir.boolValue, "size": size, "modified": modified, "path": name])
                }
            }
            // Directories first, then files (both already alphabetical).
            files.sort { (($0["isDir"] as? Bool) ?? false ? 0 : 1, ($0["name"] as? String) ?? "")
                      <  (($1["isDir"] as? Bool) ?? false ? 0 : 1, ($1["name"] as? String) ?? "") }
            self.sendJSON(connection: connection, ["hasWorkspace": true, "workspace": folderName, "files": files], corsHeaders: corsHeaders)
        }
    }

    // MARK: Gmail proxy (GmailThread/GmailMessage are not Codable → manual JSON)

    private nonisolated func handleGmailList(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let iso = ISO8601DateFormatter()
            let arr = GmailSync.shared.threads.map { t -> [String: Any] in
                [
                    "id": t.id, "subject": t.subject, "from": t.from, "snippet": t.snippet,
                    "hasUnread": t.hasUnread, "messageCount": t.messages.count,
                    "lastDate": iso.string(from: t.lastDate)
                ]
            }
            self.sendJSON(connection: connection, ["threads": arr], corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleGmailThread(connection: NWConnection, threadId: String, corsHeaders: String) {
        Task { @MainActor in
            let gmail = GmailSync.shared
            do {
                let thread: GmailThread
                if let cached = gmail.threads.first(where: { $0.id == threadId }),
                   cached.messages.contains(where: { !$0.body.isEmpty }) {
                    thread = cached
                } else {
                    thread = try await gmail.loadThread(threadId)
                }
                let iso = ISO8601DateFormatter()
                let msgs = thread.messages.map { m -> [String: Any] in
                    [
                        "id": m.id, "from": m.from, "subject": m.subject ?? "",
                        "date": iso.string(from: m.date), "isUnread": m.isUnread,
                        "snippet": m.snippet, "body": m.body
                    ]
                }
                let payload: [String: Any] = ["id": thread.id, "subject": thread.subject, "from": thread.from, "messages": msgs]
                self.sendJSON(connection: connection, ["thread": payload], corsHeaders: corsHeaders)
            } catch {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"load failed\"}", corsHeaders: corsHeaders)
            }
        }
    }

    private nonisolated func handleGmailSend(connection: NWConnection, body: String, corsHeaders: String) {
        guard let json = parseBody(body),
              let to = json["to"] as? String, !to.isEmpty,
              let subject = json["subject"] as? String,
              let mailBody = json["body"] as? String else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing to/subject/body\"}", corsHeaders: corsHeaders); return
        }
        Task { @MainActor in
            do {
                try await GmailSync.shared.sendEmail(to: to, subject: subject, body: mailBody)
                self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
            } catch {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"send failed\"}", corsHeaders: corsHeaders)
            }
        }
    }

    // MARK: - HTTP Response Helpers

    private nonisolated func sendResponse(connection: NWConnection, status: Int, body: String, corsHeaders: String = "") {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }
        
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(corsHeaders)\r\nConnection: close\r\n\r\n\(body)"
        sendRaw(connection: connection, text: response) {
            connection.cancel()
        }
    }
    
    private nonisolated func sendRaw(connection: NWConnection, text: String, completion: (@Sendable () -> Void)? = nil) {
        let data = Data(text.utf8)
        connection.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                print("[MobileServer] Send error: \(error)")
            }
            completion?()
        }))
    }
    
    // MARK: - Utility
    
    nonisolated func jsonEscape(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Write a typed SSE event from a JSON object (handles nested arrays/objects
    /// like the tool-activity `calls` payload). Frame: `data: <json>\n\n`.
    nonisolated func writeSSEJSON(connection: NWConnection, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        sendRaw(connection: connection, text: "data: \(json)\n\n")
    }

    // MARK: - Employee file download / directory browse

    /// GET /api/employees/:id/file?path=relative/path
    /// ファイル → バイナリ配信。ディレクトリ → ファイル一覧 JSON。
    private nonisolated func handleEmployeeFile(connection: NWConnection, employeeId: String,
                                                relPath: String, corsHeaders: String) {
        Task { @MainActor in
            guard let emp = AppState.shared.employees.first(where: { $0.id == employeeId }),
                  let workspace = emp.workspacePath, !workspace.isEmpty else {
                self.sendResponse(connection: connection, status: 404,
                                  body: "{\"error\":\"No workspace\"}", corsHeaders: corsHeaders); return
            }
            // Sanitize: strip traversal components then resolve symlinks before checking containment.
            // `hasPrefix(workspace)` alone allows sibling dirs like "<ws>-evil/" — use a trailing-slash bound.
            let clean = relPath.components(separatedBy: "/")
                .filter { !$0.isEmpty && $0 != ".." && $0 != "." }
                .joined(separator: "/")
            let full = clean.isEmpty ? workspace
                                     : (workspace as NSString).appendingPathComponent(clean)
            let resolvedFull = URL(fileURLWithPath: full).resolvingSymlinksInPath().path
            let resolvedWs   = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path
            let wsDir = resolvedWs.hasSuffix("/") ? resolvedWs : resolvedWs + "/"
            guard resolvedFull == resolvedWs || resolvedFull.hasPrefix(wsDir) else {
                self.sendResponse(connection: connection, status: 403,
                                  body: "{\"error\":\"Forbidden\"}", corsHeaders: corsHeaders); return
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else {
                self.sendResponse(connection: connection, status: 404,
                                  body: "{\"error\":\"Not found\"}", corsHeaders: corsHeaders); return
            }
            if isDir.boolValue {
                // Return directory listing with relative paths
                var files: [[String: Any]] = []
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: full) {
                    for name in entries.sorted() where !name.hasPrefix(".") {
                        let child = (full as NSString).appendingPathComponent(name)
                        var childDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: child, isDirectory: &childDir)
                        let attrs = try? FileManager.default.attributesOfItem(atPath: child)
                        let size = (attrs?[.size] as? Int) ?? 0
                        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                        let childRel = clean.isEmpty ? name : "\(clean)/\(name)"
                        files.append(["name": name, "isDir": childDir.boolValue,
                                      "size": size, "modified": modified, "path": childRel])
                    }
                }
                files.sort { (($0["isDir"] as? Bool) ?? false ? 0 : 1, ($0["name"] as? String) ?? "")
                          <  (($1["isDir"] as? Bool) ?? false ? 0 : 1, ($1["name"] as? String) ?? "") }
                let dirName = clean.isEmpty ? (workspace as NSString).lastPathComponent : (clean as NSString).lastPathComponent
                self.sendJSON(connection: connection,
                              ["isDir": true, "dirName": dirName, "files": files],
                              corsHeaders: corsHeaders)
            } else {
                guard let data = FileManager.default.contents(atPath: full) else {
                    self.sendResponse(connection: connection, status: 500,
                                      body: "{\"error\":\"Read failed\"}", corsHeaders: corsHeaders); return
                }
                let ext = (full as NSString).pathExtension
                self.sendBinaryResponse(connection: connection, data: data,
                                        contentType: Self.mimeType(for: ext), corsHeaders: corsHeaders)
            }
        }
    }

    private nonisolated func sendBinaryResponse(connection: NWConnection, data: Data,
                                                 contentType: String, corsHeaders: String) {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(data.count)\r\n"
        header += corsHeaders
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private nonisolated static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":             return "application/pdf"
        case "png":             return "image/png"
        case "jpg", "jpeg":     return "image/jpeg"
        case "gif":             return "image/gif"
        case "webp":            return "image/webp"
        case "svg":             return "image/svg+xml"
        case "txt", "md":       return "text/plain; charset=utf-8"
        case "html", "htm":     return "text/html; charset=utf-8"
        case "csv":             return "text/csv; charset=utf-8"
        case "json":            return "application/json"
        case "zip":             return "application/zip"
        case "mp4":             return "video/mp4"
        case "mov":             return "video/quicktime"
        case "mp3":             return "audio/mpeg"
        case "wav":             return "audio/wav"
        case "swift", "py", "js", "ts", "rb", "sh", "yaml", "yml", "toml", "xml":
            return "text/plain; charset=utf-8"
        default:                return "application/octet-stream"
        }
    }

    // MARK: - Self Graph

    private nonisolated func handleSelfGraphGet(connection: NWConnection, corsHeaders: String) {
        Task {
            guard let data = try? await SelfGraphStore.shared.encoded(),
                  let json = String(data: data, encoding: .utf8) else {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"read failed\"}", corsHeaders: corsHeaders)
                return
            }
            self.sendResponse(connection: connection, status: 200, body: json, corsHeaders: corsHeaders)
        }
    }

    private nonisolated func handleSelfGraphNodeUpsert(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let node = try? JSONDecoder().decode(SelfGraphNode.self, from: data) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid node JSON\"}", corsHeaders: corsHeaders)
            return
        }
        Task {
            do {
                try await SelfGraphStore.shared.upsertNode(node)
                guard let out = try? await SelfGraphStore.shared.encoded(),
                      let json = String(data: out, encoding: .utf8) else {
                    self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
                    return
                }
                self.sendResponse(connection: connection, status: 200, body: json, corsHeaders: corsHeaders)
            } catch {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"save failed\"}", corsHeaders: corsHeaders)
            }
        }
    }

    private nonisolated func handleSelfGraphNodeDelete(connection: NWConnection, id: String, corsHeaders: String) {
        Task {
            do {
                try await SelfGraphStore.shared.deleteNode(id: id)
                self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
            } catch {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"delete failed\"}", corsHeaders: corsHeaders)
            }
        }
    }

    private nonisolated func handleSelfGraphLinkUpsert(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let link = try? JSONDecoder().decode(SelfGraphLink.self, from: data) else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid link JSON\"}", corsHeaders: corsHeaders)
            return
        }
        Task {
            do {
                try await SelfGraphStore.shared.upsertLink(link)
                guard let out = try? await SelfGraphStore.shared.encoded(),
                      let json = String(data: out, encoding: .utf8) else {
                    self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
                    return
                }
                self.sendResponse(connection: connection, status: 200, body: json, corsHeaders: corsHeaders)
            } catch {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"save failed\"}", corsHeaders: corsHeaders)
            }
        }
    }

    private nonisolated func handleSelfGraphLinkDelete(connection: NWConnection, body: String, corsHeaders: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = json["source"] as? String,
              let target = json["target"] as? String else {
            sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing source/target\"}", corsHeaders: corsHeaders)
            return
        }
        Task {
            do {
                try await SelfGraphStore.shared.deleteLink(source: source, target: target)
                self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}", corsHeaders: corsHeaders)
            } catch {
                self.sendResponse(connection: connection, status: 500, body: "{\"error\":\"delete failed\"}", corsHeaders: corsHeaders)
            }
        }
    }

    // MARK: - Stocks

    private nonisolated func handleStocks(connection: NWConnection, corsHeaders: String) {
        let cacheURL = URL(fileURLWithPath: NSHomeDirectory() + "/.hermes/stocks-cache.json")
        // 30分以内のキャッシュがあればそのまま返す
        if let data = try? Data(contentsOf: cacheURL),
           let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let mod = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mod) < 1800,
           let body = String(data: data, encoding: .utf8) {
            sendResponse(connection: connection, status: 200, body: body, corsHeaders: corsHeaders)
            return
        }
        Task {
            let body = await self.fetchStocksJSON()
            // キャッシュ書き込み
            if let data = body.data(using: .utf8) {
                try? data.write(to: cacheURL)
            }
            self.sendResponse(connection: connection, status: 200, body: body, corsHeaders: corsHeaders)
        }
    }

    nonisolated func fetchStocksJSON() async -> String {
        let home = NSHomeDirectory()
        let portfolioPath = home + "/.hermes/scripts/portfolio.txt"
        let envPath = home + "/.hermes/scripts/.env"

        // ポートフォリオ読み込み
        guard let raw = try? String(contentsOfFile: portfolioPath, encoding: .utf8) else { return "[]" }
        var holdings: [(ticker: String, label: String)] = []
        for line in raw.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { continue }
            let parts: [String]
            if l.contains("\t") {
                parts = l.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                let sp = l.split(maxSplits: 1, whereSeparator: { $0 == " " })
                parts = sp.map { String($0) }
            }
            let ticker = parts[0]
            guard ticker.range(of: "\\s", options: .regularExpression) == nil,
                  !ticker.isEmpty else { continue }
            let label = parts.count > 1 ? parts[1] : ticker
            holdings.append((ticker, label))
        }
        guard !holdings.isEmpty else { return "[]" }

        // APIキー読み込み
        var apiKey = ""
        if let envText = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in envText.components(separatedBy: "\n") {
                let kv = line.trimmingCharacters(in: .whitespaces)
                if kv.hasPrefix("TWELVEDATA_API_KEY=") {
                    apiKey = String(kv.dropFirst("TWELVEDATA_API_KEY=".count))
                        .trimmingCharacters(in: .init(charactersIn: "\"'"))
                }
            }
        }
        guard !apiKey.isEmpty else { return "[]" }

        let symbols = holdings.map { $0.ticker }.joined(separator: ",")

        // 現在値（quote）
        let quoteURL = "https://api.twelvedata.com/quote?symbol=\(symbols)&apikey=\(apiKey)&dp=2"
        guard let qURL = URL(string: quoteURL),
              let (qData, _) = try? await URLSession.shared.data(from: qURL),
              let quoteJSON = try? JSONSerialization.jsonObject(with: qData) as? [String: Any]
        else { return "[]" }

        // 30日推移（time_series）— 6時間キャッシュで API 節約
        let histCachePath = home + "/.hermes/portfolio-history.json"
        let histCacheMaxAge: Double = 6 * 3600
        var historyByTicker: [String: [Double]] = [:]

        struct HistCache: Codable { var savedAt: Double; var data: [String: [Double]] }
        if let cacheData = try? Data(contentsOf: URL(fileURLWithPath: histCachePath)),
           let cache = try? JSONDecoder().decode(HistCache.self, from: cacheData),
           Date().timeIntervalSince1970 - cache.savedAt < histCacheMaxAge {
            historyByTicker = cache.data
        } else {
            let tsURL = "https://api.twelvedata.com/time_series?symbol=\(symbols)&interval=1day&outputsize=30&apikey=\(apiKey)&dp=2"
            if let tURL = URL(string: tsURL),
               let (tsData, _) = try? await URLSession.shared.data(from: tURL),
               let tsJSON = try? JSONSerialization.jsonObject(with: tsData) as? [String: Any] {
                // シングル銘柄は {values:[...]} 、複数は {TICKER:{values:[...]}} の2形式
                func extractValues(_ d: [String: Any]) -> [Double] {
                    guard let vals = d["values"] as? [[String: Any]] else { return [] }
                    return vals.compactMap { ($0["close"] as? String).flatMap(Double.init) }.reversed()
                }
                if tsJSON["values"] != nil {
                    // シングル銘柄レスポンス
                    if let t = holdings.first?.ticker {
                        historyByTicker[t] = extractValues(tsJSON)
                    }
                } else {
                    for h in holdings {
                        if let d = tsJSON[h.ticker] as? [String: Any] {
                            historyByTicker[h.ticker] = extractValues(d)
                        }
                    }
                }
                // キャッシュ保存
                if let cacheOut = try? JSONEncoder().encode(HistCache(savedAt: Date().timeIntervalSince1970, data: historyByTicker)) {
                    try? cacheOut.write(to: URL(fileURLWithPath: histCachePath))
                }
            }
        }

        var results: [[String: Any]] = []
        for h in holdings {
            // シングル銘柄のとき quoteJSON は ticker キーなしで直接返る
            let q: [String: Any]?
            if holdings.count == 1 {
                q = quoteJSON["close"] != nil ? quoteJSON : quoteJSON[h.ticker] as? [String: Any]
            } else {
                q = quoteJSON[h.ticker] as? [String: Any]
            }
            guard let q else { continue }
            let price     = q["close"] as? String ?? "—"
            let changeRaw = q["change"] as? String ?? "0"
            let pctRaw    = q["percent_change"] as? String ?? "0"
            let changeVal = Double(changeRaw) ?? 0
            let pctVal    = Double(pctRaw) ?? 0
            var row: [String: Any] = [
                "ticker": h.ticker,
                "label": h.label,
                "price": price,
                "change": changeVal >= 0 ? "+\(changeRaw)" : changeRaw,
                "changePercent": pctVal >= 0 ? "+\(pctRaw)%" : "\(pctRaw)%",
                "isPositive": changeVal >= 0,
            ]
            if let hist = historyByTicker[h.ticker], !hist.isEmpty {
                row["history"] = hist
            }
            results.append(row)
        }
        guard let out = try? JSONSerialization.data(withJSONObject: results),
              let str = String(data: out, encoding: .utf8) else { return "[]" }
        return str
    }

    // MARK: - Sauna News

    private nonisolated func handleSaunaNews(connection: NWConnection, corsHeaders: String) {
        Task {
            let body = await self.fetchSaunaNewsJSON()
            self.sendResponse(connection: connection, status: 200, body: body, corsHeaders: corsHeaders)
        }
    }

    nonisolated func fetchSaunaNewsJSON() async -> String {
        let query = "サウナ".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "sauna"
        let urlStr = "https://news.google.com/rss/search?q=\(query)&hl=ja&gl=JP&ceid=JP:ja"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8) else { return "[]" }

        // シンプルな正規表現なしの XML パース
        var items: [[String: String]] = []
        let parts = xml.components(separatedBy: "<item>")
        for part in parts.dropFirst().prefix(5) {
            let title = xmlText(part, tag: "title")
            let link  = xmlText(part, tag: "link")
            let date  = xmlText(part, tag: "pubDate")
            if !title.isEmpty {
                items.append(["title": title, "link": link, "date": date])
            }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: items),
              let str = String(data: out, encoding: .utf8) else { return "[]" }
        return str
    }

    // MARK: - Mac Activity

    private nonisolated func handleMacActivity(connection: NWConnection, corsHeaders: String) {
        Task { @MainActor in
            let data = MacActivityLogger.shared.todayJSON()
            let body = String(data: data, encoding: .utf8) ?? "[]"
            self.sendResponse(connection: connection, status: 200, body: body, corsHeaders: corsHeaders)
        }
    }

    private nonisolated func xmlText(_ src: String, tag: String) -> String {
        let open = "<\(tag)>"; let close = "</\(tag)>"
        guard let r1 = src.range(of: open), let r2 = src.range(of: close, range: r1.upperBound..<src.endIndex) else { return "" }
        var val = String(src[r1.upperBound..<r2.lowerBound])
        // CDATA
        if val.hasPrefix("<![CDATA[") && val.hasSuffix("]]>") {
            val = String(val.dropFirst(9).dropLast(3))
        }
        return val.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
