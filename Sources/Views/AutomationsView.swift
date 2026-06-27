import SwiftUI

struct AutomationsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var showSuggestions = false   // おすすめ欄は既定で折りたたみ（縦の長さを抑える）

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("スケジュールタスク (オートメーション)")
                            .font(.system(size: 24, weight: .bold))
                        Text("定期的に自動実行するエージェントタスクやスクリプト（Cronジョブ）の管理を行います。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    
                    Button(action: {
                        appState.fetchAutomationResults()
                        Task {
                            await appState.fetchCronJobs()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        appState.view = "chat"
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 8)

                // Section: 株モニタリング (quick setup — 保有銘柄 + LINE通知フロー)
                StockMonitorCard()

                // Section 0: Proactive automation results (H4)
                if !appState.automationResults.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("最近の自動実行結果")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)

                        VStack(spacing: 8) {
                            ForEach(Array(appState.automationResults.prefix(3))) { result in
                                AutomationResultCard(result: result)
                            }
                        }
                        if appState.automationResults.count > 3 {
                            Text("他 \(appState.automationResults.count - 3) 件")
                                .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
                                .padding(.leading, 4)
                        }
                    }
                }

                // Section 0.5: Suggested automations (collapsible — 既定で閉じる)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showSuggestions.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showSuggestions ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                                Text("おすすめのオートメーション")
                                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
                                Text("\(appState.aiSuggestions.count + AppState.curatedAutomations.count)")
                                    .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.6))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if showSuggestions {
                            Button {
                                Task { await appState.generateAutomationSuggestions() }
                            } label: {
                                HStack(spacing: 4) {
                                    if appState.isGeneratingSuggestions {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "sparkles")
                                    }
                                    Text(appState.isGeneratingSuggestions ? "生成中..." : "AIに提案してもらう")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.purple)
                            .disabled(appState.isGeneratingSuggestions)
                        }
                    }

                    if showSuggestions {
                        VStack(spacing: 8) {
                            ForEach(appState.aiSuggestions + AppState.curatedAutomations) { s in
                                AutomationSuggestionCard(suggestion: s)
                            }
                        }
                    }
                }

                // Section 1: Create Cron Job Form
                VStack(alignment: .leading, spacing: 16) {
                    Text("新しいスケジュールタスクを作成")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            TextField("タスク名 (例: daily_health_check)", text: $appState.newCronName)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(6)
                            
                            TextField("スケジュール (例: 0 9 * * *, 30m, every 2h)", text: $appState.newCronSchedule)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(6)
                        }
                        
                        TextField("エージェントへの指示プロンプト (例: 今日の天気を調べてサマリーを送信して)", text: $appState.newCronPrompt)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(6)
                        
                        HStack(spacing: 12) {
                            // 配信先（ドロップダウン選択）
                            Menu {
                                Button { appState.newCronDeliver = "local" } label: {
                                    Label("ローカル（アプリ内のみ）", systemImage: appState.newCronDeliver == "local" || appState.newCronDeliver.isEmpty ? "checkmark" : "")
                                }
                                Button { appState.newCronDeliver = "origin" } label: {
                                    Label("送信元へ返信", systemImage: appState.newCronDeliver == "origin" ? "checkmark" : "")
                                }
                                if !appState.channels.isEmpty {
                                    Divider()
                                    ForEach(appState.channels) { ch in
                                        let val = "\(ch.platform):\(ch.channelId)"
                                        Button { appState.newCronDeliver = val } label: {
                                            Label(channelMenuLabel(ch), systemImage: appState.newCronDeliver == val ? "checkmark" : "")
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "paperplane").font(.system(size: 11)).foregroundColor(.secondary)
                                    Text(deliverDisplayLabel(appState.newCronDeliver))
                                        .font(.system(size: 12)).foregroundColor(.primary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundColor(.secondary)
                                }
                                .padding(8)
                                .background(Color.primary.opacity(0.05)).cornerRadius(6)
                            }
                            .menuStyle(.borderlessButton)
                            .frame(maxWidth: .infinity)

                            TextField("スクリプトパス (任意)", text: $appState.newCronScript)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(6)
                        }
                        
                        HStack {
                            if !appState.employees.isEmpty {
                                Menu {
                                    Button { appState.newCronAssigneeId = nil } label: {
                                        Label("担当なし", systemImage: appState.newCronAssigneeId == nil ? "checkmark" : "")
                                    }
                                    ForEach(appState.sortedEmployees) { e in
                                        Button { appState.newCronAssigneeId = e.id } label: {
                                            Label("\(e.role.emoji) \(e.name)", systemImage: appState.newCronAssigneeId == e.id ? "checkmark" : "")
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "person.crop.circle").font(.system(size: 11))
                                        Text(appState.employees.first { $0.id == appState.newCronAssigneeId }?.name ?? "担当社員")
                                            .font(.system(size: 11))
                                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
                                    }.foregroundColor(.secondary)
                                }.menuStyle(.borderlessButton).fixedSize()
                            }

                            Toggle("LLMを介さずスクリプトを直接実行 (--no-agent)", isOn: $appState.newCronNoAgent)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)

                            Spacer()
                            
                            Button(action: {
                                Task {
                                    await appState.handleCreateCronJob()
                                }
                            }) {
                                HStack {
                                    if appState.isCreatingCronJob {
                                        ProgressView()
                                            .controlSize(.small)
                                            .padding(.trailing, 4)
                                        Text("作成中...")
                                    } else {
                                        Text("タスクを作成")
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(colorScheme == .dark ? Color.white : Color.black)
                                .foregroundColor(colorScheme == .dark ? .black : .white)
                                .font(.system(size: 12, weight: .semibold))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .disabled(appState.isCreatingCronJob || appState.newCronSchedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(16)
                .background(Color.primary.opacity(0.02))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
                )
                
                // Section 2: Cron Jobs List
                VStack(alignment: .leading, spacing: 16) {
                    Text("スケジュールされているジョブ")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    if appState.isFetchingCronJobs {
                        HStack {
                            Spacer()
                            ProgressView("ジョブ情報を取得中...")
                                .padding(.vertical, 40)
                            Spacer()
                        }
                    } else if appState.cronJobs.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "clock")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary.opacity(0.6))
                            Text("スケジュールされたジョブはありません。")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .background(Color.primary.opacity(0.01))
                        .cornerRadius(8)
                    } else {
                        VStack(spacing: 1) {
                            ForEach(appState.cronJobs) { job in
                                CronJobRow(job: job)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 14)
                                    .background(Color.primary.opacity(0.01))
                                
                                if job != appState.cronJobs.last {
                                    Divider()
                                        .padding(.horizontal, 14)
                                }
                            }
                        }
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
                        )
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)   // 広い窓では中央寄せ（左に寄って間延びしないように）
        }
        .onAppear {
            appState.fetchAutomationResults()
            appState.fetchChannels()
        }
    }

    /// 配信先メニューの各チャンネル表示名（LINEの長いIDは末尾だけ短縮）。
    private func channelMenuLabel(_ ch: HermesChannel) -> String {
        let plat = ch.platform.uppercased()
        if ch.name == ch.channelId && ch.channelId.count > 12 {
            return "\(plat)（…\(ch.channelId.suffix(6))）"
        }
        return "\(plat)：\(ch.name.isEmpty ? ch.channelId : ch.name)"
    }

    /// 現在の配信先の表示ラベル（local/origin/登録済みチャンネル/手入力カスタム）。
    private func deliverDisplayLabel(_ value: String) -> String {
        switch value {
        case "", "local": return "ローカル（アプリ内のみ）"
        case "origin": return "送信元へ返信"
        default:
            if let ch = appState.channels.first(where: { "\($0.platform):\($0.channelId)" == value }) {
                return channelMenuLabel(ch)
            }
            return value
        }
    }
}

