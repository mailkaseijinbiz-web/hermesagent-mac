import XCTest
@testable import HermesCustom

/// Tests for the AgentBackend abstraction: backend selection, and the resume-once
/// continuation bridge in the callback adapters (HermesBackend / AntigravityBackend) —
/// verified via injectable stream/resolve seams, no real process or runtime needed.
@MainActor
final class AgentBackendTests: XCTestCase {

    private func req() -> AgentRequest {
        AgentRequest(prompt: "p", agyPrompt: "a", imagePath: nil, cwd: "/tmp",
                     sessionId: nil, startFresh: true, agyModel: "Gemini 3 Pro (High)")
    }

    // MARK: - Router selection table

    func testSelectKind() {
        XCTAssertEqual(BackendRouter.selectKind(provider: "antigravity", useACP: false), .antigravity)
        XCTAssertEqual(BackendRouter.selectKind(provider: "antigravity", useACP: true), .antigravity)
        XCTAssertEqual(BackendRouter.selectKind(provider: "openrouter", useACP: true), .acp)
        XCTAssertEqual(BackendRouter.selectKind(provider: "openrouter", useACP: false), .hermesCLI)
        XCTAssertEqual(BackendRouter.selectKind(provider: "anthropic", useACP: false), .hermesCLI)
    }

    // MARK: - HermesBackend resume-once bridge

    func testHermesNormalCompletionResumesOnce() async {
        let backend = HermesBackend(stream: { _, _, _, _, onData, _, onEnd in
            onData("こん"); onData("にちは"); onEnd(0)
            return Process()
        })
        var chunks = ""; var gotProcess = false
        let res = await backend.send(req(), onStart: { gotProcess = ($0 != nil) }) { if case .chunk(let t) = $0 { chunks += t } }
        XCTAssertTrue(res.ok)
        XCTAssertTrue(gotProcess, "onStart should deliver the launched Process")
        XCTAssertEqual(chunks, "こんにちは")
    }

    func testHermesNonZeroExitIsNotOk() async {
        let backend = HermesBackend(stream: { _, _, _, _, _, _, onEnd in onEnd(1); return Process() })
        let res = await backend.send(req(), onStart: { _ in }) { _ in }
        XCTAssertFalse(res.ok)
    }

    func testHermesLaunchFailureNilPlusOnEndResumesExactlyOnce() async {
        // Launch failure path: streamPrompt returns nil AND fires onEnd(-1). The latch must
        // prevent a double continuation resume (which would crash withCheckedContinuation).
        var startedNil = false
        let backend = HermesBackend(stream: { _, _, _, _, _, _, onEnd in onEnd(-1); return nil })
        let res = await backend.send(req(), onStart: { startedNil = ($0 == nil) }) { _ in }
        XCTAssertFalse(res.ok)
        XCTAssertTrue(startedNil)
    }

    func testHermesNilReturnWithoutOnEndStillResumes() async {
        let backend = HermesBackend(stream: { _, _, _, _, _, _, _ in nil })   // never calls onEnd
        let res = await backend.send(req(), onStart: { _ in }) { _ in }
        XCTAssertFalse(res.ok)
    }

    // MARK: - AntigravityBackend bridge + not-installed

    func testAntigravityNotInstalledReturnsNotOk() async {
        var streamCalled = false
        let backend = AntigravityBackend(
            stream: { _, _, _, _, _, _ in streamCalled = true; return Process() },
            resolve: { nil })   // agy not installed
        let res = await backend.send(req(), onStart: { _ in }) { _ in }
        XCTAssertFalse(res.ok)
        XCTAssertFalse(streamCalled, "must not stream when agy is missing")
    }

    func testAntigravityNormalCompletion() async {
        let backend = AntigravityBackend(
            stream: { _, _, _, _, onData, onEnd in onData("ok"); onEnd(0); return Process() },
            resolve: { "/usr/local/bin/agy" })
        var chunks = ""
        let res = await backend.send(req(), onStart: { _ in }) { if case .chunk(let t) = $0 { chunks += t } }
        XCTAssertTrue(res.ok)
        XCTAssertEqual(chunks, "ok")
    }

    func testEmitsRawTextFlags() {
        XCTAssertTrue(HermesBackend().emitsRawText)
        XCTAssertTrue(AntigravityBackend().emitsRawText)
        XCTAssertFalse(ACPBackend(client: .mobile).emitsRawText)
    }
}
