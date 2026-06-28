import Foundation

/// Agent Client Protocol (ACP) transport for Hermes.
///
/// Drives a persistent `hermes acp` child process over newline-delimited JSON-RPC.
/// Unlike the `chat -q` stdout-scraping path, ACP gives STRUCTURED events:
/// `agent_message_chunk` (clean reply), `agent_thought_chunk` (reasoning),
/// `tool_call`/`tool_call_update` (tool activity), and `session/request_permission`
/// (approval). This is the foundation for tool visualization & approval flows (H2+).
///
/// H1 (thin slice): stream `agent_message_chunk` text + return token usage.
/// Box so a JSON-RPC result (non-Sendable [String:Any]) can cross a continuation.
/// Only ever produced/consumed on the MainActor.
private struct ACPResponse: @unchecked Sendable {
    let result: [String: Any]?
}

/// One agent tool invocation, assembled from `tool_call` (start) + `tool_call_update`
/// (status/result) ACP events. Drives the activity cards in the chat (H2).
/// Codable so the mobile relay can serialize it over SSE to the iOS client.
struct ACPToolCall: Identifiable, Equatable, Codable {
    let id: String          // toolCallId, e.g. "tc-4d99817dc6ee"
    var title: String       // "terminal: echo hi" / "read: /path/file"
    var kind: String        // execute | read | edit | fetch | search | think | other
    var status: String      // pending | in_progress | completed | failed
    var locations: [String] // file paths touched
    var input: String       // initial command/args text (from tool_call.content)
    var output: String      // result text (from tool_call_update.content)

    /// SF Symbol chosen by tool kind.
    var symbol: String {
        switch kind {
        case "execute": return "terminal"
        case "read":    return "doc.text"
        case "edit":    return "pencil"
        case "fetch":   return "globe"
        case "search":  return "magnifyingglass"
        case "think":   return "brain"
        default:        return "wrench.and.screwdriver"
        }
    }

    /// JSON-Serialization-friendly form for embedding in an SSE event (mobile relay).
    var sseDict: [String: Any] {
        ["id": id, "title": title, "kind": kind, "status": status,
         "locations": locations, "input": input, "output": output]
    }
}

/// One choice in a tool-permission request (allow/deny variants).
struct ACPPermissionOption: Identifiable, Equatable {
    let optionId: String
    let name: String
    let kind: String   // allow_once | allow_always | reject_once | reject_always
    var id: String { optionId }
    var isAllow: Bool { kind.contains("allow") }
}

/// A pending tool-permission request the agent is waiting on (H2 approval flow).
struct ACPPermission: Equatable {
    let title: String          // "Approve edit: /tmp/x"
    let detail: String         // diff / command / rawInput summary
    let options: [ACPPermissionOption]
}

@MainActor
final class ACPClient {
    /// The Mac UI's ACP driver (one in-flight prompt at a time).
    static let shared = ACPClient()
    /// A SEPARATE instance + `hermes acp` process for the mobile relay, so a phone
    /// prompt never collides with the Mac UI's single in-flight session/callbacks.
    static let mobile = ACPClient()

    /// When true, tool permission requests are auto-allowed (yolo). When false,
    /// `onPermission` is asked for a decision (real approval UI).
    var autoAllow: Bool = true
    /// UI hook: return the chosen optionId, or nil to cancel/deny.
    var onPermission: (@MainActor (ACPPermission) async -> String?)?

    private let hermesPath = HermesCLI.shared.hermesPath

    private var proc: Process?
    private var inPipe: Pipe?
    private var lineBuffer = Data()
    private var nextId = 1
    private var initialized = false
    private(set) var acpSessionId: String?
    private(set) var hermesSessionId: String?

    private var resultHandlers: [Int: (ACPResponse) -> Void] = [:]
    // Streaming handlers for the in-flight prompt (single prompt at a time).
    private var onChunk: ((String) -> Void)?
    private var onThought: ((String) -> Void)?
    private var onToolActivity: (([ACPToolCall]) -> Void)?
    // Tool calls accumulated during the in-flight prompt (insertion-ordered).
    private var toolCallOrder: [String] = []
    private var toolCalls: [String: ACPToolCall] = [:]

