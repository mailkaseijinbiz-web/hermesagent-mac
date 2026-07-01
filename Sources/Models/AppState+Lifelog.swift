import Foundation

extension AppState {

    /// 直近 `days` 日の日次データを1行/日のテキストに整形（履歴が無ければ空）。
    func weeklyReviewContext(days: Int = 14) -> String {
        let recent = dailyHistory.suffix(days)
        guard !recent.isEmpty else { return "" }
        return recent.map { r in
            var p: [String] = [r.date]
            if let v = r.steps { p.append("歩\(v)") }
            if let v = r.activeEnergyKcal { p.append("\(v)kcal") }
            if let v = r.restingHeartRate { p.append("安静\(v)") }
            if let v = r.sleepHours { p.append(String(format: "睡眠%.1fh", v)) }
            if let v = r.bodyMassKg { p.append(String(format: "体重%.1fkg", v)) }
            if !r.locations.isEmpty { p.append("場所[\(r.locations)]") }
            if !r.photos.isEmpty { p.append("写真[\(r.photos)]") }
            return p.joined(separator: " / ")
        }.joined(separator: "\n")
    }

    /// 自宅キーワードを反映した表示用サマリ。
    func resolvedLocationSummary(_ raw: String) -> String {
        let kw = homeLocationKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return raw }
        return raw.replacingOccurrences(of: kw, with: "自宅", options: .caseInsensitive)
    }

    func updateLocationSummary(_ s: String) {
        locationSummary = s.trimmingCharacters(in: .whitespacesAndNewlines)
        locationSummaryAt = Date().timeIntervalSince1970
        upsertToday { $0.locations = self.locationSummary }
        scheduleIntentionRefreshIfNeeded()
    }

    func updateLocation(summary: String, points: [LocationPoint]) {
        updateLocationSummary(summary)
        locationPoints = points.filter { $0.lat != 0 || $0.lon != 0 }
    }

    /// 今日の足あとを文脈に。古い（前日以前）サマリは使わない。自宅キーワードは「自宅」に置換。
    var locationContext: String? {
        guard !locationSummary.isEmpty, locationSummaryAt > 0 else { return nil }
        guard Calendar.current.isDateInToday(Date(timeIntervalSince1970: locationSummaryAt)) else { return nil }
        return "今日の行動(訪れた場所): \(resolvedLocationSummary(locationSummary))"
    }

    func updatePhotoSummary(_ s: String) {
        photoSummary = s.trimmingCharacters(in: .whitespacesAndNewlines)
        photoSummaryAt = Date().timeIntervalSince1970
        upsertToday { $0.photos = self.photoSummary }
        scheduleIntentionRefreshIfNeeded()
    }

    var photoContext: String? {
        guard !photoSummary.isEmpty, photoSummaryAt > 0 else { return nil }
        guard Calendar.current.isDateInToday(Date(timeIntervalSince1970: photoSummaryAt)) else { return nil }
        return "今日の写真: \(photoSummary)"
    }
}
