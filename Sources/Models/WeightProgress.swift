import Foundation

/// 体重の進捗ライン（最新値と7日前比・30日前比）。健康目標の閉ループ用に
/// デイリーブリーフへ毎日注入する。判断語は付けず事実のみ（解釈はコーチ側）。
enum WeightProgress {

    /// dailyHistory（date昇順でなくてもよい）から進捗ラインを作る。体重2記録未満ならnil。
    static func line(history: [AppState.DayRecord]) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let weighed: [(date: Date, kg: Double)] = history
            .compactMap { r in
                guard let kg = r.bodyMassKg, let d = f.date(from: r.date) else { return nil }
                return (d, kg)
            }
            .sorted { $0.date < $1.date }
        guard let latest = weighed.last else { return nil }
        guard weighed.count >= 2 else {
            return String(format: "体重 %.1fkg（比較できる過去記録なし）", latest.kg)
        }

        // 「n日前比」= latestからn日以上前の記録のうち最も新しいもの
        func delta(daysBack: Int, minGap: Int) -> Double? {
            let cutoff = latest.date.addingTimeInterval(-Double(daysBack) * 86400 + 43200)
            guard let ref = weighed.last(where: { $0.date <= cutoff }),
                  latest.date.timeIntervalSince(ref.date) >= Double(minGap) * 86400 else { return nil }
            return latest.kg - ref.kg
        }

        var parts: [String] = []
        if let w = delta(daysBack: 7, minGap: 5)   { parts.append(String(format: "7日前比%+.1fkg", w)) }
        if let m = delta(daysBack: 30, minGap: 21) { parts.append(String(format: "30日前比%+.1fkg", m)) }
        if parts.isEmpty {
            let first = weighed.first!
            let days = Int(latest.date.timeIntervalSince(first.date) / 86400)
            parts.append(String(format: "%d日間で%+.1fkg", days, latest.kg - first.kg))
        }
        return String(format: "体重 %.1fkg（", latest.kg) + parts.joined(separator: "・") + "）"
    }
}
