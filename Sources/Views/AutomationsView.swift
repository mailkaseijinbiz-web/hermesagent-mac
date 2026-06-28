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

                // Section 1: 新しいスケジュールタスクを作成（モーダルで開く）
                Button {
                    appState.resetNewCronForm()
                    appState.showCronCreateSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 14))
                        Text("新しいスケジュールタスクを作成").font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(.accentColor)
                    .padding(14)
                    .background(Color.accentColor.opacity(0.08)).cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
        .sheet(isPresented: $appState.showCronCreateSheet) {
            CronCreateSheet().environmentObject(appState)
        }
    }

}

/// 配信先ドロップダウン（ローカル / 送信元 / 登録チャンネル）。作成・編集フォームで共通利用。
struct DeliverPicker: View {
    @EnvironmentObject var appState: AppState
    @Binding var deliver: String

    var body: some View {
        Menu {
            Button { deliver = "local" } label: {
                Label("ローカル（アプリ内のみ）", systemImage: deliver == "local" || deliver.isEmpty ? "checkmark" : "")
            }
            Button { deliver = "origin" } label: {
                Label("送信元へ返信", systemImage: deliver == "origin" ? "checkmark" : "")
            }
            if !appState.channels.isEmpty {
                Divider()
                ForEach(appState.channels) { ch in
                    let val = "\(ch.platform):\(ch.channelId)"
                    Button { deliver = val } label: {
                        Label(Self.channelMenuLabel(ch), systemImage: deliver == val ? "checkmark" : "")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paperplane").font(.system(size: 11)).foregroundColor(.secondary)
                Text(displayLabel)
                    .font(.system(size: 12)).foregroundColor(.primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.primary.opacity(0.05)).cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
    }

    private var displayLabel: String {
        switch deliver {
        case "", "local": return "ローカル（アプリ内のみ）"
        case "origin": return "送信元へ返信"
        default:
            if let ch = appState.channels.first(where: { "\($0.platform):\($0.channelId)" == deliver }) {
                return Self.channelMenuLabel(ch)
            }
            return deliver
        }
    }

    /// 配信先メニューの各チャンネル表示名（LINEの長いIDは末尾だけ短縮）。
    static func channelMenuLabel(_ ch: HermesChannel) -> String {
        let plat = ch.platform.uppercased()
        if ch.name == ch.channelId && ch.channelId.count > 12 {
            return "\(plat)（…\(ch.channelId.suffix(6))）"
        }
        return "\(plat)：\(ch.name.isEmpty ? ch.channelId : ch.name)"
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
    @State private var showEdit = false
    @State private var showResults = false

    // cron 式を読みやすい日本語に（例: "30 8,15 * * 1-5" → "平日 8:30・15:30"、"0 9 * * *" → "毎日 9:00"）。
    static func humanSchedule(_ cron: String) -> String {
        let f = cron.split(separator: " ").map(String.init)
        guard f.count == 5 else { return cron }   // 非標準 → そのまま
        let (minute, hour, dom, mon, dow) = (f[0], f[1], f[2], f[3], f[4])

        if hour == "*", dom == "*", mon == "*", dow == "*",
           minute.hasPrefix("*/"), let n = Int(minute.dropFirst(2)) { return "\(n)分ごと" }
        if hour == "*", dom == "*", mon == "*", dow == "*", let m = Int(minute) {
            return m == 0 ? "毎時0分" : "毎時\(m)分"
        }
        if dom == "*", mon == "*", dow == "*",
           hour.hasPrefix("*/"), let n = Int(hour.dropFirst(2)) { return "\(n)時間ごと" }

        let mins = minute.split(separator: ",").compactMap { Int($0) }
        let hours = hour.split(separator: ",").compactMap { Int($0) }
        guard let mm = mins.first, !hours.isEmpty else { return cron }
        let times = hours.sorted().map { String(format: "%d:%02d", $0, mm) }.joined(separator: "・")

        let names = ["日", "月", "火", "水", "木", "金", "土"]
        let freq: String
        if dow == "1-5" { freq = "平日" }
        else if Set(dow.split(separator: ",").map(String.init)) == ["0", "6"] { freq = "週末" }
        else if dow != "*" {
            let days = dow.split(separator: ",").compactMap { Int($0) }
                .map { $0 == 7 ? 0 : $0 }.filter { (0...6).contains($0) }.map { names[$0] }
            freq = days.isEmpty ? "毎週" : "毎週" + days.joined(separator: "・") + "曜"
        } else if dom != "*" { freq = "毎月\(dom)日" }
        else { freq = "毎日" }
        return "\(freq) \(times)"
    }

    // 配信先を UID を出さずに表示（例: "line:U752…" → "LINE（登録名）"、"local" → "このMac"）。
    static func humanDeliver(_ deliver: String, channels: [HermesChannel]) -> String {
        let d = deliver.trimmingCharacters(in: .whitespaces)
        if d.isEmpty || d.lowercased() == "local" { return "このMac（ローカル）" }
        let parts = d.split(separator: ":", maxSplits: 1).map(String.init)
        let platform = parts.first ?? d
        let id = parts.count > 1 ? parts[1] : ""
        let label: String
        switch platform.lowercased() {
        case "line":     label = "LINE"
        case "telegram": label = "Telegram"
        case "discord":  label = "Discord"
        case "slack":    label = "Slack"
        case "whatsapp": label = "WhatsApp"
        default:         label = platform
        }
        if !id.isEmpty,
           let ch = channels.first(where: { $0.channelId == id && $0.platform.lowercased() == platform.lowercased() }) {
            return "\(label)（\(ch.name)）"
        }
        return label   // UID は出さない
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    Text("スケジュール: \(Self.humanSchedule(job.schedule))  |  配信: \(Self.humanDeliver(job.deliver, channels: appState.channels))")
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

                    if let err = job.lastError, !err.isEmpty {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                            Text(err)
                                .font(.system(size: 10)).lineLimit(2)
                                .textSelection(.enabled)
                        }
                        .foregroundColor(.orange)
                        .help(err)
                    }
                }
            }
            
            Spacer()
            
            if isPendingAction {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 10)
            } else {
                // 編集（名前・スケジュール・配信先）
                Button(action: { showEdit = true }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05)).cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("スケジュール・名前・配信先を編集")
                .popover(isPresented: $showEdit, arrowEdge: .bottom) {
                    CronEditView(job: job) { showEdit = false }
                }

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
                    "「\(job.name)」を今すぐ実行しますか？\n配信先（\(Self.humanDeliver(job.deliver, channels: appState.channels))）に結果が送信されます。",
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
            // このジョブに紐づく実行結果（タイトルがジョブ名で始まるもの）を展開表示
            resultsSection
        }
    }

