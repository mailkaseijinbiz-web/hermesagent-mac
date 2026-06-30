import SwiftUI

// MARK: - Flow layout（チップの折り返し表示用）

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            rowH = max(rowH, s.height); x += s.width + spacing
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            rowH = max(rowH, s.height); x += s.width + spacing
        }
    }
}

// MARK: - Timeline item (Mac activity / iOS data / memo)

enum MacLifeLogItem: Identifiable {
    case activity(MacActivityEntry)
    case memo(MacMemo)
    case iOSHealth(HealthSnapshot, Date)    // ヘルスデータ + 受信時刻
    case iOSLocation(String, Date)          // 解決済みロケーションサマリ + 受信時刻
    case iOSPhoto(String, Date)             // 写真サマリ + 受信時刻

    var id: String {
        switch self {
        case .activity(let a):      return "a-\(a.id)"
        case .memo(let m):          return "m-\(m.id)"
        case .iOSHealth(_, let t):  return "ih-\(t.timeIntervalSince1970)"
        case .iOSLocation(_, let t):return "il-\(t.timeIntervalSince1970)"
        case .iOSPhoto(_, let t):   return "ip-\(t.timeIntervalSince1970)"
        }
    }
    var time: Date {
        switch self {
        case .activity(let a):      return a.startDate
        case .memo(let m):          return m.time
        case .iOSHealth(_, let t):  return t
        case .iOSLocation(_, let t):return t
        case .iOSPhoto(_, let t):   return t
        }
    }
}

// MARK: - Main view

