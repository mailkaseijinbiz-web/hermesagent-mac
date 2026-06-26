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
        
        // CORS headers for all responses
        let corsHeaders = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization"

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
        let (require, email, clientID) = await MainActor.run {
            (AppState.shared.requireMobileAuth,
             AppState.shared.mobileAllowedEmail,
             AppState.shared.mobileAllowedClientID)
        }
        guard require else { return true }
        guard let token = extractBearerToken(raw) else { return false }
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
        let sessionsArray = (hermesItems + agyItems).sorted { $0.updatedAt > $1.updatedAt }.map { $0.dict }
        Task { @MainActor in
            let json: [String: Any] = [
                "sessions": sessionsArray,
                "currentSessionId": AppState.shared.currentSessionId ?? ""
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
            switch kind {
            case .antigravity:
                let reply = AntigravityCLI.clean(agyAcc.value)
                if !reply.isEmpty {
                    _ = AgyStore.shared.record(sessionId: effectiveSessionId, employeeId: employeeId,
                                               userText: rawText, assistantText: reply,
                                               timestamp: Date().timeIntervalSince1970)
                }
                self.writeSSEJSON(connection: connection, ["type": "done", "tokens": 0])
            case .acp:
                if let imagePath = imagePath { try? FileManager.default.removeItem(atPath: imagePath) }
                if !result.ok { self.writeSSEJSON(connection: connection, ["type": "error", "content": "ACP応答に失敗しました"]) }
                self.writeSSEJSON(connection: connection, ["type": "done", "tokens": result.tokens ?? 0])
                await AppState.shared.fetchSessions()
            case .hermesCLI:
                if let imagePath = imagePath { try? FileManager.default.removeItem(atPath: imagePath) }
                if !result.ok { self.writeSSEJSON(connection: connection, ["type": "error", "content": "Failed to start chat process"]) }
                self.writeSSEJSON(connection: connection, ["type": "done"])
                await AppState.shared.fetchSessions()
                if AppState.shared.currentSessionId == nil, let first = AppState.shared.sessions.first {
                    AppState.shared.currentSessionId = first.id
                }
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