    private var jobResults: [AppState.AutomationResult] {
        appState.automationResults.filter { $0.title.hasPrefix(job.name) }
    }

    @ViewBuilder private var resultsSection: some View {
        let results = jobResults
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button { withAnimation(.easeInOut(duration: 0.12)) { showResults.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showResults ? "chevron.down" : "chevron.right").font(.system(size: 9))
                        Text("実行結果 \(results.count)件").font(.system(size: 11, weight: .medium))
                        if let latest = results.first {
                            Text("· 最新 \(Self.relTime(latest.updatedAt))")
                                .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
                        }
                        Spacer()
                    }
                    .foregroundColor(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showResults {
                    ForEach(Array(results.prefix(8))) { r in
                        Button {
                            Task { await appState.handleSelectSession(sessionId: r.id) }
                            appState.view = "chat"
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(r.title).font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary).lineLimit(1)
                                    Spacer()
                                    Text(Self.relTime(r.updatedAt))
                                        .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
                                }
                                if !r.preview.isEmpty {
                                    Text(r.preview).font(.system(size: 10))
                                        .foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.03)).cornerRadius(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.leading, 48)
        }
    }

    private static func relTime(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP"); f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
}

/// スケジュールタスク（cronジョブ）編集ポップオーバー：名前・スケジュール・配信先。
/// プロンプト/スクリプトは一覧に値が無いため対象外（必要なら作り直し）。
struct CronEditView: View {
    @EnvironmentObject var appState: AppState
    let job: HermesCronJob
    let onClose: () -> Void
    @State private var name: String
    @State private var schedule: String
    @State private var deliver: String
    @State private var saving = false