struct MacLifeLogView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var memoStore = MacMemoStore.shared
    @State private var entries: [MacActivityEntry] = []
    @State private var showMemoInput      = false
    @State private var newMemoText        = ""
    @State private var editingMemo: MacMemo? = nil
    @State private var editMemoText       = ""
    @State private var showHomeEditor     = false
    @State private var homeKeywordDraft   = ""
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var timeline: [MacLifeLogItem] {
        let cal   = Calendar.current
        var items = entries.map { MacLifeLogItem.activity($0) }
                  + memoStore.todayMemos.map { MacLifeLogItem.memo($0) }

        // iOS ヘルスデータ（今日受信分のみ）
        if let h = appState.latestHealth, h.updatedAt > 0 {
            let t = Date(timeIntervalSince1970: h.updatedAt)
            if cal.isDateInToday(t) { items.append(.iOSHealth(h, t)) }
        }
        // iOS 位置情報（今日受信分のみ）
        if !appState.locationSummary.isEmpty, appState.locationSummaryAt > 0 {
            let t = Date(timeIntervalSince1970: appState.locationSummaryAt)
            if cal.isDateInToday(t) {
                items.append(.iOSLocation(appState.resolvedLocationSummary(appState.locationSummary), t))
            }
        }
        // iOS 写真サマリ（今日受信分のみ）
        if !appState.photoSummary.isEmpty, appState.photoSummaryAt > 0 {
            let t = Date(timeIntervalSince1970: appState.photoSummaryAt)
            if cal.isDateInToday(t) { items.append(.iOSPhoto(appState.photoSummary, t)) }
        }

        return items.sorted { $0.time < $1.time }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                dateHeader
                    .padding(.bottom, 16)

                summaryCard
                    .padding(.bottom, 16)

                if !appState.locationSummary.isEmpty {
                    locationBadge.padding(.bottom, 14)
                }

                if timeline.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(timeline.enumerated()), id: \.element.id) { idx, item in
                        MacTimelineRow(
                            item: item,
                            isLast: idx == timeline.count - 1,
                            onEditMemo: { m in editingMemo = m; editMemoText = m.text },
                            onDeleteMemo: { id in memoStore.deleteMemo(id: id) }
                        )
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 52)
            .padding(.bottom, 80)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .bottomTrailing) { fab }
        .sheet(isPresented: $showMemoInput) { memoInputSheet }
        .sheet(item: $editingMemo) { m in memoEditSheet(m) }
        .sheet(isPresented: $showHomeEditor) { homeEditorSheet }
        .onAppear { refresh() }
        .onReceive(refreshTimer) { _ in refresh() }
        .task { await appState.generateLifelogSummary() }
    }

    private func refresh() {
        entries = MacActivityLogger.shared.todayEntries()
    }

    // MARK: - Subviews

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(.purple)
                Text("今日の要約")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.purple)
                Spacer()
                if appState.isGeneratingLifelogSummary {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                } else {
                    Button {
                        Task { await appState.generateLifelogSummary(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if appState.isGeneratingLifelogSummary && appState.lifelogSummary.isEmpty {
                Text("要約を生成中…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if appState.lifelogSummary.isEmpty {
                Button {
                    Task { await appState.generateLifelogSummary(forceRefresh: true) }
                } label: {
                    Text("要約を生成する")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                Text(appState.lifelogSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if appState.lifelogSummaryAt > 0 {
                    let tf = DateFormatter(); let _ = { tf.dateFormat = "HH:mm" }()
                    Text(tf.string(from: Date(timeIntervalSince1970: appState.lifelogSummaryAt)) + " に生成")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.05))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.15), lineWidth: 1))
    }

    private var dateHeader: some View {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "M月d日(EEEE)"
        return HStack {
            Text(df.string(from: Date()))
                .font(.system(size: 22, weight: .bold))
            Spacer()
            Button { refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var locationBadge: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                Text(appState.resolvedLocationSummary(appState.locationSummary))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.blue.opacity(0.07))
            .cornerRadius(8)

            // 自宅登録ボタン
            Button {
                homeKeywordDraft = appState.homeLocationKeyword
                showHomeEditor = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: appState.homeLocationKeyword.isEmpty ? "house" : "house.fill")
                        .font(.system(size: 11))
                    Text(appState.homeLocationKeyword.isEmpty ? "自宅を登録" : "自宅設定済み")
                        .font(.system(size: 11))
                }
                .foregroundStyle(appState.homeLocationKeyword.isEmpty ? Color.secondary : Color.blue)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    private var homeEditorSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("自宅を登録", systemImage: "house.fill")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("キャンセル") { showHomeEditor = false }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("保存") {
                    appState.homeLocationKeyword = homeKeywordDraft
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    showHomeEditor = false
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            .padding()
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("現在地サマリ:")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(appState.locationSummary.isEmpty ? "（まだ取得されていません）" : appState.locationSummary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(6)
                Text("上の地名から自宅に当たるキーワードをコピーして貼り付けてください。\n一致する部分がすべて「自宅」と表示されます。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("例: 本町4丁目5-16", text: $homeKeywordDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                if !homeKeywordDraft.isEmpty && !appState.locationSummary.isEmpty {
                    let preview = appState.locationSummary.replacingOccurrences(
                        of: homeKeywordDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                        with: "自宅", options: .caseInsensitive)
                    Text("プレビュー: \(preview)")
                        .font(.system(size: 11)).foregroundStyle(.blue)
                        .lineLimit(2)
                }
                if !appState.homeLocationKeyword.isEmpty {
                    Button("登録を解除") {
                        homeKeywordDraft = ""
                        appState.homeLocationKeyword = ""
                        showHomeEditor = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.8))
                    .font(.system(size: 12))
                }
            }
            .padding()
        }
        .frame(width: 440)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("まだアクティビティがありません")
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var fab: some View {
        Button { showMemoInput = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.accentColor)
                .clipShape(Circle())
                .shadow(radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(24)
    }

    private var memoInputSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("メモを追加").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("キャンセル") { showMemoInput = false; newMemoText = "" }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("保存") {
                    let t = newMemoText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { memoStore.addMemo(t); newMemoText = "" }
                    showMemoInput = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(newMemoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? .secondary : Color.accentColor)
            }
            .padding()
            Divider()
            TextEditor(text: $newMemoText)
                .font(.system(size: 14))
                .frame(minHeight: 120)
                .padding(8)
        }
        .frame(width: 400)
    }

    private func memoEditSheet(_ m: MacMemo) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("メモを編集").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("キャンセル") { editingMemo = nil }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("保存") {
                    let t = editMemoText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { memoStore.updateMemo(id: m.id, text: t) }
                    editingMemo = nil
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            .padding()
            Divider()
            TextEditor(text: $editMemoText)
                .font(.system(size: 14))
                .frame(minHeight: 120)
                .padding(8)
        }
        .frame(width: 400)
    }
}

