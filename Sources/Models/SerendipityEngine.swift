import Foundation

/// 本人の断片同士から見つけた「意味ある偶然」のヒント。
struct SerendipityHint: Equatable {
    var line: String
    var rationale: String
    var relatedNorthStar: String
}

/// コレクション × 北極星 × 位置からセレンディピティ候補を抽出（feed ではなく本人文脈内）。
enum SerendipityEngine {
    static let maxAge: TimeInterval = 30 * 86400

    static func hints(
        from items: [CollectionItem],
        likes: String,
        goals: String,
        locationSummary: String = "",
        now: Date = Date(),
        maxHints: Int = 2
    ) -> [SerendipityHint] {
        let stars = northStarKeywords(likes: likes, goals: goals)
        guard !stars.isEmpty else { return [] }

        let cutoff = now.addingTimeInterval(-maxAge)
        let recent = items.filter { $0.createdAt >= cutoff }
        guard !recent.isEmpty else { return [] }

        var scored: [(hint: SerendipityHint, score: Double)] = []
        for item in recent {
            let blob = searchableText(for: item)
            guard !blob.isEmpty else { continue }
            for star in stars {
                guard blob.localizedCaseInsensitiveContains(star.keyword) else { continue }
                let label = displayLabel(for: item)
                let age = agePhrase(since: item.createdAt, now: now)
                let line = "\(age)に保存「\(label)」× \(star.label)「\(star.keyword)」"
                let rationale = "🎯 \(star.label)「\(star.keyword)」× \(age)の保存"
                let recency = max(0, 1 - item.createdAt.timeIntervalSince(cutoff) / maxAge)
                scored.append((SerendipityHint(line: line, rationale: rationale, relatedNorthStar: star.keyword), recency + 1))
            }
        }

        if scored.isEmpty, !locationSummary.isEmpty {
            let places = locationSummary.split(separator: "→").map { $0.trimmingCharacters(in: .whitespaces) }
            for item in recent.prefix(20) {
                let label = displayLabel(for: item)
                for place in places where place.count >= 2 {
                    if label.localizedCaseInsensitiveContains(place) || searchableText(for: item).localizedCaseInsensitiveContains(place) {
                        let age = agePhrase(since: item.createdAt, now: now)
                        let line = "\(age)の保存「\(label)」× 今日の足あと「\(place)」"
                        scored.append((SerendipityHint(line: line, rationale: "📍 \(place) × 保存した \(label)", relatedNorthStar: place), 0.8))
                    }
                }
            }
        }

        let ranked = scored.sorted { $0.score > $1.score }
        var seen: Set<String> = []
        var out: [SerendipityHint] = []
        for entry in ranked {
            let key = entry.hint.line
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(entry.hint)
            if out.count >= maxHints { break }
        }
        return out
    }

    // MARK: - Helpers

    private struct StarKeyword {
        let label: String
        let keyword: String
    }

    private static func northStarKeywords(likes: String, goals: String) -> [StarKeyword] {
        var out: [StarKeyword] = []
        for part in tokenize(goals) where part.count >= 2 {
            out.append(StarKeyword(label: "目標", keyword: part))
        }
        for part in tokenize(likes) where part.count >= 2 {
            out.append(StarKeyword(label: "好き", keyword: part))
        }
        return out
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "、", with: ",")
            .components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func searchableText(for item: CollectionItem) -> String {
        [item.title, item.note, item.text, item.url].joined(separator: " ")
    }

    private static func displayLabel(for item: CollectionItem) -> String {
        if !item.title.isEmpty { return String(item.title.prefix(40)) }
        if !item.text.isEmpty { return String(item.text.prefix(40)) }
        if !item.url.isEmpty {
            let u = item.url
            if let host = URL(string: u)?.host { return host }
            return String(u.prefix(40))
        }
        return item.kind
    }

    private static func agePhrase(since: Date, now: Date) -> String {
        let days = Int(now.timeIntervalSince(since) / 86400)
        if days <= 0 { return "今日" }
        if days == 1 { return "昨日" }
        if days < 7 { return "\(days)日前" }
        if days < 14 { return "1週間前" }
        if days < 28 { return "\(days / 7)週間前" }
        return "\(days / 30)ヶ月前"
    }
}
