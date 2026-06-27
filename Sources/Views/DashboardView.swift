import SwiftUI

/// Home dashboard: a daily brief (AI-written) + at-a-glance cards for today's schedule,
/// tasks, apps, and team status. Each card deep-links to its full view.
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy年M月d日(E)"; return f
    }()

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11:  return "おはようございます"
        case 11..<17: return "こんにちは"
        case 17..<23: return "こんばんは"
        default:      return "お疲れさまです"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                briefCard
                HStack(alignment: .top, spacing: 16) {
                    scheduleCard
                    tasksCard
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            // Auto-generate once per day (empty, or last brief was a previous day).
            let stale = appState.dailyBriefAt == 0
                || !Calendar.current.isDateInToday(Date(timeIntervalSince1970: appState.dailyBriefAt))
            if stale && !appState.isGeneratingBrief {
                Task { await appState.generateDailyBrief() }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(greeting)").font(.system(size: 24, weight: .bold))
                Text(Self.dateFmt.string(from: Date()))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            Button { appState.view = "chat" } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary).frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
    }

    // MARK: Daily brief

    private var briefCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("デイリーブリーフ", systemImage: "sun.max")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.orange)
                if appState.dailyBriefAt > 0 {
                    Text("（\(Self.timeFmt.string(from: Date(timeIntervalSince1970: appState.dailyBriefAt))) 時点）")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                if appState.isGeneratingBrief {
                    HStack(spacing: 5) { ProgressView().controlSize(.small).scaleEffect(0.7); Text("生成中…").font(.system(size: 11)).foregroundColor(.secondary) }
                } else {
                    Button { Task { await appState.generateDailyBrief() } } label: {
                        HStack(spacing: 4) { Image(systemName: "arrow.clockwise"); Text(appState.dailyBrief.isEmpty ? "生成" : "更新") }
                            .font(.system(size: 11, weight: .medium))
                    }.buttonStyle(.plain).foregroundColor(.blue)
                }
            }
            if appState.dailyBrief.isEmpty && !appState.isGeneratingBrief {
                Text("「生成」を押すと、今日の予定・タスク・アプリの状況をもとにAIがブリーフを書きます。")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            } else if appState.dailyBrief.isEmpty {
                Text("今日のブリーフを書いています…").font(.system(size: 13)).foregroundColor(.secondary)
            } else {
                Text(appState.dailyBrief)
                    .font(.system(size: 14)).lineSpacing(5)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.orange.opacity(0.10), Color.orange.opacity(0.03)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.18), lineWidth: 0.5))
    }

    // MARK: Schedule card

    private var scheduleCard: some View {
        card(title: "今日の予定", icon: "calendar", more: "スケジュール") { appState.view = "schedule" } content: {
            if appState.todayEvents.isEmpty {
                emptyLine("予定はありません")
            } else {
                ForEach(appState.todayEvents.prefix(6)) { e in
                    HStack(spacing: 8) {
                        Text(e.allDay ? "終日" : Self.timeFmt.string(from: Date(timeIntervalSince1970: e.date)))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.blue).frame(width: 42, alignment: .leading)
                        Text(e.title).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: Tasks card

    private var tasksCard: some View {
        let pending = appState.tasks(status: .doing) + appState.tasks(status: .todo)
        return card(title: "未完了タスク", icon: "checklist", more: "タスク") { appState.view = "tasks" } content: {
            if pending.isEmpty {
                emptyLine("未完了のタスクはありません")
            } else {
                ForEach(pending.prefix(6)) { t in
                    HStack(spacing: 8) {
                        Circle().fill(t.status == .doing ? Color.orange : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(t.title).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        if let aid = t.assigneeId, let e = appState.employees.first(where: { $0.id == aid }) {
                            Text(e.name).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    // MARK: Apps card

    // MARK: Helpers

    private func emptyLine(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundColor(.secondary.opacity(0.8)).padding(.vertical, 4)
    }

    private func card<C: View>(title: String, icon: String, more: String, onMore: @escaping () -> Void,
                               @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(.primary)
                Spacer()
                Button(action: onMore) {
                    HStack(spacing: 2) { Text(more); Image(systemName: "chevron.right").font(.system(size: 9)) }
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 7) { content() }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.02)).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}