// MARK: - Timeline row

struct MacTimelineRow: View {
    let item: MacLifeLogItem
    let isLast: Bool
    let onEditMemo: (MacMemo) -> Void
    let onDeleteMemo: (String) -> Void

    private var timeStr: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: item.time)
    }

    private var dotColor: Color {
        switch item {
        case .activity(let a):  return a.kind == "hermes" ? .purple : Color(.systemGray)
        case .memo:             return Color.accentColor
        case .iOSHealth:        return Color.green
        case .iOSLocation:      return Color.blue
        case .iOSPhoto:         return Color.orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(timeStr)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 3)

            VStack(spacing: 0) {
                Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 5)
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 24)

            rowContent
                .padding(.leading, 8)
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch item {
        case .activity(let a):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: a.kind == "hermes" ? "brain.head.profile" : "menubar.dock.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(a.kind == "hermes" ? Color.purple : .secondary)
                    Text(a.appName)
                        .font(.system(size: 13, weight: .medium))
                    Text(durationLabel(a.duration))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // ページタイトル（ブラウザ名サフィックスを除去して表示）
                let pageTitle: String? = {
                    guard let wt = a.windowTitle, !wt.isEmpty else {
                        return (!a.label.isEmpty && a.label != a.appName) ? a.label : nil
                    }
                    return stripBrowserSuffix(wt)
                }()
                if let pt = pageTitle {
                    Text(pt)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // URL のホスト部分（ブラウザエントリのみ）
                if let urlStr = a.url, let host = URL(string: urlStr)?.host, !host.isEmpty {
                    Text(host)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .memo(let m):
            Text(m.text)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)
                .contextMenu {
                    Button("編集") { onEditMemo(m) }
                    Divider()
                    Button("削除", role: .destructive) { onDeleteMemo(m.id) }
                }

        case .iOSHealth(let h, _):
            iOSCard(icon: "iphone", label: "iPhone ヘルスケア", tint: .green) {
                healthChips(h)
            }

        case .iOSLocation(let loc, _):
            iOSCard(icon: "iphone", label: "iPhone 位置情報", tint: .blue) {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10)).foregroundStyle(.blue)
                    Text(loc)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }

        case .iOSPhoto(let summary, _):
            iOSCard(icon: "iphone", label: "iPhone 写真", tint: .orange) {
                HStack(spacing: 4) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    Text(summary)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private func iOSCard<C: View>(icon: String, label: String, tint: Color, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10)).foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(tint.opacity(0.06))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func healthChips(_ h: HealthSnapshot) -> some View {
        let chips: [(String, String)] = [
            h.steps.map { ("figure.walk", "\($0)歩") },
            h.activeEnergyKcal.map { ("flame.fill", "\(Int($0))kcal") },
            h.heartRate.map { ("heart.fill", "\($0)bpm") },
            h.restingHeartRate.map { ("heart", "安静\($0)bpm") },
            h.sleepHours.map { ("moon.fill", String(format: "睡眠%.1fh", $0)) },
            h.distanceKm.map { ("map.fill", String(format: "%.1fkm", $0)) },
        ].compactMap { $0 }
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.0) { icon, text in
                HStack(spacing: 3) {
                    Image(systemName: icon).font(.system(size: 9)).foregroundStyle(.green)
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.green.opacity(0.1))
                .cornerRadius(5)
            }
        }
    }

    private func durationLabel(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(m)分" }
        let h = m / 60; let rem = m % 60
        return rem == 0 ? "\(h)時間" : "\(h)h\(rem)m"
    }

    private func stripBrowserSuffix(_ title: String) -> String {
        let suffixes = [" - Google Chrome", " - Mozilla Firefox", " — Safari",
                        " - Arc", " - Microsoft Edge"]
        for s in suffixes where title.hasSuffix(s) {
            return String(title.dropLast(s.count))
        }
        return title
    }
}
