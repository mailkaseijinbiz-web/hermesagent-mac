import SwiftUI

struct AutomationsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    
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

                // Section 0: Proactive automation results (H4)
                if !appState.automationResults.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("最近の自動実行結果")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)

                        VStack(spacing: 8) {
                            ForEach(appState.automationResults) { result in
                                AutomationResultCard(result: result)
                            }
                        }
                    }
                }

                // Section 0.5: Suggested automations (proactive proposals)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("おすすめのオートメーション")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
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

                    VStack(spacing: 8) {
                        ForEach(appState.aiSuggestions + AppState.curatedAutomations) { s in
                            AutomationSuggestionCard(suggestion: s)
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
                            TextField("配信先 (例: local, telegram, line:CHAT_ID)", text: $appState.newCronDeliver)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(6)
                            
                            TextField("スクリプトパス (任意)", text: $appState.newCronScript)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(6)
                        }
                        
                        HStack {
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
            .frame(maxWidth: 700)
        }
        .onAppear { appState.fetchAutomationResults() }
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
