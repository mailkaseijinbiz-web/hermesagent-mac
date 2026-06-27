import Foundation

/// Unifies the three chat backends (Hermes CLI, ACP, Antigravity `agy`) behind one
/// async entry point so the call sites stop duplicating the provider→backend dispatch.
///
/// Design (see the AgentBackend design synthesis): thin adapters wrap the UNCHANGED
/// backend functions; text cleaning stays at the call-site sink (selected by
/// `emitsRawText`), never in the backend; per-site session/persistence/image/model-swap
/// bookkeeping stays at the call site. ACP is async natively; the callback+Process
/// backends are bridged with `withCheckedContinuation` (the proven in-repo pattern), with
/// a resume-once latch so a launch failure (nil Process + onEnd(-1)) can't double-resume.

// MARK: - Selection

enum BackendKind: Equatable { case hermesCLI, acp, antigravity }

enum BackendRouter {
    /// Which backend a turn routes to. Antigravity wins on the fixed provider; otherwise
    /// the ACP toggle decides CLI vs ACP.
    static func selectKind(provider: String, useACP: Bool) -> BackendKind {
        if provider == AntigravityCLI.providerId { return .antigravity }
        return useACP ? .acp : .hermesCLI
    }

    /// Build the adapter for `kind`. `acp` is the ACPClient instance to use — `.shared`
    /// on the Mac, `.mobile` for the relay (they must never collide).
    @MainActor
    static func make(_ kind: BackendKind, acp: ACPClient) -> AgentBackend {
        switch kind {
        case .hermesCLI:   return HermesBackend()
        case .antigravity: return AntigravityBackend()
        case .acp:         return ACPBackend(client: acp)
        }
    }
}

// MARK: - Request / events / result

/// One turn's inputs. `prompt` is the sentinel-wrapped text for Hermes/ACP; `agyPrompt`
/// is the sentinel-free text for agy; both are built by the caller before the request.
struct AgentRequest {
    var prompt: String
    var agyPrompt: String
    var imagePath: String?
    var cwd: String
    var sessionId: String?
    var startFresh: Bool
    var agyModel: String
}

enum AgentEvent {
    case chunk(String)            // reply text (CLI/agy raw; ACP already clean)
    case thought(String)         // ACP reasoning
    case toolActivity([ACPToolCall])
}

struct AgentResult {
    var ok: Bool
    var tokens: Int? = nil
    var hermesSessionId: String? = nil
}

// MARK: - Protocol

@MainActor
protocol AgentBackend {
    /// True when emitted `.chunk` text is raw CLI/agy output the sink must clean
    /// (parseResponseText / AntigravityCLI.clean). ACP emits already-clean text.
    var emitsRawText: Bool { get }

    /// Run one turn. `onStart` fires synchronously with the launched Process (CLI/agy)
    /// as soon as it spawns — so `cancelStreaming` can terminate it DURING the stream —
    /// or nil (ACP / launch failure). `onEvent` streams output. Returns the final result.
    func send(_ req: AgentRequest,
              onStart: @escaping (Process?) -> Void,
              onEvent: @escaping (AgentEvent) -> Void) async -> AgentResult
}

// MARK: - Hermes CLI adapter

@MainActor
final class HermesBackend: AgentBackend {
    var emitsRawText: Bool { true }

    /// Injectable seam (defaults to the real HermesCLI) so the resume-once bridge is
    /// unit-testable without spawning a process.
    typealias StreamFn = @MainActor (_ prompt: String, _ sessionId: String?, _ imagePath: String?, _ cwd: String,
                          _ onData: @escaping @Sendable (String) -> Void,
                          _ onStderr: @escaping @Sendable (String) -> Void,
                          _ onEnd: @escaping @Sendable (Int32) -> Void) -> Process?
    private let stream: StreamFn

    init(stream: @escaping StreamFn = { p, s, i, c, d, e, en in
        HermesCLI.shared.streamPrompt(prompt: p, sessionId: s, imagePath: i, cwd: c, onData: d, onStderr: e, onEnd: en)
    }) { self.stream = stream }

    func send(_ req: AgentRequest, onStart: @escaping (Process?) -> Void,
              onEvent: @escaping (AgentEvent) -> Void) async -> AgentResult {
        await withCheckedContinuation { (cont: CheckedContinuation<AgentResult, Never>) in
            var resumed = false
            let proc = stream(req.prompt, req.sessionId, req.imagePath, req.cwd,
                          { onEvent(.chunk($0)) }, { _ in },
                          { code in if !resumed { resumed = true; cont.resume(returning: AgentResult(ok: code == 0)) } })
            onStart(proc)
            if proc == nil && !resumed { resumed = true; cont.resume(returning: AgentResult(ok: false)) }
        }
    }
}

// MARK: - Antigravity (agy) adapter

@MainActor
final class AntigravityBackend: AgentBackend {
    var emitsRawText: Bool { true }

    typealias StreamFn = @MainActor (_ bin: String, _ prompt: String, _ model: String, _ cwd: String,
                          _ onData: @escaping @Sendable (String) -> Void,
                          _ onEnd: @escaping @Sendable (Int32) -> Void) -> Process?
    typealias ResolveFn = @MainActor () async -> String?
    private let stream: StreamFn
    private let resolve: ResolveFn

    init(stream: @escaping StreamFn = { b, p, m, c, d, en in
            AntigravityCLI.shared.streamPrompt(bin: b, prompt: p, model: m, cwd: c, onData: d, onEnd: en)
         },
         resolve: @escaping ResolveFn = { await AntigravityCLI.shared.resolveBinaryAsync() }) {
        self.stream = stream
        self.resolve = resolve
    }

    func send(_ req: AgentRequest, onStart: @escaping (Process?) -> Void,
              onEvent: @escaping (AgentEvent) -> Void) async -> AgentResult {
        guard let bin = await resolve() else { onStart(nil); return AgentResult(ok: false) }
        return await withCheckedContinuation { (cont: CheckedContinuation<AgentResult, Never>) in
            var resumed = false
            let proc = stream(bin, req.agyPrompt, req.agyModel, req.cwd,
                          { onEvent(.chunk($0)) },
                          { code in if !resumed { resumed = true; cont.resume(returning: AgentResult(ok: code == 0)) } })
            onStart(proc)
            if proc == nil && !resumed { resumed = true; cont.resume(returning: AgentResult(ok: false)) }
        }
    }
}

// MARK: - ACP adapter

@MainActor
final class ACPBackend: AgentBackend {
    var emitsRawText: Bool { false }   // ACP relays already-clean text + structured events
    private let client: ACPClient
    init(client: ACPClient) { self.client = client }

    func send(_ req: AgentRequest, onStart: @escaping (Process?) -> Void,
              onEvent: @escaping (AgentEvent) -> Void) async -> AgentResult {
        onStart(nil)   // ACP has no cancellable Process
        let r = await client.prompt(
            req.prompt, imagePath: req.imagePath, cwd: req.cwd,
            resumeHermesSessionId: req.sessionId, startFresh: req.startFresh,
            onChunk: { onEvent(.chunk($0)) },
            onThought: { onEvent(.thought($0)) },
            onToolActivity: { onEvent(.toolActivity($0)) })
        return AgentResult(ok: r.ok, tokens: r.tokens, hermesSessionId: client.hermesSessionId)
    }
}
