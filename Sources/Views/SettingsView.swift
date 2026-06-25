import SwiftUI

/// Settings presented as a modal dialog: a left category nav + a right content
/// panel (like the reference layout). Shown via `appState.showSettings`.
struct SettingsModal: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var voice = VoiceManager.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var selected: Section = .general
    @State private var isLoggingIn = false
    @State private var mgmtTab: ManagementTab = .memory
    @State private var showModelPicker = false
    @State private var settingsSearch = ""

    enum Section: String, CaseIterable, Identifiable {
        case general = "一般"
        case github = "GitHub"
        case cloud = "クラウド同期"
        case channels = "チャンネル"
        case plugins = "プラグイン"
        case management = "管理"
        case experimental = "実験的機能"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .github: return "chevron.left.forwardslash.chevron.right"
            case .cloud: return "cloud"
            case .channels: return "bubble.left.and.bubble.right"
            case .plugins: return "puzzlepiece.extension"
            case .management: return "brain.head.profile"
            case .experimental: return "flask"
            }
        }
        /// Extra search terms so a query like "supabase" or "モデル" finds the right section.
        var keywords: String {
            switch self {
            case .general: return "モデル model プロバイダー provider api キー key 性格 personality 音声 読み上げ tts elevenlabs"
            case .github: return "github リポジトリ repo ワークスペース clone git 作業フォルダ"
            case .cloud: return "クラウド cloud 同期 sync supabase バックアップ url キー key 社員"
            case .channels: return "チャンネル channel telegram discord slack line whatsapp signal teams メール email"
            case .plugins: return "プラグイン plugin インストール install 拡張"
            case .management: return "管理 メモリ memory スキル skill mcp soul"
            case .experimental: return "実験 experimental acp 転送 承認 自動許可 ツール"
            }
        }
        func matches(_ q: String) -> Bool {
            let s = q.lowercased()
            return s.isEmpty || rawValue.lowercased().contains(s) || keywords.lowercased().contains(s)
        }
    }

    let providers = [
        ("openrouter", "OpenRouter"),
        ("openai", "OpenAI"),
        ("anthropic", "Anthropic"),
        ("gemini", "Google Gemini"),
        ("nous", "Nous Portal (OAuth)"),
        ("xai-oauth", "xAI Grok (OAuth)"),
        ("openai-codex", "OpenAI Codex (OAuth)")
    ]
    let personalities = [
        ("kawaii", "Kawaii (Cute / Sparkly)"),
        ("helpful", "Helpful (Friendly AI)"),
        ("technical", "Technical (Detailed Expert)"),
        ("concise", "Concise (Brief / Direct)"),
        ("catgirl", "Catgirl (Neko-chan)"),
        ("noir", "Noir (Detective Drama)"),
        ("pirate", "Pirate (Buccaneer Style)"),
        ("surfer", "Surfer (Chill Surf Bro)")
    ]

    var body: some View {
        HStack(spacing: 0) {
            // Left category nav
            VStack(alignment: .leading, spacing: 2) {
                Text("設定")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("設定を検索", text: $settingsSearch).textFieldStyle(.plain).font(.system(size: 12))
                    if !settingsSearch.isEmpty {
                        Button { settingsSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.05)).cornerRadius(7)
                .padding(.horizontal, 8).padding(.bottom, 6)
                .onChange(of: settingsSearch) { _, q in
                    // Keep the selection valid: if it's filtered out, jump to the first match.
                    let matches = Section.allCases.filter { $0.matches(q) }
                    if !matches.contains(selected), let first = matches.first { selected = first }
                }

                ForEach(Section.allCases.filter { $0.matches(settingsSearch) }) { sec in
                    Button { selected = sec } label: {
                        HStack(spacing: 10) {
                            Image(systemName: sec.icon)
                                .font(.system(size: 13))
                                .frame(width: 18)
                            Text(sec.rawValue)
                                .font(.system(size: 13, weight: selected == sec ? .semibold : .regular))
                            Spacer()
                        }
                        .foregroundColor(selected == sec ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(selected == sec ? Color.primary.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(width: 200)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.035))

            Divider()

            // Right content panel
            VStack(spacing: 0) {
                HStack {
                    Text(selected.rawValue)
                        .font(.system(size: 18, weight: .bold))
                    Spacer()
                    Button { appState.showSettings = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch selected {
                        case .general: generalSection
                        case .github: githubSection
                        case .cloud: cloudSection
                        case .channels: channelsSection
                        case .plugins: pluginsSection
                        case .management: managementSection
                        case .experimental: experimentalSection
                        }
                        if selected == .general || selected == .experimental { saveButton }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 580)
        .background(colorScheme == .dark ? Color(red: 0.1, green: 0.1, blue: 0.11) : Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        .onAppear { appState.fetchChannels() }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView().environmentObject(appState)
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            card(title: "プロバイダーとモデル") {
                fieldLabel("Inference Provider")
                Picker("", selection: $appState.provider) {
                    ForEach(providers, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.menu)
                .onChange(of: appState.provider) { _, v in appState.handleProviderChange(v) }

                fieldLabel("モデル")
                Button { showModelPicker = true } label: {
                    HStack {
                        Text(appState.defaultModel.isEmpty ? "モデルを選択…" : appState.defaultModel)
                            .font(.system(size: 13))
                            .foregroundColor(appState.defaultModel.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Text("検索・テストして選べます。動作しないモデルは一覧から隠せます。")
                    .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8))

                if ["nous", "xai-oauth", "openai-codex"].contains(appState.provider) {
                    fieldLabel("OAuth Authentication")
                    Button {
                        Task { isLoggingIn = true; await appState.triggerOAuthLogin(); isLoggingIn = false }
                    } label: {
                        HStack { Spacer()
                            if isLoggingIn { ProgressView().controlSize(.small).padding(.trailing, 6); Text("認証中...") }
                            else { Text("OAuth認証でログインする") }
                            Spacer() }
                        .padding(.vertical, 8)
                        .background(Color.purple.opacity(0.2)).foregroundColor(.purple).cornerRadius(6)
                    }
                    .buttonStyle(.plain).disabled(isLoggingIn)
                } else {
                    fieldLabel("API Key for \(appState.provider)")
                    styledField(SecureField("Enter API Key", text: $appState.apiKey))
                }
            }

            card(title: "エージェント性格") {
                fieldLabel("Personality Persona")
                Picker("", selection: $appState.personality) {
                    ForEach(personalities, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.menu)
            }

            card(title: "音声読み上げ (TTS)") {
                Toggle(isOn: $voice.useElevenLabs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ElevenLabs の音声を使う")
                            .font(.system(size: 13, weight: .medium))
                        Text(voice.elevenLabsAvailable
                             ? "高品質な多言語音声(eleven_multilingual_v2)。OFFはシステム音声。"
                             : "⚠️ ~/.hermes/.env に ELEVENLABS_API_KEY が必要です。")
                            .font(.system(size: 10))
                            .foregroundColor(voice.elevenLabsAvailable ? .secondary.opacity(0.8) : .orange)
                            .lineLimit(nil)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!voice.elevenLabsAvailable)

                if voice.useElevenLabs {
                    fieldLabel("Voice ID")
                    styledField(TextField("例: 21m00Tcm4TlvDq8ikWAM (Rachel)", text: $voice.elevenLabsVoiceId))
                }

                Button {
                    voice.speak("こんにちは。これは読み上げのテストです。")
                } label: {
                    HStack { Image(systemName: "speaker.wave.2"); Text("読み上げテスト") }
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var channelsSection: some View {
        card(titleView: AnyView(
            HStack {
                Text("チャンネル").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Button { appState.fetchChannels() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
        )) {
            HStack(spacing: 8) {
                Circle().fill(appState.isLineBridgeRunning ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text("LINEブリッジ: \(appState.isLineBridgeRunning ? "稼働中" : "停止中") (:8650)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button("再起動") { Task { await appState.restartLineBridge() } }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundColor(.blue)
            }
            if !appState.lineBridgeStatus.isEmpty {
                Text(appState.lineBridgeStatus)
                    .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7)).lineLimit(nil)
            }
            Divider()

            if appState.channels.isEmpty {
                Text("登録済みチャンネルはありません。").font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                ForEach(appState.channels) { ch in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ch.name).font(.system(size: 13, weight: .medium)).foregroundColor(.primary)
                            Text("\(ch.platform) · \(ch.channelId)").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("テスト") { Task { await appState.testSendChannel(ch) } }
                            .font(.system(size: 11)).buttonStyle(.plain).foregroundColor(.blue)
                        Button { appState.removeChannel(ch) } label: {
                            Image(systemName: "trash").font(.system(size: 11)).foregroundColor(.red.opacity(0.8))
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            Text("※ チャンネルは受信したチャットから自動で一覧に追加されます。プラットフォーム連携（ボットトークン等）は hermes 側の設定が必要です。")
                .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8)).lineLimit(nil)
        }
    }

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            card(titleView: AnyView(
                HStack {
                    Text("アカウント").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                    Spacer()
                    if appState.isFetchingRepos { ProgressView().controlSize(.small).padding(.trailing, 4) }
                    Button { Task { await appState.fetchGitHubRepos() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle").foregroundColor(.secondary)
                    Text(appState.githubAccount.isEmpty ? "未接続（ターミナルで gh auth login）" : appState.githubAccount)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                fieldLabel("Clone先フォルダ")
                styledField(TextField("~/Documents/development", text: $appState.githubCloneBase))
            }

            card(title: "現在の作業フォルダ") {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.selectedRepoSlug ?? "ホーム（リポジトリ未選択）")
                            .font(.system(size: 13, weight: .semibold))
                        if let p = appState.selectedRepoPath {
                            Text(p).font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    if appState.selectedRepoSlug != nil {
                        Button("解除") { appState.clearWorkspace() }
                            .font(.system(size: 11)).buttonStyle(.plain).foregroundColor(.red.opacity(0.8))
                    }
                }
                Text("コードモードのエージェントはこのフォルダ内でファイル/ターミナルを操作します。")
                    .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8)).lineLimit(nil)
            }

            card(title: "リポジトリ") {
                if appState.isFetchingRepos && appState.githubRepos.isEmpty {
                    HStack { Spacer(); ProgressView("取得中...").padding(.vertical, 20); Spacer() }
                } else if appState.githubRepos.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 28)).foregroundColor(.secondary.opacity(0.6))
                        Text("リポジトリがありません（更新ボタンで取得）")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    ForEach(appState.githubRepos) { repo in
                        GitHubRepoRow(repo: repo)
                        if repo != appState.githubRepos.last { Divider() }
                    }
                }
            }
        }
        .onAppear { if appState.githubRepos.isEmpty { Task { await appState.fetchGitHubRepos() } } }
    }

    private var managementSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $mgmtTab) {
                ForEach(ManagementTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Group {
                switch mgmtTab {
                case .memory: MemoryEditor()
                case .skills: SkillsList()
                case .mcp: MCPList()
                }
            }
            .frame(height: 430)
        }
    }

    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            card(titleView: AnyView(
                HStack {
                    Text("新しいプラグインをインストール")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                    Spacer()
                    Button { Task { await appState.fetchPlugins() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            )) {
                fieldLabel("Git URL または owner/repo")
                HStack(spacing: 10) {
                    styledField(TextField("例: nousresearch/hermes-spotify", text: $appState.pluginInstallInput))
                    Button {
                        Task { await appState.handleInstallPlugin() }
                    } label: {
                        HStack(spacing: 4) {
                            if appState.isInstallingPlugin {
                                ProgressView().controlSize(.small)
                                Text("インストール中...")
                            } else {
                                Text("インストール")
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .font(.system(size: 12, weight: .semibold)).cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isInstallingPlugin || appState.pluginInstallInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            card(title: "インストール済みプラグイン") {
                if appState.isFetchingPlugins {
                    HStack { Spacer(); ProgressView("プラグイン情報を取得中...").padding(.vertical, 24); Spacer() }
                } else if appState.pluginsList.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece")
                            .font(.system(size: 28)).foregroundColor(.secondary.opacity(0.6))
                        Text("インストールされているプラグインはありません。")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    ForEach(appState.pluginsList) { plugin in
                        PluginRow(plugin: plugin).padding(.vertical, 6)
                        if plugin != appState.pluginsList.last {
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear { Task { await appState.fetchPlugins() } }
    }

    private var experimentalSection: some View {
        card(title: "実験的機能") {
            Toggle(isOn: $appState.useACPTransport) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACP転送を使う").font(.system(size: 13, weight: .medium))
                    Text("構造化エージェント転送(ツール/承認の土台)。クリーンな本文とトークン数。新規チャットから適用。")
                        .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8)).lineLimit(nil)
                }
            }.toggleStyle(.switch)
            Divider()
            Toggle(isOn: $appState.acpAutoAllow) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ツール実行を自動許可").font(.system(size: 13, weight: .medium))
                    Text("OFFにすると、ファイル編集など承認が必要な操作で承認/拒否ダイアログを表示します(ACP転送時)。")
                        .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8)).lineLimit(nil)
                }
            }.toggleStyle(.switch)
        }
    }

    private var cloudSection: some View {
        // Supabase card is hidden after migrating to iCloud (supabaseCard + its
        // AppState logic are kept so it can be restored by re-adding it here).
        icloudCard
    }

    private var icloudCard: some View {
        card(title: "クラウド同期 (iCloud · CloudKit)") {
            Toggle(isOn: $appState.icloudSyncEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud同期を有効化").font(.system(size: 13, weight: .medium))
                    Text("社員・チーム・タスクを iCloud (CloudKit) で全端末同期します。編集時に自動同期＋起動時に取得＋他端末の変更を約20秒ごとに自動反映（起動中）。")
                        .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8)).lineLimit(nil)
                }
            }.toggleStyle(.switch)

            HStack(spacing: 10) {
                Button { Task { await appState.syncRosterNow() } } label: {
                    HStack(spacing: 4) {
                        if appState.isSyncingICloud { ProgressView().controlSize(.small) }
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("iCloudで今すぐ同期")
                    }.font(.system(size: 12))
                }.buttonStyle(.borderedProminent)
                    .disabled(!appState.icloudSyncEnabled || appState.isSyncingICloud)

                Button { Task { await appState.testICloud() } } label: {
                    HStack(spacing: 4) {
                        if appState.isTestingICloud { ProgressView().controlSize(.small) }
                        Image(systemName: "icloud")
                        Text("接続テスト")
                    }.font(.system(size: 12))
                }.buttonStyle(.bordered).disabled(appState.isTestingICloud)
                Spacer()
            }

            Divider().padding(.vertical, 2)

            Toggle(isOn: $appState.icloudMirrorMessages) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("メッセージもミラー（一方向）").font(.system(size: 12, weight: .medium))
                    Text("会話履歴を iCloud にバックアップします。state.db は読み取り専用のため書き戻しはしません（他端末では閲覧用）。")
                        .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8)).lineLimit(nil)
                }
            }.toggleStyle(.switch).disabled(!appState.icloudSyncEnabled)

            HStack(spacing: 10) {
                Button { Task { await appState.mirrorMessagesNow() } } label: {
                    HStack(spacing: 4) {
                        if appState.isMirroringMessages { ProgressView().controlSize(.small) }
                        Image(systemName: "arrow.up.doc")
                        Text("メッセージをミラー")
                    }.font(.system(size: 12))
                }.buttonStyle(.bordered)
                    .disabled(!appState.icloudSyncEnabled || appState.isMirroringMessages)
                Button { Task { await appState.verifyCloudHistory() } } label: {
                    HStack(spacing: 4) { Image(systemName: "checkmark.icloud"); Text("クラウド履歴を確認") }
                        .font(.system(size: 12))
                }.buttonStyle(.bordered).disabled(!appState.icloudSyncEnabled)
                Spacer()
            }

            if !appState.icloudStatus.isEmpty {
                Text(appState.icloudStatus)
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(nil)
            }
            Text("※ コンテナ iCloud.com.custom.hermes / public DB（個人iCloud容量を消費しません）。同期は社員/チーム/タスクの共有項目のみ（アバター・作業フォルダ等は端末ローカル）。Mac がシステム設定で iCloud にサインインしている必要があります。")
                .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.8)).lineLimit(nil)
        }
    }

    private var supabaseCard: some View {
        card(title: "クラウド同期 (Supabase)") {
            Toggle(isOn: $appState.cloudSyncEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("クラウド同期を有効化").font(.system(size: 13, weight: .medium))
                    Text("社員（今後メッセージも）をSupabaseに保存し、全端末で同期します。")
                        .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8)).lineLimit(nil)
                }
            }.toggleStyle(.switch)

            fieldLabel("Project URL")
            styledField(TextField("https://xxxx.supabase.co", text: $appState.supabaseURL))
            fieldLabel("API Key (anon public)")
            styledField(SecureField("eyJhbGciOi...", text: $appState.supabaseAnonKey))
            fieldLabel("ワークスペース（端末グループ識別・任意）")
            styledField(TextField("例: あなたのメール", text: $appState.cloudWorkspace))

            HStack(spacing: 10) {
                Button { Task { await appState.testCloudConnection() } } label: {
                    HStack(spacing: 4) {
                        if appState.isTestingCloud { ProgressView().controlSize(.small) }
                        Text("接続テスト")
                    }.font(.system(size: 12))
                }.buttonStyle(.bordered)
                Button { Task { await appState.syncEmployeesNow() } } label: {
                    HStack(spacing: 4) { Image(systemName: "arrow.triangle.2.circlepath"); Text("社員を今すぐ同期") }
                        .font(.system(size: 12))
                }.buttonStyle(.bordered).disabled(!appState.cloudSyncEnabled)
                Spacer()
            }
            if !appState.cloudSyncStatus.isEmpty {
                Text(appState.cloudSyncStatus)
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(nil)
            }
            Text("※ Supabaseでプロジェクト作成 → テーブル作成SQLを実行 → URL と anon キーをここに入力 → 接続テスト。")
                .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.8)).lineLimit(nil)
        }
    }

    private var saveButton: some View {
        Button {
            Task { await appState.handleSaveSettings() }
        } label: {
            HStack { Spacer()
                if appState.isSavingSettings { ProgressView().controlSize(.small).padding(.trailing, 6); Text("保存中...") }
                else { Text("設定を適用して保存") }
                Spacer() }
            .padding(.vertical, 10)
            .background(appState.isSavingSettings ? Color.primary.opacity(0.3) : (colorScheme == .dark ? Color.white : Color.black))
            .foregroundColor(colorScheme == .dark ? .black : .white)
            .font(.system(size: 14, weight: .bold)).cornerRadius(6)
        }
        .buttonStyle(.plain).disabled(appState.isSavingSettings).padding(.top, 4)
    }

    // MARK: - Reusable bits

    private func fieldLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
    }

    private func styledField<V: View>(_ field: V) -> some View {
        field
            .textFieldStyle(.plain)
            .padding(8)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func card<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        card(titleView: AnyView(
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
        ), content)
    }

    private func card<Content: View>(titleView: AnyView, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            titleView
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(16)
                .background(Color.primary.opacity(0.02))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.05), lineWidth: 0.5))
        }
    }
}

