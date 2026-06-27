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
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection: connection, accumulated: Data())
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
        case ("GET", _) where pathOnly.hasPrefix("/api/employees/") && pathOnly.hasSuffix("/files"):
            let id = String(pathOnly.dropFirst("/api/employees/".count).dropLast("/files".count))
            handleEmployeeFiles(connection: connection, employeeId: id, corsHeaders: corsHeaders)
        case ("POST", "/api/gmail/send"):
            handleGmailSend(connection: connection, body: body, corsHeaders: corsHeaders)
        case ("GET", "/api/gmail"):
            handleGmailList(connection: connection, corsHeaders: corsHeaders)
        case ("GET", _) where pathOnly.hasPrefix("/api/gmail/"):
            handleGmailThread(connection: connection, threadId: String(pathOnly.dropFirst("/api/gmail/".count)), corsHeaders: corsHeaders)
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
        // ローカル自動化キー（同一マシンの cron）— 完全一致なら Google 検証をスキップ。
        if !localKey.isEmpty, token == localKey { return true }
        return await GoogleTokenVerifier.shared.verify(
            idToken: token,
            allowedEmail: email,
            allowedClientID: clientID
        )
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
                    files.append(["name": name, "isDir": isDir.boolValue, "size": size, "modified": modified])
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
}