/// A suggested automation. "使う" prefills the create form for review.
struct AutomationSuggestionCard: View {
    @EnvironmentObject var appState: AppState
    let suggestion: AutomationSuggestion
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 15))
                .foregroundColor(.purple)
                .frame(width: 30, height: 30)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.title).font(.system(size: 13, weight: .semibold))
                    Text(suggestion.schedule)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06)).clipShape(Capsule())
                }
                Text(suggestion.prompt)
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer()
            Button("使う") { appState.applyAutomationSuggestion(suggestion) }
                .font(.system(size: 11)).buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.primary.opacity(hovered ? 0.05 : 0.02))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.12), lineWidth: 0.5))
        .onHover { hovered = $0 }
    }
}

/// 株モニタリングのワンクリック設定カード。保有銘柄とAPIキーを編集・保存し、
/// 「このフローを設定」で証券アナリスト×LINE通知のcron作成フォームをプリフィルする。
struct StockMonitorCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var showKey = false
    @State private var expanded = false

    private func statusChip(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 9)).foregroundColor(ok ? .green : .orange)
            Text(text).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 12 : 0) {
            // ヘッダ（タップで開閉）。折りたたみ時は状態を1行で表示。
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 14)).foregroundColor(.green)
                        .frame(width: 28, height: 28)
                        .background(Color.green.opacity(0.12)).cornerRadius(7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("株モニタリング").font(.system(size: 14, weight: .semibold))
                        if expanded {
                            Text("保有銘柄の株価・ニュースを証券アナリストが定期チェックし、LINEに通知。")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        } else {
                            HStack(spacing: 10) {
                                statusChip(appState.stockAnalyst?.name ?? "アナリスト未設定", ok: appState.stockAnalyst != nil)
                                statusChip(appState.firstLineChannelId != nil ? "LINE" : "LINE未", ok: appState.firstLineChannelId != nil)
                                statusChip(appState.stockApiKey.isEmpty ? "株価キー未" : "株価キー", ok: !appState.stockApiKey.isEmpty)
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                // 保有銘柄
                TextEditor(text: $appState.stockPortfolioText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 92).padding(6)
                    .background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                Text("1行1銘柄。例) 7203 トヨタ自動車 ／ AAPL Apple（日本株はコード、米国株はティッカー）")
                    .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8))

                // APIキー（任意）
                HStack(spacing: 8) {
                    Image(systemName: "key").font(.system(size: 11)).foregroundColor(.secondary)
                    if showKey {
                        TextField("Twelve Data APIキー（株価取得・任意）", text: $appState.stockApiKey)
                            .textFieldStyle(.plain).font(.system(size: 12))
                    } else {
                        SecureField("Twelve Data APIキー（株価取得・任意）", text: $appState.stockApiKey)
                            .textFieldStyle(.plain).font(.system(size: 12))
                    }
                    Button(showKey ? "隠す" : "表示") { showKey.toggle() }
                        .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.blue)
                }
                .padding(8).background(Color.primary.opacity(0.05)).cornerRadius(6)

                // アクション
                HStack(spacing: 10) {
                    Button {
                        appState.savePortfolioText(); appState.saveStockApiKey()
                    } label: {
                        Text("保存").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Color.primary.opacity(0.08)).cornerRadius(6)
                    }.buttonStyle(.plain)
                    Spacer()
                    Button {
                        appState.savePortfolioText(); appState.saveStockApiKey()
                        appState.prefillStockMonitor()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.fill").font(.system(size: 10))
                            Text("このフローを設定").font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(6)
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(Color.green.opacity(0.04)).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.18), lineWidth: 0.5))
    }
}