    init(job: HermesCronJob, onClose: @escaping () -> Void) {
        self.job = job
        self.onClose = onClose
        _name = State(initialValue: job.name)
        _schedule = State(initialValue: job.schedule)
        _deliver = State(initialValue: job.deliver)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("スケジュールタスクを編集").font(.system(size: 13, weight: .semibold))

            labeledField("タスク名") {
                TextField("例: 株モニタリング", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("スケジュール").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                SchedulePicker(schedule: $schedule)   // 自前で背景を持つので labeledField で包まない
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("配信先").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                DeliverPicker(deliver: $deliver)   // 自前で背景を持つので labeledField で包まない
            }

            if let sc = job.script, !sc.isEmpty {
                Text("スクリプト: \(sc)（編集不可）")
                    .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
            }

            HStack(spacing: 10) {
                Spacer()
                Button("キャンセル") { onClose() }.buttonStyle(.plain).font(.system(size: 12))
                Button {
                    saving = true
                    Task {
                        let ok = await appState.cronEdit(id: job.id, schedule: schedule, name: name, deliver: deliver)
                        saving = false
                        if ok { onClose() }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if saving { ProgressView().controlSize(.small) }
                        Text("保存").font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.accentColor).foregroundColor(.white).cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(saving || schedule.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 340)
    }

    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            content()
                .padding(8)
                .background(Color.primary.opacity(0.05)).cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

/// スケジュールタスク作成モーダル。名前・スケジュール(SchedulePicker)・プロンプト・配信先・
/// スクリプト・担当社員・--no-agent を入力して作成。成功でシートを閉じる。
struct CronCreateSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("新しいスケジュールタスク").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary).frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06)).clipShape(Circle())
                }.buttonStyle(.plain)
            }
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // クイック設定: 株モニタリング（展開して「このフローを設定」で下のフォームに反映）
                    StockMonitorCard()

                    labeledField("タスク名") {
                        TextField("例: daily_health_check", text: $appState.newCronName)
                            .textFieldStyle(.plain).font(.system(size: 12))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("スケジュール").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                        SchedulePicker(schedule: $appState.newCronSchedule)
                    }
                    labeledField("エージェントへの指示プロンプト") {
                        TextField("例: 今日の天気を調べてサマリーを送信して", text: $appState.newCronPrompt, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...5)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("配信先").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                        DeliverPicker(deliver: $appState.newCronDeliver)
                    }
                    labeledField("スクリプトパス（任意）") {
                        TextField("~/.hermes/scripts/ 配下のファイル名", text: $appState.newCronScript)
                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
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
                            .toggleStyle(.checkbox).font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding(.vertical, 2)
            }

            Divider().padding(.vertical, 12)

            HStack(spacing: 10) {
                Spacer()
                Button("キャンセル") { dismiss() }.buttonStyle(.plain).font(.system(size: 13))
                Button {
                    Task { if await appState.handleCreateCronJob() { dismiss() } }
                } label: {
                    HStack(spacing: 5) {
                        if appState.isCreatingCronJob { ProgressView().controlSize(.small) }
                        Text(appState.isCreatingCronJob ? "作成中..." : "作成")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(appState.isCreatingCronJob || appState.newCronSchedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
    }

    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            content()
                .padding(8)
                .background(Color.primary.opacity(0.05)).cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}