/// One repository row in the GitHub settings section: set-as-workspace or clone.
struct GitHubRepoRow: View {
    @EnvironmentObject var appState: AppState
    let repo: GitHubRepo

    private var isSelected: Bool { appState.selectedRepoSlug == repo.nameWithOwner }
    private var localPath: String? { appState.localPath(for: repo) }
    private var isCloning: Bool { appState.cloningRepo == repo.nameWithOwner }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .purple : .secondary)
                .frame(width: 28, height: 28)
                .background(Color.purple.opacity(isSelected ? 0.12 : 0.04))
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    if !repo.language.isEmpty {
                        Text(repo.language).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    if localPath != nil {
                        Text("ローカル").font(.system(size: 9, weight: .semibold)).foregroundColor(.green)
                    }
                }
            }

            Spacer()

            if isSelected {
                Text("選択中").font(.system(size: 11, weight: .semibold)).foregroundColor(.purple)
            } else if isCloning {
                ProgressView().controlSize(.small)
            } else if let p = localPath {
                Button("設定") { appState.setWorkspace(path: p, slug: repo.nameWithOwner) }
                    .font(.system(size: 11)).buttonStyle(.bordered)
            } else {
                Button("Clone") { Task { await appState.cloneRepo(repo) } }
                    .font(.system(size: 11)).buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
