import SwiftUI
import MapKit

/// Home dashboard — a customizable "bento" widget board on a square 4-column grid.
/// 編集モードでウィジェットをドラッグ移動・右下ハンドルでリサイズでき、レイアウトは永続化される。
/// Widgets: 健康 / 自分のリソース / 今日の予定 / タスク / 足あと / 写真 / アプリ / 社員 /
/// デイリーブリーフ / 週次メタ認知レビュー。
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    @State private var editing = false
    @State private var dragId: String? = nil
    @State private var dragTranslation: CGSize = .zero
    @State private var resizeId: String? = nil
    @State private var resizeTranslation: CGSize = .zero

    private let cols = AppState.dashboardCols
    private let gap: CGFloat = 12

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy年M月d日(E)"; return f
    }()
    private static let stampFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M月d日 HH:mm 更新"; return f
    }()

    private let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .mint, .brown]

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11:  return "おはようございます"
        case 11..<17: return "こんにちは"
        case 17..<23: return "こんばんは"
        default:      return "お疲れさまです"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            GeometryReader { geo in
                let cell = max(60, (geo.size.width - gap * CGFloat(cols - 1)) / CGFloat(cols))
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        ForEach(appState.dashboardLayout) { tile in
                            tileView(tile, cell: cell)
                        }
                    }
                    .frame(width: geo.size.width, height: boardHeight(cell), alignment: .topLeading)
                    .padding(.bottom, 24)
                }
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 52)
        .ignoresSafeArea(edges: .top)
        .onAppear { appState.ensureDashboardLayoutComplete(); compact() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.system(size: 24, weight: .bold))
                Text(Self.dateFmt.string(from: Date())).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            if editing {
                Button { appState.resetDashboardLayout() } label: {
                    Text("リセット").font(.system(size: 12)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            Button { withAnimation(.easeInOut(duration: 0.15)) { editing.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: editing ? "checkmark" : "square.grid.2x2")
                    Text(editing ? "完了" : "編集")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(editing ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                .foregroundColor(editing ? .accentColor : .secondary)
                .clipShape(Capsule())
            }.buttonStyle(.plain)
            Button { appState.view = "chat" } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary).frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
    }

    // MARK: Tile (positioned widget with drag + resize)

    @ViewBuilder
    private func tileView(_ tile: AppState.WidgetTile, cell: CGFloat) -> some View {
        let liveW = resizeId == tile.id ? max(cell, span(tile.w, cell) + resizeTranslation.width) : span(tile.w, cell)
        let liveH = resizeId == tile.id ? max(cell, span(tile.h, cell) + resizeTranslation.height) : span(tile.h, cell)
        let baseX = CGFloat(tile.col) * (cell + gap)
        let baseY = CGFloat(tile.row) * (cell + gap)
        let liveX = baseX + (dragId == tile.id ? dragTranslation.width : 0)
        let liveY = baseY + (dragId == tile.id ? dragTranslation.height : 0)

        ZStack(alignment: .topLeading) {
            widget(tile.id).allowsHitTesting(!editing)
            if editing {
                Color.accentColor.opacity(0.001)   // transparent drag surface on top of the card
                    .contentShape(Rectangle())
                    .gesture(dragGesture(tile, cell: cell))
            }
        }
        .frame(width: liveW, height: liveH, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if editing {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundColor(.accentColor.opacity(0.5))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if editing {
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor).clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(5)
                    .gesture(resizeGesture(tile, cell: cell))
            }
        }
        .offset(x: liveX, y: liveY)
        .zIndex(dragId == tile.id || resizeId == tile.id ? 10 : 0)
        .animation(.easeInOut(duration: 0.18), value: appState.dashboardLayout)
    }

    private func dragGesture(_ tile: AppState.WidgetTile, cell: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { v in dragId = tile.id; dragTranslation = v.translation }
            .onEnded { v in
                let step = cell + gap
                let curX = CGFloat(tile.col) * step
                let curY = CGFloat(tile.row) * step
                let newCol = clampInt(Int(((curX + v.translation.width) / step).rounded()), 0, cols - tile.w)
                let newRow = max(0, Int(((curY + v.translation.height) / step).rounded()))
                dragId = nil; dragTranslation = .zero
                commitMove(id: tile.id, col: newCol, row: newRow)
            }
    }

    private func resizeGesture(_ tile: AppState.WidgetTile, cell: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in resizeId = tile.id; resizeTranslation = v.translation }
            .onEnded { v in
                let step = cell + gap
                let newW = clampInt(Int(((span(tile.w, cell) + v.translation.width + gap) / step).rounded()), 1, cols - tile.col)
                let newH = max(1, Int(((span(tile.h, cell) + v.translation.height + gap) / step).rounded()))
                resizeId = nil; resizeTranslation = .zero
                commitResize(id: tile.id, w: newW, h: newH)
            }
    }

    // MARK: Layout math + commit

    private func span(_ n: Int, _ cell: CGFloat) -> CGFloat { cell * CGFloat(n) + gap * CGFloat(max(0, n - 1)) }
    private func clampInt(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), max(lo, hi)) }

    private func boardHeight(_ cell: CGFloat) -> CGFloat {
        let maxRow = appState.dashboardLayout.map { $0.row + $0.h }.max() ?? 1
        return CGFloat(maxRow) * (cell + gap)
    }

    private func overlaps(_ a: AppState.WidgetTile, _ b: AppState.WidgetTile) -> Bool {
        !(a.col + a.w <= b.col || b.col + b.w <= a.col || a.row + a.h <= b.row || b.row + b.h <= a.row)
    }

    private func commitMove(id: String, col: Int, row: Int) {
        guard let i = appState.dashboardLayout.firstIndex(where: { $0.id == id }) else { return }
        var candidate = appState.dashboardLayout[i]
        candidate.col = clampInt(col, 0, cols - candidate.w); candidate.row = max(0, row)
        let others = appState.dashboardLayout.filter { $0.id != id }
        guard !others.contains(where: { overlaps(candidate, $0) }) else { return }   // revert if it would overlap
        appState.dashboardLayout[i] = candidate
        compact()
    }

    private func commitResize(id: String, w: Int, h: Int) {
        guard let i = appState.dashboardLayout.firstIndex(where: { $0.id == id }) else { return }
        var candidate = appState.dashboardLayout[i]
        candidate.w = clampInt(w, 1, cols - candidate.col); candidate.h = max(1, h)
        let others = appState.dashboardLayout.filter { $0.id != id }
        guard !others.contains(where: { overlaps(candidate, $0) }) else { return }
        appState.dashboardLayout[i] = candidate
        compact()
    }

    /// Gravity-up compaction: pull every tile to the lowest free row in its column span so
    /// vertical gaps close automatically. Preserves array order; only rewrites changed rows.
    private func compact() {
        var placed: [AppState.WidgetTile] = []
        for t in appState.dashboardLayout.sorted(by: { $0.row != $1.row ? $0.row < $1.row : $0.col < $1.col }) {
            var cur = t
            while cur.row > 0 {
                var probe = cur; probe.row -= 1
                if placed.contains(where: { overlaps(probe, $0) }) { break }
                cur = probe
            }
            placed.append(cur)
        }
        var newLayout = appState.dashboardLayout
        var changed = false
        for i in newLayout.indices {
            if let p = placed.first(where: { $0.id == newLayout[i].id }), p.row != newLayout[i].row {
                newLayout[i].row = p.row; changed = true
            }
        }
        if changed {
            withAnimation(.easeInOut(duration: 0.2)) { appState.dashboardLayout = newLayout }
        }
    }

    // MARK: Widget registry

    @ViewBuilder
    private func widget(_ id: String) -> some View {
        switch id {
        case "health":    healthWidget
        case "self":      selfWidget
        case "schedule":  scheduleWidget
        case "tasks":     tasksWidget
        case "location":  locationWidget
        case "photos":    photosWidget
        case "apps":      appsWidget
        case "employees": employeesWidget
        case "brief":     briefWidget
        case "review":    reviewWidget
        case "lifelog":   lifelogWidget
        default:          EmptyView()
        }
    }

    // MARK: 健康

    private var healthWidget: some View {
        card(title: "健康", icon: "heart.fill") {
            let h = appState.latestHealth
            HStack(spacing: 8) {
                stat(h?.steps.map { "\($0)" } ?? "—", "歩", "歩数", "figure.walk", .green)
                stat(h?.activeEnergyKcal.map { "\(Int($0))" } ?? "—", "kcal", "消費", "flame.fill", .orange)
                stat(h?.restingHeartRate.map { "\($0)" } ?? "—", "bpm", "安静時", "heart.fill", .red)
                stat(h?.sleepHours.map { String(format: "%.1f", $0) } ?? "—", "h", "睡眠", "bed.double.fill", .indigo)
            }
            let days = Array(appState.dailyHistory.suffix(7))
            if days.contains(where: { ($0.steps ?? 0) > 0 }) {
                Text("7日間の歩数").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary).padding(.top, 2)
                stepsChart(days)
            }
            Spacer(minLength: 0)
        }
    }

    private func stepsChart(_ days: [AppState.DayRecord]) -> some View {
        let maxSteps = max(days.map { $0.steps ?? 0 }.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(height: max(3, 40 * CGFloat(d.steps ?? 0) / CGFloat(maxSteps)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 44)
    }

    private func stat(_ value: String, _ unit: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(color)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(.system(size: 8, weight: .medium)).foregroundColor(.secondary)
            }
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
        .background(Color.primary.opacity(0.03)).cornerRadius(8)
    }

    // MARK: 自分のリソース

    private var selfWidget: some View {
        card(title: "自分のリソース", icon: "cpu") {
            let m = appState.selfModel
            let allocs = m.allocations.filter { $0.percent > 0 }
            if allocs.isEmpty {
                emptyLine("頭のメモリ割り当ては未設定（iOSで設定）")
            } else {
                allocationBar(allocs)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 4) {
                    ForEach(Array(allocs.enumerated()), id: \.element.id) { i, a in
                        HStack(spacing: 4) {
                            Circle().fill(palette[i % palette.count]).frame(width: 7, height: 7)
                            Text("\(a.name) \(a.percent)%").font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Text("稼働 \(m.workStartHour):00–\(m.workEndHour):00"
                 + (m.targetFocusHours > 0 ? String(format: " ・ 目標集中%.1fh/日", m.targetFocusHours) : ""))
                .font(.system(size: 10)).foregroundColor(.secondary).padding(.top, 2)
            Spacer(minLength: 0)
        }
    }

    private func allocationBar(_ allocs: [AppState.ResourceAllocation]) -> some View {
        let total = max(allocs.reduce(0) { $0 + $1.percent }, 100)
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(allocs.enumerated()), id: \.element.id) { i, a in
                    RoundedRectangle(cornerRadius: 3).fill(palette[i % palette.count])
                        .frame(width: max(3, geo.size.width * CGFloat(a.percent) / CGFloat(total)))
                }
                if allocs.reduce(0, { $0 + $1.percent }) < 100 {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                }
            }
        }
        .frame(height: 16)
    }

    // MARK: 今日の予定

    private var scheduleWidget: some View {
        card(title: "今日の予定", icon: "calendar", more: "スケジュール", onMore: { appState.view = "schedule" }) {
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
            Spacer(minLength: 0)
        }
    }

    // MARK: タスク

    private var tasksWidget: some View {
        let pending = appState.tasks(status: .doing) + appState.tasks(status: .todo)
        return card(title: "未完了タスク", icon: "checklist", more: "タスク", onMore: { appState.view = "tasks" }) {
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
            Spacer(minLength: 0)
        }
    }

    // MARK: 足あと / 写真 (compact)

    private var locationWidget: some View {
        card(title: "足あと", icon: "mappin.and.ellipse") {
            let fresh = isToday(appState.locationSummaryAt)
            if fresh, !appState.locationPoints.isEmpty {
                footprintMap(appState.locationPoints)
                if !appState.locationSummary.isEmpty {
                    Text(appState.locationSummary).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                }
            } else if fresh, !appState.locationSummary.isEmpty {
                Text(appState.locationSummary).font(.system(size: 12)).foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                emptyLine("今日の記録なし")
                Spacer(minLength: 0)
            }
        }
    }

    private func footprintMap(_ pts: [AppState.LocationPoint]) -> some View {
        let coords = pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        return Map(initialPosition: .automatic, interactionModes: []) {
            if coords.count >= 2 {
                MapPolyline(coordinates: coords).stroke(.blue, lineWidth: 3)
            }
            ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                Marker("\(i + 1). \(p.name)", coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
                    .tint(.blue)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var photosWidget: some View {
        card(title: "写真", icon: "photo.on.rectangle.angled") {
            if isToday(appState.photoSummaryAt), !appState.photoSummary.isEmpty {
                Text(appState.photoSummary).font(.system(size: 12)).foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                emptyLine("今日の記録なし")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: アプリ / 社員 (compact)

    private var appsWidget: some View {
        card(title: "アプリ", icon: "square.grid.2x2.fill", more: "開く", onMore: { appState.view = "apps" }) {
            Text("\(appState.apps.count)").font(.system(size: 26, weight: .bold))
            let running = appState.runningApps.count
            Text(running > 0 ? "起動中 \(running)" : "\(appState.apps.filter { $0.status == .building }.count) 開発中")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var employeesWidget: some View {
        card(title: "社員", icon: "person.3.fill", more: "会社", onMore: { appState.view = "company" }) {
            Text("\(appState.employees.count)").font(.system(size: 26, weight: .bold))
            let busy = appState.busyEmployees
            Text(busy.isEmpty ? "全員待機中" : "対応中 \(busy.count)名")
                .font(.system(size: 11)).foregroundColor(busy.isEmpty ? .secondary : .purple)
            Spacer(minLength: 0)
        }
    }

    // MARK: デイリーブリーフ (wide)

    private var briefWidget: some View {
        card(title: "今日の振り返り", icon: "sparkles",
             trailing: { regenButton(generating: appState.isGeneratingBrief) { Task { await appState.generateDailyBrief() } } }) {
            if appState.dailyBrief.isEmpty {
                emptyLine("まだ振り返りがありません。右上から生成できます。")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(appState.dailyBrief).font(.system(size: 13)).foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if appState.dailyBriefAt > 0 {
                            Text(Self.stampFmt.string(from: Date(timeIntervalSince1970: appState.dailyBriefAt)))
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 週次メタ認知レビュー (wide)

    private var reviewWidget: some View {
        card(title: "週次メタ認知レビュー", icon: "brain.head.profile",
             trailing: { regenButton(generating: appState.isGeneratingReview) { Task { await appState.generateWeeklyReview() } } }) {
            if appState.weeklyReview.isEmpty {
                emptyLine("数日〜1週間データがたまると、行動パターンの気づきと提案を生成できます。")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(appState.weeklyReview).font(.system(size: 13)).foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if appState.weeklyReviewAt > 0 {
                            Text(Self.stampFmt.string(from: Date(timeIntervalSince1970: appState.weeklyReviewAt)))
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: ライフログ

    private var lifelogWidget: some View {
        card(title: "今日の活動", icon: "clock.arrow.circlepath",
             more: "ライフログ", onMore: { appState.view = "lifelog" }) {
            let entries = MacActivityLogger.shared.todayEntries()
            if entries.isEmpty {
                emptyLine("まだアクティビティがありません")
            } else {
                ForEach(entries.suffix(6).reversed()) { e in
                    HStack(spacing: 6) {
                        Image(systemName: e.kind == "hermes" ? "brain.head.profile" : "menubar.dock.rectangle")
                            .font(.system(size: 10))
                            .foregroundColor(e.kind == "hermes" ? .purple : .secondary)
                            .frame(width: 14)
                        Text(e.appName).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(miniDuration(e.duration))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    }
                }
                if entries.count > 6 {
                    Text("他 \(entries.count - 6) 件").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func miniDuration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(m)m" }
        let rem = m % 60
        return rem == 0 ? "\(m / 60)h" : "\(m / 60)h\(rem)m"
    }

    private func regenButton(generating: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if generating {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 3) { Image(systemName: "arrow.clockwise"); Text("再生成") }
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain).disabled(generating)
    }

    // MARK: Helpers

    private func isToday(_ ts: Double) -> Bool {
        ts > 0 && Calendar.current.isDateInToday(Date(timeIntervalSince1970: ts))
    }

    private func emptyLine(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundColor(.secondary.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
    }

    private func card<C: View, T: View>(title: String, icon: String,
                                        more: String? = nil, onMore: (() -> Void)? = nil,
                                        @ViewBuilder trailing: () -> T = { EmptyView() },
                                        @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 15, weight: .bold)).foregroundColor(.primary)
                Spacer()
                if let more = more, let onMore = onMore {
                    Button(action: onMore) {
                        HStack(spacing: 2) { Text(more); Image(systemName: "chevron.right").font(.system(size: 9)) }
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                trailing()
            }
            VStack(alignment: .leading, spacing: 7) { content() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.02)).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .clipped()
    }
}