    // Serialize prompts on this instance: a single in-flight callback/session model
    // means concurrent prompts (e.g. iPhone + iPad both via ACPClient.mobile) would
    // clobber each other's callbacks/session. Queue them so each runs to completion.
    private var promptBusy = false
    private var promptQueue: [CheckedContinuation<Void, Never>] = []
    /// Last time ANY message arrived from the agent (response/chunk/thought/tool). Drives the
    /// request idle-watchdog so a hung/dead ACP subprocess can't hold the prompt lock forever.
    private var lastAcpActivity = Date()

    private func lockPrompt() async {
        if !promptBusy { promptBusy = true; return }
        await withCheckedContinuation { promptQueue.append($0) }
    }

    private func unlockPrompt() {
        if promptQueue.isEmpty { promptBusy = false }
        else { promptQueue.removeFirst().resume() }
    }

    init() {}

    // MARK: - Process lifecycle

    private func ensureStarted() -> Bool {
        if proc != nil { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hermesPath)
        p.arguments = ["acp", "--accept-hooks"]
        p.environment = HermesCLI.shared.mergedEnvironment
        let ip = Pipe(), op = Pipe()
        p.standardInput = ip
        p.standardOutput = op
        p.standardError = FileHandle.nullDevice

        op.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            guard !d.isEmpty else { return }
            Task { @MainActor in self?.ingest(d) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }
        do { try p.run() } catch {
            Log.acp.error("failed to launch hermes acp: \(error.localizedDescription, privacy: .public)")
            return false
        }
        Log.acp.info("hermes acp started (pid \(p.processIdentifier))")
        proc = p
        inPipe = ip
        return true
    }

    func shutdown() {
        proc?.terminate()
        handleTermination()
    }

    private func handleTermination() {
        proc = nil
        inPipe = nil
        initialized = false
        acpSessionId = nil
        hermesSessionId = nil
        lineBuffer.removeAll()
        let handlers = resultHandlers
        resultHandlers.removeAll()
        for (_, h) in handlers { h(ACPResponse(result: nil)) }
    }

    // MARK: - Stream parsing (newline-delimited JSON-RPC)