/// A card summarizing a proactive (cron/gateway-originated) agent run. Tap to open.
struct AutomationResultCard: View {
    @EnvironmentObject var appState: AppState
    let result: AppState.AutomationResult
    @State private var hovered = false

    private var sourceIcon: String {
        switch result.source.lowercased() {
        case "cron": return "clock.arrow.circlepath"
        case "slack": return "number"
        case "line", "telegram", "whatsapp": return "message"
        default: return "sparkles"
        }
    }

    private var timeText: String {
        guard result.updatedAt > 0 else { return "" }
        let date = Date(timeIntervalSince1970: result.updatedAt)
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        Button {
            Task { await appState.handleSelectSession(sessionId: result.id) }
            appState.view = "chat"
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(result.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(result.source)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                        Spacer()
                        Text(timeText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    if !result.preview.isEmpty {
                        Text(result.preview)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(hovered ? 0.05 : 0.02))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct CronJobRow: View {
    @EnvironmentObject var appState: AppState
    let job: HermesCronJob
    @State private var isPendingAction = false
    @State private var isHovered = false
    @State private var showRunConfirm = false
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20))
                .foregroundColor(job.isActive ? .green : .secondary)
                .frame(width: 32, height: 32)
                .background(Color.green.opacity(job.isActive ? 0.1 : 0.03))
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(job.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text(job.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(4)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("スケジュール: \(job.schedule)  |  配信: \(job.deliver)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    if let script = job.script {
                        Text("スクリプト: \(script)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    if !job.nextRun.isEmpty {
                        Text("次回実行: \(job.nextRun)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    
                    if let lastRun = job.lastRun {
                        Text("前回実行: \(lastRun)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
            }
            
            Spacer()
            
            if isPendingAction {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 10)
            } else {
                // テスト実行（今すぐ実行 → 配信先へ送信）
                Button(action: { showRunConfirm = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill").font(.system(size: 10))
                        Text("テスト送信").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.10)).cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("今すぐ実行して配信先（LINE等）に送信します")
                .confirmationDialog(
                    "「\(job.name)」を今すぐ実行しますか？\n配信先（\(job.deliver)）に結果が送信されます。",
                    isPresented: $showRunConfirm, titleVisibility: .visible
                ) {
                    Button("実行して送信") {
                        Task {
                            isPendingAction = true
                            _ = await appState.cronRunNow(id: job.id)
                            isPendingAction = false
                        }
                    }
                    Button("キャンセル", role: .cancel) {}
                }

                Toggle("", isOn: Binding(
                    get: { job.isActive },
                    set: { _ in
                        Task {
                            isPendingAction = true
                            await appState.handleToggleCronJob(job)
                            isPendingAction = false
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                
                Button(action: {
                    Task {
                        isPendingAction = true
                        await appState.handleDeleteCronJob(job)
                        isPendingAction = false
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(.red.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.05))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
    }
}
