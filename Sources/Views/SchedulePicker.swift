import SwiftUI

/// 人間に読みやすいスケジュール入力。内部状態から hermes cron が解釈できる文字列
/// （`MM HH * * dow` / `0 * * * *` / `30m` / `every 2h`）を生成し、`schedule` バインディングへ書き戻す。
/// 既存ジョブ編集時は現在の文字列を逆解析してUIへ復元（解釈できない複雑な式はカスタムcronに退避）。
/// 注: スケジュールはシステムのローカル時刻で解釈される。
struct SchedulePicker: View {
    @Binding var schedule: String

    enum Mode: String, CaseIterable, Identifiable {
        case daily, weekdays, weekly, hourly, minutes, hours, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily:    return "毎日"
            case .weekdays: return "平日（月〜金）"
            case .weekly:   return "毎週（曜日を指定）"
            case .hourly:   return "毎時"
            case .minutes:  return "〜分ごと"
            case .hours:    return "〜時間ごと"
            case .custom:   return "カスタム（cron式）"
            }
        }
    }

    // cron の曜日: 0=日 … 6=土
    private static let dowNames = ["日", "月", "火", "水", "木", "金", "土"]

    @State private var mode: Mode = .daily
    @State private var time: Date = SchedulePicker.timeAt(9, 0)
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5]   // 既定: 月〜金
    @State private var interval: Int = 30
    @State private var custom: String = ""
    @State private var lastGenerated: String = ""
    @State private var didInit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 頻度プルダウン
            Menu {
                ForEach(Mode.allCases) { m in
                    Button(m.label) { mode = m; regen() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(mode.label).font(.system(size: 12)).foregroundColor(.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundColor(.secondary)
                }
                .padding(8).background(Color.primary.opacity(0.05)).cornerRadius(6)
            }
            .menuStyle(.borderlessButton)

            // モード別コントロール
            switch mode {
            case .daily, .weekdays, .weekly:
                if mode == .weekly { weekdayChips }
                DatePicker("時刻", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .onChange(of: time) { _, _ in regen() }
            case .hourly:
                EmptyView()
            case .minutes, .hours:
                Stepper(value: $interval, in: 1...(mode == .minutes ? 720 : 168)) {
                    Text(mode == .minutes ? "\(interval) 分ごと" : "\(interval) 時間ごと")
                        .font(.system(size: 12))
                }
                .onChange(of: interval) { _, _ in regen() }
            case .custom:
                TextField("例: 0 9 * * *  /  30m  /  every 2h", text: $custom)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(8).background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .onChange(of: custom) { _, new in schedule = new; lastGenerated = new }
            }

            // 人間向けサマリー
            Text(summary)
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .onAppear {
            if !didInit { parse(schedule); didInit = true }
        }
        .onChange(of: schedule) { _, new in
            if new != lastGenerated { parse(new) }   // 外部(プリフィル等)からの変更を反映
        }
    }

    private var weekdayChips: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { d in
                let on = weekdays.contains(d)
                Button {
                    if on { weekdays.remove(d) } else { weekdays.insert(d) }
                    regen()
                } label: {
                    Text(Self.dowNames[d])
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .frame(width: 24, height: 24)
                        .background(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
                        .foregroundColor(on ? .accentColor : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 生成

    private func regen() {
        let s: String
        let (h, m) = Self.hm(time)
        switch mode {
        case .daily:    s = "\(m) \(h) * * *"
        case .weekdays: s = "\(m) \(h) * * 1-5"
        case .weekly:
            let days = weekdays.sorted().map(String.init).joined(separator: ",")
            s = days.isEmpty ? "\(m) \(h) * * *" : "\(m) \(h) * * \(days)"
        case .hourly:   s = "0 * * * *"
        case .minutes:  s = "\(interval)m"
        case .hours:    s = "every \(interval)h"
        case .custom:   s = custom
        }
        schedule = s
        lastGenerated = s
    }

    private var summary: String {
        let t = Self.hhmm(time)
        switch mode {
        case .daily:    return "毎日 \(t) に実行（ローカル時刻）"
        case .weekdays: return "平日（月〜金）\(t) に実行"
        case .weekly:
            let names = weekdays.sorted().map { Self.dowNames[$0] }.joined(separator: "・")
            return names.isEmpty ? "曜日を選んでください" : "毎週 \(names)曜 \(t) に実行"
        case .hourly:   return "毎時 0 分に実行"
        case .minutes:  return "\(interval) 分ごとに実行"
        case .hours:    return "\(interval) 時間ごとに実行"
        case .custom:   return custom.isEmpty ? "cron式を入力してください" : "cron: \(custom)"
        }
    }

    // MARK: - 逆解析

    private func parse(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lastGenerated = s

        if s.isEmpty {   // 新規作成: 既定（毎日9:00）にして書き戻す
            mode = .daily; time = Self.timeAt(9, 0); regen(); return
        }
        // 間隔: "30m" / "every 2h" / "every 30m"
        if let n = match(s, #"^(\d+)\s*m$"#) { mode = .minutes; interval = n; return }
        if let n = match(s, #"^every\s+(\d+)\s*h$"#) { mode = .hours; interval = n; return }
        if let n = match(s, #"^every\s+(\d+)\s*m$"#) { mode = .minutes; interval = n; return }

        // 5フィールド cron
        let f = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if f.count == 5 {
            let (mn, hr, dom, mon, dow) = (f[0], f[1], f[2], f[3], f[4])
            if mn == "0", hr == "*", dom == "*", mon == "*", dow == "*" { mode = .hourly; return }
            if dom == "*", mon == "*", let H = Int(hr), let M = Int(mn) {
                time = Self.timeAt(H, M)
                if dow == "*" { mode = .daily; return }
                if dow == "1-5" { mode = .weekdays; return }
                if let days = parseDow(dow) { mode = .weekly; weekdays = days; return }
            }
        }
        // 解釈不能 → カスタム
        mode = .custom; custom = s
    }

    /// 曜日フィールド（"1,3,5" / "0" など単一値のカンマ列）を Set へ。範囲等は nil。
    private func parseDow(_ dow: String) -> Set<Int>? {
        var out = Set<Int>()
        for part in dow.split(separator: ",") {
            guard let v = Int(part), (0...7).contains(v) else { return nil }
            out.insert(v == 7 ? 0 : v)   // 7 と 0 はどちらも日曜
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - 小道具

    private func match(_ s: String, _ pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    private static func timeAt(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
    }
    private static func hm(_ d: Date) -> (Int, Int) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0, c.minute ?? 0)
    }
    private static func hhmm(_ d: Date) -> String {
        let (h, m) = hm(d)
        return String(format: "%d:%02d", h, m)
    }
}
