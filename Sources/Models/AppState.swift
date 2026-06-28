import Foundation
import Combine
import AppKit

enum AppConfig {
    static let mobilePort: UInt16 = 9119
}

struct Session: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
    let lastActive: String
}

enum MessageRole {
    case user
    case assistant
    case system
}

/// A file staged for the next chat message (composer attachment). `url` is a local path the
/// agent can read; `imageData` is set when the file is an image (drives the preview + vision).
struct AttachedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var imageData: Data? = nil
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased() }
    var isImage: Bool { imageData != nil }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif"]
    static func isImagePath(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }
}

struct Message: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    var isError: Bool = false
    var imageData: Data? = nil
    var typewriter: Bool = false
    var tokens: Int? = nil          // token_count from the store (assistant)
    var elapsed: Double? = nil      // seconds since the preceding message
    var toolCalls: [ACPToolCall] = []   // ACP tool activity (H2)
    var thinking: String = ""           // ACP reasoning (collapsible)
    // Phase 2 delegation: when a manager delegates, the reply is attributed to the
    // specialist who handled it (drives the avatar + "委譲" header).
    var delegatedName: String? = nil
    var delegatedRole: EmployeeRole? = nil
    /// The id of the employee a delegated reply is attributed to (names aren't unique,
    /// so this is the reliable key — e.g. for "成果物として保存").
    var delegatedId: String? = nil

    init(id: UUID = UUID(), role: MessageRole, content: String, isError: Bool = false, imageData: Data? = nil, typewriter: Bool = false, tokens: Int? = nil, elapsed: Double? = nil, toolCalls: [ACPToolCall] = [], thinking: String = "", delegatedName: String? = nil, delegatedRole: EmployeeRole? = nil, delegatedId: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.isError = isError
        self.imageData = imageData
        self.typewriter = typewriter
        self.tokens = tokens
        self.elapsed = elapsed
        self.toolCalls = toolCalls
        self.thinking = thinking
        self.delegatedName = delegatedName
        self.delegatedRole = delegatedRole
        self.delegatedId = delegatedId
    }
}


/// Chat vs Code mode (Claude Code風). Difference is BEHAVIORAL only: a short
/// directive is prepended to each prompt (the agent keeps all tools in both modes).
/// The directive is wrapped in a sentinel so it can be stripped from the displayed
/// user bubble (see `AppState.stripModeDirective`).
enum AgentMode: String, Codable, CaseIterable, Identifiable {
    case chat
    case code
    var id: String { rawValue }

    var label: String { self == .chat ? "チャット" : "コード" }
    var icon: String { self == .chat ? "bubble.left" : "chevron.left.forwardslash.chevron.right" }

    /// Behavioral steering injected before the user's text.
    var directive: String {
        switch self {
        case .chat:
            return "あなたはチャットモードです。会話的・簡潔に答えてください。明示的に依頼されない限り、ファイルの作成・編集やコマンドの実行は行わず、説明・提案・相談に徹してください。"
        case .code:
            return "あなたはコードモードです。これはコーディング/開発タスクです。必要なツール（ファイル編集・ターミナル・コード実行など）を積極的に活用し、最後までやり切ってください。"
        }
    }

    /// The user's text + a sentinel-wrapped directive APPENDED. Suffix (not prefix) so
    /// hermes derives the session title/preview from the clean leading user text, and
    /// the directive still steers the model (recency). The UI strips it for display.
    func wrap(_ userText: String) -> String {
        "\(userText)\n\n\(AgentMode.sentinelOpen)\(directive)\(AgentMode.sentinelClose)"
    }

    static let sentinelOpen = "⟦HMODE⟧"
    static let sentinelClose = "⟦/HMODE⟧"

    /// Remove the trailing sentinel-wrapped directive block from text (everything from
    /// the opening sentinel onward). Safe on truncated previews/titles too.
    static func strip(_ text: String) -> String {
        guard let openRange = text.range(of: sentinelOpen) else { return text }
        return String(text[..<openRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A GitHub repository from `gh repo list` — selectable as the agent's working folder (cwd).
struct GitHubRepo: Identifiable, Equatable {
    var id: String { nameWithOwner }
    let nameWithOwner: String
    let description: String
    let isPrivate: Bool
    let updatedAt: String
    let language: String
    /// "owner/repo" → "repo"
    var name: String { nameWithOwner.contains("/") ? String(nameWithOwner.split(separator: "/").last!) : nameWithOwner }
}

/// Per-employee usage/cost rollup (Phase 3) computed from state.db token counts.
struct EmployeeUsage: Equatable {
    var tokens: Int = 0
    var sessions: Int = 0
    var costUSD: Double = 0
}

/// A suggested automation (cron). Tapping it prefills the create form.
struct AutomationSuggestion: Identifiable, Equatable {
    var id = UUID()
    let title: String
    let schedule: String
    let prompt: String
    let deliver: String
    let icon: String
    let rationale: String
}

/// An installed Hermes skill (parsed from `hermes skills list`).
struct HermesSkill: Identifiable, Equatable {
    let id: String       // name
    let name: String
    let category: String
    let source: String   // builtin | local | official | hub
    let status: String   // enabled | disabled
    var isEnabled: Bool { status.lowercased().contains("enabled") }
}

/// A built-in memory document the user can view/edit from the app.
enum MemoryFile: String, CaseIterable, Identifiable {
    case memory = "MEMORY.md"
    case user = "USER.md"
    case soul = "SOUL.md"
    var id: String { rawValue }
    var path: String {
        let home = NSHomeDirectory()
        switch self {
        case .memory: return home + "/.hermes/memories/MEMORY.md"
        case .user:   return home + "/.hermes/memories/USER.md"
        case .soul:   return home + "/.hermes/SOUL.md"
        }
    }
    var label: String {
        switch self {
        case .memory: return "MEMORY.md（記憶）"
        case .user:   return "USER.md（ユーザー像）"
        case .soul:   return "SOUL.md（人格）"
        }
    }
}

struct HermesPlugin: Identifiable, Equatable {
    let id: String // name
    let name: String
    let status: String // "enabled" | "not enabled"
    let version: String
    let source: String

    var isEnabled: Bool {
        return status == "enabled" || (status.contains("enabled") && !status.contains("not"))
    }
}

struct HermesCronJob: Identifiable, Equatable {
    let id: String // hash ID (e.g. aaa0cf18ec8e)
    let name: String
    let schedule: String
    let repeatCount: String
    let nextRun: String
    let deliver: String
    let status: String // "active" | "paused"
    let script: String?
    let mode: String?
    let lastRun: String?
    let lastError: String?   // 直近の実行/配信エラー（`⚠ ...` 行）。正常時は nil

    var isActive: Bool {
        return status == "active"
    }
}

struct HermesChannel: Identifiable, Equatable {
    var id: String { "\(platform):\(channelId)" }
    let platform: String
    let channelId: String
    let name: String
    let type: String
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var view: String = "chat" // "chat" | "company" | "automations"
    @Published var showCommandPalette = false   // ⌘K quick-jump overlay
    @Published var showSettings: Bool = false   // settings shown as a modal dialog
    @Published var sessions: [Session] = []
    @Published var currentSessionId: String? = nil
    @Published var messages: [Message] = []
    /// Per-message feedback rating (message id → 1 good / -1 needs-fix). Drives the 👍/👎 UI;
    /// also appended to ~/.hermes/feedback.jsonl for later review.
    @Published var messageFeedback: [UUID: Int] = [:]
    @Published var inputValue: String = ""
    // Files attached to the next message (drag-drop / picker / paste). Shown as composer
    // thumbnails the user can remove. Images also feed --image (vision); all files' local
    // paths are referenced in the sent prompt so the agent can read them.
    @Published var attachedFiles: [AttachedFile] = []
    /// The first attached image's bytes (for vision / the message bubble), or nil.
    var attachedImageData: Data? { attachedFiles.first(where: { $0.isImage })?.imageData }

    // Channels (messaging platform recipients in ~/.hermes/channel_directory.json)
    @Published var channels: [HermesChannel] = []
    @Published var newChannelPlatform: String = "telegram"
    @Published var newChannelId: String = ""
    @Published var newChannelName: String = ""
    /// True when the CURRENTLY ACTIVE employee has an in-flight turn.
    /// Computed from `streamingEmployeeIds` (which IS @Published) so SwiftUI re-renders correctly.
    var isStreaming: Bool { streamingEmployeeIds.contains(activeEmployeeId ?? "") }
    @Published var streamText: String = ""
    @Published var activeStatus: String = "online" // "online" | "thinking"
    /// Backend health circuit breaker (#5 offline resilience): trips to false after a run of
    /// empty/failed turns so the UI shows 「接続不安定」 instead of the user staring at silent
    /// failures; recovers on the next successful reply.
    @Published var backendHealthy: Bool = true
    private var backendFailureStreak = 0
    // Liveness of the visible streaming turn: when it started, and when the last chunk/thought/
    // tool event actually arrived. Drives the "受信中 / 応答待ち / 遅延" indicator so the user can
    // tell whether the agent is progressing or stalled (vs a purely decorative spinner).
    @Published var streamStartedAt: Date? = nil
    @Published var lastStreamActivityAt: Date? = nil
    /// Bytes/chars streamed so far in the visible turn (a rising count = data is flowing).
    @Published var streamedCharCount: Int = 0
    
    // Dashboard (Mobile Sync) State
    @Published var isDashboardRunning: Bool = false
    @Published var dashboardURL: String = ""
    @Published var qrCodeImage: NSImage? = nil
    
    // Mobile Server State
    @Published var isMobileServerRunning: Bool = false

    // LINE bridge (bridge.py on :8650) — auto-started with the app so LINE always works.
    @Published var isLineBridgeRunning: Bool = false
    @Published var lineBridgeStatus: String = ""

    /// Ensure the LINE bridge is running, then reflect its live state in the UI.
    func startLineBridge() async {
        lineBridgeStatus = LineBridge.shared.ensureRunning()
        try? await Task.sleep(nanoseconds: 1_800_000_000)   // give bridge.py time to bind :8650
        let up = LineBridge.shared.isPortUp()
        isLineBridgeRunning = up
        if up {
            lineBridgeStatus = "LINEブリッジ稼働中（:\(LineBridge.shared.port)）"
        } else if LineBridge.shared.isInstalled && !lineBridgeStatus.contains("失敗") {
            lineBridgeStatus = "起動を試みました（応答待ち / ~/.hermes/line-bridge/bridge.log を確認）"
        }
    }

    func restartLineBridge() async {
        LineBridge.shared.stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await startLineBridge()
    }

    // Mobile Server Auth (Google Sign-In access gate)
    // When enabled, only requests carrying a valid Google ID token whose verified
    // email matches `mobileAllowedEmail` are accepted by MobileServer.
    @Published var requireMobileAuth: Bool = UserDefaults.standard.bool(forKey: "requireMobileAuth") {
        didSet { UserDefaults.standard.set(requireMobileAuth, forKey: "requireMobileAuth") }
    }
    @Published var mobileAllowedEmail: String = UserDefaults.standard.string(forKey: "mobileAllowedEmail") ?? "" {
        didSet { UserDefaults.standard.set(mobileAllowedEmail, forKey: "mobileAllowedEmail") }
    }
    // Optional iOS OAuth client ID for `aud` verification (defense-in-depth). Empty = skip aud check.
    @Published var mobileAllowedClientID: String = UserDefaults.standard.string(forKey: "mobileAllowedClientID") ?? "" {
        didSet { UserDefaults.standard.set(mobileAllowedClientID, forKey: "mobileAllowedClientID") }
    }

    /// ローカル自動化キー。同一マシンの cron ジョブが `Authorization: Bearer <key>` で送ると
    /// MobileServer に Google ID トークンなしで到達できる（Tailscale 越しは従来通り Google 認証）。
    /// `~/.hermes/.env` の `HERMES_LOCAL_API_KEY` に保存。初回は自動生成。
    /// 注: `~/.hermes/.env` を読めるローカルプロセスはこのキーを利用可能（同一マシン信頼前提）。
    @Published var localAutomationKey: String = AppState.loadOrCreateLocalKey()

    static var hermesEnvPath: String { NSHomeDirectory() + "/.hermes/.env" }
    static func loadOrCreateLocalKey() -> String {
        let path = hermesEnvPath
        if let txt = try? String(contentsOfFile: path, encoding: .utf8) {
            for raw in txt.split(separator: "\n") {
                let l = raw.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("HERMES_LOCAL_API_KEY=") {
                    let v = String(l.dropFirst("HERMES_LOCAL_API_KEY=".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !v.isEmpty { return v }
                }
            }
        }
        let key = "loc_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        body += "HERMES_LOCAL_API_KEY=\(key)\n"
        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            // static context → no toast; the file log captures it for later diagnosis.
            Log.failure("app", "ローカルAPIキーの保存に失敗 (\(path))", error)
        }
        return key
    }

    // APNs push notifications (Mac acts as the push provider)
    @Published var apnsEnabled: Bool = UserDefaults.standard.bool(forKey: "apnsEnabled") {
        didSet { UserDefaults.standard.set(apnsEnabled, forKey: "apnsEnabled") }
    }
    @Published var apnsKeyPath: String = UserDefaults.standard.string(forKey: "apnsKeyPath") ?? "" {
        didSet { UserDefaults.standard.set(apnsKeyPath, forKey: "apnsKeyPath") }
    }
    @Published var apnsKeyId: String = UserDefaults.standard.string(forKey: "apnsKeyId") ?? "" {
        didSet { UserDefaults.standard.set(apnsKeyId, forKey: "apnsKeyId") }
    }
    // 既定は空：開発者個人の Apple Team ID をバイナリへ焼き込まない。利用者が設定画面で自分の Team ID を入力する。
    @Published var apnsTeamId: String = UserDefaults.standard.string(forKey: "apnsTeamId") ?? "" {
        didSet { UserDefaults.standard.set(apnsTeamId, forKey: "apnsTeamId") }
    }
    @Published var apnsBundleId: String = UserDefaults.standard.string(forKey: "apnsBundleId") ?? "com.custom.hermesagent" {
        didSet { UserDefaults.standard.set(apnsBundleId, forKey: "apnsBundleId") }
    }
    @Published var apnsUseSandbox: Bool = (UserDefaults.standard.object(forKey: "apnsUseSandbox") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(apnsUseSandbox, forKey: "apnsUseSandbox") }
    }
    // Notification filter: only push cron/automation replies, not interactive chats.
    @Published var pushOnlyAutomations: Bool = UserDefaults.standard.bool(forKey: "pushOnlyAutomations") {
        didSet { UserDefaults.standard.set(pushOnlyAutomations, forKey: "pushOnlyAutomations") }
    }
    // H1: use the structured ACP transport for chat instead of `chat -q` stdout scraping.
    @Published var useACPTransport: Bool = UserDefaults.standard.bool(forKey: "useACPTransport") {
        didSet {
            UserDefaults.standard.set(useACPTransport, forKey: "useACPTransport")
            if !useACPTransport { ACPClient.shared.shutdown() }
        }
    }
    // H2 approval flow: when true, auto-allow tool permission requests; when false,
    // show an approve/deny dialog. Default true (preserves prior behavior).
    @Published var acpAutoAllow: Bool = (UserDefaults.standard.object(forKey: "acpAutoAllow") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(acpAutoAllow, forKey: "acpAutoAllow")
            ACPClient.shared.autoAllow = acpAutoAllow
        }
    }
    // Chat vs Code mode (behavioral, prompt-only). Default .code preserves the
    // current full-agent behavior; chat steers toward conversation (no auto edits).
    @Published var agentMode: AgentMode = AgentMode(rawValue: UserDefaults.standard.string(forKey: "agentMode") ?? "") ?? .code {
        didSet { UserDefaults.standard.set(agentMode.rawValue, forKey: "agentMode") }
    }
    // The tool-permission request currently awaiting the user's decision (drives the dialog).
    @Published var pendingPermission: ACPPermission? = nil
    private var permissionCont: CheckedContinuation<String?, Never>? = nil
    // Registered iOS device tokens (from /api/push/register)
    @Published var pushDeviceTokens: [String] = UserDefaults.standard.stringArray(forKey: "pushDeviceTokens") ?? [] {
        didSet { UserDefaults.standard.set(pushDeviceTokens, forKey: "pushDeviceTokens") }
    }
    private var lastPushedMessageId: Int64 = 0
    
    // Settings Form State
    // Persisted to UserDefaults so a global Antigravity selection (deliberately never
    // written to the Hermes config) survives a restart instead of reverting to Hermes.
    @Published var provider: String = UserDefaults.standard.string(forKey: "globalProvider") ?? "openrouter" {
        didSet { UserDefaults.standard.set(provider, forKey: "globalProvider") }
    }
    @Published var defaultModel: String = UserDefaults.standard.string(forKey: "globalDefaultModel") ?? "nvidia/nemotron-3-super-120b-a12b:free" {
        didSet { UserDefaults.standard.set(defaultModel, forKey: "globalDefaultModel") }
    }
    @Published var apiKey: String = ""
    @Published var personality: String = "kawaii"
    @Published var isSavingSettings: Bool = false
    
    // New Feature States
    @Published var showRightSidebar: Bool = false
    // Which panel the right sidebar shows.
    enum RightTab { case terminal, browser, employee, history }
    @Published var rightTab: RightTab = .terminal
    // Side terminal
    @Published var terminalOutput: String = ""
    @Published var terminalCwd: String = NSHomeDirectory()
    @Published var isRunningTerminalCommand: Bool = false
    // One-click app launch (Phase F): id → live dev-server process, so 起動/停止 works
    // and a running app shows a spinner. `appPreviewOpened` dedupes the auto-preview.
    @Published var runningAppIds: Set<String> = []
    var appProcesses: [String: Process] = [:]   // internal: used by AppState+AppLaunch (live dev-server processes)
    // App-launch state — internal so AppState+AppLaunch (extracted Phase F) can access it.
    var appPreviewOpened: Set<String> = []
    // The URL a running app actually bound to (detected from its banner) — drives "別ウィンドウ".
    var detectedAppURL: [String: String] = [:]
    // Auto-repair: how many times we've auto-fixed this app's launch (caps the loop), and the
    // app to re-launch once the in-flight repair chat turn finishes.
    var appRepairAttempts: [String: Int] = [:]
    var pendingRelaunchAppId: String? = nil
    // Monotonic launch token per app — a stale process's handlers bail if it changed (so a
    // rapid 停止→起動 can't let the OLD process's terminationHandler clobber the NEW one's state).
    var appGenerations: [String: Int] = [:]
    // When true, handleSendMessage skips local command interception (used by runAppAction to
    // forward an augmented prompt to the agent without re-matching its own command pattern).
    var bypassCommandIntercept = false
    @Published var pluginsList: [HermesPlugin] = []
    @Published var isFetchingPlugins: Bool = false
    @Published var pluginInstallInput: String = ""
    @Published var isInstallingPlugin: Bool = false

    // GitHub workspace: pick a repo as the agent's working folder (cwd).
    @Published var githubRepos: [GitHubRepo] = []
    @Published var isFetchingRepos: Bool = false
    @Published var githubAccount: String = ""
    @Published var cloningRepo: String? = nil   // slug currently cloning
    @Published var githubCloneBase: String = UserDefaults.standard.string(forKey: "githubCloneBase") ?? (NSHomeDirectory() + "/Documents/development") {
        didSet { UserDefaults.standard.set(githubCloneBase, forKey: "githubCloneBase") }
    }
    // The selected repo's local path (the agent cwd) and its "owner/repo" slug.
    @Published var selectedRepoPath: String? = UserDefaults.standard.string(forKey: "selectedRepoPath") {
        didSet { UserDefaults.standard.set(selectedRepoPath, forKey: "selectedRepoPath") }
    }
    @Published var selectedRepoSlug: String? = UserDefaults.standard.string(forKey: "selectedRepoSlug") {
        didSet { UserDefaults.standard.set(selectedRepoSlug, forKey: "selectedRepoSlug") }
    }
    // AI employees ("会社のメタファー"): each has isolated session/persona/model/cwd.
    @Published var employees: [Employee] = AppState.loadEmployees() {
        didSet { AppState.saveEmployees(employees); scheduleICloudPush() }
    }
    @Published var activeEmployeeId: String? = UserDefaults.standard.string(forKey: "activeEmployeeId") {
        didSet { UserDefaults.standard.set(activeEmployeeId, forKey: "activeEmployeeId") }
    }
    var activeEmployee: Employee? { employees.first { $0.id == activeEmployeeId } }

    // Teams (Phase A) and tasks (Phase B), persisted like employees.
    @Published var teams: [Team] = AppState.loadTeams() {
        didSet { AppState.saveJSON(teams, "teams"); scheduleICloudPush() }
    }

    /// User-set company name (会社名). Empty → fall back to the default label via companyDisplayName.
    @Published var companyName: String = UserDefaults.standard.string(forKey: "companyName") ?? "" {
        didSet { UserDefaults.standard.set(companyName, forKey: "companyName") }
    }
    /// The name to show for the company everywhere (default when unset).
    var companyDisplayName: String {
        let n = companyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "会社（AI社員）" : n
    }
    /// Set the company name (空文字 → 既定に戻す)。
    func setCompanyName(_ name: String) {
        companyName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @Published var workTasks: [WorkTask] = AppState.loadTasks() {
        didSet { AppState.saveJSON(workTasks, "workTasks"); scheduleICloudPush() }
    }

    // Health data pushed from the iOS app (HealthKit). Device-local (not iCloud-synced).
    @Published var latestHealth: HealthSnapshot? = AppState.loadJSON("latestHealth") {
        didSet { AppState.saveJSON(latestHealth, "latestHealth") }
    }
    func updateHealth(_ snap: HealthSnapshot) { latestHealth = snap }

    /// 健康データの日本語1行サマリー（健康アドバイザーのチャットへ注入／表示用）。データ無しは nil。
    var healthSummaryLine: String? {
        guard let h = latestHealth else { return nil }
        var parts: [String] = []
        if let v = h.steps { parts.append("歩数 \(v)歩") }
        if let v = h.distanceKm { parts.append(String(format: "距離 %.1fkm", v)) }
        if let v = h.activeEnergyKcal { parts.append("消費エネルギー \(Int(v))kcal") }
        if let v = h.exerciseMinutes { parts.append("運動 \(v)分") }
        if let v = h.heartRate { parts.append("心拍 \(v)bpm") }
        if let v = h.restingHeartRate { parts.append("安静時心拍 \(v)bpm") }
        if let v = h.sleepHours { parts.append(String(format: "睡眠 %.1f時間", v)) }
        if let v = h.bodyMassKg { parts.append(String(format: "体重 %.1fkg", v)) }
        guard !parts.isEmpty else { return nil }
        let day = (h.date?.isEmpty == false) ? "（\(h.date!)）" : ""
        return "ユーザーの健康データ\(day): " + parts.joined(separator: " / ")
    }
    // Per-employee deliverables (Phase E), persisted + synced like tasks.
    @Published var artifacts: [Artifact] = AppState.loadArtifacts() {
        didSet { AppState.saveJSON(artifacts, "artifacts"); scheduleICloudPush() }
    }
    // AI-developed app projects (Phase F), persisted + synced like tasks.
    @Published var apps: [AppProject] = AppState.loadApps() {
        didSet { AppState.saveJSON(apps, "apps"); scheduleICloudPush() }
    }
    static func loadApps() -> [AppProject] { loadJSON("apps") ?? [] }
    var sortedApps: [AppProject] { apps.sorted { $0.updatedAt > $1.updatedAt } }
    // Calendar events (Phase G), persisted + synced like tasks.
    @Published var events: [ScheduleEvent] = AppState.loadEvents() {
        didSet { AppState.saveJSON(events, "events"); scheduleICloudPush() }
    }
    static func loadEvents() -> [ScheduleEvent] { loadJSON("events") ?? [] }

    // Dashboard daily brief: an AI-written narrative summary of today, persisted with its
    // timestamp so the dashboard can show "as of HH:mm" and auto-refresh when stale.
    @Published var dailyBrief: String = UserDefaults.standard.string(forKey: "dailyBrief") ?? "" {
        didSet { UserDefaults.standard.set(dailyBrief, forKey: "dailyBrief") }
    }
    @Published var dailyBriefAt: Double = UserDefaults.standard.double(forKey: "dailyBriefAt") {
        didSet { UserDefaults.standard.set(dailyBriefAt, forKey: "dailyBriefAt") }
    }
    @Published var isGeneratingBrief: Bool = false

    // The employee whose detail/management screen is open (view == "employee").
    @Published var detailEmployeeId: String? = nil
    var detailEmployee: Employee? { employees.first { $0.id == detailEmployeeId } }
    static func loadTeams() -> [Team] { loadJSON("teams") ?? [] }
    static func loadTasks() -> [WorkTask] { loadJSON("workTasks") ?? [] }
    static func loadArtifacts() -> [Artifact] { loadJSON("artifacts") ?? [] }
    static func loadJSON<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func saveJSON<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    // Employees currently handling a delegated task (so they show a spinner too).
    @Published var busyEmployeeIds: Set<String> = []
    /// All employee keys (id, or "" for 全体) that have an in-flight streaming turn.
    /// Multiple employees can stream simultaneously — true parallel sends.
    @Published var streamingEmployeeIds: Set<String> = []

    // Per-employee backing stores for parallel streaming:
    //   empStreamTexts  — raw accumulated chunk text per turn
    //   empProcesses    — the CLI/agy Process per turn (for cancelStreaming)
    //   empACPClients   — a dedicated ACPClient per employee (enables truly parallel ACP)
    //   empMessages     — shadow message array (accumulates chunks in background)
    private var empStreamTexts:  [String: String]   = [:]
    private var empProcesses:    [String: Process]  = [:]
    var empACPClients:   [String: ACPClient] = [:]   // internal: used by AppState+ModelValidation (handleSaveSettings recycles idle ACP)
    private var empMessages:     [String: [Message]] = [:]
    /// owningKey → assistantId of the turn currently streaming for that key. Lets a late
    /// `onEvent` callback — delivered after the turn finalized, or after a NEWER turn started
    /// for the same employee — no-op instead of overwriting finalized content or re-creating
    /// `empStreamTexts` (the parallel-streaming race). Bounded: one entry per key.
    private var streamingAssistantIds: [String: UUID] = [:]

    /// Cap on each employee's shadow message array. Shadows snapshot the FULL `messages` per
    /// employee you switch away from / who is streaming — with many employees and image messages
    /// this multiplies memory and, over multi-day runs, can OOM/freeze the app. Keep only the
    /// most recent N (the streaming bubble is the last element, so it always survives). The full
    /// history still lives in StateDB and reloads when you reopen that conversation.
    private let maxShadowMessages = 600
    private func cappedShadow(_ msgs: [Message]) -> [Message] {
        msgs.count > maxShadowMessages ? Array(msgs.suffix(maxShadowMessages)) : msgs
    }

    /// Convenience — stable key for an employee id (nil → "全体"). internal: used by domain extensions.
    func empKey(_ id: String?) -> String { id ?? "" }
    /// Convenience — key for the currently active employee.
    func empKey() -> String { empKey(activeEmployeeId) }

    // MARK: - 構造化出力（ニュース等）

    /// メモ化キー：最新アシスタントメッセージの id + content 長。変化したときだけ再パース。
    private var _entriesKey: String = ""
    private var _entriesCache: [NewsEntry] = []

    /// 現在の会話の「最新アシスタント出力（非エラー）」を解析した構造化エントリ。
    /// メモ化済み：ストリーミング中の毎フレーム呼び出しでも再パースしない。
    var latestAssistantEntries: [NewsEntry] {
        guard let last = messages.last(where: { $0.role == .assistant && !$0.isError && !$0.content.isEmpty })
        else { _entriesKey = ""; _entriesCache = []; return [] }
        let key = last.id.uuidString + ":\(last.content.count)"
        if key == _entriesKey { return _entriesCache }
        _entriesKey = key
        _entriesCache = NewsParser.parse(last.content)
        return _entriesCache
    }

    /// チャット内ピッカーで実際に構造化できる出力があるか（あるときだけピッカーを出す）。
    var hasStructurableOutput: Bool { !latestAssistantEntries.isEmpty }

    /// メモ化キー：各キーの最新アシスタントメッセージ数を連結した文字列。
    private var _newsKey: String = ""
    private var _newsCache: [NewsFeedItem] = []

    /// 読み込み済みの各会話（empMessages ＋現在の messages）から、解析で2件以上得られた
    /// アシスタント出力を社員名タグ付きで集約。トップレベル Newsページの入力。
    /// 現在会話を優先し、社員名でソートして決定的な順序を保証する。
    var allNewsEntries: [NewsFeedItem] {
        // 内容が変わったときだけ再パース（Newsページ毎描画での O(N) 回避）
        var sources: [(key: String, msgs: [Message])] = empMessages
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
        let curKey = empKey()
        // 現在会話を後に追加（seenKeys により優先されて上書き）
        sources.append((curKey, messages))

        let newKey = sources.map { "\($0.key):\($0.msgs.count)" }.joined(separator: "|")
        if newKey == _newsKey { return _newsCache }
        _newsKey = newKey

        var feed: [NewsFeedItem] = []
        var seenKeys = Set<String>()

        func nameForKey(_ key: String) -> String {
            if key.isEmpty { return "全体チャット" }
            return employees.first(where: { $0.id == key })?.name ?? "チャット"
        }

        // 現在会話を最後に追加するため reversed() で走査すると current が先勝ち
        for src in sources.reversed() {
            guard !seenKeys.contains(src.key) else { continue }
            for msg in src.msgs.reversed() where msg.role == .assistant && !msg.isError && !msg.content.isEmpty {
                let entries = NewsParser.parse(msg.content)
                if entries.count >= 2 {
                    feed.append(NewsFeedItem(employeeName: nameForKey(src.key),
                                             employeeId: src.key.isEmpty ? nil : src.key,
                                             entries: entries))
                    seenKeys.insert(src.key)
                    break
                }
            }
        }
        // 社員名で昇順ソートして表示順を安定させる
        _newsCache = feed.sorted { $0.employeeName < $1.employeeName }
        return _newsCache
    }

    /// True if this employee is actively working now (streaming or delegated task).
    func isEmployeeBusy(_ id: String) -> Bool {
        busyEmployeeIds.contains(id) || streamingEmployeeIds.contains(id)
    }

    /// Lazily create (or return existing) a dedicated ACPClient for an employee.
    private func getOrCreateACPClient(for key: String) -> ACPClient {
        if let c = empACPClients[key] { return c }
        let c = ACPClient()
        c.autoAllow = acpAutoAllow
        c.onPermission = { [weak self] perm in
            guard let self else { return nil }
            return await withCheckedContinuation { cont in
                self.permissionCont = cont
                self.pendingPermission = perm
            }
        }
        empACPClients[key] = c
        return c
    }

    // sessionId → owning employeeId, so the sidebar can show only the active
    // employee's chats (and 全体 shows chats not owned by any employee).
    @Published var sessionOwner: [String: String] = AppState.loadSessionOwner() {
        didSet { AppState.saveSessionOwner(sessionOwner) }
    }
    static func loadSessionOwner() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "sessionOwner"),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }
    static func saveSessionOwner(_ m: [String: String]) {
        if let data = try? JSONEncoder().encode(m) { UserDefaults.standard.set(data, forKey: "sessionOwner") }
    }
    func recordSessionOwner(_ sid: String?, _ empId: String?) {
        guard let sid = sid, let empId = empId else { return }
        if sessionOwner[sid] != empId { sessionOwner[sid] = empId }
    }

    /// Sessions shown in the sidebar: the active employee's own chats (incl. its current
    /// session), or — when no employee is active (全体) — chats not owned by any employee.
    var visibleSessions: [Session] {
        if let empId = activeEmployeeId {
            let curSid = employees.first { $0.id == empId }?.sessionId
            return sessions.filter { sessionOwner[$0.id] == empId || $0.id == curSid }
        }
        return sessions.filter { sessionOwner[$0.id] == nil }
    }

    /// A specific employee's sessions (for the employee panel's チャット履歴 tab — works even
    /// when that employee isn't the active one, unlike `visibleSessions`).
    func employeeSessions(_ employeeId: String) -> [Session] {
        let curSid = employees.first { $0.id == employeeId }?.sessionId
        return sessions.filter { sessionOwner[$0.id] == employeeId || $0.id == curSid }
    }

    // MARK: - Cost / usage (Phase 3)

    @Published var usageByEmployee: [String: EmployeeUsage] = [:]
    @Published var totalTokens: Int = 0
    @Published var totalCostUSD: Double = 0   // this calendar month
    // Monthly budget (USD); 0 = unset. Drives the budget bar + over-budget warning.
    @Published var monthlyBudgetUSD: Double = UserDefaults.standard.double(forKey: "monthlyBudgetUSD") {
        didSet { UserDefaults.standard.set(monthlyBudgetUSD, forKey: "monthlyBudgetUSD") }
    }


    // MARK: - Cloud sync (Supabase)

    /// Normalized Supabase base URL (no trailing slash).
    private var supabaseBase: String? {
        let u = supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return nil }
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    /// Probe the Supabase REST endpoint + employees table to verify URL/key/SQL setup.
    func testCloudConnection() async {
        isTestingCloud = true
        defer { isTestingCloud = false }
        guard let base = supabaseBase, !supabaseAnonKey.isEmpty,
              let url = URL(string: "\(base)/rest/v1/employees?select=id&limit=1") else {
            cloudSyncStatus = "URL と APIキーを入力してください"; return
        }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                cloudSyncStatus = "接続OK ✓（employees テーブルを確認）"
            } else {
                let body = String(data: data, encoding: .utf8)?.prefix(140) ?? ""
                cloudSyncStatus = "失敗 HTTP \(code): \(body)"
            }
        } catch {
            cloudSyncStatus = "接続エラー: \(error.localizedDescription)"
        }
    }

