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

    init(id: UUID = UUID(), role: MessageRole, content: String, isError: Bool = false, imageData: Data? = nil, typewriter: Bool = false, tokens: Int? = nil, elapsed: Double? = nil, toolCalls: [ACPToolCall] = [], thinking: String = "", delegatedName: String? = nil, delegatedRole: EmployeeRole? = nil) {
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
    @Published var inputValue: String = ""
    @Published var attachedImageData: Data? = nil  // dropped/attached image for the next message

    // Channels (messaging platform recipients in ~/.hermes/channel_directory.json)
    @Published var channels: [HermesChannel] = []
    @Published var newChannelPlatform: String = "telegram"
    @Published var newChannelId: String = ""
    @Published var newChannelName: String = ""
    @Published var isStreaming: Bool = false
    @Published var streamText: String = ""
    @Published var activeStatus: String = "online" // "online" | "thinking"
    
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
    @Published var apnsTeamId: String = UserDefaults.standard.string(forKey: "apnsTeamId") ?? "576D2UUHH5" {
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
    @Published var provider: String = "openrouter"
    @Published var defaultModel: String = "nvidia/nemotron-3-super-120b-a12b:free"
    @Published var apiKey: String = ""
    @Published var personality: String = "kawaii"
    @Published var isSavingSettings: Bool = false
    
    // New Feature States
    @Published var showRightSidebar: Bool = false
    // Which panel the right sidebar shows.
    enum RightTab { case terminal, browser }
    @Published var rightTab: RightTab = .terminal
    // Side terminal
    @Published var terminalOutput: String = ""
    @Published var terminalCwd: String = NSHomeDirectory()
    @Published var isRunningTerminalCommand: Bool = false
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
    @Published var workTasks: [WorkTask] = AppState.loadTasks() {
        didSet { AppState.saveJSON(workTasks, "workTasks"); scheduleICloudPush() }
    }
    static func loadTeams() -> [Team] { loadJSON("teams") ?? [] }
    static func loadTasks() -> [WorkTask] { loadJSON("workTasks") ?? [] }
    static func loadJSON<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func saveJSON<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    // Employees currently handling a delegated task (so they show a spinner too).
    @Published var busyEmployeeIds: Set<String> = []

    /// True if this employee is actively working now (its own turn streaming, or a
    /// delegated task running) — drives the spinner in the sidebar / company view.
    func isEmployeeBusy(_ id: String) -> Bool {
        busyEmployeeIds.contains(id) || (activeEmployeeId == id && isStreaming)
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

    // MARK: - Cost / usage (Phase 3)

    @Published var usageByEmployee: [String: EmployeeUsage] = [:]
    @Published var totalTokens: Int = 0
    @Published var totalCostUSD: Double = 0   // this calendar month
    // Monthly budget (USD); 0 = unset. Drives the budget bar + over-budget warning.
    @Published var monthlyBudgetUSD: Double = UserDefaults.standard.double(forKey: "monthlyBudgetUSD") {
        didSet { UserDefaults.standard.set(monthlyBudgetUSD, forKey: "monthlyBudgetUSD") }
    }

    /// Spend as a fraction of budget (capped at 1.0 for the bar fill).
    var budgetFraction: Double { monthlyBudgetUSD > 0 ? min(totalCostUSD / monthlyBudgetUSD, 1.0) : 0 }
    /// Uncapped ratio (so >1.0 means over budget).
    var budgetRatio: Double { monthlyBudgetUSD > 0 ? totalCostUSD / monthlyBudgetUSD : 0 }
    /// 0 = ok, 1 = warning (>=80%), 2 = over (>=100%).
    var budgetState: Int { monthlyBudgetUSD <= 0 ? 0 : (budgetRatio >= 1.0 ? 2 : (budgetRatio >= 0.8 ? 1 : 0)) }
    /// Start of the current calendar month (epoch seconds).
    private var startOfMonthEpoch: Double {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))?.timeIntervalSince1970 ?? 0
    }

    /// Rough blended price ($ per 1M tokens, in+out averaged) per model — for estimates only.
    static func blendedRatePerMTok(_ model: String) -> Double {
        let m = model.lowercased()
        if m.contains(":free") || m.contains("nemotron") { return 0 }
        if m.contains("claude") && m.contains("opus") { return 30 }
        if m.contains("claude") && m.contains("sonnet") { return 9 }
        if m.contains("claude") && m.contains("haiku") { return 2.5 }
        if m.contains("gpt-4o-mini") || m.contains("4.1-mini") || m.contains("4o-mini") { return 0.4 }
        if m.contains("gpt-4o") || m.contains("gpt-4.1") || m.contains("o3") { return 6 }
        if m.contains("gemini") && m.contains("flash") { return 0.2 }
        if m.contains("gemini") && m.contains("pro") { return 3 }
        return 1.0   // unknown model → conservative default
    }

    /// Recompute THIS MONTH's per-employee tokens + estimated cost from state.db.
    func refreshUsage() {
        let totals = StateDB.shared.tokenTotalsBySession(since: startOfMonthEpoch)
        var byEmp: [String: EmployeeUsage] = [:]
        for emp in employees {
            var sids = Set(sessionOwner.filter { $0.value == emp.id }.map { $0.key })
            if let cur = emp.sessionId { sids.insert(cur) }
            var u = EmployeeUsage()
            for sid in sids {
                let t = totals[sid] ?? 0
                if t > 0 { u.tokens += t; u.sessions += 1 }
            }
            u.costUSD = Double(u.tokens) / 1_000_000 * AppState.blendedRatePerMTok(emp.model)
            byEmp[emp.id] = u
        }
        usageByEmployee = byEmp
        totalTokens = byEmp.values.reduce(0) { $0 + $1.tokens }
        totalCostUSD = byEmp.values.reduce(0) { $0 + $1.costUSD }
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

    private func pushEmployees() async {
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
            if icloudSyncEnabled { Task { await syncRosterNow() }; startICloudLiveSync() }
            else { stopICloudLiveSync() }
        }
    }
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
        return CloudKitSync.RosterPayload(employees: emps, teams: teams,
                                          tasks: workTasks, tombstones: prunedTombstones())
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
    }

    /// Full sync: pull cloud, merge, then push the merged result.
    func syncRosterNow() async {
        guard icloudSyncEnabled else { icloudStatus = "iCloud同期がオフです"; return }
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
        guard icloudSyncEnabled, !isApplyingRemote else { return }
        icloudPushTask?.cancel()
        icloudPushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pushRosterOnly()
        }
    }

    private func pushRosterOnly() async {
        guard icloudSyncEnabled else { return }
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
        guard icloudSyncEnabled else { icloudStatus = "iCloud同期がオフです"; return }
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
        guard icloudSyncEnabled, icloudMirrorMessages, !isMirroringMessages else { return }
        mirrorPushTask?.cancel()
        mirrorPushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.mirrorMessagesNow()
        }
    }

    /// Read the mirror back from CloudKit to confirm the one-way round-trip works.
    func verifyCloudHistory() async {
        guard icloudSyncEnabled else { icloudStatus = "iCloud同期がオフです"; return }
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
        guard icloudSyncEnabled else { return }
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
        guard icloudSyncEnabled else { livePollTask = nil; return }
        let interval = livePollInterval
        livePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self, self.icloudSyncEnabled else { break }
                await self.pullRosterOnly()
            }
        }
    }

    func stopICloudLiveSync() { livePollTask?.cancel(); livePollTask = nil }

    /// The working directory the agent runs in: active employee's workspace, else the
    /// selected GitHub repo, else home.
    var effectiveCwd: String { activeEmployee?.workspacePath ?? selectedRepoPath ?? NSHomeDirectory() }

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

    private var activeProcess: Process? = nil

    // Store-sync: detect state.db changes (from iPhone/cron/etc.) and refresh the UI.
    private var storeSyncTimer: Task<Void, Never>? = nil
    private var lastStoreToken: String = ""

    private init() {
        // Clean up child processes / timers when the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        // Pull other devices' roster edits the moment the app regains focus.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.icloudSyncEnabled else { return }
                Task { await self.pullRosterOnly() }
            }
        }
        Task {
            await fetchSessions()
            await fetchConfig()
            await loadApiKey()
            await updateDashboardURL()
            await fetchPlugins()
            await fetchAvailableModels()
            setupACPPermissions()
            if cloudSyncEnabled { await syncEmployeesNow() }
            if icloudSyncEnabled { await syncRosterNow() }
            startICloudLiveSync()

            // Auto-start mobile server for iOS connectivity
            MobileServer.shared.start()
            self.isMobileServerRunning = true

            // Keep the LINE bridge (bridge.py on :8650) running so LINE always works.
            await startLineBridge()

            // Reflect changes made from other devices (iPhone/iPad) or sources (cron).
            startStoreSync()
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
        activeProcess?.terminate(); activeProcess = nil
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
                        // Don't consume the token while streaming our own reply — only
                        // refresh the sidebar; reconcile the open conversation once the
                        // stream finishes (otherwise the view can stay stale).
                        await self.fetchSessions()
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
        guard apnsEnabled, !apnsKeyId.isEmpty, !apnsKeyPath.isEmpty, !pushDeviceTokens.isEmpty else { return }
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
        // Keep the existing list on a transient empty read (e.g. DB momentarily locked),
        // rather than clearing the sidebar.
        guard !rows.isEmpty || sessions.isEmpty else { return }
        self.sessions = rows.map { r in
            // Defensive: strip any mode-directive sentinel that leaked into title/preview.
            let cleanTitle = AgentMode.strip(r.title)
            let cleanPreview = AgentMode.strip(r.preview)
            let title = cleanTitle.isEmpty ? (cleanPreview.isEmpty ? "(無題)" : String(cleanPreview.prefix(30))) : cleanTitle
            return Session(id: r.id, title: title, preview: String(cleanPreview.prefix(60)), lastActive: "")
        }
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
                        if let prov = dict["provider"] as? String {
                            self.provider = prov
                        }
                        if let def = dict["default"] as? String {
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
        // A new chat for the active employee starts a fresh isolated thread.
        if let empId = activeEmployeeId, let idx = employees.firstIndex(where: { $0.id == empId }) {
            employees[idx].sessionId = nil
        }
        ACPClient.shared.resetSession()   // start a fresh ACP session for the new chat
    }
    
    func handleSelectSession(_ session: Session) {
        self.currentSessionId = session.id
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
        // Drop any live ACP session so the next send resumes THIS session (resumeHermesSessionId).
        ACPClient.shared.resetSession()
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
    
    func handleSendMessage() {
        let text = inputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgData = attachedImageData
        guard (!text.isEmpty || imgData != nil) && !isStreaming else { return }

        // Optional image → temp file for the CLI's --image flag.
        let imagePath: String? = imgData.flatMap { writeTempImage($0) }

        self.messages.append(Message(role: .user, content: text, imageData: imgData))
        self.inputValue = ""
        self.attachedImageData = nil
        self.isStreaming = true
        self.activeStatus = "thinking"
        self.streamText = ""

        // Single assistant bubble updated in place (stable id) so the typewriter
        // animation reveals characters continuously without restarting.
        let assistantId = UUID()
        self.messages.append(Message(id: assistantId, role: .assistant, content: "", typewriter: true))

        let effectivePrompt = (text.isEmpty && imagePath != nil) ? "添付した画像について説明してください。" : text
        // Append the active employee's persona + chat/code mode directive (sentinel-stripped from display).
        let sentPrompt = wrapForSend(effectivePrompt)

        // H1: structured ACP transport (clean text + tokens, foundation for tool viz).
        if useACPTransport {
            sendViaACP(assistantId: assistantId, prompt: sentPrompt, imagePath: imagePath)
            return
        }

        self.activeProcess = HermesCLI.shared.streamPrompt(
            prompt: sentPrompt,
            sessionId: currentSessionId,
            imagePath: imagePath,
            cwd: effectiveCwd,
            onData: { [weak self] chunk in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.streamText += chunk
                    let cleaned = self.parseResponseText(self.streamText)
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                        self.messages[idx].content = cleaned
                    }
                }
            },
            onStderr: { chunk in
                print("CLI stderr: \(chunk)")
            },
            onEnd: { [weak self] code in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.isStreaming = false
                    self.activeStatus = "online"
                    self.activeProcess = nil

                    let cleaned = self.parseResponseText(self.streamText)
                    self.streamText = ""
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                        if cleaned.isEmpty {
                            // Empty reply → show a clear error + retry (was silently dropped).
                            self.messages[idx].content = "応答がありませんでした。モデルが応答していない可能性があります（モデルを確認）。"
                            self.messages[idx].isError = true
                            self.messages[idx].typewriter = false
                        } else {
                            self.messages[idx].content = cleaned
                        }
                    }
                    if let imagePath = imagePath {
                        try? FileManager.default.removeItem(atPath: imagePath)
                    }

                    Task {
                        await self.fetchSessions()

                        // If it was a new session, auto-resume the latest one (exact id from the store)
                        if self.currentSessionId == nil {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            await self.fetchSessions()
                            if let first = self.sessions.first {
                                self.currentSessionId = first.id
                            }
                        }
                        self.bindCurrentSessionToActiveEmployee()
                    }
                }
            }
        )
    }
    
    /// H1 thin slice: stream a reply via the ACP transport (structured, clean text + tokens).
    private func sendViaACP(assistantId: UUID, prompt: String, imagePath: String?) {
        Task { [weak self] in
            guard let self = self else { return }
            // Ensure the active employee's model config is applied before the session starts.
            await self.modelApplyTask?.value
            var acc = ""
            let (tokens, ok) = await ACPClient.shared.prompt(
                prompt,
                imagePath: imagePath,
                cwd: effectiveCwd,
                // Resume the active session (employee/selected) so context isn't lost;
                // no id → a brand-new session.
                resumeHermesSessionId: currentSessionId,
                startFresh: currentSessionId == nil,
                onChunk: { [weak self] chunk in
                    guard let self = self else { return }
                    acc += chunk
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                        self.messages[idx].content = acc   // ACP text is already clean (no banner/ANSI)
                    }
                },
                onThought: { [weak self] t in
                    guard let self = self else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                        self.messages[idx].thinking += t
                    }
                },
                onToolActivity: { [weak self] calls in
                    guard let self = self else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                        self.messages[idx].toolCalls = calls
                    }
                }
            )
            self.isStreaming = false
            self.activeStatus = "online"
            if let imagePath = imagePath { try? FileManager.default.removeItem(atPath: imagePath) }

            if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                if acc.isEmpty {
                    // Empty reply (failed or model returned nothing) → show a clear error + retry.
                    self.messages[idx].content = ok
                        ? "応答がありませんでした。モデルが応答していない可能性があります（モデルを確認）。"
                        : "応答に失敗しました。接続やモデル設定を確認してください。"
                    self.messages[idx].isError = true
                    self.messages[idx].typewriter = false
                } else {
                    self.messages[idx].content = acc
                    self.messages[idx].tokens = tokens
                }
            }
            // Reconcile to the session ACP actually used (new or resumed) so the UI and
            // the employee record both follow it — not a stale id.
            if let hsid = ACPClient.shared.hermesSessionId {
                self.currentSessionId = hsid
            }
            self.bindCurrentSessionToActiveEmployee()
            await self.fetchSessions()
        }
    }

    func cancelStreaming() {
        if let proc = activeProcess {
            proc.terminate()
            activeProcess = nil
        }
        self.isStreaming = false
        self.activeStatus = "online"
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
        attachedImageData = img
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
    
    // Quick model presets for the in-composer switcher.
    struct ModelPreset: Identifiable {
        let id = UUID()
        let label: String
        let provider: String
        let model: String
    }

    /// One model from the live OpenRouter catalog (dynamic list).
    struct ModelOption: Identifiable, Equatable {
        let id: String      // "anthropic/claude-opus-4.8"
        let name: String    // display name
        var provider: String { id.contains("/") ? String(id.split(separator: "/")[0]) : "other" }
    }

    /// Live catalog (fetched from OpenRouter) so the picker never goes stale/404.
    @Published var availableModels: [ModelOption] = []

    /// Catalog grouped by provider for the picker submenus.
    var modelsByProvider: [(provider: String, models: [ModelOption])] {
        Dictionary(grouping: availableModels) { $0.provider }
            .map { (provider: $0.key, models: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.provider < $1.provider }
    }

    /// Fetch the OpenRouter model catalog (valid, current IDs) for the picker.
    func fetchAvailableModels() async {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        let key = HermesCLI.shared.getApiKey(provider: "openrouter")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["data"] as? [[String: Any]] else { return }
            var opts: [ModelOption] = []
            for m in arr {
                guard let id = m["id"] as? String else { continue }
                opts.append(ModelOption(id: id, name: (m["name"] as? String) ?? id))
            }
            self.availableModels = opts.sorted { $0.id < $1.id }
            Log.app.info("loaded \(self.availableModels.count) models from OpenRouter")
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

    // MARK: - GitHub workspace

    /// Run `gh ...` via the login-shell environment (resolves /opt/homebrew/bin/gh).
    private func runGH(_ args: [String]) async -> (success: Bool, stdout: String, stderr: String) {
        await HermesCLI.shared.execCommand("/usr/bin/env", ["gh"] + args)
    }

    /// Fetch the signed-in account + the user's repositories via the gh CLI.
    func fetchGitHubRepos() async {
        isFetchingRepos = true
        defer { isFetchingRepos = false }

        let acc = await runGH(["api", "user", "--jq", ".login"])
        if acc.success {
            let login = acc.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !login.isEmpty { self.githubAccount = login }
        }

        let res = await runGH(["repo", "list", "--json", "nameWithOwner,description,isPrivate,updatedAt,primaryLanguage", "--limit", "100"])
        guard res.success,
              let data = res.stdout.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if !res.success { triggerToast(message: "GitHubリポジトリの取得に失敗しました") }
            return
        }
        self.githubRepos = arr.compactMap { item in
            guard let slug = item["nameWithOwner"] as? String, !slug.isEmpty else { return nil }
            let lang = (item["primaryLanguage"] as? [String: Any])?["name"] as? String ?? ""
            return GitHubRepo(
                nameWithOwner: slug,
                description: item["description"] as? String ?? "",
                isPrivate: item["isPrivate"] as? Bool ?? false,
                updatedAt: item["updatedAt"] as? String ?? "",
                language: lang
            )
        }
    }

    /// Local path under the clone base if the repo is already cloned, else nil.
    func localPath(for repo: GitHubRepo) -> String? {
        let p = (githubCloneBase as NSString).appendingPathComponent(repo.name)
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Clone a repo under the clone base, then set it as the working folder.
    func cloneRepo(_ repo: GitHubRepo) async {
        cloningRepo = repo.nameWithOwner
        defer { cloningRepo = nil }
        try? FileManager.default.createDirectory(atPath: githubCloneBase, withIntermediateDirectories: true)
        let target = (githubCloneBase as NSString).appendingPathComponent(repo.name)
        if FileManager.default.fileExists(atPath: target) {
            setWorkspace(path: target, slug: repo.nameWithOwner)
            return
        }
        let res = await runGH(["repo", "clone", repo.nameWithOwner, target])
        if res.success {
            setWorkspace(path: target, slug: repo.nameWithOwner)
        } else {
            triggerToast(message: "cloneに失敗しました: \(repo.name)")
        }
    }

    /// Point the agent at a local repo (cwd) and start a fresh chat scoped to it.
    func setWorkspace(path: String, slug: String) {
        selectedRepoPath = path
        selectedRepoSlug = slug
        handleNewChat()        // resets the ACP session → next prompt uses the new cwd
        view = "chat"
        showSettings = false
        triggerToast(message: "作業フォルダ: \(slug)")
    }

    /// Clear the workspace → back to the home directory.
    func clearWorkspace() {
        selectedRepoPath = nil
        selectedRepoSlug = nil
        handleNewChat()
        triggerToast(message: "作業フォルダを解除しました（ホーム）")
    }

    // MARK: - AI employees ("会社")

    /// Hire a new employee with role defaults. Returns the created employee.
    @discardableResult
    func hireEmployee(name: String, role: EmployeeRole) -> Employee {
        let emp = Employee.make(name: name.trimmingCharacters(in: .whitespacesAndNewlines), role: role)
        employees.append(emp)
        triggerToast(message: "\(emp.role.title)「\(emp.name)」を採用しました")
        if cloudSyncEnabled { Task { await pushEmployees() } }
        return emp
    }

    /// Fire (remove) an employee, with an Undo toast (avatar kept for restore).
    func fireEmployee(_ id: String) {
        guard let removed = employees.first(where: { $0.id == id }) else { return }
        employees.removeAll { $0.id == id }
        tombstone(id)
        if activeEmployeeId == id { switchEmployee(nil) }
        if cloudSyncEnabled { Task { await deleteCloudEmployee(id) } }
        triggerToast(message: "\(removed.role.title)「\(removed.name)」を解雇しました", actionLabel: "取り消し") { [weak self] in
            guard let self = self, !self.employees.contains(where: { $0.id == removed.id }) else { return }
            self.syncTombstones[removed.id] = nil      // undo the delete: clear its tombstone
            var restored = removed
            restored.updatedAt = Date().timeIntervalSince1970   // beat any stale tombstone on other devices
            self.employees.append(restored)
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
        guard !isStreaming else { triggerToast(message: "応答中は切り替えできません"); return }
        // Persist the current conversation's session onto the outgoing employee.
        if let curId = activeEmployeeId, let idx = employees.firstIndex(where: { $0.id == curId }) {
            employees[idx].sessionId = currentSessionId
            recordSessionOwner(currentSessionId, curId)
        }
        activeEmployeeId = id
        if let emp = activeEmployee {
            agentMode = emp.mode
            currentSessionId = emp.sessionId
            messages = emp.sessionId.map { messagesFromStore($0) } ?? []
            modelApplyTask = Task { await applyModelSilently(provider: emp.provider, model: emp.model) }
        } else {
            currentSessionId = nil
            messages = []
            modelApplyTask = nil
        }
        inputValue = ""
        ACPClient.shared.resetSession()   // next prompt uses the new model/cwd/session
        view = "chat"
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
                                delegatedName: target.name, delegatedRole: target.role))
        isStreaming = true
        activeStatus = "thinking"
        busyEmployeeIds.insert(employeeId)   // the specialist is now working (spinner)
        recordSessionOwner(target.sessionId, employeeId)
        let started = Date()

        let directive = "あなたは「\(target.name)」という名前の\(target.role.title)です。\(target.persona) \(target.mode.directive)"
        let wrapped = "\(trimmed)\n\n\(AgentMode.sentinelOpen)\(directive)\(AgentMode.sentinelClose)"
        let cwd = target.workspacePath ?? effectiveCwd
        var acc = ""

        // Run the delegated task on the specialist's own model, then restore the
        // manager's. Best-effort: a resumed ACP session may keep its original model.
        await modelApplyTask?.value
        let mgrProvider = provider, mgrModel = defaultModel
        let swapModel = (target.provider != mgrProvider || target.model != mgrModel)
        if swapModel { await setHermesModelConfig(provider: target.provider, model: target.model) }

        if useACPTransport {
            let (delTokens, ok) = await ACPClient.shared.prompt(
                wrapped, cwd: cwd,
                resumeHermesSessionId: target.sessionId,
                startFresh: target.sessionId == nil,
                onChunk: { [weak self] chunk in
                    guard let self = self else { return }
                    acc += chunk
                    if let i = self.messages.firstIndex(where: { $0.id == msgId }) { self.messages[i].content = acc }
                }
            )
            // Only adopt a brand-new specialist session; never overwrite an existing id
            // (a silently-forked failed session/load must not orphan the real session).
            if target.sessionId == nil,
               let ti = employees.firstIndex(where: { $0.id == employeeId }),
               let hsid = ACPClient.shared.hermesSessionId {
                employees[ti].sessionId = hsid
                recordSessionOwner(hsid, employeeId)
            }
            if let i = messages.firstIndex(where: { $0.id == msgId }) {
                messages[i].typewriter = false
                messages[i].elapsed = Date().timeIntervalSince(started)
                if let t = delTokens { messages[i].tokens = t }
                if acc.isEmpty { messages[i].content = ok ? "(空の応答)" : "委譲に失敗しました"; messages[i].isError = !ok }
            }
            // The shared ACP client now holds the specialist's session; reset so the
            // manager's next message resumes the manager's session.
            ACPClient.shared.resetSession()
        } else {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                _ = HermesCLI.shared.streamPrompt(
                    prompt: wrapped, sessionId: target.sessionId, cwd: cwd,
                    onData: { [weak self] chunk in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            acc += chunk
                            if let i = self.messages.firstIndex(where: { $0.id == msgId }) {
                                self.messages[i].content = self.parseResponseText(acc)
                            }
                        }
                    },
                    onStderr: { _ in },
                    onEnd: { _ in DispatchQueue.main.async { cont.resume() } }
                )
            }
            if target.sessionId == nil {
                await fetchSessions()
                if let ti = employees.firstIndex(where: { $0.id == employeeId }), let first = sessions.first {
                    employees[ti].sessionId = first.id
                    recordSessionOwner(first.id, employeeId)
                }
            }
            if let i = messages.firstIndex(where: { $0.id == msgId }) {
                messages[i].typewriter = false
                messages[i].elapsed = Date().timeIntervalSince(started)
                let cleaned = parseResponseText(acc)
                if cleaned.isEmpty { messages[i].content = "委譲に失敗しました"; messages[i].isError = true }
                else { messages[i].content = cleaned }
            }
        }

        if swapModel { await setHermesModelConfig(provider: mgrProvider, model: mgrModel) }
        busyEmployeeIds.remove(employeeId)
        isStreaming = false
        activeStatus = "online"
        await fetchSessions()
    }

    /// Set the hermes model config WITHOUT touching the published provider/defaultModel
    /// (used to temporarily run a delegated task on a specialist's model, then restore).
    private func setHermesModelConfig(provider: String, model: String) async {
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.provider", provider])
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.default", model])
        let baseUrl = provider == "openrouter" ? "https://openrouter.ai/api/v1" : ""
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.base_url", baseUrl])
    }

    // MARK: - Teams (Phase A)

    func employees(inTeam teamId: String) -> [Employee] { employees.filter { $0.teamId == teamId } }
    var unassignedEmployees: [Employee] { employees.filter { $0.teamId == nil } }

    @discardableResult
    func createTeam(name: String) -> Team {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var t = Team(name: n.isEmpty ? "新しいチーム" : n)
        t.updatedAt = Date().timeIntervalSince1970
        teams.append(t)
        return t
    }
    func assignEmployee(_ empId: String, toTeam teamId: String?) {
        guard let idx = employees.firstIndex(where: { $0.id == empId }) else { return }
        employees[idx].teamId = teamId
        employees[idx].updatedAt = Date().timeIntervalSince1970
        if cloudSyncEnabled { Task { await pushEmployees() } }
    }
    func setTeamManager(_ teamId: String, managerId: String?) {
        guard let idx = teams.firstIndex(where: { $0.id == teamId }) else { return }
        teams[idx].managerId = managerId
        teams[idx].updatedAt = Date().timeIntervalSince1970
    }
    func renameTeam(_ teamId: String, name: String) {
        guard let idx = teams.firstIndex(where: { $0.id == teamId }) else { return }
        teams[idx].name = name
        teams[idx].updatedAt = Date().timeIntervalSince1970
    }
    func deleteTeam(_ teamId: String) {
        tombstone(teamId)
        teams.removeAll { $0.id == teamId }
        for i in employees.indices where employees[i].teamId == teamId {
            employees[i].teamId = nil
            employees[i].updatedAt = Date().timeIntervalSince1970
        }
    }

    // MARK: - Tasks (Phase B)

    @discardableResult
    func createTask(title: String, assigneeId: String?) -> WorkTask {
        var t = WorkTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        t.assigneeId = assigneeId
        workTasks.insert(t, at: 0)
        return t
    }
    func setTaskStatus(_ taskId: String, _ status: TaskStatus) {
        guard let idx = workTasks.firstIndex(where: { $0.id == taskId }) else { return }
        workTasks[idx].status = status
        workTasks[idx].updatedAt = Date().timeIntervalSince1970
    }
    func assignTask(_ taskId: String, to assigneeId: String?) {
        guard let idx = workTasks.firstIndex(where: { $0.id == taskId }) else { return }
        workTasks[idx].assigneeId = assigneeId
        workTasks[idx].updatedAt = Date().timeIntervalSince1970
    }
    func deleteTask(_ taskId: String) {
        tombstone(taskId)
        workTasks.removeAll { $0.id == taskId }
    }
    func tasks(status: TaskStatus) -> [WorkTask] { workTasks.filter { $0.status == status } }

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

    // MARK: - Model validation (hide non-working models)

    /// Test an OpenRouter model with a 1-token request; record + return whether it works.
    /// Only a definitive client error (400/401/402/403/404) marks a model broken — transient
    /// conditions (429/5xx/timeout) leave health unknown so a model isn't wrongly hidden.
    /// Note: this is a real (billable) completion for paid models.
    @discardableResult
    func validateModel(_ id: String) async -> Bool {
        let key = HermesCLI.shared.getApiKey(provider: "openrouter")
        guard !key.isEmpty, let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            return modelHealth[id] ?? true   // no key → can't test; leave unknown
        }
        validatingModelId = id
        defer { if validatingModelId == id { validatingModelId = nil } }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": id, "messages": [["role": "user", "content": "hi"]], "max_tokens": 1]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var works = true
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["error"] != nil { works = false }
                modelHealth[id] = works
                return works
            } else if [400, 401, 402, 403, 404].contains(code) {
                modelHealth[id] = false   // bad model / no access / no credits → unusable
                return false
            } else {
                return modelHealth[id] ?? true   // 429/5xx etc → transient, keep prior/unknown
            }
        } catch {
            return modelHealth[id] ?? true   // timeout/network → unknown, don't mark broken
        }
    }

    /// Re-validate the recommended presets (+ the default when on OpenRouter). Runs the
    /// pings concurrently and keeps the set small/fast.
    func revalidatePresets() async {
        isValidatingModels = true
        defer { isValidatingModels = false }
        var ids = Set(AppState.modelPresets.map { $0.model })
        if provider == "openrouter" { ids.insert(defaultModel) }   // don't test a non-OR model against OR
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { [weak self] in _ = await self?.validateModel(id) } }
        }
        triggerToast(message: "おすすめモデルを検証しました")
    }

    /// True if the model is proven non-working AND the hide toggle is on. The currently
    /// selected model is never hidden (so the user can always see their own choice).
    func modelIsHidden(_ id: String) -> Bool { id != defaultModel && hideBrokenModels && modelHealth[id] == false }

    /// Quietly apply a model (no toast) — used on employee switch.
    func applyModelSilently(provider: String, model: String) async {
        self.provider = provider
        self.defaultModel = model
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.provider", provider])
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.default", model])
        let baseUrl = provider == "openrouter" ? "https://openrouter.ai/api/v1" : ""
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.base_url", baseUrl])
        await loadApiKey()
    }

    /// Switch the active model (and provider) from the composer, persisting to the CLI config.
    func setModel(provider: String, model: String) async {
        await applyModelSilently(provider: provider, model: model)
        // Persist onto the active employee so their default follows them.
        if let empId = activeEmployeeId, let idx = employees.firstIndex(where: { $0.id == empId }) {
            employees[idx].provider = provider
            employees[idx].model = model
            employees[idx].updatedAt = Date().timeIntervalSince1970
            if cloudSyncEnabled { Task { await pushEmployees() } }
        }
        triggerToast(message: "モデルを変更しました: \(model)")
    }

    /// Set just the model id, keeping the current provider (for custom entry).
    func setCustomModel(_ model: String) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await setModel(provider: provider, model: trimmed)
    }

    // Provider selection helper
    func handleProviderChange(_ newProvider: String) {
        self.provider = newProvider
        switch newProvider {
        case "openrouter":
            self.defaultModel = "nvidia/nemotron-3-super-120b-a12b:free"
        case "openai":
            self.defaultModel = "gpt-4o-mini"
        case "anthropic":
            self.defaultModel = "claude-3-5-sonnet-20241022"
        case "gemini":
            self.defaultModel = "gemini-2.5-flash"
        case "nous":
            self.defaultModel = "anthropic/claude-3-5-sonnet-latest"
        case "xai-oauth":
            self.defaultModel = "grok-beta"
        case "openai-codex":
            self.defaultModel = "code-davinci-002"
        default:
            break
        }
        
        Task {
            await loadApiKey()
        }
    }
    
    // Save Settings Config
    func handleSaveSettings() async {
        self.isSavingSettings = true
        
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.provider", provider])
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.default", defaultModel])
        
        let baseUrl = provider == "openrouter" ? "https://openrouter.ai/api/v1" : ""
        _ = await HermesCLI.shared.exec(args: ["config", "set", "model.base_url", baseUrl])
        _ = await HermesCLI.shared.exec(args: ["config", "set", "display.personality", personality])
        
        if !["nous", "xai-oauth", "openai-codex"].contains(provider) {
            _ = HermesCLI.shared.saveApiKey(provider: provider, key: apiKey)
        }
        
        triggerToast(message: "設定を保存しました。")
        await fetchConfig()
        self.isSavingSettings = false
    }
    
    // Trigger OAuth Auth command
    func triggerOAuthLogin() async {
        triggerToast(message: "ブラウザを起動して認証を開始します...")
        let res = await HermesCLI.shared.exec(args: ["auth", "add", provider, "--type", "oauth"])
        if res.success {
            triggerToast(message: "認証が完了しました。")
        } else {
            triggerToast(message: "認証エラーが発生しました。")
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
        if let host = HermesCLI.shared.getTailscaleHostname() {
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
                
                if components[0] == "not" && components[1] == "enabled" {
                    status = "not enabled"
                    source = components[2]
                    version = components[3]
                    name = components[4]
                } else {
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
    
    // MARK: - Channels (messaging recipients)

    private var channelDirectoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/channel_directory.json")
    }

    func fetchChannels() {
        guard let data = try? Data(contentsOf: channelDirectoryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platforms = json["platforms"] as? [String: Any] else {
            self.channels = []
            return
        }
        var result: [HermesChannel] = []
        for (platform, value) in platforms {
            guard let list = value as? [[String: Any]] else { continue }
            for item in list {
                let cid = (item["id"] as? String) ?? (item["id"] as? Int).map(String.init) ?? ""
                guard !cid.isEmpty else { continue }
                result.append(HermesChannel(
                    platform: platform,
                    channelId: cid,
                    name: (item["name"] as? String) ?? cid,
                    type: (item["type"] as? String) ?? "dm"
                ))
            }
        }
        self.channels = result.sorted { $0.platform < $1.platform }
    }

    func addChannel() {
        let platform = newChannelPlatform.trimmingCharacters(in: .whitespacesAndNewlines)
        let cid = newChannelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = newChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !platform.isEmpty, !cid.isEmpty else {
            triggerToast(message: "プラットフォームとIDを入力してください。")
            return
        }

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: channelDirectoryURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        var platforms = (json["platforms"] as? [String: Any]) ?? [:]
        var list = (platforms[platform] as? [[String: Any]]) ?? []
        if !list.contains(where: { ($0["id"] as? String) == cid }) {
            list.append(["id": cid, "name": name.isEmpty ? cid : name, "type": "dm", "thread_id": NSNull()])
        }
        platforms[platform] = list
        json["platforms"] = platforms
        json["updated_at"] = ISO8601DateFormatter().string(from: Date())

        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? out.write(to: channelDirectoryURL)
            triggerToast(message: "チャンネルを追加しました。")
            newChannelId = ""
            newChannelName = ""
            fetchChannels()
        } else {
            triggerToast(message: "保存に失敗しました。")
        }
    }

    func removeChannel(_ channel: HermesChannel) {
        guard let data = try? Data(contentsOf: channelDirectoryURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var platforms = json["platforms"] as? [String: Any],
              var list = platforms[channel.platform] as? [[String: Any]] else { return }
        list.removeAll { ($0["id"] as? String) == channel.channelId }
        platforms[channel.platform] = list
        json["platforms"] = platforms
        json["updated_at"] = ISO8601DateFormatter().string(from: Date())
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? out.write(to: channelDirectoryURL)
            fetchChannels()
        }
    }

    func testSendChannel(_ channel: HermesChannel) async {
        triggerToast(message: "\(channel.name) にテスト送信中...")
        let message = "Hermes Agent テスト通知です ✅"
        let res: (success: Bool, stdout: String, stderr: String)
        if channel.platform.lowercased() == "line" {
            // LINE is wired through the custom bridge (line-send.sh) in this setup,
            // not `hermes send` (which has no LINE home channel and would error).
            let script = NSHomeDirectory() + "/.hermes/line-bridge/line-send.sh"
            res = await HermesCLI.shared.execCommand("/bin/bash", [script, channel.channelId, message])
        } else {
            let target = "\(channel.platform):\(channel.channelId)"
            res = await HermesCLI.shared.exec(args: ["send", "-t", target, message])
        }
        if res.success {
            triggerToast(message: "送信しました。")
        } else {
            // Surface the actual reason instead of a generic failure.
            let err = (res.stderr.isEmpty ? res.stdout : res.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            triggerToast(message: "送信に失敗: \(String(err.prefix(90)))")
        }
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
        triggerToast(message: "提案をフォームに反映しました。内容を確認して『タスクを作成』。")
    }

    /// Ask the agent to propose automations (best-effort; parsed from pipe-delimited lines).
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
                    lastRun: currentLastRun
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

    func handleCreateCronJob() async {
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
            return
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
