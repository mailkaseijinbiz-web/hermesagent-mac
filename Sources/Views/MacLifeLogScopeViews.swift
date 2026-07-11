import HermesShared
import SwiftUI

// Mac版ライフログの週/月/年スコープ（iOSのHomeViewスコープ切替のMac対応）。
// 日ビューは従来の MacLifeLogView 本体、ここは集計ビューのみ。

enum LifeLogScope: String, CaseIterable, Identifiable {
    case day = "日", week = "週", month = "月", year = "年"
    var id: String { rawValue }
}

struct MacLifeLogScopeView: View {
    let scope: LifeLogScope
    @Binding var anchor: Date

    @State private var records: [String: DayRecord] = [:]   // dateKey → record
    @State private var weekSummaryText: String = ""

    private static let dayKeyFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private var cal: Calendar { Calendar.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            periodHeader
            switch scope {
            case .day: EmptyView()
            case .week: weekView
            case .month: monthView
            case .year: yearView
            }
        }
        .task(id: "\(scope.rawValue)-\(Int(anchor.timeIntervalSince1970))") { await load() }
    }

    // MARK: - 期間ナビゲーション

    private var periodTitle: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP")
        switch scope {
        case .day: return ""
        case .week:
            let s = weekStart, e = cal.date(byAdding: .day, value: 6, to: s)!
            f.dateFormat = "M/d"
            return "\(f.string(from: s))〜\(f.string(from: e)) の週"
        case .month: f.dateFormat = "yyyy年M月"; return f.string(from: anchor)
        case .year:  f.dateFormat = "yyyy年";   return f.string(from: anchor)
        }
    }

    private var periodHeader: some View {
        HStack(spacing: 10) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Text(periodTitle).font(.system(size: 15, weight: .semibold))
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            Spacer()
        }
        .foregroundStyle(.primary)
    }

    private func shift(_ dir: Int) {
        let comp: Calendar.Component = scope == .week ? .weekOfYear : (scope == .month ? .month : .year)
        anchor = cal.date(byAdding: comp, value: dir, to: anchor) ?? anchor
    }

    private var weekStart: Date {
        let wd = cal.component(.weekday, from: anchor)          // 1=日
        let delta = (wd + 5) % 7                                // 月曜始まり
        return cal.startOfDay(for: cal.date(byAdding: .day, value: -delta, to: anchor)!)
    }

    // MARK: - データ読み込み

    private func load() async {
        var keys: [String] = []
        switch scope {
        case .day: return
        case .week:
            keys = (0..<7).map { Self.dayKeyFmt.string(from: cal.date(byAdding: .day, value: $0, to: weekStart)!) }
        case .month:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: anchor))!
            let days = cal.range(of: .day, in: .month, for: anchor)?.count ?? 30
            keys = (0..<days).map { Self.dayKeyFmt.string(from: cal.date(byAdding: .day, value: $0, to: start)!) }
        case .year:
            let start = cal.date(from: cal.dateComponents([.year], from: anchor))!
            let end = cal.date(byAdding: .year, value: 1, to: start)!
            let days = Int(end.timeIntervalSince(start) / 86400)
            keys = (0..<days).map { Self.dayKeyFmt.string(from: cal.date(byAdding: .day, value: $0, to: start)!) }
        }
        var out: [String: DayRecord] = [:]
        for k in keys {
            if let r = await DayRecordStore.shared.persisted(dateKey: k) { out[k] = r }
        }
        records = out
        if scope == .week {
            let startKey = Self.dayKeyFmt.string(from: weekStart)
            if let ws = await AppState.shared.weekSummary(startKey: startKey, force: false) {
                let statsPart = ws.stats.isEmpty ? "" : ws.stats.map { "・" + $0 }.joined(separator: "\n")
                weekSummaryText = [ws.analysis, statsPart].filter { !$0.isEmpty }.joined(separator: "\n\n")
            } else {
                weekSummaryText = ""
            }
        }
    }

    private func record(_ date: Date) -> DayRecord? { records[Self.dayKeyFmt.string(from: date)] }

    // MARK: - 週

    private var weekView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !weekSummaryText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("週の要約", systemImage: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(.purple)
                    Text(weekSummaryText).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.07)))
            }
            statRow(days: (0..<7).compactMap { record(cal.date(byAdding: .day, value: $0, to: weekStart)!) })
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<7, id: \.self) { i in
                    let d = cal.date(byAdding: .day, value: i, to: weekStart)!
                    dayMiniCard(d, record(d))
                }
            }
        }
    }

    private func dayMiniCard(_ date: Date, _ r: DayRecord?) -> some View {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "E\nd"
        return VStack(spacing: 6) {
            Text(f.string(from: date)).font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.center)
                .foregroundStyle(cal.isDateInToday(date) ? Color.accentColor : .secondary)
            if let m = r?.metrics {
                miniMetric("👟", m.steps.map { "\($0 / 1000)k" })
                miniMetric("🌙", m.sleepHours.map { String(format: "%.1f", $0) })
                miniMetric("💻", m.macHours.map { String(format: "%.1f", $0) })
            } else {
                Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private func miniMetric(_ icon: String, _ v: String?) -> some View {
        Text("\(icon) \(v ?? "–")").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
    }

    // MARK: - 月

    private var monthView: some View {
        let start = cal.date(from: cal.dateComponents([.year, .month], from: anchor))!
        let days = cal.range(of: .day, in: .month, for: anchor)?.count ?? 30
        let lead = (cal.component(.weekday, from: start) + 5) % 7   // 月曜始まりの先頭空き
        let maxSteps = max(records.values.compactMap { $0.metrics.steps }.max() ?? 1, 1)
        let cols = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        return VStack(alignment: .leading, spacing: 12) {
            statRow(days: Array(records.values))
            Text("歩数ヒートマップ").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, spacing: 5) {
                ForEach(["月", "火", "水", "木", "金", "土", "日"], id: \.self) {
                    Text($0).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 34) }
                ForEach(1...days, id: \.self) { day in
                    let date = cal.date(byAdding: .day, value: day - 1, to: start)!
                    let steps = record(date)?.metrics.steps ?? 0
                    let intensity = steps == 0 ? 0.05 : 0.15 + 0.75 * Double(steps) / Double(maxSteps)
                    VStack(spacing: 2) {
                        Text("\(day)").font(.system(size: 9.5)).foregroundStyle(.secondary)
                        Text(steps > 0 ? "\(steps / 1000)k" : "").font(.system(size: 9, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(intensity)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                        cal.isDateInToday(date) ? Color.accentColor : .clear, lineWidth: 1.5))
                }
            }
        }
    }

    // MARK: - 年

    private var yearView: some View {
        let year = cal.component(.year, from: anchor)
        return VStack(alignment: .leading, spacing: 10) {
            statRow(days: Array(records.values))
            ForEach(1...12, id: \.self) { month in
                let monthRecs = records.filter {
                    $0.key.hasPrefix(String(format: "%04d-%02d", year, month))
                }.map(\.value)
                yearMonthRow(month: month, recs: monthRecs)
            }
            Text("※ 記録が保存されている日のみ集計（DayRecordの保持範囲に依存）")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func yearMonthRow(month: Int, recs: [DayRecord]) -> some View {
        let steps = recs.compactMap { $0.metrics.steps }
        let avgSteps = steps.isEmpty ? 0 : steps.reduce(0, +) / steps.count
        let macH = recs.compactMap { $0.metrics.macHours }.reduce(0, +)
        let sleep = recs.compactMap { $0.metrics.sleepHours }
        let avgSleep = sleep.isEmpty ? 0 : sleep.reduce(0, +) / Double(sleep.count)
        return HStack(spacing: 10) {
            Text("\(month)月").font(.system(size: 12, weight: .semibold)).frame(width: 36, alignment: .leading)
            if recs.isEmpty {
                Text("記録なし").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green.opacity(0.5))
                        .frame(width: max(4, geo.size.width * min(1, Double(avgSteps) / 12000)), height: 8)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 16)
                Text("👟\(avgSteps)歩/日  💻\(String(format: "%.0f", macH))h  🌙\(String(format: "%.1f", avgSleep))h")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 共通統計行

    private func statRow(days: [DayRecord]) -> some View {
        let steps = days.compactMap { $0.metrics.steps }
        let sleep = days.compactMap { $0.metrics.sleepHours }
        let macH = days.compactMap { $0.metrics.macHours }
        func chip(_ label: String, _ value: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
        return HStack(spacing: 8) {
            chip("記録日数", "\(days.count)日")
            chip("歩数 平均", steps.isEmpty ? "–" : "\(steps.reduce(0, +) / steps.count)歩")
            chip("睡眠 平均", sleep.isEmpty ? "–" : String(format: "%.1fh", sleep.reduce(0, +) / Double(sleep.count)))
            chip("Mac作業 計", macH.isEmpty ? "–" : String(format: "%.0fh", macH.reduce(0, +)))
            Spacer()
        }
    }
}
