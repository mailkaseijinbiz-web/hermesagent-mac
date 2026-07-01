import SwiftUI

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var sidebarWidth: CGFloat = 260
    @State private var resizeHovered = false
    @State private var rightSidebarWidth: CGFloat = 360
    @State private var showModelSelection = false
    
    var body: some View {
        ZStack {
            mainContent

            // Hidden ⌘K trigger for the command palette.
            Button("") { appState.showCommandPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)

            // Settings modal dialog (dimmed backdrop + centered card).
            if appState.showSettings {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { appState.showSettings = false }
                SettingsModal()
                    .environmentObject(appState)
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
            }

            // Command palette (⌘K): dimmed backdrop + top-anchored panel.
            if appState.showCommandPalette {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { appState.showCommandPalette = false }
                CommandPaletteView()
                    .environmentObject(appState)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 90)
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.showSettings)
        .animation(.easeInOut(duration: 0.12), value: appState.showCommandPalette)
        .background(WindowConfigurator(dx: 8, dy: 6))   // inset traffic lights (down + right)
        // Toast above everything (including the settings modal) so confirmations show.
        .overlay(alignment: .bottom) {
            if appState.showToast {
                ToastView(message: appState.toastMessage)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 30)
            }
        }
        .animation(.easeInOut, value: appState.showToast)
        .onChange(of: appState.view) { _, _ in
            appState.mainScrollOffset = 0
        }
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: sidebarWidth)
                .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
                .ignoresSafeArea()
            
            // Resize handler bar — divider line only appears on hover (no faint line at rest).
            Color.clear
                .frame(width: 5)
                .contentShape(Rectangle())
                .onHover { hovering in
                    resizeHovered = hovering
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let newWidth = sidebarWidth + value.translation.width
                            sidebarWidth = max(200, min(newWidth, 450))
                        }
                )
                .overlay(
                    Rectangle()
                        .fill(Color.primary.opacity(resizeHovered ? 0.15 : 0))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity),
                    alignment: .center
                )
                .animation(.easeInOut(duration: 0.15), value: resizeHovered)
            
            HStack(spacing: 0) {
                ZStack(alignment: .top) {
                    if colorScheme == .dark {
                        Color(red: 0.07, green: 0.07, blue: 0.08) // #121214
                            .ignoresSafeArea()
                    } else {
                        Color.white
                            .ignoresSafeArea()
                    }

                    if appState.view == "chat" {
                        ChatView()
                    } else if appState.view == "home" || appState.view == "dashboard" || appState.view == "lifelog" {
                        MacLifeLogView()
                    } else if appState.view == "company" {
                        CompanyView()
                    } else if appState.view == "employee" {
                        EmployeeDetailView()
                    } else if appState.view == "gmail" {
                        GmailView()
                    } else if appState.view == "schedule" {
                        ScheduleView()
                    } else if appState.view == "tasks" {
                        TasksView()
                    } else if appState.view == "apps" {
                        AppsView()
                    } else if appState.view == "automations" {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onAppear {
                                appState.view = "home"
                                appState.openAutomationsSettings()
                            }
                    } else if appState.view == "news" {
                        MacNewsView()
                    } else if appState.view == "collection" {
                        MacCollectionView()
                    } else {
                        ChatView()
                    }

                    // ヘッダー下のグラデーション（コンテンツが被らないよう徐々に透明に）
                    headerFadeGradient

                    // Header row: title (件名) + workspace badge on the left, action
                    // icons on the right — all on one aligned line with even padding.
                    headerBar
                }

                if appState.showRightSidebar {
                    Group {
                        switch appState.rightTab {
                        case .browser:  BrowserView()
                        case .employee: EmployeeSidePanel()
                        case .terminal: TerminalView()
                        case .history:  ChatHistoryPanel()
                        }
                    }
                    .frame(width: rightSidebarWidth)
                    // Resize handle overlaid on the left edge (above the WKWebView so it
                    // reliably receives the drag). Drag left widens; right narrows.
                    .overlay(alignment: .leading) {
                        Color.black.opacity(0.001)
                            .frame(width: 10)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let newWidth = rightSidebarWidth - value.translation.width
                                        rightSidebarWidth = max(300, min(newWidth, 820))
                                    }
                            )
                    }
                    .transition(.move(edge: .trailing))
                }
            }
        }
    }

    /// Toggle the right sidebar: clicking the active panel's icon closes it; clicking
    /// the other icon switches to that panel (opening the sidebar if needed).
    private func toggleRightSidebar(_ tab: AppState.RightTab) {
        if appState.showRightSidebar && appState.rightTab == tab {
            appState.showRightSidebar = false
        } else {
            appState.rightTab = tab
            appState.showRightSidebar = true
        }
    }

    /// ヘッダー直下に置くグラデーション層。スクロールでコンテンツがヘッダー下に入ったときだけ表示。
    private var headerFadeGradient: some View {
        let bg = colorScheme == .dark
            ? Color(red: 0.07, green: 0.07, blue: 0.08)
            : Color.white
        return LinearGradient(
            stops: [
                .init(color: bg,              location: 0.0),
                .init(color: bg,              location: 0.55),
                .init(color: bg.opacity(0.7), location: 0.75),
                .init(color: bg.opacity(0),   location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 80)
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
        .opacity(headerFadeOpacity)
        .animation(.easeOut(duration: 0.15), value: appState.mainScrollOffset)
    }

    private var headerFadeOpacity: Double {
        let offset = appState.mainScrollOffset
        guard offset > 6 else { return 0 }
        return Double(min(1, (offset - 6) / 18))
    }

    /// The title shown in the header (current chat 件名, or the active section name).
    private var headerTitle: String {
        switch appState.view {
        case "home", "dashboard", "lifelog": return "ホーム"
        case "company": return "社員"
        case "employee": return appState.detailEmployee.map { "\($0.name)（\($0.role.title)）" } ?? "社員"
        case "schedule": return "スケジュール"
        case "tasks": return "タスク"
        case "apps": return "アプリ"
        case "automations": return "オートメーション"
        case "news":        return "ニュース"
        case "collection":  return "コレクション"
        case "settings": return "設定"
        default:
            if let emp = appState.activeEmployee {
                return "\(emp.name)（\(emp.role.title)）"
            }
            if let sid = appState.currentSessionId,
               let s = appState.sessions.first(where: { $0.id == sid }) {
                return s.title
            }
            return "新しいチャット"
        }
    }

    /// Section screens (ホーム/ニュース/タスク/社員) — title only, no status chips or sidebar toggles.
    private var headerIsSectionScreen: Bool {
        switch appState.view {
        case "home", "dashboard", "lifelog", "news", "tasks", "collection", "company", "employee":
            return true
        default:
            return false
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Text(headerTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !headerIsSectionScreen {
                Text(appState.workspaceName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())

            // Activity indicator — is the agent working right now, and is it progressing?
            HStack(spacing: 5) {
                if appState.isStreaming {
                    TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                        let s = LiveStreamStatus.compute(appState: appState, now: ctx.date)
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                            Text(s.label).font(.system(size: 10, weight: .semibold)).foregroundColor(s.color)
                            if let e = s.elapsedText {
                                Text(e).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                            }
                        }
                    }
                } else if !appState.backendHealthy {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text("接続不安定")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                } else {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("待機中")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05))
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.2), value: appState.isStreaming)
            .help(appState.isStreaming ? "エージェントが稼働中です（経過時間と受信状況を表示）"
                  : (appState.backendHealthy ? "待機中（入力できます）"
                     : "バックエンドの応答が不安定です。hermes(ゲートウェイ)を確認してください。"))
            }

            Spacer(minLength: 12)

            // モバイル連携（QRペアリング）は「設定 → モバイル」に集約したのでヘッダーからは撤去。

            if !headerIsSectionScreen {
            Button(action: { toggleRightSidebar(.employee) }) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14))
                    .foregroundColor(appState.showRightSidebar && appState.rightTab == .employee ? .purple : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("社員パネル（タスク・成果物・ファイル）")

            Button(action: { toggleRightSidebar(.browser) }) {
                Image(systemName: "globe")
                    .font(.system(size: 14))
                    .foregroundColor(appState.showRightSidebar && appState.rightTab == .browser ? .purple : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("ブラウザ")

            Button(action: { toggleRightSidebar(.terminal) }) {
                Image(systemName: "terminal")
                    .font(.system(size: 14))
                    .foregroundColor(appState.showRightSidebar && appState.rightTab == .terminal ? .purple : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("ターミナル")
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .frame(height: 52)               // content centered → aligns with inset traffic lights
        .ignoresSafeArea(.container, edges: .top)  // sit in the title-bar band, not below it
    }
}

struct MobileSyncView: View {
    @EnvironmentObject var appState: AppState

    // Both the allowed email and the OAuth client ID (aud) must be set for the gate to admit anyone.
    private var authConfigComplete: Bool {
        !appState.mobileAllowedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !appState.mobileAllowedClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("モバイルと同期")
                .font(.system(size: 14, weight: .bold))

            // Network badge: Tailscale (reachable anywhere) vs local Wi-Fi
            HStack(spacing: 6) {
                Image(systemName: appState.isUsingTailscale ? "lock.shield.fill" : "wifi")
                    .font(.system(size: 11))
                Text(appState.isUsingTailscale ? "Tailscale経由で接続" : "ローカルWi-Fiで接続")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(appState.isUsingTailscale ? .green : .secondary)

            if appState.isMobileServerRunning, let qrImage = appState.qrCodeImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 160, height: 160)
                    .padding(8)
                    .background(Color.white)
                    .cornerRadius(8)

                VStack(spacing: 4) {
                    Text("スマホでスキャンして接続")
                        .font(.system(size: 11, weight: .semibold))
                    Text(appState.dashboardURL)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                ProgressView()
                    .frame(width: 160, height: 160)
            }

            Text(appState.isUsingTailscale
                 ? "※iPhone/iPadもTailscaleにログインしていれば、どのネットワークからでも接続できます。"
                 : "※Macとスマホが同じWi-Fi（ローカルネットワーク）に接続している必要があります。")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(nil)

            Divider()

            // Google Sign-In access gate
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $appState.requireMobileAuth) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.system(size: 9))
                        Text("Google認証を必須にする").font(.system(size: 11, weight: .medium))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if appState.requireMobileAuth {
                    TextField("許可するGoogleメール", text: $appState.mobileAllowedEmail)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    TextField("iOS OAuthクライアントID (xxx.apps.googleusercontent.com)", text: $appState.mobileAllowedClientID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Text(authConfigComplete
                         ? "このアカウント・このアプリでサインインした端末のみ接続できます。"
                         : "⚠️ メールとクライアントID両方を設定するまで、すべての接続を拒否します。")
                        .font(.system(size: 9))
                        .foregroundColor(authConfigComplete ? .secondary.opacity(0.8) : .orange)
                        .lineLimit(nil)
                }
            }

            Divider()

            // APNs push notifications
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $appState.apnsEnabled) {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.badge").font(.system(size: 9))
                        Text("Push通知を有効化").font(.system(size: 11, weight: .medium))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if appState.apnsEnabled {
                    TextField(".p8キーのパス", text: $appState.apnsKeyPath)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    TextField("Key ID (10桁)", text: $appState.apnsKeyId)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    TextField("Team ID", text: $appState.apnsTeamId)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Toggle("Sandbox(開発ビルド)", isOn: $appState.apnsUseSandbox)
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                    Toggle("自動実行(cron等)のみ通知", isOn: $appState.pushOnlyAutomations)
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                    Text("登録端末: \(appState.pushDeviceTokens.count)台 ／ 新着のアシスタント応答を通知します。")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(nil)
                }
            }
        }
        .padding(20)
        .frame(width: 250)
        .task {
            await appState.updateDashboardURL()
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var appState: AppState
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
            if let label = appState.toastActionLabel {
                Divider().frame(height: 16).overlay(Color.white.opacity(0.25))
                Button { appState.performToastAction() } label: {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(red: 0.55, green: 0.78, blue: 1.0))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color(red: 0.15, green: 0.15, blue: 0.18))
                .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 3)
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

struct TerminalView: View {
    @EnvironmentObject var appState: AppState
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("ターミナル")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { appState.openInTerminalApp() }) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Terminal.app で開く")
                Button(action: { appState.terminalOutput = "" }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("クリア")
                Button(action: { appState.showRightSidebar = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Output
            ScrollViewReader { proxy in
                ScrollView {
                    Text(appState.terminalOutput.isEmpty ? "コマンドを入力してください（cd / clear 対応）" : appState.terminalOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(appState.terminalOutput.isEmpty ? .secondary.opacity(0.5) : .primary.opacity(0.85))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Spacer().frame(height: 1).id("term_bottom")
                }
                .onChange(of: appState.terminalOutput) { _, _ in
                    proxy.scrollTo("term_bottom", anchor: .bottom)
                }
            }

            Divider()

            // Input
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.green)
                TextField("command…", text: $command, onCommit: {
                    appState.runTerminalCommand(command)
                    command = ""
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                if appState.isRunningTerminalCommand {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1)
                .frame(maxHeight: .infinity),
            alignment: .leading
        )
    }
}

struct ModelSelectionModal: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    
    let providers = [
        ("openrouter", "OpenRouter"),
        ("cerebras", "Cerebras"),
        ("openai", "OpenAI"),
        ("anthropic", "Anthropic"),
        ("gemini", "Google Gemini"),
        ("nous", "Nous Portal (OAuth)"),
        ("xai-oauth", "xAI Grok (OAuth)"),
        ("openai-codex", "OpenAI Codex (OAuth)")
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("モデルの選択")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
            
            // Provider Dropdown
            VStack(alignment: .leading, spacing: 6) {
                Text("Inference Provider")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                Picker("", selection: $appState.provider) {
                    ForEach(providers, id: \.0) { item in
                        Text(item.1).tag(item.0)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appState.provider) { _, newVal in
                    appState.handleProviderChange(newVal)
                }
            }
            
            // Default Model Field
            VStack(alignment: .leading, spacing: 6) {
                Text("Default Model")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                TextField("e.g. anthropic/claude-3-5-sonnet", text: $appState.defaultModel)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
            }
            
            // Apply Button
            Button(action: {
                Task {
                    await appState.handleSaveSettings()
                    dismiss()
                }
            }) {
                HStack {
                    Spacer()
                    if appState.isSavingSettings {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 6)
                        Text("適用中...")
                    } else {
                        Text("モデルを適用")
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(colorScheme == .dark ? Color.white : Color.black)
                .foregroundColor(colorScheme == .dark ? .black : .white)
                .font(.system(size: 12, weight: .bold))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(appState.isSavingSettings)
        }
        .padding(18)
        .frame(width: 300)
    }
}