    /// The workspace key grouping this user's devices (explicit, else allowed email, else default).
    var effectiveCloudWorkspace: String {
        let w = cloudWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !w.isEmpty { return w }
        return mobileAllowedEmail.isEmpty ? "default" : mobileAllowedEmail
    }

    private func cloudHeaders(_ req: inout URLRequest) {
        req.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
    }

    /// Shared (cross-device) fields only — session/workspace/avatar stay device-local.
    private func employeeRow(_ e: Employee) -> [String: Any] {
        [
            "id": e.id,
            "workspace": effectiveCloudWorkspace,
            "name": e.name,
            "role": e.role.rawValue,
            "provider": e.provider,
            "model": e.model,
            "mode": e.mode.rawValue,
            "persona_override": e.personaOverride ?? NSNull(),
            "created_at": e.createdAt,
            "client_updated": e.updatedAt ?? e.createdAt
        ]
    }

    /// Pull cloud employees, merge (last-write-wins on shared fields), then push local.
    func syncEmployeesNow() async {
        guard cloudSyncEnabled, supabaseBase != nil, !supabaseAnonKey.isEmpty else {
            cloudSyncStatus = "クラウド同期がオフ、またはURL/キー未設定です"; return
        }
        if let rows = await fetchCloudEmployees() { mergeCloudEmployees(rows) }
        await pushEmployees()
        if !cloudSyncStatus.hasPrefix("取得") && !cloudSyncStatus.hasPrefix("push") {
            cloudSyncStatus = "社員を同期しました（\(employees.count)名）"
        }
    }