    private func ingest(_ data: Data) {
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            if !lineData.isEmpty,
               let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] {
                route(obj)
            }
        }
    }

    private func route(_ obj: [String: Any]) {
        lastAcpActivity = Date()   // any inbound message = the subprocess is alive (idle-watchdog)
        // Agent → client request (has both method and id): respond.
        if let method = obj["method"] as? String, let id = obj["id"] {
            if method == "session/request_permission" {
                handlePermission(id: id, params: obj["params"] as? [String: Any])
            }
            return
        }
        // Agent → client notification.
        if let method = obj["method"] as? String, method == "session/update",
           let params = obj["params"] as? [String: Any],
           let update = params["update"] as? [String: Any],
           let kind = update["sessionUpdate"] as? String {
            switch kind {
            case "agent_message_chunk":
                if let t = (update["content"] as? [String: Any])?["text"] as? String { onChunk?(t) }
            case "agent_thought_chunk":
                if let t = (update["content"] as? [String: Any])?["text"] as? String { onThought?(t) }
            case "tool_call":
                handleToolCall(update, isUpdate: false)
            case "tool_call_update":
                handleToolCall(update, isUpdate: true)
            default:
                break  // plan / usage_update / available_commands_update → later phases
            }
            return
        }
        // Response to one of our requests.
        if let id = obj["id"] as? Int {
            let h = resultHandlers.removeValue(forKey: id)
            h?(ACPResponse(result: obj["error"] == nil ? (obj["result"] as? [String: Any]) : nil))
        }
    }

    // MARK: - Tool activity (H2)

    /// Merge a `tool_call` / `tool_call_update` event into the in-flight prompt's
    /// tool list and notify the UI with the full ordered snapshot.
    private func handleToolCall(_ u: [String: Any], isUpdate: Bool) {
        guard let id = u["toolCallId"] as? String else { return }
        let text = flattenContent(u["content"])
        let locs = (u["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }

        if var tc = toolCalls[id] {
            if let k = u["kind"] as? String { tc.kind = k }
            if let s = u["status"] as? String { tc.status = s }
            if let t = u["title"] as? String, !t.isEmpty { tc.title = t }
            if !locs.isEmpty { tc.locations = locs }
            if isUpdate {
                if !text.isEmpty { tc.output = text }
            } else if !text.isEmpty {
                tc.input = text
            }
            toolCalls[id] = tc
        } else {
            let tc = ACPToolCall(
                id: id,
                title: (u["title"] as? String) ?? (u["kind"] as? String) ?? "tool",
                kind: (u["kind"] as? String) ?? "other",
                status: (u["status"] as? String) ?? (isUpdate ? "completed" : "in_progress"),
                locations: locs,
                input: isUpdate ? "" : text,
                output: isUpdate ? text : ""
            )
            toolCallOrder.append(id)
            toolCalls[id] = tc
        }
        onToolActivity?(toolCallOrder.compactMap { toolCalls[$0] })
    }

    /// Flatten an ACP content-block array into display text. Handles `content`
    /// (text) and `diff` (path/oldText/newText) block types.
    private func flattenContent(_ raw: Any?) -> String {
        guard let blocks = raw as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for b in blocks {
            switch b["type"] as? String {
            case "content":
                if let c = b["content"] as? [String: Any], let t = c["text"] as? String { parts.append(t) }
            case "diff":
                let path = b["path"] as? String ?? ""
                let old = b["oldText"] as? String ?? ""
                let new = b["newText"] as? String ?? ""
                parts.append("\(path)\n- \(old)\n+ \(new)")
            default:
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Route a permission request: auto-allow (yolo) or ask the UI.
    private func handlePermission(id: Any, params: [String: Any]?) {
        if autoAllow || onPermission == nil {
            autoAllowPermission(id: id, params: params)
            return
        }
        let rawOptions = params?["options"] as? [[String: Any]] ?? []
        let opts = rawOptions.compactMap { o -> ACPPermissionOption? in
            guard let oid = o["optionId"] as? String else { return nil }
            return ACPPermissionOption(optionId: oid,
                                       name: (o["name"] as? String) ?? oid,
                                       kind: (o["kind"] as? String) ?? "")
        }
        guard !opts.isEmpty else { autoAllowPermission(id: id, params: params); return }

        let tc = params?["toolCall"] as? [String: Any]
        let perm = ACPPermission(
            title: (tc?["title"] as? String) ?? "ツールの実行を許可しますか？",
            detail: permissionDetail(tc),
            options: opts
        )
        let cb = onPermission!
        let idInt = id as? Int
        let idStr = id as? String
        Task { @MainActor in
            let chosen = await cb(perm)
            var resp: [String: Any] = ["jsonrpc": "2.0", "id": idInt ?? idStr ?? 0]
            if let chosen {
                resp["result"] = ["outcome": ["outcome": "selected", "optionId": chosen]]
            } else {
                resp["result"] = ["outcome": ["outcome": "cancelled"]]
            }
            self.sendRaw(resp)
        }
    }

    /// Build a human-readable summary of what a tool wants to do (for the dialog).
    private func permissionDetail(_ tc: [String: Any]?) -> String {
        guard let tc else { return "" }
        let s = flattenContent(tc["content"])
        if !s.isEmpty { return String(s.prefix(800)) }
        if let raw = tc["rawInput"] as? [String: Any],
           let d = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: d, encoding: .utf8) {
            return String(str.prefix(800))
        }
        return ""
    }

    /// Auto-allow tool permission requests (yolo / personal-use default).
    private func autoAllowPermission(id: Any, params: [String: Any]?) {
        let options = params?["options"] as? [[String: Any]] ?? []
        let allow = options.first { (($0["kind"] as? String) ?? "").contains("allow") } ?? options.first
        let outcome: [String: Any]
        if let optionId = allow?["optionId"] as? String {
            outcome = ["outcome": "selected", "optionId": optionId]
        } else {
            outcome = ["outcome": "cancelled"]
        }
        sendRaw(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
    }

    private func sendRaw(_ obj: [String: Any]) {
        guard let inPipe = inPipe, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        inPipe.fileHandleForWriting.write(data)
    }

    private func request(_ method: String, _ params: [String: Any], idleTimeout: TimeInterval = 60) async -> [String: Any]? {
        let id = nextId; nextId += 1
        lastAcpActivity = Date()
        let response: ACPResponse = await withCheckedContinuation { (cont: CheckedContinuation<ACPResponse, Never>) in
            resultHandlers[id] = { cont.resume(returning: $0) }
            sendRaw(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            // Idle watchdog: if NO message of any kind arrives for `idleTimeout` seconds, fail this
            // request so `send`'s `defer { unlockPrompt() }` runs instead of the prompt lock being
            // held forever on a hung/dead subprocess. removeValue-then-call (same as route's response
            // path) guarantees a single resume even if a real response races in.
            Task { @MainActor [weak self] in
                while true {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self else { return }
                    if self.resultHandlers[id] == nil { return }   // already answered
                    if Date().timeIntervalSince(self.lastAcpActivity) > idleTimeout {
                        if let h = self.resultHandlers.removeValue(forKey: id) {
                            Log.acp.error("ACP request idle-timeout '\(method, privacy: .public)' after \(Int(idleTimeout))s")
                            h(ACPResponse(result: nil))
                        }
                        return
                    }
                }
            }
        }
        return response.result
    }

    // MARK: - Session

    func resetSession() {
        acpSessionId = nil
        hermesSessionId = nil
    }

    private func ensureSession(cwd: String, resume hermesSessionId: String? = nil) async -> Bool {
        guard ensureStarted() else { return false }
        if !initialized {
            let r = await request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]]
            ])
            guard r != nil else { return false }
            initialized = true
        }
        // Resume an existing Hermes conversation (mobile continuing a thread). ACP's
        // sessionId == the Hermes session id, so session/load by that id works.
        if let resume = hermesSessionId, !resume.isEmpty {
            if acpSessionId == resume { return true }
            guard await request("session/load", ["sessionId": resume, "cwd": cwd, "mcpServers": []]) != nil else {
                // Fall back to a fresh session if load isn't possible.
                return await startNewSession(cwd: cwd)
            }
            acpSessionId = resume
            self.hermesSessionId = resume
            return true
        }
        if acpSessionId == nil {
            return await startNewSession(cwd: cwd)
        }
        return acpSessionId != nil
    }

    private func startNewSession(cwd: String) async -> Bool {
        guard let r = await request("session/new", ["cwd": cwd, "mcpServers": []]) else {
            acpSessionId = nil; hermesSessionId = nil; return false
        }
        acpSessionId = r["sessionId"] as? String
        if let meta = r["_meta"] as? [String: Any],
           let h = meta["hermes"] as? [String: Any],
           let prov = h["sessionProvenance"] as? [String: Any] {
            hermesSessionId = prov["currentHermesSessionId"] as? String
        }
        return acpSessionId != nil
    }

    /// Send a prompt; streams reply chunks via `onChunk`. Returns total tokens + success.
    /// `startFresh` forces a new session (mobile "new chat", which is stateless per
    /// request — unlike the Mac UI which reuses the current session until reset).
    @discardableResult
    func prompt(_ text: String,
                imagePath: String? = nil,
                cwd: String = NSHomeDirectory(),
                resumeHermesSessionId: String? = nil,
                startFresh: Bool = false,
                onChunk: @escaping (String) -> Void,
                onThought: @escaping (String) -> Void = { _ in },
                onToolActivity: @escaping ([ACPToolCall]) -> Void = { _ in }) async -> (tokens: Int?, ok: Bool) {
        await lockPrompt()
        defer { unlockPrompt() }

        if startFresh { acpSessionId = nil; hermesSessionId = nil }
        guard await ensureSession(cwd: cwd, resume: resumeHermesSessionId), let sid = acpSessionId else { return (nil, false) }
        self.onChunk = onChunk
        self.onThought = onThought
        self.onToolActivity = onToolActivity
        toolCallOrder.removeAll()
        toolCalls.removeAll()
        defer { self.onChunk = nil; self.onThought = nil; self.onToolActivity = nil }

        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        if let imagePath = imagePath, let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) {
            blocks.append([
                "type": "image",
                "data": data.base64EncodedString(),
                "mimeType": imagePath.hasSuffix("png") ? "image/png" : "image/jpeg"
            ])
        }
        // 180s of total silence (no chunk/thought/tool/response) = stuck. Healthy long turns keep
        // streaming, so this only trips on a real hang — releasing the lock instead of deadlocking.
        let result = await request("session/prompt", ["sessionId": sid, "prompt": blocks], idleTimeout: 180)
        let tokens = (result?["usage"] as? [String: Any])?["totalTokens"] as? Int
        return (tokens, result != nil)
    }
}