    private func fetchCloudEmployees() async -> [[String: Any]]? {
        guard let base = supabaseBase else { return nil }
        let ws = effectiveCloudWorkspace.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? effectiveCloudWorkspace
        guard let url = URL(string: "\(base)/rest/v1/employees?workspace=eq.\(ws)&select=*") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 15; cloudHeaders(&req)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                cloudSyncStatus = "取得失敗: \(String(data: data, encoding: .utf8)?.prefix(120) ?? "")"
                return nil
            }
            return arr
        } catch { cloudSyncStatus = "取得エラー: \(error.localizedDescription)"; return nil }
    }

    private func mergeCloudEmployees(_ rows: [[String: Any]]) {
        for row in rows {
            guard let id = row["id"] as? String,
                  let roleStr = row["role"] as? String, let role = EmployeeRole(rawValue: roleStr) else { continue }
            let cloudUpdated = (row["client_updated"] as? Double) ?? (row["created_at"] as? Double) ?? 0
            let name = row["name"] as? String ?? role.title
            let provider = row["provider"] as? String ?? role.defaultProvider
            let model = row["model"] as? String ?? role.defaultModel
            let mode = AgentMode(rawValue: row["mode"] as? String ?? "") ?? role.defaultMode
            let persona = row["persona_override"] as? String
            if let idx = employees.firstIndex(where: { $0.id == id }) {
                let localUpdated = employees[idx].updatedAt ?? employees[idx].createdAt
                if cloudUpdated > localUpdated {
                    employees[idx].name = name
                    employees[idx].provider = provider
                    employees[idx].model = model
                    employees[idx].mode = mode
                    employees[idx].personaOverride = persona
                    employees[idx].updatedAt = cloudUpdated
                }
            } else {
                var e = Employee(name: name, role: role, provider: provider, model: model, mode: mode)
                e.id = id
                e.personaOverride = persona
                e.createdAt = (row["created_at"] as? Double) ?? Date().timeIntervalSince1970
                e.updatedAt = cloudUpdated
                employees.append(e)
            }
        }
    }

    // internal (not private): called from AppState+Teams.swift (assignEmployee) and other domain extensions.
    func pushEmployees() async {
        guard let base = supabaseBase, !employees.isEmpty,
              let url = URL(string: "\(base)/rest/v1/employees?on_conflict=id") else { return }
        let rows = employees.map { employeeRow($0) }
        guard let body = try? JSONSerialization.data(withJSONObject: rows) else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 15; cloudHeaders(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(code) {
                cloudSyncStatus = "push失敗 HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(120) ?? "")"
            }
        } catch { cloudSyncStatus = "pushエラー: \(error.localizedDescription)" }
    }

    // Model health (model id → works?) from test pings; hides non-working models.
    @Published var modelHealth: [String: Bool] = AppState.loadModelHealth() {
        didSet { AppState.saveModelHealth(modelHealth) }
    }
    @Published var isValidatingModels: Bool = false
    @Published var validatingModelId: String? = nil
    // Hide models that a test ping proved non-working (402/403/404/error).
    @Published var hideBrokenModels: Bool = (UserDefaults.standard.object(forKey: "hideBrokenModels") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(hideBrokenModels, forKey: "hideBrokenModels") }
    }

    // Cloud sync (Supabase) — full sync of employees (+later messages) across devices.
    @Published var supabaseURL: String = UserDefaults.standard.string(forKey: "supabaseURL") ?? "" {
        didSet { UserDefaults.standard.set(supabaseURL, forKey: "supabaseURL") }
    }
    @Published var supabaseAnonKey: String = UserDefaults.standard.string(forKey: "supabaseAnonKey") ?? "" {
        didSet { UserDefaults.standard.set(supabaseAnonKey, forKey: "supabaseAnonKey") }
    }
    @Published var cloudSyncEnabled: Bool = UserDefaults.standard.bool(forKey: "cloudSyncEnabled") {
        didSet {
            UserDefaults.standard.set(cloudSyncEnabled, forKey: "cloudSyncEnabled")
            if cloudSyncEnabled { Task { await syncEmployeesNow() } }
        }
    }
    /// A stable key grouping all of this user's devices (defaults to the allowed email).
    @Published var cloudWorkspace: String = UserDefaults.standard.string(forKey: "cloudWorkspace") ?? "" {
        didSet { UserDefaults.standard.set(cloudWorkspace, forKey: "cloudWorkspace") }
    }
    @Published var cloudSyncStatus: String = ""
    @Published var isTestingCloud: Bool = false

    // iCloud (CloudKit) — Stage 0 foundation test. Proves the signed build can reach
    // the private CloudKit DB before we build the real sync on top of it.
    @Published var icloudStatus: String = ""
    @Published var isTestingICloud: Bool = false

    /// Write+read+delete one probe record in CloudKit to verify entitlements + account.
    func testICloud() async {
        isTestingICloud = true
        defer { isTestingICloud = false }
        icloudStatus = "テスト中…"
        do {
            icloudStatus = try await CloudKitSync.smokeTest()
        } catch {
            icloudStatus = "失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - iCloud roster sync (Stage 1: employees / teams / tasks)

    @Published var icloudSyncEnabled: Bool = UserDefaults.standard.bool(forKey: "icloudSyncEnabled") {
        didSet {
            UserDefaults.standard.set(icloudSyncEnabled, forKey: "icloudSyncEnabled")
            if icloudUsable { Task { await syncRosterNow() }; startICloudLiveSync() }
            else { stopICloudLiveSync() }
        }
    }
    /// iCloud 同期が有効かつ entitlement が利用可能（未署名ビルドでのトラップ防止）。
    var icloudUsable: Bool { icloudSyncEnabled && CloudKitSync.isAvailable }
    @Published var isSyncingICloud: Bool = false
    /// id → deletion time, so deletes propagate across devices (resurrection guard).
    @Published var syncTombstones: [String: Double] = AppState.loadJSON("syncTombstones") ?? [:] {
        didSet { AppState.saveJSON(syncTombstones, "syncTombstones") }
    }
    /// Set while applying a remote pull so the array didSets don't echo a push back.
    private var isApplyingRemote = false
    private var icloudPushTask: Task<Void, Never>? = nil
    private var lastPushedRosterSig: Int = 0

    /// Record a delete so it wins over stale copies on other devices.
    func tombstone(_ id: String) { syncTombstones[id] = Date().timeIntervalSince1970 }

    /// True if `id` was deleted at/after the item's own last edit (so the delete wins).
    private func tombstoneWins(_ id: String, _ itemUpdated: Double) -> Bool {
        if let ts = syncTombstones[id], ts >= itemUpdated { return true }
        return false
    }

    /// Drop tombstones older than 60 days so the record doesn't grow without bound.
    private func prunedTombstones() -> [String: Double] {
        let cutoff = Date().timeIntervalSince1970 - 60 * 24 * 3600
        return syncTombstones.filter { $0.value >= cutoff }
    }

    /// Build the shared-fields payload from current local state (call after merge).
    private func localRosterPayload() -> CloudKitSync.RosterPayload {
        let emps = employees.map {
            CloudKitSync.EmployeeShared(
                id: $0.id, name: $0.name, role: $0.role.rawValue,
                provider: $0.provider, model: $0.model, mode: $0.mode.rawValue,
                personaOverride: $0.personaOverride, teamId: $0.teamId,
                createdAt: $0.createdAt, updatedAt: $0.updatedAt ?? $0.createdAt)
        }
        // .file artifacts hold a device-local absolute path (like workspacePath, which
        // is deliberately not synced) — they'd render as broken rows on other devices, so
        // only sync the portable kinds (note/link). Their deletes still propagate via tombstones.
        return CloudKitSync.RosterPayload(employees: emps, teams: teams,
                                          tasks: workTasks,
                                          artifacts: artifacts.filter { $0.kind != .file },
                                          apps: apps, events: events,
                                          tombstones: prunedTombstones())
    }

    /// Merge a fetched cloud roster into local state (item-level last-write-wins + tombstones).
    private func mergeRoster(_ cloud: CloudKitSync.RosterPayload) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }

        // Union tombstones (keep the newest deletion time per id).
        for (id, ts) in cloud.tombstones where (syncTombstones[id] ?? 0) < ts { syncTombstones[id] = ts }

        // Employees — LWW on shared fields; keep device-local fields (avatar/cwd/session).
        for ce in cloud.employees {
            guard let role = EmployeeRole(rawValue: ce.role) else { continue }
            if tombstoneWins(ce.id, ce.updatedAt) { continue }
            if let idx = employees.firstIndex(where: { $0.id == ce.id }) {
                let local = employees[idx].updatedAt ?? employees[idx].createdAt
                if ce.updatedAt > local {
                    employees[idx].name = ce.name
                    employees[idx].provider = ce.provider
                    employees[idx].model = ce.model
                    employees[idx].mode = AgentMode(rawValue: ce.mode) ?? role.defaultMode
                    employees[idx].personaOverride = ce.personaOverride
                    employees[idx].teamId = ce.teamId
                    employees[idx].updatedAt = ce.updatedAt
                }
            } else {
                var e = Employee(name: ce.name, role: role, provider: ce.provider,
                                 model: ce.model, mode: AgentMode(rawValue: ce.mode) ?? role.defaultMode)
                e.id = ce.id
                e.personaOverride = ce.personaOverride
                e.teamId = ce.teamId
                e.createdAt = ce.createdAt
                e.updatedAt = ce.updatedAt
                employees.append(e)
            }
        }
        employees.removeAll { tombstoneWins($0.id, $0.updatedAt ?? $0.createdAt) }

        // Teams
        for ct in cloud.teams {
            if tombstoneWins(ct.id, ct.updatedAt ?? 0) { continue }
            if let idx = teams.firstIndex(where: { $0.id == ct.id }) {
                if (ct.updatedAt ?? 0) > (teams[idx].updatedAt ?? 0) { teams[idx] = ct }
            } else {
                teams.append(ct)
            }
        }
        teams.removeAll { tombstoneWins($0.id, $0.updatedAt ?? 0) }

        // Tasks
        for ck in cloud.tasks {
            if tombstoneWins(ck.id, ck.updatedAt) { continue }
            if let idx = workTasks.firstIndex(where: { $0.id == ck.id }) {
                if ck.updatedAt > workTasks[idx].updatedAt { workTasks[idx] = ck }
            } else {
                workTasks.append(ck)
            }
        }
        workTasks.removeAll { tombstoneWins($0.id, $0.updatedAt) }

        // Artifacts (Phase E)
        for ca in cloud.artifacts {
            if tombstoneWins(ca.id, ca.updatedAt) { continue }
            if let idx = artifacts.firstIndex(where: { $0.id == ca.id }) {
                if ca.updatedAt > artifacts[idx].updatedAt { artifacts[idx] = ca }
            } else {
                artifacts.append(ca)
            }
        }
        artifacts.removeAll { tombstoneWins($0.id, $0.updatedAt) }

        // Apps (Phase F)
        for ca in cloud.apps {
            if tombstoneWins(ca.id, ca.updatedAt) { continue }
            if let idx = apps.firstIndex(where: { $0.id == ca.id }) {
                if ca.updatedAt > apps[idx].updatedAt { apps[idx] = ca }
            } else {
                apps.append(ca)
            }
        }
        apps.removeAll { tombstoneWins($0.id, $0.updatedAt) }

        // Events (Phase G)
        for ce in cloud.events {
            if tombstoneWins(ce.id, ce.updatedAt) { continue }
            if let idx = events.firstIndex(where: { $0.id == ce.id }) {
                if ce.updatedAt > events[idx].updatedAt { events[idx] = ce }
            } else {
                events.append(ce)
            }
        }
        events.removeAll { tombstoneWins($0.id, $0.updatedAt) }
    }

    /// Full sync: pull cloud, merge, then push the merged result.
    func syncRosterNow() async {
        guard icloudUsable else { icloudStatus = "iCloud同期がオフです"; return }
        isSyncingICloud = true
        defer { isSyncingICloud = false }
        icloudStatus = "iCloud同期中…"
        let ws = effectiveCloudWorkspace
        do {
            if let cloud = try await CloudKitSync.fetchRoster(workspace: ws) { mergeRoster(cloud) }
            let payload = localRosterPayload()
            try await CloudKitSync.pushRoster(payload, workspace: ws)
            lastPushedRosterSig = rosterSignature(payload)
            icloudStatus = "iCloud同期完了（社員\(employees.count)・チーム\(teams.count)・タスク\(workTasks.count)）"
        } catch {
            icloudStatus = "iCloud同期 失敗: \(error.localizedDescription)"
        }
    }

    /// Debounced push triggered by local edits (skips device-local-only churn).
    func scheduleICloudPush() {
        guard icloudUsable, !isApplyingRemote else { return }
        icloudPushTask?.cancel()
        icloudPushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pushRosterOnly()
        }
    }

    private func pushRosterOnly() async {
        guard icloudUsable else { return }
        let payload = localRosterPayload()
        let sig = rosterSignature(payload)
        guard sig != lastPushedRosterSig else { return }   // shared fields unchanged → skip
        do {
            try await CloudKitSync.pushRoster(payload, workspace: effectiveCloudWorkspace)
            lastPushedRosterSig = sig
        } catch {
            icloudStatus = "iCloud push失敗: \(error.localizedDescription)"
        }
    }

    private func rosterSignature(_ p: CloudKitSync.RosterPayload) -> Int {
        (try? JSONEncoder().encode(p))?.hashValue ?? 0
    }

    // MARK: - iCloud message mirror (Stage 2: one-way; state.db is CLI-owned / read-only)

    @Published var icloudMirrorMessages: Bool = UserDefaults.standard.bool(forKey: "icloudMirrorMessages") {
        didSet {
            UserDefaults.standard.set(icloudMirrorMessages, forKey: "icloudMirrorMessages")
            if icloudMirrorMessages { Task { await mirrorMessagesNow() } }
        }
    }
    @Published var isMirroringMessages: Bool = false
    /// sessionId → last message id already mirrored (so only changed sessions re-push).
    private var mirroredSessionMsgId: [String: Int64] = AppState.loadJSON("mirroredSessionMsgId") ?? [:] {
        didSet { AppState.saveJSON(mirroredSessionMsgId, "mirroredSessionMsgId") }
    }
    private var mirrorPushTask: Task<Void, Never>? = nil
    /// At most this many session logs per run (bounds latency; rest picked up next pass).
    private let mirrorLogsPerRun = 40

    /// Cap one session's mirrored messages under CloudKit's ~1MB record limit: keep the
    /// most recent, dropping oldest until the JSON fits.
    private func capMessages(_ rows: [StateDB.MessageRow]) -> [CloudKitSync.MessageDTO] {
        var dtos = rows.suffix(1000).map {
            CloudKitSync.MessageDTO(id: $0.id, role: $0.role, content: $0.content,
                                    timestamp: $0.timestamp, tokenCount: $0.tokenCount)
        }
        while dtos.count > 1, let data = try? JSONEncoder().encode(dtos), data.count > 950_000 {
            dtos.removeFirst(max(1, dtos.count / 10))
        }
        return dtos
    }

    /// Mirror sessions + (changed) messages up to CloudKit. One-way — never written back.
    func mirrorMessagesNow() async {
        guard icloudUsable else { icloudStatus = "iCloud同期がオフです"; return }
        isMirroringMessages = true
        defer { isMirroringMessages = false }
        icloudStatus = "メッセージをミラー中…"
        let ws = effectiveCloudWorkspace
        let sessions = StateDB.shared.sessions(limit: 500)
        do {
            var metas: [CloudKitSync.SessionMeta] = []
            var pushed = 0, remaining = 0
            for s in sessions {
                metas.append(CloudKitSync.SessionMeta(
                    id: s.id, title: s.title, preview: s.preview, source: s.source,
                    archived: s.archived, messageCount: s.messageCount,
                    lastMessageId: s.lastMessageId, updatedAt: s.updatedAt))
                guard s.lastMessageId > (mirroredSessionMsgId[s.id] ?? -1) else { continue }
                if pushed >= mirrorLogsPerRun { remaining += 1; continue }
                let msgs = capMessages(StateDB.shared.messages(sessionId: s.id))
                try await CloudKitSync.pushSessionLog(ws: ws, sessionId: s.id, messages: msgs)
                mirroredSessionMsgId[s.id] = s.lastMessageId
                pushed += 1
            }
            try await CloudKitSync.pushSessionIndex(ws: ws, sessions: metas)
            icloudStatus = remaining > 0
                ? "メッセージをミラー（セッション\(metas.count)・更新\(pushed)、残り\(remaining)件は次回）"
                : "メッセージをミラーしました（セッション\(metas.count)・更新\(pushed)）"
            if remaining > 0 {   // more changed sessions remain → continue shortly
                mirrorPushTask?.cancel()
                mirrorPushTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    await self.mirrorMessagesNow()
                }
            }
        } catch {
            icloudStatus = "メッセージミラー失敗: \(error.localizedDescription)"
        }
    }

    /// Debounced auto-mirror, triggered by store changes when the toggle is on.
    func scheduleMessageMirror() {
        guard icloudUsable, icloudMirrorMessages, !isMirroringMessages else { return }
        mirrorPushTask?.cancel()
        mirrorPushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.mirrorMessagesNow()
        }
    }

    /// Read the mirror back from CloudKit to confirm the one-way round-trip works.
    func verifyCloudHistory() async {
        guard icloudUsable else { icloudStatus = "iCloud同期がオフです"; return }
        icloudStatus = "クラウド履歴を確認中…"
        do {
            let ws = effectiveCloudWorkspace
            let metas = try await CloudKitSync.fetchSessionIndex(ws: ws)
            let total = metas.reduce(0) { $0 + $1.messageCount }
            if let first = metas.first {
                let log = try await CloudKitSync.fetchSessionLog(ws: ws, sessionId: first.id)
                icloudStatus = "クラウド履歴: セッション\(metas.count)件・メタ合計\(total)msg（先頭「\(first.title)」のミラー\(log.count)msg）"
            } else {
                icloudStatus = "クラウド履歴: セッション0件（まだミラーされていません）"
            }
        } catch {
            icloudStatus = "履歴確認失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - iCloud live sync (Stage 3: near-realtime via lightweight polling)
    //
    // The public DB can't use CKDatabaseSubscription (private/shared only), and
    // CKQuerySubscription would need queryable indexes + a Push entitlement + an
    // AppDelegate. Polling while the app is open gives ~realtime reflection of other
    // devices' roster edits with zero extra setup. True APNs push is a later option.

    private var livePollTask: Task<Void, Never>? = nil
    private let livePollInterval: UInt64 = 20_000_000_000   // 20s

    /// Pull + merge the roster without pushing (live poll / on focus). The
    /// `isApplyingRemote` guard inside `mergeRoster` prevents an echo push.
    private func pullRosterOnly() async {
        guard icloudUsable else { return }
        do {
            if let cloud = try await CloudKitSync.fetchRoster(workspace: effectiveCloudWorkspace) {
                mergeRoster(cloud)
            }
        } catch {
            // transient (offline / throttled) — the next tick retries
        }
    }

    /// Reflect other devices' roster changes in ~realtime while the app is open.
    func startICloudLiveSync() {
        livePollTask?.cancel()
        guard icloudUsable else { livePollTask = nil; return }
        let interval = livePollInterval
        livePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self, self.icloudUsable else { break }
                await self.pullRosterOnly()
            }
        }
    }

    func stopICloudLiveSync() { livePollTask?.cancel(); livePollTask = nil }

    /// Transient cwd override for "develop this app" — points the agent at the app folder
    /// for this thread WITHOUT permanently changing the employee's own workspace. Cleared
    /// on employee switch / new chat / session select.
    @Published var cwdOverride: String? = nil

    /// The working directory the agent runs in: develop-app override, else the active
    /// employee's workspace, else the selected GitHub repo, else home.
    var effectiveCwd: String { cwdOverride ?? activeEmployee?.workspacePath ?? selectedRepoPath ?? NSHomeDirectory() }

    /// Tilde-abbreviated working-folder path for the composer badge (full path via `.help`).
    var effectiveCwdDisplay: String { (effectiveCwd as NSString).abbreviatingWithTildeInPath }

    /// Current git branch of the working folder, read straight from `.git/HEAD` (no subprocess).
    /// Returns nil when the folder isn't a git repo — the branch badge is hidden in that case.
    var effectiveCwdBranch: String? {
        let head = (effectiveCwd as NSString).appendingPathComponent(".git/HEAD")
        guard let s = try? String(contentsOfFile: head, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "ref: refs/heads/") { return String(t[r.upperBound...]) }
        return t.isEmpty ? nil : String(t.prefix(7))   // detached HEAD → short sha
    }

    // MARK: Employee persistence
    static func loadEmployees() -> [Employee] {
        guard let data = UserDefaults.standard.data(forKey: "employees"),
              let arr = try? JSONDecoder().decode([Employee].self, from: data) else { return [] }
        return arr
    }
    static func saveEmployees(_ list: [Employee]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: "employees")
        }
    }
    static func loadModelHealth() -> [String: Bool] {
        guard let data = UserDefaults.standard.data(forKey: "modelHealth"),
              let m = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return m
    }
    static func saveModelHealth(_ m: [String: Bool]) {
        if let data = try? JSONEncoder().encode(m) {
            UserDefaults.standard.set(data, forKey: "modelHealth")
        }
    }
    
    // Automations (Cron) State
    @Published var cronJobs: [HermesCronJob] = []
    @Published var isFetchingCronJobs: Bool = false
    @Published var isCreatingCronJob: Bool = false
    
    // Create Cron Form State
    @Published var newCronName: String = ""
    @Published var newCronSchedule: String = ""
    @Published var newCronPrompt: String = ""
    @Published var newCronDeliver: String = "local"
    @Published var newCronScript: String = ""
    @Published var newCronNoAgent: Bool = false
    // Phase D: the AI employee a scheduled task runs as (persona-wrapped).
    @Published var newCronAssigneeId: String? = nil

    /// 作成フォームをモーダル（シート）で表示するか。「使う」/「このフローを設定」/新規作成で開く。
    @Published var showCronCreateSheet = false

    // 株モニタリング: 保有銘柄リスト & 株価APIキー(Twelve Data)。ディスク(~/.hermes/scripts/)が真実、
    // これらは編集用バッファ。保存で書き出し、スクリプト(stock-monitor.py)が読む。
    @Published var stockPortfolioText: String = AppState.loadPortfolioText()
    @Published var stockApiKey: String = AppState.loadStockApiKey()

    // Automation suggestions (proactive proposals the user can one-tap into the form).
    @Published var aiSuggestions: [AutomationSuggestion] = []
    @Published var isGeneratingSuggestions: Bool = false

    // Toast UI (optionally with an Undo-style action)
    @Published var toastMessage: String = ""
    @Published var showToast: Bool = false
    @Published var toastActionLabel: String? = nil
    var toastAction: (() -> Void)? = nil
    private var toastToken = 0

    // Workspace badge (header): the selected GitHub repo slug, else the app name.
    var workspaceName: String { selectedRepoSlug ?? "hermesagent-mac" }

    // Delegation-only process (separate from per-employee empProcesses used in handleSendMessage).
    private var delegationProcess: Process? = nil

    // Store-sync: detect state.db changes (from iPhone/cron/etc.) and refresh the UI.
    private var storeSyncTimer: Task<Void, Never>? = nil
    private var lastStoreToken: String = ""
    /// Throttle the sidebar refresh during our own streaming (see startStoreSync) — the heavy
    /// sessions() query + @Published reassign every 1.2s is the main streaming-time UI jank.
    private var lastStreamingSessionRefresh: Date = .distantPast

    private init() {
        // Clean up child processes / timers when the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        // Pull other devices' roster edits the moment the app regains focus.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.icloudUsable else { return }
                Task { await self.pullRosterOnly() }
            }
        }
        // Auto-assign a working folder to every employee that doesn't have one (migration).
        ensureAllEmployeeWorkspaces()
        Task {
            // Independent reads run concurrently so a slow one (the Tailscale-status subprocess in
            // updateDashboardURL, especially) doesn't serialize behind the others. All are @MainActor
            // so only their I/O waits overlap — no state race. The provider→key→models chain stays
            // sequential because each step depends on the previous.
            async let sessionsDone: Void = fetchSessions()
            async let dashDone: Void = updateDashboardURL()
            async let pluginsDone: Void = fetchPlugins()
            await fetchConfig()
            await loadApiKey()
            await fetchAvailableModels()
            _ = await sessionsDone; _ = await dashDone; _ = await pluginsDone

            fetchChannels()   // load registered channels (LINE etc.) so "LINEに〜送って" works
            setupACPPermissions()

            // Start the mobile server / LINE bridge / store sync WITHOUT waiting on the (multi-second)
            // cloud sync — none of them depend on it, and blocking here was the main launch stall.
            MobileServer.shared.start()
            self.isMobileServerRunning = true
            startStoreSync()                              // reflect iPhone/iPad/cron changes
            let bridge = Task { await self.startLineBridge() }   // bridge.py on :8650 (keep LINE working)

            // Cloud sync (can take seconds) now overlaps the above instead of gating it.
            if cloudSyncEnabled { await syncEmployeesNow() }
            if icloudUsable { await syncRosterNow() }
            startICloudLiveSync()
            _ = await bridge.value
        }
    }

    /// Connect the ACP permission flow to the UI: requests pause here until the
    /// user taps a choice in the dialog (unless auto-allow is on).
    func setupACPPermissions() {
        ACPClient.shared.autoAllow = acpAutoAllow
        ACPClient.shared.onPermission = { [weak self] perm in
            guard let self else { return nil }
            return await withCheckedContinuation { cont in
                self.permissionCont = cont
                self.pendingPermission = perm
            }
        }
    }

    /// The user chose an option (optionId) or cancelled (nil) in the permission dialog.
    func resolvePermission(_ optionId: String?) {
        pendingPermission = nil
        permissionCont?.resume(returning: optionId)
        permissionCont = nil
    }

    /// Terminate child processes and cancel timers on app quit.
    func shutdown() {
        delegationProcess?.terminate(); delegationProcess = nil
        for proc in appProcesses.values {
            let pid = proc.processIdentifier
            proc.terminate()
            if pid > 0 { AppState.terminateTree(pid) }
        }
        appProcesses.removeAll(); runningAppIds.removeAll()
        for proc in empProcesses.values { proc.terminate() }; empProcesses.removeAll()
        for client in empACPClients.values { client.shutdown() }; empACPClients.removeAll()
        storeSyncTimer?.cancel(); storeSyncTimer = nil
        livePollTask?.cancel(); livePollTask = nil
        LineBridge.shared.stop()
        ACPClient.shared.shutdown()
        ACPClient.mobile.shutdown()   // the mobile relay's own hermes acp process
        MobileServer.shared.stop()
    }

    // MARK: - Store sync (reflect external changes in this app)

    func startStoreSync() {
        guard storeSyncTimer == nil else { return }
        let initial = StateDB.shared.digest()
        lastStoreToken = initial.token
        lastPushedMessageId = initial.maxMessageId   // don't push the existing backlog
        storeSyncTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self else { break }
                let d = StateDB.shared.digest()
                if d.token != self.lastStoreToken {
                    if self.isStreaming {
                        // Don't consume the token while streaming our own reply — only refresh the
                        // sidebar; reconcile the open conversation once the stream finishes. Throttle
                        // to ~5s: the open chat already shows the live reply, so the sidebar list
                        // doesn't need a heavy sessions() re-query every 1.2s (that was the jank).
                        let now = Date()
                        if now.timeIntervalSince(self.lastStreamingSessionRefresh) > 5 {
                            self.lastStreamingSessionRefresh = now
                            await self.fetchSessions()
                        }
                    } else {
                        self.lastStoreToken = d.token
                        await self.refreshFromStore()
                    }
                    self.scheduleMessageMirror()   // mirror history on store change (toggle-gated)
                }
                if d.maxMessageId > self.lastPushedMessageId {
                    self.checkAndPush(currentMaxId: d.maxMessageId)
                }
            }
        }
    }

    /// A new message landed in the store — push the latest assistant reply to phones.
    private func checkAndPush(currentMaxId: Int64) {
        let previous = lastPushedMessageId
        lastPushedMessageId = currentMaxId
        guard previous > 0 else { return }
        guard let m = StateDB.shared.latestAssistantMessage(), m.id > previous else { return }

        // Notification filtering: when "automations only" is on, skip interactive
        // (cli) chats and only push cron/slack/whatsapp-originated replies.
        if pushOnlyAutomations {
            let source = StateDB.shared.sessions().first { $0.id == m.sessionId }?.source ?? ""
            if source.isEmpty || source == "cli" { return }
        }
        sendPushIfEnabled(title: "Hermes", body: String(m.content.prefix(140)), sessionId: m.sessionId)
    }

    // Device presence: token → (session it's currently viewing in foreground, last report).
    // Used to suppress a push to a device that's already looking at that session.
    private var devicePresence: [String: (sessionId: String, ts: Date)] = [:]

    /// A device reported its foreground state (via POST /api/presence).
    func updatePresence(token: String, sessionId: String?, active: Bool) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if active, let sid = sessionId, !sid.isEmpty {
            devicePresence[t] = (sid, Date())
        } else {
            devicePresence.removeValue(forKey: t)
        }
    }

    /// Is this device currently foregrounded on this session (within the freshness window)?
    private func isForegroundedOn(token: String, sessionId: String) -> Bool {
        guard let p = devicePresence[token] else { return false }
        return p.sessionId == sessionId && Date().timeIntervalSince(p.ts) < 30
    }

    func sendPushIfEnabled(title: String, body: String, sessionId: String?) {
        guard apnsEnabled, !apnsKeyId.isEmpty, !apnsKeyPath.isEmpty, !apnsTeamId.isEmpty, !pushDeviceTokens.isEmpty else { return }
        let cfg = APNsSender.Config(
            keyPath: apnsKeyPath, keyId: apnsKeyId, teamId: apnsTeamId,
            bundleId: apnsBundleId, useSandbox: apnsUseSandbox
        )
        // Skip devices that are already viewing this session in the foreground — they
        // see the message live via SSE, so a banner would be redundant/annoying.
        var tokens = pushDeviceTokens
        if let sid = sessionId {
            tokens = tokens.filter { !isForegroundedOn(token: $0, sessionId: sid) }
        }
        guard !tokens.isEmpty else { return }
        Task { [weak self] in
            let invalid = await APNsSender.shared.send(to: tokens, title: title, body: body, sessionId: sessionId, config: cfg)
            if !invalid.isEmpty {
                await MainActor.run { self?.pushDeviceTokens.removeAll { invalid.contains($0) } }
            }
        }
    }

    func addPushToken(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !pushDeviceTokens.contains(t) else { return }
        pushDeviceTokens.append(t)
        if pushDeviceTokens.count > 5 {
            pushDeviceTokens.removeFirst(pushDeviceTokens.count - 5)
        }
    }

    /// Refresh the sidebar and (if not actively streaming) the open conversation
    /// from the SQLite store, so messages/sessions added on the iPhone appear here.
    func refreshFromStore() async {
        await fetchSessions()
        if let sid = currentSessionId, !isStreaming {
            var stored = messagesFromStore(sid)
            if !stored.isEmpty {
                // The store doesn't persist ACP activity (tool cards / reasoning).
                // Re-attach it from the in-memory messages so it survives reconcile.
                let activity = messages.filter {
                    $0.role == .assistant && (!$0.toolCalls.isEmpty || !$0.thinking.isEmpty)
                }
                if !activity.isEmpty {
                    for i in stored.indices where stored[i].role == .assistant {
                        if let m = activity.first(where: { sameAssistantTurn($0.content, stored[i].content) }) {
                            stored[i].toolCalls = m.toolCalls
                            stored[i].thinking = m.thinking
                        }
                    }
                }
                // In-memory-only turns the store doesn't have — delegated replies and
                // failure/retry bubbles — are preserved IN PLACE so they survive the 2s
                // store reconcile; everything else syncs from the store.
                let isPreserved: (Message) -> Bool = {
                    $0.delegatedName != nil || $0.isError
                        || ($0.role == .user && $0.content.hasPrefix("［委譲→"))
                }
                if messages.contains(where: isPreserved) {
                    var merged: [Message] = []
                    var si = 0
                    for m in messages {
                        if isPreserved(m) {
                            merged.append(m)
                        } else if si < stored.count {
                            merged.append(stored[si]); si += 1
                        }
                    }
                    while si < stored.count { merged.append(stored[si]); si += 1 }
                    self.messages = merged
                } else {
                    self.messages = stored
                }
            }
        }
    }

    /// Loose equality so re-attached ACP activity survives minor store/clean diffs.
    private func sameAssistantTurn(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// Map persisted (user/assistant) messages from state.db to the UI model,
    /// attaching token count and elapsed time (vs the preceding message) to replies.
    func messagesFromStore(_ sessionId: String) -> [Message] {
        // agy sessions live in the writable AgyStore, not the read-only Hermes state.db.
        if AgyStore.isAgySession(sessionId) {
            return AgyStore.shared.messages(sessionId).compactMap { m in
                let role: MessageRole = m.role == "user" ? .user : .assistant
                let content = role == .assistant ? stripNoiseLines(m.content) : m.content
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return Message(role: role, content: content)
            }
        }
        let rows = StateDB.shared.messages(sessionId: sessionId)
        var result: [Message] = []
        var prevTimestamp: Double? = nil
        for row in rows {
            let role: MessageRole = row.role == "user" ? .user : .assistant
            // Assistant: strip CLI noise. User: strip the mode-directive sentinel preamble.
            let content = role == .assistant ? stripNoiseLines(row.content) : AgentMode.strip(row.content)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var elapsed: Double? = nil
                if role == .assistant, let prev = prevTimestamp {
                    let dt = row.timestamp - prev
                    if dt > 0, dt < 3600 { elapsed = dt }
                }
                result.append(Message(
                    role: role,
                    content: content,
                    tokens: role == .assistant && row.tokenCount > 0 ? row.tokenCount : nil,
                    elapsed: elapsed
                ))
            }
            prevTimestamp = row.timestamp
        }
        return result
    }
    
    // Fetch sessions list. Read the SQLite store directly — the CLI `sessions list`
    // output is column-aligned and the scraper truncated IDs (e.g. dropped the
    // leading digit → "Session not found"). The store gives exact IDs.
    func fetchSessions() async {
        let rows = StateDB.shared.sessions()
        let agy = AgyStore.shared.sessions()
        // Keep the existing list on a transient empty read (e.g. DB momentarily locked),
        // rather than clearing the sidebar.
        guard !rows.isEmpty || !agy.isEmpty || sessions.isEmpty else { return }
        // Union Hermes + agy sessions, newest first by last-updated.
        let hermesItems: [(id: String, title: String, preview: String, updatedAt: Double)] = rows.map { r in
            let cleanTitle = AgentMode.strip(r.title)
            let cleanPreview = AgentMode.strip(r.preview)
            let title = cleanTitle.isEmpty ? (cleanPreview.isEmpty ? "(無題)" : String(cleanPreview.prefix(30))) : cleanTitle
            return (r.id, title, String(cleanPreview.prefix(60)), r.updatedAt)
        }
        let agyItems: [(id: String, title: String, preview: String, updatedAt: Double)] = agy.map { s in
            let preview = s.messages.last?.content ?? ""
            return (s.id, s.title.isEmpty ? "(無題)" : s.title, String(preview.prefix(60)), s.updatedAt)
        }
        self.sessions = (hermesItems + agyItems)
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { Session(id: $0.id, title: $0.title, preview: $0.preview, lastActive: "") }
    }
    
    // Fetch configuration
    func fetchConfig() async {
        let res = await HermesCLI.shared.exec(args: ["config"])
        if res.success {
            // Parse Model line
            if let modelRange = res.stdout.range(of: #"Model:\s+(\{.*\})"#, options: .regularExpression) {
                let match = String(res.stdout[modelRange])
                if let braceStart = match.firstIndex(of: "{") {
                    let jsonStr = String(match[braceStart...])
                        .replacingOccurrences(of: "'", with: "\"")
                    if let data = jsonStr.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // The provider is a Settings-only, fixed value — never overwrite it
                        // from the Hermes config. Only pick up a model change when the config
                        // still matches the fixed provider (so it can't apply a stale model
                        // from a different provider). Compare against the Hermes-side provider id
                        // (cerebras → "custom"), since that's what's written to disk.
                        let cfgProvider = dict["provider"] as? String
                        if let def = dict["default"] as? String, cfgProvider == AppState.hermesProviderId(self.provider) {
                            self.defaultModel = def
                        }
                    }
                }
            }
            // Parse Personality line
            if let persRange = res.stdout.range(of: #"Personality:\s+(\w+)"#, options: .regularExpression) {
                let match = String(res.stdout[persRange])
                if let colonIdx = match.firstIndex(of: ":") {
                    let nextIdx = match.index(after: colonIdx)
                    self.personality = String(match[nextIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }
    
    // Load API Key whenever provider changes
    func loadApiKey() async {
        self.apiKey = HermesCLI.shared.getApiKey(provider: provider)
    }
    
    // Actions
    func handleNewChat() {
        self.currentSessionId = nil
        self.messages = []
        self.inputValue = ""
        self.cwdOverride = nil   // a fresh chat is not an app-develop thread
        // A new chat for the active employee starts a fresh isolated thread.
        if let empId = activeEmployeeId, let idx = employees.firstIndex(where: { $0.id == empId }) {
            employees[idx].sessionId = nil
        }
        // Reset both the shared client and this employee's dedicated client.
        ACPClient.shared.resetSession()
        empACPClients[empKey()]?.resetSession()
        empMessages.removeValue(forKey: empKey())  // clear any stale shadow for this employee
    }

    func handleSelectSession(_ session: Session) {
        self.currentSessionId = session.id
        self.cwdOverride = nil   // viewing an existing chat is not an app-develop thread
        // Load the real conversation history from the store (was a placeholder before).
        let stored = messagesFromStore(session.id)
        self.messages = stored.isEmpty
            ? [Message(role: .system, content: "Resumed session: \(session.title)")]
            : stored
        self.inputValue = ""
        // Keep the active employee if this is one of THEIR chats (make it current);
        // otherwise (browsing 全体 / an automation result) detach the employee.
        if let empId = activeEmployeeId {
            let belongsToActive = sessionOwner[session.id] == empId
                || employees.first(where: { $0.id == empId })?.sessionId == session.id
            if belongsToActive {
                if let idx = employees.firstIndex(where: { $0.id == empId }) { employees[idx].sessionId = session.id }
            } else {
                activeEmployeeId = nil
            }
        }
        // Drop any live ACP session so the next send resumes THIS session.
        ACPClient.shared.resetSession()
        empACPClients[empKey()]?.resetSession()
    }
    
    // Overload for mobile API — select session by ID string
    func handleSelectSession(sessionId: String) async {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            handleSelectSession(session)
        } else {
            // Refresh and try again
            await fetchSessions()
            if let session = sessions.first(where: { $0.id == sessionId }) {
                handleSelectSession(session)
            }
        }
    }
    
    func handleDeleteSession(id: String) async {
        // agy sessions live in the AgyStore, not the Hermes CLI's store.
        if AgyStore.isAgySession(id) {
            AgyStore.shared.delete(id)
            if self.currentSessionId == id { handleNewChat() }
            await fetchSessions()
            return
        }
        let res = await HermesCLI.shared.exec(args: ["sessions", "delete", "--yes", id])
        if res.success {
            if self.currentSessionId == id {
                handleNewChat()
            }
            await fetchSessions()
        }
    }
    
    // Parse a raw streaming chunk for the mobile API
    func parseStreamChunk(_ raw: String) -> String {
        return parseResponseText(raw)
    }
    
    /// Send a tapped quick-reply choice as the next message (from the choice chips).
    func sendQuickReply(_ text: String) {
        guard !isStreaming, !text.isEmpty else { return }
        inputValue = text
        handleSendMessage()
    }

    // MARK: - 回答へのフィードバック（誤対応を指摘しやすく）

    /// 回答に👍/👎を付ける。👎のときは note（何が違ったか）を受け取り、ログに残す。
    /// 記録は ~/.hermes/feedback.jsonl に追記（後で改善の材料にできる）。
    func giveMessageFeedback(_ id: UUID, positive: Bool, note: String = "") {
        messageFeedback[id] = positive ? 1 : -1
        logFeedback(messageId: id, positive: positive, note: note)
        if positive { triggerToast(message: "フィードバックを記録しました 👍") }
    }

    private func logFeedback(messageId: UUID, positive: Bool, note: String) {
        let entry: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "employee": activeEmployee?.name ?? "全体",
            "sessionId": currentSessionId ?? "",
            "messageId": messageId.uuidString,
            "rating": positive ? "up" : "down",
            "note": note,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("feedback.jsonl")
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            if let d = line.data(using: .utf8) { fh.write(d) }
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    /// 👎のあと、直前の回答の訂正をエージェントに依頼する（フィードバックを実際の修正につなげる）。
    func sendCorrectionForLastReply(note: String) {
        guard !isStreaming else { triggerToast(message: "応答中です。完了までお待ちください。"); return }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        inputValue = n.isEmpty
            ? "先ほどの回答が正しくありませんでした。誤りを見直して、正しく回答し直してください。"
            : "先ほどの回答について修正をお願いします。誤っていた点: \(n)"
        handleSendMessage()
    }

    func handleSendMessage() {
        let text = inputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachedFiles
        let imgData = files.first(where: { $0.isImage })?.imageData
        guard !text.isEmpty || !files.isEmpty else { return }
        // Block only if THIS employee already has an in-flight turn (other employees can still send).
        let curKey = empKey()
        if streamingEmployeeIds.contains(curKey) {
            triggerToast(message: "応答中です。完了までお待ちください。"); return
        }

        // App-managed task command: "…のタスクを追加" / "タスク追加: …" actually creates a
        // WorkTask assigned to the active employee. The chat agent runs in a separate
        // process and can't touch the app's task store, so without this it just hallucinates
        // a "added it" reply (the bug). Handled locally → real task + deterministic confirm.
        if !bypassCommandIntercept, files.isEmpty, let cmd = parseTaskAddCommand(text) {
            messages.append(Message(role: .user, content: text))
            let who = activeEmployee.map { "（\($0.name)）" } ?? ""
            switch cmd {
            case .single(let title):
                let task = createTask(title: title, assigneeId: activeEmployeeId)
                messages.append(Message(role: .system, content: "✅ タスクを追加しました\(who)：「\(task.title)」（未着手）"))
                triggerToast(message: "タスクを追加：\(task.title)")
            case .fromContext:
                // 「これら」= 直前メッセージの箇条書きを1項目ずつタスク化。
                let items = extractContextualTaskItems()
                if items.isEmpty {
                    messages.append(Message(role: .system, content: "直前のメッセージから箇条書きの項目を見つけられませんでした。追加したい内容を箇条書きで送ってください。"))
                } else {
                    // createTask は先頭に挿入するので、リスト順を保つため逆順で追加。
                    for it in items.reversed() { _ = createTask(title: it, assigneeId: activeEmployeeId) }
                    let list = items.map { "・\($0)" }.joined(separator: "\n")
                    messages.append(Message(role: .system, content: "✅ \(items.count)件のタスクを追加しました\(who)（すべて未着手）：\n\(list)"))
                    triggerToast(message: "タスクを\(items.count)件追加しました")
                }
            }
            inputValue = ""
            attachedFiles = []
            return
        }

        // App-managed action command: "〇〇アプリで〜を作成/更新して" performs a REAL data
        // operation inside the registered app — routed to the agent running in the app's folder
        // (which uses the app's HTTP API or data files; see chatControllableRequirement).
        if !bypassCommandIntercept, files.isEmpty, let action = parseAppActionCommand(text) {
            inputValue = ""
            attachedFiles = []
            if action.destructive {
                // Deletes/overwrites of real data → require an explicit confirmation tap.
                let app = action.app
                messages.append(Message(role: .user, content: text))
                messages.append(Message(role: .system, content: "⚠️ これは「\(app.name)」の実データを変更・削除する操作です。問題なければ実行してください。"))
                triggerToast(message: "データ変更を含む操作です", actionLabel: "実行する") { [weak self] in
                    self?.runAppAction(app: app, command: text)
                }
            } else {
                runAppAction(app: action.app, command: text)
            }
            return
        }

        // App-managed launch command: "〇〇アプリを開いて / 起動して" actually launches the
        // registered app (starts its dev-server + opens the preview). Handled locally so the
        // chat agent doesn't just describe it.
        if !bypassCommandIntercept, files.isEmpty, let app = parseAppLaunchCommand(text) {
            messages.append(Message(role: .user, content: text))
            let running = isAppRunning(app.id)
            messages.append(Message(role: .system, content: running
                ? "🪟 「\(app.name)」を開きます（起動中）"
                : "▶️ 「\(app.name)」を起動します…"))
            inputValue = ""
            attachedFiles = []
            launchApp(app.id)
            return
        }

        // App-managed send command: "LINEに〜を送って" actually delivers the message to the
        // registered LINE channel via the bridge (the chat agent can't reach it). Handled
        // locally → real send + deterministic confirmation. The user typed the instruction
        // themselves, so acting on it is authorized.
        if !bypassCommandIntercept, files.isEmpty, looksLikeLineSend(text) {
            if let cmd = parseLineSendCommand(text) {
                messages.append(Message(role: .user, content: text))
                inputValue = ""
                attachedFiles = []
                let sendingId = UUID()
                messages.append(Message(id: sendingId, role: .system, content: "📤 LINE（\(cmd.channel.name)）に送信中…「\(cmd.message)」"))
                Task { @MainActor in
                    let r = await self.sendToChannel(cmd.channel, text: cmd.message)
                    if let idx = self.messages.firstIndex(where: { $0.id == sendingId }) {
                        if r.ok {
                            self.messages[idx].content = "✅ LINE（\(cmd.channel.name)）に送信しました：「\(cmd.message)」"
                        } else {
                            self.messages[idx].content = "⚠️ LINE送信に失敗しました：\(String(r.detail.prefix(120)))"
                            self.messages[idx].isError = true
                        }
                    }
                    self.triggerToast(message: r.ok ? "LINEに送信しました" : "LINE送信に失敗しました")
                }
                return
            }
            // Looks like a LINE-send request but no LINE channel is registered.
            if !channels.contains(where: { $0.platform.lowercased() == "line" }) {
                messages.append(Message(role: .user, content: text))
                messages.append(Message(role: .system, content: "⚠️ 送信先のLINEチャンネルが登録されていません。設定 → チャンネル でLINEのIDを追加してください。"))
                inputValue = ""; attachedFiles = []
                return
            }
        }

        let imagePath: String? = imgData.flatMap { writeTempImage($0) }
        // Show the attached file names in the user bubble so the history reflects them.
        let displayText: String = {
            guard !files.isEmpty else { return text }
            let names = files.map { "📎 \($0.name)" }.joined(separator: "  ")
            return text.isEmpty ? names : "\(text)\n\(names)"
        }()

        self.messages.append(Message(role: .user, content: displayText, imageData: imgData))
        self.inputValue = ""
        self.attachedFiles = []
        streamingEmployeeIds.insert(curKey)  // mark THIS employee as streaming
        self.activeStatus = "thinking"
        self.streamText = ""
        empStreamTexts[curKey] = ""
        let now = Date()
        self.streamStartedAt = now
        self.lastStreamActivityAt = now
        self.streamedCharCount = 0

        // Stable id for the streaming bubble — updated in place by chunk events.
        let assistantId = UUID()
        self.messages.append(Message(id: assistantId, role: .assistant, content: "", typewriter: true))
        // Snapshot current messages into the shadow (background streaming keeps chunks here).
        empMessages[curKey] = cappedShadow(messages)
        // Mark this assistantId as the live turn for curKey (guards against late/superseded events).
        streamingAssistantIds[curKey] = assistantId

        // Reference attached files by their local path so the agent (which has file tools) can
        // open them. Images beyond the first — and all non-image files — go here; the first
        // image additionally rides --image for vision.
        let fileRefs: String = {
            let paths = files.map { $0.url.path }
            guard !paths.isEmpty else { return "" }
            let list = paths.map { "- \($0)" }.joined(separator: "\n")
            return "\n\n【添付ファイル】以下のローカルファイルを読んで対応してください:\n\(list)"
        }()
        // 健康アドバイザー社員とのチャットには、最新の健康データ(HealthKit由来)を文脈として
        // 前置する（表示メッセージには出さない）。「今日の歩数は？」等に答えられるように。
        let healthContext: String = {
            guard let emp = activeEmployee,
                  emp.name.contains("健康") || emp.name.lowercased().contains("health"),
                  let line = healthSummaryLine else { return "" }
            return "【参考データ（連携中のHealthKit）】\(line)\n\n"
        }()

        var effectivePrompt = text
        if effectivePrompt.isEmpty { effectivePrompt = imagePath != nil ? "添付した画像について説明してください。" : "添付したファイルを確認してください。" }
        effectivePrompt += fileRefs
        if !healthContext.isEmpty { effectivePrompt = healthContext + effectivePrompt }
        let sentPrompt = wrapForSend(effectivePrompt)
        let kind = BackendRouter.selectKind(provider: provider, useACP: useACPTransport)

        var agyPrompt = ""
        if kind == .antigravity {
            if imagePath != nil && text.trimmingCharacters(in: .whitespaces).isEmpty {
                finishSendError(assistantId, imagePath, "Antigravity CLI (agy) は画像入力に対応していません。テキストで指定してください。", owningKey: curKey)
                return
            }
            var userText = text.isEmpty ? "添付したファイルを確認してください。" : text
            userText += fileRefs
            if imagePath != nil { userText += "\n\n（注: 添付画像は Antigravity CLI では無視されます）" }
            if !healthContext.isEmpty { userText = healthContext + userText }
            agyPrompt = antigravityPrompt(userText, employee: activeEmployee, mode: agentMode)
        }

        let req = AgentRequest(
            prompt: sentPrompt, agyPrompt: agyPrompt,
            imagePath: (kind == .antigravity ? nil : imagePath),
            cwd: effectiveCwd, sessionId: currentSessionId, startFresh: currentSessionId == nil,
            agyModel: modelForFixedProvider(activeEmployee))
        let userText = text
        let started = Date()
        // Capture owning context at send time — survives any mid-stream switch.
        let owningEmployeeId = activeEmployeeId
        let owningSessionId = currentSessionId
        let owningKey = curKey

        Task { @MainActor in
            if kind != .antigravity { await self.modelApplyTask?.value }
            if kind == .antigravity, await AntigravityCLI.shared.resolveBinaryAsync() == nil {
                self.finishSendError(assistantId, imagePath, AntigravityCLI.installHint, owningKey: owningKey)
                return
            }

            // Dedicated ACP client per employee enables truly parallel ACP turns.
            // HermesCLI/agy already spawn independent processes — no sharing needed.
            let acp = kind == .acp ? self.getOrCreateACPClient(for: owningKey) : ACPClient.shared
            let backend = BackendRouter.make(kind, acp: acp)

            let result = await backend.send(
                req,
                onStart: { [weak self] proc in
                    guard let proc = proc else { return }
                    self?.empProcesses[owningKey] = proc
                },
                onEvent: { [weak self] event in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        // Drop events that arrive after this turn finalized, or after a newer turn
                        // started for the same employee — otherwise a late chunk overwrites the
                        // finalized bubble or re-creates a leaked empStreamTexts entry.
                        guard self.streamingAssistantIds[owningKey] == assistantId else { return }
                        let isActive = (self.activeEmployeeId == owningEmployeeId)
                        // Heartbeat: a real event just arrived → the turn is progressing, not stuck.
                        if isActive {
                            self.lastStreamActivityAt = Date()
                            if case .chunk(let t) = event { self.streamedCharCount += t.count }
                            else if case .thought(let t) = event { self.streamedCharCount += t.count }
                        }
                        switch event {
                        case .chunk(let t):
                            self.empStreamTexts[owningKey, default: ""] += t
                            let rawText = self.empStreamTexts[owningKey] ?? ""
                            let parsed: String
                            switch kind {
                            case .hermesCLI:   parsed = self.parseResponseText(rawText)
                            case .antigravity: parsed = AntigravityCLI.clean(rawText)
                            case .acp:         parsed = rawText
                            }
                            // Always update the shadow (background streaming).
                            if let idx = self.empMessages[owningKey]?.firstIndex(where: { $0.id == assistantId }) {
                                self.empMessages[owningKey]![idx].content = parsed
                            }
                            // Update visible messages + streamText only when this is the active employee.
                            if isActive {
                                if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                                    self.messages[idx].content = parsed
                                }
                                self.streamText = rawText
                            }
                        case .thought(let t):
                            if let idx = self.empMessages[owningKey]?.firstIndex(where: { $0.id == assistantId }) {
                                self.empMessages[owningKey]![idx].thinking += t
                            }
                            if isActive, let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                                self.messages[idx].thinking += t
                            }
                        case .toolActivity(let calls):
                            if let idx = self.empMessages[owningKey]?.firstIndex(where: { $0.id == assistantId }) {
                                self.empMessages[owningKey]![idx].toolCalls = calls
                            }
                            if isActive, let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                                self.messages[idx].toolCalls = calls
                            }
                        }
                    }
                })

            // Clean up this employee's streaming state.
            self.streamingEmployeeIds.remove(owningKey)
            self.empProcesses.removeValue(forKey: owningKey)
            let rawStream = self.empStreamTexts.removeValue(forKey: owningKey) ?? ""

            let isActive = (self.activeEmployeeId == owningEmployeeId)
            if isActive { self.streamText = ""; self.streamStartedAt = nil; self.lastStreamActivityAt = nil }
            if self.streamingEmployeeIds.isEmpty { self.activeStatus = "online" }

            let final: String
            switch kind {
            case .hermesCLI:   final = self.parseResponseText(rawStream)
            case .antigravity: final = AntigravityCLI.clean(rawStream)
            case .acp:         final = rawStream
            }
            // Backend health: a real reply = healthy; an empty turn = a failure signal.
            self.recordBackendOutcome(ok: !final.isEmpty)

            // Finalize the bubble in the shadow array (always — needed if user switches back).
            if let idx = self.empMessages[owningKey]?.firstIndex(where: { $0.id == assistantId }) {
                self.empMessages[owningKey]![idx].elapsed = Date().timeIntervalSince(started)
                if final.isEmpty {
                    self.empMessages[owningKey]![idx].content = self.emptyTurnMessage(kind: kind, ok: result.ok, raw: rawStream)
                    self.empMessages[owningKey]![idx].isError = true
                    self.empMessages[owningKey]![idx].typewriter = false
                } else {
                    self.empMessages[owningKey]![idx].content = final
                    if kind == .acp { self.empMessages[owningKey]![idx].tokens = result.tokens }
                }
            }
            // Finalize visible messages only when still viewing this employee.
            if isActive, let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                self.messages[idx].elapsed = Date().timeIntervalSince(started)
                if final.isEmpty {
                    self.messages[idx].content = self.emptyTurnMessage(kind: kind, ok: result.ok, raw: rawStream)
                    self.messages[idx].isError = true
                    self.messages[idx].typewriter = false
                    if self.rawIndicatesNoToolSupport(rawStream) { self.modelHealth[self.defaultModel] = false }
                } else {
                    self.messages[idx].content = final
                    if kind == .acp { self.messages[idx].tokens = result.tokens }
                }
            }
            if let imagePath = imagePath { try? FileManager.default.removeItem(atPath: imagePath) }

            // Session reconcile attributed to the owning employee.
            let stillViewing = isActive
            var turnSession: String? = owningSessionId
            switch kind {
            case .acp:
                turnSession = acp.hermesSessionId ?? owningSessionId
                if stillViewing, let s = turnSession { self.currentSessionId = s }
                await self.fetchSessions()
            case .antigravity:
                if !final.isEmpty {
                    let sid = AgyStore.shared.record(sessionId: owningSessionId, employeeId: owningEmployeeId,
                                                     userText: userText, assistantText: final, timestamp: Date().timeIntervalSince1970)
                    turnSession = sid
                    if stillViewing { self.currentSessionId = sid }
                    await self.fetchSessions()
                }
            case .hermesCLI:
                await self.fetchSessions()
                if turnSession == nil {
                    if self.sessions.first == nil {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await self.fetchSessions()
                    }
                    turnSession = self.sessions.first?.id
                    if stillViewing, self.currentSessionId == nil { self.currentSessionId = turnSession }
                }
            }
            self.bindSession(turnSession, toEmployee: owningEmployeeId)
            // Turn complete — the store is authoritative; clear the in-flight shadow. Clearing the
            // live-turn marker makes any still-queued onEvent callbacks no-op. Only clear if it's
            // still OURS (a newer turn for this key may have already claimed the slot).
            self.empMessages.removeValue(forKey: owningKey)
            if self.streamingAssistantIds[owningKey] == assistantId {
                self.streamingAssistantIds.removeValue(forKey: owningKey)
            }

            // If the agent produced a PDF (e.g. an invoice), surface it — open the file so it
            // "comes back" to the user. Only opens a real on-disk .pdf the reply names.
            if !final.isEmpty, owningEmployeeId == self.activeEmployeeId {
                self.openReferencedPDF(in: final)
            }

            // Auto-repair follow-through: this turn was an AI fix for a failed app launch —
            // re-launch the app now that the fix is done (a brief pause lets files settle).
            if let relaunchId = self.pendingRelaunchAppId {
                self.pendingRelaunchAppId = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.terminalOutput += "\n🔄 修復が完了しました。再起動します…\n"
                    self.launchApp(relaunchId)
                }
            }
        }
    }

    /// Finalize a send turn with an error bubble (agy image-only / not-installed pre-checks).
    private func finishSendError(_ assistantId: UUID, _ imagePath: String?, _ msg: String, owningKey: String) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].content = msg
            messages[idx].isError = true
            messages[idx].typewriter = false
        }
        streamingEmployeeIds.remove(owningKey)
        streamText = ""
        empStreamTexts.removeValue(forKey: owningKey)
        empMessages.removeValue(forKey: owningKey)
        streamingAssistantIds.removeValue(forKey: owningKey)
        if owningKey == empKey() { streamStartedAt = nil; lastStreamActivityAt = nil }
        if streamingEmployeeIds.isEmpty { activeStatus = "online" }
        if let imagePath = imagePath { try? FileManager.default.removeItem(atPath: imagePath) }
    }

    func cancelStreaming() {
        let key = empKey()
        empProcesses[key]?.terminate()
        empProcesses.removeValue(forKey: key)
        // Shut down and remove the dedicated ACP client (will be recreated on next send).
        empACPClients[key]?.shutdown()
        empACPClients.removeValue(forKey: key)
        streamingEmployeeIds.remove(key)
        streamText = ""
        empStreamTexts.removeValue(forKey: key)
        empMessages.removeValue(forKey: key)
        streamingAssistantIds.removeValue(forKey: key)   // late onEvent callbacks now no-op
        streamStartedAt = nil; lastStreamActivityAt = nil
        if streamingEmployeeIds.isEmpty { activeStatus = "online" }
    }

    /// Re-send the most recent user message (after a failed/empty reply). Drops the
    /// failed turn and re-runs it.
    func retryLastUserMessage() {
        guard !isStreaming else { return }
        guard let userIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        let text = messages[userIdx].content
        let img = messages[userIdx].imageData
        messages.removeSubrange(userIdx...)   // drop the failed user+assistant turn
        inputValue = text
        attachedFiles = []
        if let img = img, let path = writeTempImage(img) {
            attachedFiles = [AttachedFile(url: URL(fileURLWithPath: path), imageData: img)]
        }
        handleSendMessage()
    }

    /// Write attached image bytes to a temp file for the CLI's --image flag.
    private func writeTempImage(_ data: Data) -> String? {
        let path = NSTemporaryDirectory() + "hermes_compose_\(UUID().uuidString).jpg"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    // MARK: - Composer attachments

    /// Stage a file (drop / picker) as a composer attachment. De-dupes by path; loads image
    /// bytes for a preview when it's an image. Capped so the composer can't be flooded.
    func attachFileURL(_ url: URL) {
        guard attachedFiles.count < 10,
              !attachedFiles.contains(where: { $0.url.path == url.path }) else { return }
        var imgData: Data? = nil
        if AttachedFile.isImagePath(url), let img = NSImage(contentsOf: url) {
            imgData = img.jpegData() ?? (try? Data(contentsOf: url))
        }
        attachedFiles.append(AttachedFile(url: url, imageData: imgData))
    }

    /// Stage raw image bytes (dragged from a browser / pasted) → write a temp file so the
    /// attachment has a local path the agent can read.
    func attachImageData(_ data: Data) {
        guard attachedFiles.count < 10, let path = writeTempImage(data) else { return }
        attachedFiles.append(AttachedFile(url: URL(fileURLWithPath: path), imageData: data))
    }

    func removeAttachment(_ id: UUID) { attachedFiles.removeAll { $0.id == id } }
    
    // Quick model presets for the in-composer switcher.
    struct ModelPreset: Identifiable {
        let id = UUID()
        let label: String
        let provider: String
        let model: String
    }

    /// One model from a live provider catalog (dynamic list).
    struct ModelOption: Identifiable, Equatable {
        let id: String      // "anthropic/claude-opus-4.8" or "llama-3.3-70b"
        let name: String    // display name
        var group: String? = nil   // explicit grouping label (e.g. "cerebras" when ids have no "/")
        var provider: String { group ?? (id.contains("/") ? String(id.split(separator: "/")[0]) : "other") }
    }

    /// Live catalog (fetched from OpenRouter) so the picker never goes stale/404.
    @Published var availableModels: [ModelOption] = []

    /// Catalog grouped by provider for the picker submenus.
    var modelsByProvider: [(provider: String, models: [ModelOption])] {
        Dictionary(grouping: availableModels) { $0.provider }
            .map { (provider: $0.key, models: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.provider < $1.provider }
    }

    /// Fetch the live model catalog for the CURRENT provider (valid, current IDs) for the
    /// picker. Provider-aware: OpenRouter, Cerebras (and any OpenAI-compatible base URL).
    func fetchAvailableModels() async {
        // Antigravity has its own preset list (no HTTP catalog).
        guard provider != AntigravityCLI.providerId,
              let urlStr = AppState.providerModelsURL(provider),
              let url = URL(string: urlStr) else { self.availableModels = []; return }
        // Cerebras ids have no "/", so group them explicitly under the provider name.
        let groupLabel: String? = provider == "openrouter" ? nil : provider
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        let key = HermesCLI.shared.getApiKey(provider: provider)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["data"] as? [[String: Any]] else { return }
            var opts: [ModelOption] = []
            for m in arr {
                guard let id = m["id"] as? String else { continue }
                opts.append(ModelOption(id: id, name: (m["name"] as? String) ?? id, group: groupLabel))
            }
            self.availableModels = opts.sorted { $0.id < $1.id }
            Log.app.info("loaded \(self.availableModels.count) models from \(self.provider)")
        } catch {
            Log.app.error("fetchAvailableModels failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // All via OpenRouter so they work with the single OpenRouter key (no per-provider
    // key needed). Use "カスタムモデルを入力…" for direct-provider models.
    static let modelPresets: [ModelPreset] = [
        .init(label: "Nemotron 120B（無料）", provider: "openrouter", model: "nvidia/nemotron-3-super-120b-a12b:free"),
        .init(label: "Nemotron Nano VL（無料・画像対応）", provider: "openrouter", model: "nvidia/nemotron-nano-12b-v2-vl:free"),
        .init(label: "Claude Sonnet 4.5（画像対応・要クレジット）", provider: "openrouter", model: "anthropic/claude-sonnet-4.5"),
        .init(label: "GPT-4o（画像対応・要クレジット）", provider: "openrouter", model: "openai/gpt-4o-2024-11-20"),
        .init(label: "GPT-4o mini（画像対応・安価）", provider: "openrouter", model: "openai/gpt-4o-mini"),
        .init(label: "Gemini 3.5 Flash（画像対応・要クレジット）", provider: "openrouter", model: "google/gemini-3.5-flash"),
    ]

    /// Curated Cerebras models (very fast inference; tool-calling capable). Availability
    /// depends on the account/tier — use "すべてのモデル" (the live catalog from
    /// fetchAvailableModels) for the authoritative, account-specific list.
    static let cerebrasPresets: [ModelPreset] = [
        .init(label: "GLM 4.7（推奨・強力）", provider: "cerebras", model: "zai-glm-4.7"),
        .init(label: "GPT-OSS 120B", provider: "cerebras", model: "gpt-oss-120b"),
        .init(label: "Qwen3 235B Instruct", provider: "cerebras", model: "qwen-3-235b-a22b-instruct-2507"),
        .init(label: "Qwen3 Coder 480B（コーディング）", provider: "cerebras", model: "qwen-3-coder-480b"),
        .init(label: "Llama 3.3 70B（高速）", provider: "cerebras", model: "llama-3.3-70b"),
    ]

    /// Presets for the currently selected inference provider (composer / palette).
    var currentModelPresets: [ModelPreset] {
        switch provider {
        case "cerebras": return AppState.cerebrasPresets
        default:         return AppState.modelPresets
        }
    }

    // MARK: - Inference provider routing (app provider id → Hermes config)

    /// The OpenAI-compatible base URL written to Hermes `model.base_url` for an app
    /// provider. "" means "let Hermes use its built-in default for this provider".
    static func providerBaseURL(_ provider: String) -> String {
        switch provider {
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "cerebras":   return "https://api.cerebras.ai/v1"
        default:           return ""
        }
    }

    /// The value written to Hermes `model.provider`. Cerebras is NOT a built-in Hermes
    /// provider, so it routes through Hermes' generic "custom" path: model.provider=custom
    /// + base_url=api.cerebras.ai, where Hermes derives CEREBRAS_API_KEY from the host
    /// (hermes_cli/runtime_provider._host_derived_api_key). Verified against hermes v0.17.
    static func hermesProviderId(_ provider: String) -> String {
        provider == "cerebras" ? "custom" : provider
    }

    /// api_mode to pin for OpenAI chat-completions providers (nil = let Hermes auto-detect).
    static func providerAPIMode(_ provider: String) -> String? {
        switch provider {
        case "openrouter", "cerebras": return "chat_completions"
        default:                       return nil
        }
    }

    /// The OpenAI-compatible model-catalog endpoint for a provider (for the picker).
    static func providerModelsURL(_ provider: String) -> String? {
        let base = providerBaseURL(provider)
        return base.isEmpty ? nil : base + "/models"
    }

    /// Human-readable provider name for user-facing messages.
    static func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "openrouter":   return "OpenRouter"
        case "cerebras":     return "Cerebras"
        case "openai":       return "OpenAI"
        case "anthropic":    return "Anthropic"
        case "gemini":       return "Google Gemini"
        case AntigravityCLI.providerId: return "Antigravity"
        default:             return provider.isEmpty ? "選択中のプロバイダー" : provider
        }
    }

    /// Write the full Hermes model config for an app provider + model in one place:
    /// handles the cerebras→custom routing, base_url, api_mode, and clears a stale
    /// `model.api_key` on the custom route so Hermes resolves the host-derived key
    /// (a leftover key would otherwise leak to the wrong endpoint — verified). Antigravity
    /// is a separate backend and must never be written into the Hermes config.
    func writeHermesModelConfig(provider: String, model: String) async {
        guard provider != AntigravityCLI.providerId else { return }
        let hermesProvider = AppState.hermesProviderId(provider)
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.provider", hermesProvider])
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.default", model])
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.base_url", AppState.providerBaseURL(provider)])
        if let mode = AppState.providerAPIMode(provider) {
            _ = await HermesCLI.shared.exec(args: ["config", "set", "model.api_mode", mode])
        }
        // Custom route (cerebras): clear any persisted model.api_key so Hermes falls through
        // to the host-derived CEREBRAS_API_KEY instead of leaking a stale OpenRouter key.
        if hermesProvider == "custom" {
            _ = await HermesCLI.shared.exec(args: ["config", "set", "model.api_key", ""])
        }
    }

    // MARK: - AI employees ("会社")

    /// Hire a new employee with role defaults. Returns the created employee.
    @discardableResult
    func hireEmployee(name: String, role: EmployeeRole) -> Employee {
        let emp = Employee.make(name: name.trimmingCharacters(in: .whitespacesAndNewlines), role: role)
        employees.append(emp)
        ensureEmployeeWorkspace(emp.id)   // auto-assign a working folder on hire
        triggerToast(message: "\(emp.role.title)「\(emp.name)」を採用しました")
        if cloudSyncEnabled { Task { await pushEmployees() } }
        return emp
    }

    /// Fire (remove) an employee, with an Undo toast (avatar kept for restore).
    /// Cascades to the employee's per-employee data so nothing is orphaned: their
    /// artifacts are tombstoned+removed and their tasks are unassigned (kept on the
    /// board as 未割当). Undo restores all of it.
    func fireEmployee(_ id: String) {
        guard let removed = employees.first(where: { $0.id == id }) else { return }
        // Capture owned data before removal (for cascade + undo).
        let removedArtifacts = artifacts.filter { $0.employeeId == id }
        let unassignedTaskIds = workTasks.filter { $0.assigneeId == id }.map { $0.id }
        let unassignedAppIds = apps.filter { $0.assigneeId == id }.map { $0.id }
        let unassignedEventIds = events.filter { $0.assigneeId == id }.map { $0.id }

        employees.removeAll { $0.id == id }
        tombstone(id)
        // Cascade: tombstone+remove the employee's artifacts; unassign tasks/apps/events.
        for a in removedArtifacts { tombstone(a.id) }
        artifacts.removeAll { $0.employeeId == id }
        let nowFire = Date().timeIntervalSince1970
        for i in workTasks.indices where workTasks[i].assigneeId == id {
            workTasks[i].assigneeId = nil; workTasks[i].updatedAt = nowFire
        }
        for i in apps.indices where apps[i].assigneeId == id {
            apps[i].assigneeId = nil; apps[i].updatedAt = nowFire
        }
        for i in events.indices where events[i].assigneeId == id {
            events[i].assigneeId = nil; events[i].updatedAt = nowFire
        }

        if activeEmployeeId == id { switchEmployee(nil) }
        if cloudSyncEnabled { Task { await deleteCloudEmployee(id) } }
        triggerToast(message: "\(removed.role.title)「\(removed.name)」を解雇しました", actionLabel: "取り消し") { [weak self] in
            guard let self = self, !self.employees.contains(where: { $0.id == removed.id }) else { return }
            self.syncTombstones[removed.id] = nil      // undo the delete: clear its tombstone
            var restored = removed
            restored.updatedAt = Date().timeIntervalSince1970   // beat any stale tombstone on other devices
            self.employees.append(restored)
            // Restore cascaded data: clear tombstones, re-add artifacts, re-assign tasks.
            let now = Date().timeIntervalSince1970
            for a in removedArtifacts { self.syncTombstones[a.id] = nil }
            self.artifacts.append(contentsOf: removedArtifacts.map { var x = $0; x.updatedAt = now; return x })
            for tid in unassignedTaskIds {
                if let idx = self.workTasks.firstIndex(where: { $0.id == tid }) {
                    self.workTasks[idx].assigneeId = removed.id
                    self.workTasks[idx].updatedAt = now
                }
            }
            for aid in unassignedAppIds {
                if let idx = self.apps.firstIndex(where: { $0.id == aid }) {
                    self.apps[idx].assigneeId = removed.id; self.apps[idx].updatedAt = now
                }
            }
            for eid in unassignedEventIds {
                if let idx = self.events.firstIndex(where: { $0.id == eid }) {
                    self.events[idx].assigneeId = removed.id; self.events[idx].updatedAt = now
                }
            }
            if self.cloudSyncEnabled { Task { await self.pushEmployees() } }
            self.triggerToast(message: "「\(removed.name)」を戻しました")
        }
    }

    private func deleteCloudEmployee(_ id: String) async {
        guard let base = supabaseBase,
              let url = URL(string: "\(base)/rest/v1/employees?id=eq.\(id)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "DELETE"; req.timeoutInterval = 15; cloudHeaders(&req)
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        _ = try? await URLSession.shared.data(for: req)
    }

    /// In-flight per-employee model application; a send awaits it so the first message
    /// can't run on the previous employee's model.
    private var modelApplyTask: Task<Void, Never>? = nil

    /// Make an employee active: apply their model/persona/mode/cwd and load THEIR
    /// isolated session. nil → back to the default single-agent (no employee).
    func switchEmployee(_ id: String?) {
        cwdOverride = nil
        // Save the outgoing employee's current messages to their shadow (preserves streaming bubble).
        let outKey = empKey(activeEmployeeId)
        empMessages[outKey] = cappedShadow(messages)
        if let curId = activeEmployeeId, let idx = employees.firstIndex(where: { $0.id == curId }) {
            employees[idx].sessionId = currentSessionId
            recordSessionOwner(currentSessionId, curId)
        }
        activeEmployeeId = id
        let newKey = empKey(id)

        // If the full-screen employee detail is open, follow the sidebar selection so picking a
        // different employee on the left shows that employee's management on the right.
        if view == "employee", let id { detailEmployeeId = id }

        if let emp = activeEmployee {
            agentMode = emp.mode
            currentSessionId = emp.sessionId
            // If the incoming employee has an in-flight turn, show their live shadow messages
            // (includes the streaming bubble). Otherwise load from the store as usual.
            if streamingEmployeeIds.contains(newKey), let live = empMessages[newKey], !live.isEmpty {
                messages = live
                streamText = empStreamTexts[newKey] ?? ""
            } else {
                messages = emp.sessionId.map { messagesFromStore($0) } ?? []
                streamText = ""
            }
            let m = modelForFixedProvider(emp)
            modelApplyTask = Task { await applyModelSilently(model: m) }
        } else {
            currentSessionId = nil
            if streamingEmployeeIds.contains(newKey), let live = empMessages[newKey], !live.isEmpty {
                messages = live
                streamText = empStreamTexts[newKey] ?? ""
            } else {
                messages = []
                streamText = ""
            }
            modelApplyTask = nil
        }
        inputValue = ""
        // Liveness indicator: if the employee we switched to is mid-stream, we don't know the
        // original start time — approximate it as "now" so the elapsed/heartbeat keeps working;
        // otherwise clear it.
        if streamingEmployeeIds.contains(newKey) {
            streamStartedAt = Date()   // real start is unknown post-switch — approximate
            lastStreamActivityAt = Date()
        } else {
            streamStartedAt = nil; lastStreamActivityAt = nil
        }
        // Only reset this employee's dedicated ACP client if they are NOT currently streaming.
        // The shared ACP client (used for delegation) is independent — never reset here.
        if !streamingEmployeeIds.contains(newKey) { empACPClients[newKey]?.resetSession() }
        view = "chat"
    }

    /// Bind a session to a specific employee (context isolation) — used by the in-flight
    /// turn reconcile so a turn that finished after you switched away is attributed correctly.
    func bindSession(_ sid: String?, toEmployee empId: String?) {
        guard let empId = empId, let sid = sid,
              let idx = employees.firstIndex(where: { $0.id == empId }) else { return }
        if employees[idx].sessionId != sid { employees[idx].sessionId = sid }
        recordSessionOwner(sid, empId)
    }

    /// Bind the just-created hermes session to the active employee (context isolation).
    func bindCurrentSessionToActiveEmployee() {
        guard let empId = activeEmployeeId, let sid = currentSessionId,
              let idx = employees.firstIndex(where: { $0.id == empId }) else { return }
        if employees[idx].sessionId != sid { employees[idx].sessionId = sid }
        recordSessionOwner(sid, empId)
    }

    /// Phase 2 — Manager delegation. Run `task` in `target`'s ISOLATED context (their
    /// persona + session + workspace) and append the result to the current (manager's)
    /// chat, attributed to the specialist. Does not change the active employee or model.
    func delegate(to employeeId: String, task: String) async {
        guard !isStreaming, let target = employees.first(where: { $0.id == employeeId }) else { return }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Visible: the assignment (synthetic user bubble) + the specialist's reply bubble.
        messages.append(Message(role: .user, content: "［委譲→\(target.role.title)・\(target.name)］\(trimmed)"))
        let msgId = UUID()
        messages.append(Message(id: msgId, role: .assistant, content: "", typewriter: true,
                                delegatedName: target.name, delegatedRole: target.role,
                                delegatedId: employeeId))
        let delegateKey = empKey()
        streamingEmployeeIds.insert(delegateKey)  // manager's chat slot is occupied
        activeStatus = "thinking"
        busyEmployeeIds.insert(employeeId)   // the specialist is now working (spinner)
        recordSessionOwner(target.sessionId, employeeId)
        let started = Date()

        let directive = "あなたは「\(target.name)」という名前の\(target.role.title)です。\(target.persona) \(target.mode.directive)"
        let wrapped = "\(trimmed)\n\n\(AgentMode.sentinelOpen)\(directive)\(AgentMode.sentinelClose)"
        let cwd = target.workspacePath ?? effectiveCwd
        let kind = BackendRouter.selectKind(provider: provider, useACP: useACPTransport)

        func finishDelegate() {
            busyEmployeeIds.remove(employeeId)
            streamingEmployeeIds.remove(delegateKey)
            if streamingEmployeeIds.isEmpty && busyEmployeeIds.isEmpty { activeStatus = "online" }
        }

        // agy install check (clear hint) at the call site.
        if kind == .antigravity, await AntigravityCLI.shared.resolveBinaryAsync() == nil {
            if let i = messages.firstIndex(where: { $0.id == msgId }) {
                messages[i].content = AntigravityCLI.installHint; messages[i].isError = true; messages[i].typewriter = false
            }
            finishDelegate(); await fetchSessions(); return
        }

        // Run on the specialist's MODEL (provider fixed), then restore the manager's —
        // Hermes/ACP only (agy carries its model in the request, no Hermes config swap).
        var swapModel = false
        var mgrModel = defaultModel
        if kind != .antigravity {
            await modelApplyTask?.value
            mgrModel = defaultModel
            let targetModel = modelForFixedProvider(target)
            swapModel = (targetModel != mgrModel)
            if swapModel { await setHermesModelConfig(model: targetModel) }
        }

        let req = AgentRequest(
            prompt: wrapped,
            agyPrompt: antigravityPrompt(trimmed, employee: target, mode: target.mode),
            imagePath: nil, cwd: cwd,
            sessionId: target.sessionId, startFresh: target.sessionId == nil,
            agyModel: modelForFixedProvider(target))

        var acc = ""
        let backend = BackendRouter.make(kind, acp: .shared)
        let result = await backend.send(
            req,
            onStart: { [weak self] proc in self?.delegationProcess = proc },
            onEvent: { [weak self] event in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    guard case .chunk(let t) = event,
                          let i = self.messages.firstIndex(where: { $0.id == msgId }) else { return }
                    acc += t
                    switch kind {       // delegation UI shows only the reply (no reasoning/tool cards)
                    case .hermesCLI:   self.messages[i].content = self.parseResponseText(acc)
                    case .antigravity: self.messages[i].content = AntigravityCLI.clean(acc)
                    case .acp:         self.messages[i].content = acc
                    }
                }
            })

        self.delegationProcess = nil
        let final: String
        switch kind {
        case .hermesCLI:   final = parseResponseText(acc)
        case .antigravity: final = AntigravityCLI.clean(acc)
        case .acp:         final = acc
        }
        if let i = messages.firstIndex(where: { $0.id == msgId }) {
            messages[i].typewriter = false
            messages[i].elapsed = Date().timeIntervalSince(started)
            if kind == .acp, let t = result.tokens { messages[i].tokens = t }
            if final.isEmpty {
                if kind == .acp {
                    messages[i].content = result.ok ? "(空の応答)" : "委譲に失敗しました"; messages[i].isError = !result.ok
                } else {
                    messages[i].content = "委譲に失敗しました"; messages[i].isError = true
                }
            } else {
                messages[i].content = final
            }
        }

        // Per-kind specialist-session adoption.
        switch kind {
        case .antigravity:
            if !final.isEmpty {
                let sid = AgyStore.shared.record(sessionId: target.sessionId, employeeId: employeeId,
                                                 userText: trimmed, assistantText: final, timestamp: Date().timeIntervalSince1970)
                if let ti = employees.firstIndex(where: { $0.id == employeeId }) {
                    employees[ti].sessionId = sid; recordSessionOwner(sid, employeeId)
                }
            }
        case .acp:
            // Only adopt a brand-new specialist session; never overwrite an existing id.
            if target.sessionId == nil, let ti = employees.firstIndex(where: { $0.id == employeeId }),
               let hsid = result.hermesSessionId {
                employees[ti].sessionId = hsid; recordSessionOwner(hsid, employeeId)
            }
            // Reset the shared ACP client so the manager's next message resumes their session.
            ACPClient.shared.resetSession()
        case .hermesCLI:
            if target.sessionId == nil {
                await fetchSessions()
                if let ti = employees.firstIndex(where: { $0.id == employeeId }), let first = sessions.first {
                    employees[ti].sessionId = first.id; recordSessionOwner(first.id, employeeId)
                }
            }
        }

        if swapModel { await setHermesModelConfig(model: mgrModel) }
        finishDelegate()
        await fetchSessions()
    }

    /// Temporarily set the hermes MODEL (provider is fixed) WITHOUT touching the published
    /// provider/defaultModel — used to run a delegated task on a specialist's model, then
    /// restore the manager's.
    private func setHermesModelConfig(model: String) async {
        // Antigravity isn't a Hermes provider — it runs via `agy`, not the Hermes config.
        guard provider != AntigravityCLI.providerId else { return }
        await writeHermesModelConfig(provider: provider, model: model)
    }

    // MARK: - Schedule (Phase G — calendar events)

    /// Events on a given calendar day (local time), earliest first.
    func events(on day: Date) -> [ScheduleEvent] {
        let cal = Calendar.current
        return events
            .filter { cal.isDate(Date(timeIntervalSince1970: $0.date), inSameDayAs: day) }
            .sorted { ($0.allDay ? 0 : 1, $0.date) < ($1.allDay ? 0 : 1, $1.date) }
    }
    /// True if a day has any events (for the calendar dot).
    func hasEvents(on day: Date) -> Bool {
        let cal = Calendar.current
        return events.contains { cal.isDate(Date(timeIntervalSince1970: $0.date), inSameDayAs: day) }
    }

    @discardableResult
    func addEvent(title: String, date: Double, allDay: Bool, detail: String = "", assigneeId: String? = nil) -> ScheduleEvent {
        var e = ScheduleEvent(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "予定" : title.trimmingCharacters(in: .whitespacesAndNewlines), date: date)
        e.allDay = allDay; e.detail = detail; e.assigneeId = assigneeId
        events.append(e)
        triggerToast(message: "予定を追加しました")
        return e
    }
    func updateEvent(_ id: String, title: String? = nil, date: Double? = nil, allDay: Bool? = nil,
                     detail: String? = nil, assigneeId: String?? = nil) {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        if let v = title?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { events[idx].title = v }
        if let v = date { events[idx].date = v }
        if let v = allDay { events[idx].allDay = v }
        if let v = detail { events[idx].detail = v }
        if let v = assigneeId { events[idx].assigneeId = v }
        events[idx].updatedAt = Date().timeIntervalSince1970
    }
    func deleteEvent(_ id: String) {
        tombstone(id); events.removeAll { $0.id == id }
    }

    /// Phase C — a meeting: ask each participant the topic (in their isolated context),
    /// then optionally have a manager synthesize. Reuses `delegate` per participant.
    func holdMeeting(topic: String, participantIds: [String], synthesize: Bool) async {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !t.isEmpty, !participantIds.isEmpty else { return }
        view = "chat"
        messages.append(Message(role: .system, content: "会議: \(t)"))

        var transcript: [(name: String, text: String)] = []
        for pid in participantIds {
            guard let emp = employees.first(where: { $0.id == pid }) else { continue }
            await delegate(to: pid, task: t)
            if let last = messages.last(where: { $0.delegatedName == emp.name && !$0.isError && !$0.content.isEmpty }) {
                transcript.append((emp.name, last.content))
            }
        }

        if synthesize, !transcript.isEmpty,
           let mgr = activeEmployee?.role == .manager ? activeEmployee : employees.first(where: { $0.role == .manager }) {
            let body = transcript.map { "【\($0.name)】\n\($0.text)" }.joined(separator: "\n\n")
            let prompt = "次の会議の各メンバーの意見をまとめ、結論と次のアクションを簡潔に示してください。\n\n\(body)"
            await delegate(to: mgr.id, task: prompt)
        }
    }

    /// Register an automation (cron) for a specific employee: preset the assignee (and
    /// optionally the prompt/name) and jump to the Automations screen to set the schedule.
    func registerAutomationForEmployee(_ employeeId: String, prompt: String? = nil) {
        newCronAssigneeId = employeeId
        if let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            newCronPrompt = p
        }
        if let emp = employees.first(where: { $0.id == employeeId }),
           newCronName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newCronName = "\(emp.name)の定期タスク"
        }
        view = "automations"
        Task { await fetchCronJobs() }
        triggerToast(message: "担当者を設定しました。スケジュールと指示を入力して作成してください。")
    }

    /// Hand a task to its assignee: switch to that employee, prefill the task as the
    /// prompt, mark it 対応中, and open the chat.
    func startTask(_ taskId: String) {
        guard let t = workTasks.first(where: { $0.id == taskId }) else { return }
        if let aid = t.assigneeId, employees.contains(where: { $0.id == aid }) {
            switchEmployee(aid)
        }
        setTaskStatus(taskId, .doing)
        inputValue = t.title + (t.detail.isEmpty ? "" : "\n\n\(t.detail)")
        view = "chat"
    }

    /// Mobile send wrap: explicit mode + optional employee (iOS picks the employee, not
    /// the Mac's active one). Sentinel-stripped from display like wrapForSend.
    func wrapForMobile(_ text: String, mode: AgentMode, employeeId: String?) -> String {
        var directive = ""
        if let eid = employeeId, let emp = employees.first(where: { $0.id == eid }) {
            directive += "あなたは「\(emp.name)」という名前の\(emp.role.title)です。\(emp.persona) "
        }
        directive += mode.directive
        return "\(text)\n\n\(AgentMode.sentinelOpen)\(directive)\(AgentMode.sentinelClose)"
    }

    /// The sentinel-wrapped directive for a send: active employee persona (if any) + mode.
    func wrapForSend(_ text: String) -> String {
        var directive = ""
        if let emp = activeEmployee {
            directive += "あなたは「\(emp.name)」という名前の\(emp.role.title)です。\(emp.persona) "
        }
        directive += agentMode.directive
        return "\(text)\n\n\(AgentMode.sentinelOpen)\(directive)\(AgentMode.sentinelClose)"
    }

    // MARK: - Antigravity CLI backend (agy)

    /// Build a plain (sentinel-free) prompt for `agy`, prepending the employee persona
    /// and appending the chat/code mode directive as plain text. Antigravity won't strip
    /// Hermes sentinels, so the directive is included verbatim (not sentinel-wrapped).
    func antigravityPrompt(_ text: String, employee: Employee?, mode: AgentMode) -> String {
        var prefix = ""
        if let emp = employee {
            prefix += "あなたは「\(emp.name)」という名前の\(emp.role.title)です。\(emp.persona)\n\n"
        }
        return "\(prefix)\(text)\n\n\(mode.directive)"
    }

    /// The model to run under the FIXED global provider. The provider is a Settings-only
    /// value (never auto-switched), so an employee's own model is honored only when it
    /// belongs to that provider; otherwise we fall back to the global default model.
    func modelForFixedProvider(_ employee: Employee?) -> String {
        if let e = employee, e.provider == provider, !e.model.isEmpty { return e.model }
        if !defaultModel.isEmpty { return defaultModel }
        return provider == AntigravityCLI.providerId ? AntigravityCLI.defaultModel : defaultModel
    }

    /// Generate an AI avatar via Pollinations (free, no key) and cache it to disk.
    func generateAIAvatar(for employeeId: String) async {
        guard let emp = employees.first(where: { $0.id == employeeId }) else { return }
        let english: [EmployeeRole: String] = [
            .manager: "business manager", .engineer: "software engineer", .researcher: "researcher",
            .writer: "writer", .designer: "designer", .analyst: "data analyst",
            .reviewer: "quality reviewer", .assistant: "personal assistant"
        ]
        let role = english[emp.role] ?? "office worker"
        let promptText = "professional friendly corporate avatar portrait of a \(role), flat vector illustration, centered, simple solid background"
        let enc = promptText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? promptText
        // Vary the seed each generation so re-generating yields a fresh portrait.
        let stamp = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://image.pollinations.ai/prompt/\(enc)?width=256&height=256&nologo=true&seed=\(stamp)") else { return }
        do {
            var req = URLRequest(url: url); req.timeoutInterval = 60
            let (data, _) = try await URLSession.shared.data(for: req)
            guard NSImage(data: data) != nil else { triggerToast(message: "アバター生成に失敗しました"); return }
            let dir = avatarsDir()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Unique filename so SwiftUI/NSImage reload (stable path + NSImage cache would not).
            let path = dir.appendingPathComponent("\(employeeId)-\(stamp).png")
            try data.write(to: path)
            if let idx = employees.firstIndex(where: { $0.id == employeeId }) {
                let old = employees[idx].avatarImagePath
                employees[idx].avatarImagePath = path.path
                if let old = old, old != path.path { try? FileManager.default.removeItem(atPath: old) }
            }
            triggerToast(message: "アバターを生成しました")
        } catch {
            triggerToast(message: "アバター生成に失敗しました")
        }
    }

    func avatarsDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HermesCustom/avatars", isDirectory: true)
    }

    // MARK: - Turn-failure diagnostics (actionable error messages)

    /// True when a raw backend stream/error says the model has no tool-capable provider
    /// (OpenRouter: "No endpoints found that support tool use"). The app always runs the
    /// agent WITH tools, so such a model can't work here even though a plain chat would.
    func rawIndicatesNoToolSupport(_ raw: String) -> Bool {
        let r = raw.lowercased()
        return r.contains("support tool use") || r.contains("no endpoints found that support tool")
    }

    private func shortModel(_ m: String) -> String {
        m.contains("/") ? String(m.split(separator: "/").last!) : m
    }

    /// A user-facing, actionable reason for an empty/failed turn. Detects the common causes
    /// (no tool support / no credits / bad key); otherwise still nudges toward switching
    /// models, since a tool-incapable model is by far the most common cause of an instant
    /// empty reply in this agent.
    func emptyTurnMessage(kind: BackendKind, ok: Bool, raw: String) -> String {
        let r = raw.lowercased()
        if rawIndicatesNoToolSupport(raw) {
            return "このモデル（\(shortModel(defaultModel))）はツール使用（関数呼び出し）に未対応のため、このアプリでは動作しません。下のモデル名から別のモデル（例: Nemotron 120B〔無料〕/ GPT-4o mini）に切り替えてください。"
        }
        let pname = AppState.providerDisplayName(provider)
        if r.contains("402") || r.contains("insufficient") || r.contains("credit") {
            return "クレジット不足の可能性があります。\(pname)の残高、または無料/安価モデルへの切替をご確認ください。"
        }
        if r.contains("401") || r.contains("unauthorized") || r.contains("invalid api key") {
            return "APIキーが無効/未設定の可能性があります。設定で\(pname)のAPIキーを確認してください。"
        }
        if kind == .antigravity {
            return "応答がありませんでした（Antigravity CLI / `agy` を確認してください）。"
        }
        return "応答が得られませんでした。多くの場合、選択中のモデルがツール使用に未対応です。下のモデル名から別のモデル（例: Nemotron 120B〔無料〕/ GPT-4o mini）に切り替えて再試行してください。"
    }

    // MARK: - Diagnostics / toast / dashboard / output parsing

    /// Surface a failure that would otherwise be swallowed by `try?`: write a structured entry to
    /// ~/.hermes/logs/app.log (+ unified log) and, when `toast` is given, notify the user. Use this
    /// for operations whose silent failure leaves the user confused (key/config writes, etc.).
    func reportFailure(_ context: String, error: Error? = nil, toast: String? = nil, category: String = "app") {
        Log.failure(category, context, error)
        if let toast {
            // Give the user a way to see what actually went wrong (#2 logging UX): a tap opens app.log.
            triggerToast(message: toast, actionLabel: "ログ", action: { [weak self] in self?.openAppLog() })
        }
    }

    /// Open ~/.hermes/logs/app.log in the default app (or reveal the logs folder if not created yet).
    func openAppLog() {
        let url = Log.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    /// Record a chat turn's outcome for the backend circuit breaker. A run of empty/failed turns
    /// trips `backendHealthy` → false (clear 「接続不安定」 state + one toast); the next good reply
    /// recovers it. Called once per finalized turn.
    func recordBackendOutcome(ok: Bool) {
        if ok {
            backendFailureStreak = 0
            if !backendHealthy {
                backendHealthy = true
                Log.event("net", "INFO", "backend recovered")
                triggerToast(message: "バックエンドの応答が回復しました。")
            }
        } else {
            backendFailureStreak += 1
            if backendFailureStreak >= 3, backendHealthy {
                backendHealthy = false
                Log.failure("net", "backend unhealthy: \(backendFailureStreak) consecutive empty/failed turns")
                triggerToast(message: "バックエンドの応答が不安定です。hermes(ゲートウェイ)の状態をご確認ください。")
            }
        }
    }

    func triggerToast(message: String, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        toastToken += 1
        let token = toastToken
        self.toastMessage = message
        self.toastActionLabel = actionLabel
        self.toastAction = action
        self.showToast = true
        let delay = action != nil ? 6.0 : 3.0   // longer window when an Undo is offered
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.toastToken == token else { return }
            self.dismissToast()
        }
    }

    private func dismissToast() {
        showToast = false
        toastMessage = ""
        toastActionLabel = nil
        toastAction = nil
    }

    /// Run the toast's action (e.g. Undo) and dismiss it.
    func performToastAction() {
        let act = toastAction
        toastToken += 1
        dismissToast()
        act?()
    }
    
    // Whether the QR/connection URL is using the Tailscale network
    @Published var isUsingTailscale: Bool = false

    // Update dashboard URL and generate QR Code.
    // Prefer the Tailscale address (reachable from anywhere on the tailnet),
    // falling back to the local Wi-Fi/LAN IP, then loopback.
    func updateDashboardURL() async {
        let port = AppConfig.mobilePort
        // Prefer the stable MagicDNS hostname over a raw IP, so the QR/URL the user
        // shares keeps working even if the tailnet IP changes.
        // Run the (blocking) `tailscale status` subprocess OFF the main actor so a slow
        // or hung tailnet can never freeze the UI on launch.
        let host = await Task.detached(priority: .utility) {
            HermesCLI.shared.getTailscaleHostname()
        }.value
        if let host = host {
            self.dashboardURL = "http://\(host):\(port)"
            self.qrCodeImage = QRCodeGenerator.generate(from: self.dashboardURL)
            self.isUsingTailscale = true
        } else if let tsIP = HermesCLI.shared.getTailscaleIPAddress() {
            self.dashboardURL = "http://\(tsIP):\(port)"
            self.qrCodeImage = QRCodeGenerator.generate(from: self.dashboardURL)
            self.isUsingTailscale = true
        } else if let ip = HermesCLI.shared.getLocalIPAddress() {
            self.dashboardURL = "http://\(ip):\(port)"
            self.qrCodeImage = QRCodeGenerator.generate(from: self.dashboardURL)
            self.isUsingTailscale = false
        } else {
            self.dashboardURL = "http://127.0.0.1:\(port)"
            self.qrCodeImage = nil
            self.isUsingTailscale = false
        }
    }
    
    // Toggle Dashboard HTTP server
    func toggleDashboard() async {
        if isDashboardRunning {
            // Start dashboard bound to 0.0.0.0
            let started = await HermesCLI.shared.startDashboard(port: 9119)
            if started {
                await updateDashboardURL()
                triggerToast(message: "モバイル接続サーバーを起動しました。")
            } else {
                self.isDashboardRunning = false
                triggerToast(message: "サーバーの起動に失敗しました。")
            }
        } else {
            // Stop dashboard
            await HermesCLI.shared.stopDashboard()
            self.qrCodeImage = nil
            self.dashboardURL = ""
            triggerToast(message: "モバイル接続サーバーを停止しました。")
        }
    }
    
    // Parse raw CLI stdout and extract only the AI's response inside the Hermes banners
    private func parseResponseText(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        var inResponseSection = false
        var responseLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Detect start boundary (e.g. "╭─ ⚕ Hermes ───╮")
            if trimmed.contains("⚕ Hermes") {
                inResponseSection = true
                continue
            }
            
            if inResponseSection {
                // Detect end boundary (e.g. "╰─────────────────╯")
                if trimmed.hasPrefix("╰") || trimmed.contains("╯") {
                    inResponseSection = false
                    break
                }
                
                // Backup border check
                let isBorder = trimmed.range(of: #"^[╭╮╯╰─━⎼➖\s]+$"#, options: .regularExpression) != nil
                if isBorder && trimmed.replacingOccurrences(of: " ", with: "").count >= 10 {
                    inResponseSection = false
                    break
                }
                
                responseLines.append(line)
            }
        }
        
        var result = responseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Fallback filter if start/end boundaries weren't detected cleanly
        if result.isEmpty && !raw.isEmpty {
            var fallbackLines: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("Query:") ||
                   trimmed.hasPrefix("Initializing agent...") ||
                   trimmed.hasPrefix("Resume this session with:") ||
                   trimmed.hasPrefix("hermes --resume") ||
                   trimmed.hasPrefix("Session:") ||
                   trimmed.hasPrefix("Duration:") ||
                   trimmed.hasPrefix("Messages:") ||
                   trimmed.hasPrefix("↻ Resumed session") ||
                   trimmed.contains("⚕ Hermes") ||
                   trimmed.range(of: #"^[╭╮╯╰─━⎼➖\s]+$"#, options: .regularExpression) != nil {
                    continue
                }
                fallbackLines.append(line)
            }
            result = fallbackLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Final pass: drop CLI noise (warnings, spinners, status lines) so they
        // never surface as the assistant's message.
        result = stripNoiseLines(result)

        return result
    }

    /// Remove non-response CLI noise lines (warnings, vision/spinner/status output).
    func stripNoiseLines(_ text: String) -> String {
        let kept = text.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return true }
            if t.hasPrefix("Warning:") { return false }
            if t.contains("Unknown toolsets") { return false }
            if t.hasPrefix("Query:") { return false }
            if t.hasPrefix("Initializing agent") { return false }
            if t.hasPrefix("Resume this session") { return false }
            if t.hasPrefix("hermes --resume") { return false }
            if t.hasPrefix("Session:") || t.hasPrefix("Duration:") || t.hasPrefix("Messages:") { return false }
            if t.hasPrefix("↻") { return false }
            if t.hasPrefix("⚠") { return false }
            if t.contains("👁") || t.contains("vision analysis") { return false }
            if t.contains("⚕ Hermes") { return false }
            return true
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Side terminal (replaces real-time logs)

    func runTerminalCommand(_ cmd: String) {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        terminalOutput += "\n\(terminalCwd) $ \(trimmed)\n"

        if trimmed == "clear" { terminalOutput = ""; return }

        // Handle `cd` in-process so the working directory persists.
        if trimmed == "cd" || trimmed.hasPrefix("cd ") {
            let arg = trimmed == "cd" ? "~" : String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let expanded = (arg as NSString).expandingTildeInPath
            let target = expanded.hasPrefix("/") ? expanded : (terminalCwd as NSString).appendingPathComponent(expanded)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue {
                terminalCwd = (target as NSString).standardizingPath
            } else {
                terminalOutput += "cd: no such directory: \(arg)\n"
            }
            return
        }

        isRunningTerminalCommand = true
        let cwd = terminalCwd
        Task { [weak self] in
            let out = await AppState.runShell(trimmed, cwd: cwd)
            await MainActor.run {
                guard let self = self else { return }
                self.terminalOutput += out
                self.isRunningTerminalCommand = false
                let lines = self.terminalOutput.components(separatedBy: .newlines)
                if lines.count > 1000 { self.terminalOutput = lines.suffix(1000).joined(separator: "\n") }
            }
        }
    }

    nonisolated static func runShell(_ cmd: String, cwd: String) async -> String {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { cont.resume(returning: "error: \(error.localizedDescription)\n") }
        }
    }

    /// Open the real Terminal.app at the current working directory.
    func openInTerminalApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", terminalCwd]
        try? p.run()
    }

    // Rename Session Method
    func handleRenameSession(id: String, newTitle: String) async {
        let res = await HermesCLI.shared.exec(args: ["sessions", "rename", id, newTitle])
        if res.success {
            triggerToast(message: "セッション名を変更しました。")
            await fetchSessions()
        } else {
            triggerToast(message: "名前変更に失敗しました。")
        }
    }
    
    // Plugins Management Methods
    func fetchPlugins() async {
        self.isFetchingPlugins = true
        let res = await HermesCLI.shared.exec(args: ["plugins", "list", "--plain"])
        if res.success {
            self.pluginsList = parsePluginsList(stdout: res.stdout)
        }
        self.isFetchingPlugins = false
    }

    // MARK: - Proactive automation results — H4

    /// A session produced by an automation (cron / messaging gateway), surfaced
    /// as a card so the user sees what the agent did on its own.
    struct AutomationResult: Identifiable, Equatable {
        let id: String
        let title: String
        let preview: String
        let source: String
        let updatedAt: Double
    }
    @Published var automationResults: [AutomationResult] = []

    /// Pull recent non-interactive sessions (source != cli/acp) as proactive cards.
    func fetchAutomationResults() {
        automationResults = StateDB.shared.sessions()
            .filter {
                let s = $0.source.lowercased()
                return !s.isEmpty && s != "cli" && s != "acp" && s != "mobile"
            }
            .prefix(12)
            .map { AutomationResult(id: $0.id,
                                    title: $0.title.isEmpty ? "(無題)" : $0.title,
                                    preview: $0.preview,
                                    source: $0.source,
                                    updatedAt: $0.updatedAt) }
    }

    // MARK: - Management (skills / MCP / memory) — H3

    @Published var skills: [HermesSkill] = []
    @Published var isFetchingSkills = false
    @Published var mcpRawOutput: String = ""

    /// Load the installed skills list (`hermes skills list`).
    func fetchSkills() async {
        isFetchingSkills = true
        let res = await HermesCLI.shared.exec(args: ["skills", "list"])
        if res.success { self.skills = Self.parseSkillsTable(res.stdout) }
        isFetchingSkills = false
    }

    /// Parse the rich-table skills output into rows (cols: name | category | source | trust | status).
    static func parseSkillsTable(_ s: String) -> [HermesSkill] {
        var out: [HermesSkill] = []
        for line in s.components(separatedBy: "\n") where line.contains("│") {
            let c = line.components(separatedBy: "│")
            guard c.count >= 6 else { continue }
            let name = c[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "Name" else { continue }
            out.append(HermesSkill(
                id: name, name: name,
                category: c[2].trimmingCharacters(in: .whitespaces),
                source: c[3].trimmingCharacters(in: .whitespaces),
                status: c[5].trimmingCharacters(in: .whitespaces)
            ))
        }
        return out
    }

    /// Enable/disable a skill via opt-in / opt-out, then refresh.
    func toggleSkill(_ skill: HermesSkill) async {
        let cmd = skill.isEnabled ? "opt-out" : "opt-in"
        _ = await HermesCLI.shared.exec(args: ["skills", cmd, skill.name])
        await fetchSkills()
    }

    /// Load configured MCP servers (raw text; format varies / often empty).
    func fetchMCPServers() async {
        let res = await HermesCLI.shared.exec(args: ["mcp", "list"])
        self.mcpRawOutput = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read a built-in memory document (empty string if absent).
    func loadMemory(_ f: MemoryFile) -> String {
        (try? String(contentsOfFile: f.path, encoding: .utf8)) ?? ""
    }

    /// Write a built-in memory document.
    func saveMemory(_ f: MemoryFile, _ content: String) {
        let url = URL(fileURLWithPath: f.path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            triggerToast(message: "\(f.rawValue) を保存しました")
        } catch {
            triggerToast(message: "保存に失敗しました")
        }
    }
    
    private func parsePluginsList(stdout: String) -> [HermesPlugin] {
        let lines = stdout.components(separatedBy: .newlines)
        var parsed: [HermesPlugin] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if components.count >= 4 {
                var status = ""
                var source = ""
                var version = ""
                var name = ""

                if components[0] == "not" && components[1] == "enabled" && components.count >= 5 {
                    status = "not enabled"
                    source = components[2]
                    version = components[3]
                    name = components[4]
                } else if components[0] != "not" {
                    status = components[0]
                    source = components[1]
                    version = components[2]
                    name = components[3]
                }
                
                parsed.append(HermesPlugin(
                    id: name,
                    name: name,
                    status: status,
                    version: version,
                    source: source
                ))
            }
        }
        return parsed
    }
    
    func handleTogglePlugin(_ plugin: HermesPlugin) async {
        let action = plugin.isEnabled ? "disable" : "enable"
        let res = await HermesCLI.shared.exec(args: ["plugins", action, plugin.name])
        if res.success {
            triggerToast(message: "\(plugin.name) を\(plugin.isEnabled ? "無効" : "有効")にしました。")
            await fetchPlugins()
        } else {
            triggerToast(message: "操作に失敗しました。")
        }
    }
    
    func handleInstallPlugin() async {
        let url = pluginInstallInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        self.isInstallingPlugin = true
        triggerToast(message: "プラグインをインストール中...")
        let res = await HermesCLI.shared.exec(args: ["plugins", "install", url])
        if res.success {
            triggerToast(message: "インストールが完了しました。")
            self.pluginInstallInput = ""
            await fetchPlugins()
        } else {
            triggerToast(message: "インストールに失敗しました。")
        }
        self.isInstallingPlugin = false
    }
    
    func handleUninstallPlugin(_ plugin: HermesPlugin) async {
        triggerToast(message: "\(plugin.name) を削除中...")
        let res = await HermesCLI.shared.exec(args: ["plugins", "remove", plugin.name])
        if res.success {
            triggerToast(message: "削除が完了しました。")
            await fetchPlugins()
        } else {
            triggerToast(message: "削除に失敗しました。")
        }
    }
    

    // MARK: - Send to a channel from a chat prompt ("LINEに〜を送って")

    /// Deliver `text` to a registered channel (LINE via the bridge's line-send.sh; others via
    /// `hermes send`). Returns success + an error detail.
    func sendToChannel(_ channel: HermesChannel, text: String) async -> (ok: Bool, detail: String) {
        let res: (success: Bool, stdout: String, stderr: String)
        if channel.platform.lowercased() == "line" {
            let script = NSHomeDirectory() + "/.hermes/line-bridge/line-send.sh"
            res = await HermesCLI.shared.execCommand("/bin/bash", [script, channel.channelId, text])
        } else {
            let target = "\(channel.platform):\(channel.channelId)"
            res = await HermesCLI.shared.exec(args: ["send", "-t", target, text])
        }
        let err = (res.stderr.isEmpty ? res.stdout : res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return (res.success, err)
    }

    /// Detect a "send this to LINE" instruction in a chat prompt and extract the recipient
    /// channel + the message body. Returns nil when it isn't a clear send command (so the
    /// prompt falls through to the AI as usual). Conservative: requires BOTH a LINE/ライン
    /// mention and an explicit send verb.
    /// True if the prompt reads as a LINE-send instruction (LINE/ライン mention + a send verb,
    /// and not a how-to question). Channel-agnostic so the caller can surface "no channel".
    func looksLikeLineSend(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4, t.count < 2000, !t.contains("\n\n") else { return false }
        guard t.lowercased().contains("line") || t.contains("ライン") else { return false }
        let sendVerbs = ["送って", "送信", "送る", "送っといて", "送っておいて", "プッシュ", "通知して", "通知", "メッセージして", "伝えて", "知らせて"]
        guard sendVerbs.contains(where: { t.contains($0) }) else { return false }
        // Reject "how-to" questions and conditional/recurring phrasing (unless an explicit quote
        // pins the exact message text). 条件・反復表現（「〜たら」「定期的に」「毎日」など）は
        // 一回限りの送信ではなく『自動化を組んでほしい』という意図なので、文字通り送らない。
        if !t.contains("「") && !t.contains("『") {
            let howTo = ["使い方", "とは", "教えて", "どうやって", "方法", "設定", "繋ぎ方", "つなぎ方", "連携", "とは何"]
            let automationCues = ["たら", "次第", "毎日", "毎時", "毎週", "毎朝", "毎晩", "定期", "ごとに", "都度", "監視", "あれば", "出たら"]
            for q in howTo + automationCues where t.contains(q) {
                return false
            }
        }
        return true
    }

    func parseLineSendCommand(_ text: String) -> (channel: HermesChannel, message: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeLineSend(t) else { return nil }
        let lineChannels = channels.filter { $0.platform.lowercased() == "line" }
        guard !lineChannels.isEmpty else { return nil }   // caller surfaces "no LINE channel"
        // Prefer a channel whose name is explicitly mentioned; else the only/first one.
        let target = lineChannels.first { $0.name.count >= 2 && t.contains($0.name) } ?? lineChannels[0]
        guard let msg = extractSendMessage(t), !msg.isEmpty else { return nil }
        return (target, msg)
    }

    /// Best-effort extraction of the message body from a send command (handles quoted text and
    /// both "LINEに〜送って" and "〜をLINEに送って" forms).
    private func extractSendMessage(_ t: String) -> String? {
        // 1) Quoted content wins.
        for (open, close) in [("「", "」"), ("『", "』"), ("\u{201C}", "\u{201D}"), ("\"", "\"")] {
            if let o = t.range(of: open), let c = t.range(of: close, range: o.upperBound..<t.endIndex) {
                let inner = String(t[o.upperBound..<c.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return inner }
            }
        }
        // 2) "<message> (を|と|って) LINE(に|へ|で) 送って" — message is BEFORE the LINE framing.
        let trailing = #"\s*(を|と|って)?\s*(line|ライン)\s*(に|へ|で|宛て?に)\s*(送信|送って|送る|送っ|通知|プッシュ|メッセージ|伝え|知らせ).*$"#
        if let r = t.range(of: trailing, options: [.regularExpression, .caseInsensitive]) {
            let before = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if before.count >= 1 { return stripEdgeParticles(before) }
        }
        // 3) "LINE(に|へ|で) <message> (を) 送って" — message is AFTER the LINE marker.
        var s = t
        for marker in ["LINEに", "LINEへ", "LINEで", "ラインに", "ラインへ", "ラインで", "lineに", "lineで", "lineへ", "LINE", "ライン", "line"] {
            if let r = s.range(of: marker, options: [.caseInsensitive]) { s = String(s[r.upperBound...]); break }
        }
        for tail in ["。", "．", ".", "！", "!", "してください", "して下さい", "してね", "しておいて", "しといて",
                     "して", "お願いします", "おねがいします", "お願い", "よろしく", "を送信", "を送って",
                     "を送る", "を通知", "とメッセージ", "と送って", "って送って", "を伝えて", "と伝えて",
                     "を知らせて", "送信", "送って", "通知", "プッシュ"] {
            while s.hasSuffix(tail) { s = String(s.dropLast(tail.count)).trimmingCharacters(in: .whitespaces) }
        }
        return stripEdgeParticles(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func stripEdgeParticles(_ s: String) -> String? {
        var r = s
        for tail in ["を", "と", "、", ",", "って", "は", "に"] {
            while r.hasSuffix(tail) { r = String(r.dropLast(tail.count)).trimmingCharacters(in: .whitespaces) }
        }
        r = r.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? nil : r
    }

    // MARK: - Automations (Cron) Management
    
    // MARK: - Automation suggestions

    /// Always-available curated automation ideas (no LLM needed).
    static let curatedAutomations: [AutomationSuggestion] = [
        .init(title: "毎朝のニュース要約", schedule: "0 8 * * *",
              prompt: "今日の主要なニュースを3つ、日本語で簡潔に要約して。",
              deliver: "local", icon: "newspaper", rationale: "毎朝の情報収集を自動化"),
        .init(title: "今日のTODO整理", schedule: "0 9 * * 1-5",
              prompt: "未完了のタスクと今日の予定を整理し、優先順位をつけて提案して。",
              deliver: "local", icon: "checklist", rationale: "平日の朝に1日の計画を準備"),
        .init(title: "週次の振り返りレポート", schedule: "0 18 * * 5",
              prompt: "今週の活動を振り返り、来週やるべきことを3点提案して。",
              deliver: "local", icon: "chart.line.uptrend.xyaxis", rationale: "毎週金曜にレビュー"),
        .init(title: "GitHub PRの確認", schedule: "0 10 * * 1-5",
              prompt: "自分が関係するオープンなPRとレビュー待ちを gh で一覧にして。",
              deliver: "local", icon: "chevron.left.forwardslash.chevron.right", rationale: "レビュー漏れを防ぐ"),
        .init(title: "受信メールの要約", schedule: "0 7,19 * * *",
              prompt: "新着の重要なメールを確認し、要点を箇条書きで要約して。",
              deliver: "local", icon: "envelope", rationale: "朝晩にメールを把握"),
    ]

    /// Prefill the create form from a suggestion (the user reviews, then 作成).
    func applyAutomationSuggestion(_ s: AutomationSuggestion) {
        newCronName = s.title
        newCronSchedule = s.schedule
        newCronPrompt = s.prompt
        newCronDeliver = s.deliver.isEmpty ? "local" : s.deliver
        newCronScript = ""
        newCronNoAgent = false
        showCronCreateSheet = true   // 反映した内容を作成モーダルで開く
    }

    /// Ask the agent to propose automations (best-effort; parsed from pipe-delimited lines).
    // MARK: - Dashboard / daily brief

    /// Today's events (local day), earliest first.
    var todayEvents: [ScheduleEvent] { events(on: Date()) }
    /// Employees currently working (own turn or delegated).
    var busyEmployees: [Employee] { employees.filter { isEmployeeBusy($0.id) } }
    /// Apps with a live dev-server.
    var runningApps: [AppProject] { apps.filter { runningAppIds.contains($0.id) } }

    /// Compact factual snapshot of "today" fed to the AI brief writer.
    private func dailyBriefContext() -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "ja_JP"); df.dateFormat = "M月d日(E)"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "ja_JP"); tf.dateFormat = "HH:mm"
        var lines: [String] = ["日付: \(df.string(from: Date()))"]
        let ev = todayEvents
        lines.append("今日の予定(\(ev.count)件): " + (ev.isEmpty ? "なし" :
            ev.prefix(8).map { ($0.allDay ? "終日 " : tf.string(from: Date(timeIntervalSince1970: $0.date)) + " ") + $0.title }.joined(separator: " / ")))
        let todo = tasks(status: .todo), doing = tasks(status: .doing)
        lines.append("タスク: 未着手\(todo.count) / 対応中\(doing.count) / 完了\(tasks(status: .done).count)")
        let pending = (doing + todo).prefix(8).map { t -> String in
            let who = t.assigneeId.flatMap { id in employees.first { $0.id == id }?.name }.map { "（\($0)）" } ?? ""
            return "\(t.title)\(who)"
        }
        if !pending.isEmpty { lines.append("対応中/未着手の主なタスク: " + pending.joined(separator: " / ")) }
        let building = apps.filter { $0.status == .building }
        if !building.isEmpty { lines.append("開発中アプリ: " + building.map { $0.name }.joined(separator: " / ")) }
        if !runningApps.isEmpty { lines.append("起動中アプリ: " + runningApps.map { $0.name }.joined(separator: " / ")) }
        lines.append("社員数: \(employees.count)人" + (busyEmployees.isEmpty ? "" : "（作業中: \(busyEmployees.map { $0.name }.joined(separator: "、"))）"))
        if monthlyBudgetUSD > 0 { lines.append(String(format: "今月のコスト: $%.2f / 予算 $%.2f", totalCostUSD, monthlyBudgetUSD)) }
        return lines.joined(separator: "\n")
    }

    /// Write today's daily brief with the agent (one-shot), persisting the result + time.
    /// Races the model against a timeout so a slow/stuck model can't pin the card on "生成中…";
    /// on timeout/failure it falls back to a deterministic computed brief.
    func generateDailyBrief() async {
        guard !isGeneratingBrief else { return }
        isGeneratingBrief = true
        defer { isGeneratingBrief = false }
        let prompt = """
        あなたは有能な秘書です。以下の社内データをもとに、今日の「デイリーブリーフ」を日本語で簡潔に書いてください。
        ルール: 挨拶や前置きは書かない。まず2〜3文で今日の概況、続けて「今日の重点」として箇条書きを最大3つ。誇張せず事実ベースで。データが少なければ無理に埋めない。

        【今日のデータ】
        \(dailyBriefContext())
        """
        // Race the AI call vs a 40s timeout (the model may hang).
        let stdout: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await HermesCLI.shared.exec(args: ["chat", "-q", prompt]).stdout }
            group.addTask { try? await Task.sleep(nanoseconds: 40_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let text = stdout.map { parseResponseText($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        // Treat an error/empty response as failure → deterministic fallback (so the card never
        // shows a raw "HTTP 429 / API call failed" line as if it were the brief).
        if text.isEmpty || looksLikeErrorResponse(text) {
            dailyBrief = computedBrief()
            dailyBriefAt = Date().timeIntervalSince1970
            let hint = looksLikeErrorResponse(text) ? "（モデルがエラーを返しました：\(String(text.prefix(80)))）" : "（モデルが応答しませんでした）"
            triggerToast(message: "簡易ブリーフを表示しました\(hint)")
        } else {
            dailyBrief = text
            dailyBriefAt = Date().timeIntervalSince1970
        }
    }

    /// Heuristic: does the model's text look like an error banner rather than a real reply?
    private func looksLikeErrorResponse(_ text: String) -> Bool {
        let l = text.lowercased()
        let markers = ["api call failed", "http 4", "http 5", "429", "rate limit", "limit exceeded",
                       "too many tokens", "insufficient", "unauthorized", "invalid api key",
                       "no endpoints", "error:", "エラー:", "failed after"]
        // Short + contains a marker → very likely an error (real briefs are multi-sentence).
        return markers.contains { l.contains($0) } && text.count < 400
    }

    /// Deterministic fallback brief built directly from today's data (no model needed).
    private func computedBrief() -> String {
        let ev = todayEvents
        let todo = tasks(status: .todo), doing = tasks(status: .doing)
        var parts: [String] = []
        parts.append(ev.isEmpty ? "本日の登録予定はありません。" : "本日の予定は\(ev.count)件です。")
        parts.append("未完了タスクは\(todo.count + doing.count)件（対応中\(doing.count)・未着手\(todo.count)）。")
        if !runningApps.isEmpty { parts.append("起動中アプリ: \(runningApps.map { $0.name }.joined(separator: "、"))。") }
        if !busyEmployees.isEmpty { parts.append("作業中の社員: \(busyEmployees.map { $0.name }.joined(separator: "、"))。") }
        var s = parts.joined(separator: " ")
        let focus = (doing + todo).prefix(3).map { "・\($0.title)" }
        if !focus.isEmpty { s += "\n\n今日の重点:\n" + focus.joined(separator: "\n") }
        return s
    }

    func generateAutomationSuggestions() async {
        isGeneratingSuggestions = true
        defer { isGeneratingSuggestions = false }
        let prompt = """
        役立つ定期自動実行タスク（cron）を3つ提案してください。各行を厳密に次の形式（パイプ区切り、余計な装飾なし）で3行だけ出力:
        タイトル | cronスケジュール | エージェントへの指示
        例: 毎朝のニュース要約 | 0 8 * * * | 今日の主要ニュースを3つ日本語で要約して
        """
        let res = await HermesCLI.shared.exec(args: ["chat", "-q", prompt])
        let text = parseResponseText(res.stdout)
        var parsed: [AutomationSuggestion] = []
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[1].contains(" ") || parts[1].contains("*") else { continue }
            parsed.append(.init(title: parts[0], schedule: parts[1], prompt: parts[2],
                                deliver: "local", icon: "sparkles", rationale: "AIの提案"))
        }
        if parsed.isEmpty {
            triggerToast(message: "提案を生成できませんでした。もう一度お試しください。")
        } else {
            aiSuggestions = Array(parsed.prefix(3))
        }
    }

    func fetchCronJobs() async {
        self.isFetchingCronJobs = true
        let res = await HermesCLI.shared.exec(args: ["cron", "list"])
        self.isFetchingCronJobs = false
        
        guard res.success else { return }
        
        var jobs: [HermesCronJob] = []
        let lines = res.stdout.components(separatedBy: CharacterSet.newlines)
        
        var currentId = ""
        var currentStatus = ""
        var currentName = ""
        var currentSchedule = ""
        var currentRepeat = ""
        var currentNextRun = ""
        var currentDeliver = ""
        var currentScript: String? = nil
        var currentMode: String? = nil
        var currentLastRun: String? = nil
        var currentLastError: String? = nil

        func saveCurrentJob() {
            if !currentId.isEmpty {
                jobs.append(HermesCronJob(
                    id: currentId,
                    name: currentName.isEmpty ? "Unnamed Job" : currentName,
                    schedule: currentSchedule,
                    repeatCount: currentRepeat,
                    nextRun: currentNextRun,
                    deliver: currentDeliver,
                    status: currentStatus,
                    script: currentScript,
                    mode: currentMode,
                    lastRun: currentLastRun,
                    lastError: currentLastError
                ))
            }
        }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let rawLine = line
            
            if rawLine.hasPrefix("  ") && !rawLine.hasPrefix("    ") {
                let parts = trimmed.components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let id = parts[0]
                    if id.count == 12 { // hash ID validation
                        saveCurrentJob()
                        currentId = id
                        let statusPart = parts[1]
                        currentStatus = statusPart.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                        currentName = ""
                        currentSchedule = ""
                        currentRepeat = ""
                        currentNextRun = ""
                        currentDeliver = ""
                        currentScript = nil
                        currentMode = nil
                        currentLastRun = nil
                        currentLastError = nil
                    }
                }
            } else if !currentId.isEmpty && rawLine.hasPrefix("    ") {
                if trimmed.hasPrefix("Name:") {
                    currentName = trimmed.replacingOccurrences(of: "Name:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Schedule:") {
                    currentSchedule = trimmed.replacingOccurrences(of: "Schedule:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Repeat:") {
                    currentRepeat = trimmed.replacingOccurrences(of: "Repeat:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Next run:") {
                    currentNextRun = trimmed.replacingOccurrences(of: "Next run:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Deliver:") {
                    currentDeliver = trimmed.replacingOccurrences(of: "Deliver:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Script:") {
                    currentScript = trimmed.replacingOccurrences(of: "Script:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Mode:") {
                    currentMode = trimmed.replacingOccurrences(of: "Mode:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Last run:") {
                    currentLastRun = trimmed.replacingOccurrences(of: "Last run:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("⚠") || trimmed.lowercased().contains("delivery failed") {
                    // 例: "⚠ Delivery failed: delivery error: LINE push 401: {...}"
                    currentLastError = trimmed
                        .replacingOccurrences(of: "⚠", with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        saveCurrentJob()
        
        self.cronJobs = jobs
    }
    
    func handleToggleCronJob(_ job: HermesCronJob) async {
        let action = job.isActive ? "pause" : "resume"
        triggerToast(message: "ジョブを\(job.isActive ? "一時停止" : "再開")中...")
        let res = await HermesCLI.shared.exec(args: ["cron", action, job.id])
        if res.success {
            triggerToast(message: "ジョブを\(job.isActive ? "一時停止" : "開始")しました。")
            await fetchCronJobs()
        } else {
            triggerToast(message: "操作に失敗しました。")
        }
    }
    
    func handleDeleteCronJob(_ job: HermesCronJob) async {
        triggerToast(message: "ジョブを削除中...")
        let res = await HermesCLI.shared.exec(args: ["cron", "delete", job.id])
        if res.success {
            triggerToast(message: "ジョブを削除しました。")
            await fetchCronJobs()
        } else {
            triggerToast(message: "削除に失敗しました。")
        }
    }
    
    // MARK: - Cron ops for the mobile API (no UI side effects)

    func cronJobsJSON() async -> [[String: Any]] {
        await fetchCronJobs()
        return cronJobs.map { j in
            ["id": j.id, "name": j.name, "schedule": j.schedule, "deliver": j.deliver,
             "status": j.status, "nextRun": j.nextRun, "script": j.script ?? "", "lastRun": j.lastRun ?? ""]
        }
    }

    func cronCreate(schedule: String, prompt: String, name: String, deliver: String, script: String, noAgent: Bool) async -> Bool {
        let s = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        var args = ["cron", "create", s]
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { args.append(p) }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { args.append(contentsOf: ["--name", n]) }
        let d = deliver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { args.append(contentsOf: ["--deliver", d]) }
        let sc = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sc.isEmpty { args.append(contentsOf: ["--script", sc]) }
        if noAgent { args.append("--no-agent") }
        let res = await HermesCLI.shared.exec(args: args)
        if res.success { await fetchCronJobs() }
        return res.success
    }

    func cronSetPaused(id: String, paused: Bool) async -> Bool {
        let res = await HermesCLI.shared.exec(args: ["cron", paused ? "pause" : "resume", id])
        if res.success { await fetchCronJobs() }
        return res.success
    }

    func cronDelete(id: String) async -> Bool {
        let res = await HermesCLI.shared.exec(args: ["cron", "delete", id])
        if res.success { await fetchCronJobs() }
        return res.success
    }

    /// テスト実行: ジョブを今すぐ実行キューに入れる(`hermes cron run`)。スケジューラ(Gateway)が
    /// 稼働していれば次tickで発火し、設定された配信先(LINE等)へ結果が送られる。外部送信を伴うため
    /// 呼び出し元(UI)で確認ダイアログを挟むこと。
    func cronRunNow(id: String) async -> Bool {
        let res = await HermesCLI.shared.exec(args: ["cron", "run", id])
        if res.success {
            triggerToast(message: "テスト実行をトリガーしました。まもなく配信先に届きます。")
            await fetchCronJobs()
            fetchAutomationResults()
        } else {
            triggerToast(message: "テスト実行に失敗: \(res.stderr)")
        }
        return res.success
    }

    /// 既存のスケジュールタスクを編集（`hermes cron edit`）。空でない項目だけ更新する。
    func cronEdit(id: String, schedule: String, name: String, deliver: String) async -> Bool {
        var args = ["cron", "edit", id]
        let s = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { args.append(contentsOf: ["--schedule", s]) }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { args.append(contentsOf: ["--name", n]) }
        let d = deliver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { args.append(contentsOf: ["--deliver", d]) }
        guard args.count > 3 else { return false }   // 変更項目なし
        let res = await HermesCLI.shared.exec(args: args)
        if res.success {
            triggerToast(message: "スケジュールタスクを更新しました。")
            await fetchCronJobs()
        } else {
            triggerToast(message: "更新に失敗: \(res.stderr)")
        }
        return res.success
    }

    @discardableResult
    func handleCreateCronJob() async -> Bool {
        let name = newCronName.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = newCronSchedule.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = newCronPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Phase D: run the scheduled task as the assigned employee (prepend its persona).
        if let aid = newCronAssigneeId, let emp = employees.first(where: { $0.id == aid }), !prompt.isEmpty {
            prompt = "あなたは「\(emp.name)」という名前の\(emp.role.title)です。\(emp.persona)\n\n\(prompt)"
        }
        let deliver = newCronDeliver.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = newCronScript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !schedule.isEmpty else {
            triggerToast(message: "スケジュールを入力してください。")
            return false
        }
        
        self.isCreatingCronJob = true
        triggerToast(message: "スケジュールタスクを作成中...")
        
        var args = ["cron", "create", schedule]
        if !prompt.isEmpty {
            args.append(prompt)
        }
        if !name.isEmpty {
            args.append(contentsOf: ["--name", name])
        }
        if !deliver.isEmpty {
            args.append(contentsOf: ["--deliver", deliver])
        }
        if !script.isEmpty {
            args.append(contentsOf: ["--script", script])
        }
        if newCronNoAgent {
            args.append("--no-agent")
        }
        
        let res = await HermesCLI.shared.exec(args: args)
        if res.success {
            triggerToast(message: "タスクを作成しました。")
            newCronName = ""
            newCronSchedule = ""
            newCronPrompt = ""
            newCronDeliver = "local"
            newCronScript = ""
            newCronAssigneeId = nil
            newCronNoAgent = false
            await fetchCronJobs()
        } else {
            triggerToast(message: "作成に失敗しました: \(res.stderr)")
        }
        self.isCreatingCronJob = false
        return res.success
    }

    /// 作成フォームを初期状態へリセット（モーダルを「新規作成」で開く前に呼ぶ）。
    func resetNewCronForm() {
        newCronName = ""
        newCronSchedule = ""
        newCronPrompt = ""
        newCronDeliver = "local"
        newCronScript = ""
        newCronAssigneeId = nil
        newCronNoAgent = false
    }

}

extension NSImage {
    /// Downscale to fit `maxDimension` and encode as JPEG (for attaching/sending).
    func jpegData(maxDimension: CGFloat = 1536, quality: CGFloat = 0.7) -> Data? {
        let size = self.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: target)
        resized.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: target),
                  from: NSRect(origin: .zero, size: size),
                  operation: .copy, fraction: 1.0)
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
