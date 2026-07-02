import Foundation

/// Detects health-trend questions and builds chart JSON for ```chart-line``` blocks in chat.
enum HealthTrendQuery {
    enum Metric { case weight, hba1c }

    static func metric(in text: String) -> Metric? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if matchesWeight(t) { return .weight }
        if matchesHbA1c(t) { return .hba1c }
        return nil
    }

    @MainActor
    static func chartBlock(for text: String) -> String? {
        guard let metric = metric(in: text),
              let json = chartJSON(for: metric) else { return nil }
        return "```chart-line\n\(json)\n```"
    }

    @MainActor
    static func chartJSON(for metric: Metric) -> String? {
        switch metric {
        case .weight: return buildWeightChartJSON()
        case .hba1c: return buildHbA1cChartJSON()
        }
    }

    private static func matchesWeight(_ t: String) -> Bool {
        let lower = t.lowercased()
        guard t.contains("体重") || lower.contains("weight") || lower.contains("body mass") else { return false }
        return t.contains("推移") || t.contains("グラフ") || t.contains("変化") || t.contains("履歴")
            || t.contains("経過") || lower.contains("trend") || lower.contains("chart") || t.contains("見せ")
            || t.contains("教え") || t.contains("どう")
    }

    private static func matchesHbA1c(_ t: String) -> Bool {
        let lower = t.lowercased()
        guard t.contains("HbA1c") || t.contains("hba1c") || t.contains("ヘモグロビン") || t.contains("糖化") else { return false }
        return t.contains("推移") || t.contains("グラフ") || t.contains("変化") || t.contains("履歴")
            || t.contains("経過") || lower.contains("trend") || t.contains("見せ") || t.contains("教え")
    }

    @MainActor
    private static func buildWeightChartJSON() -> String? {
        let records = WeightRecordStore.all().sorted { $0.recordedAt < $1.recordedAt }.suffix(30)
        guard records.count >= 2 else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ja_JP")
        fmt.dateFormat = "M/d"
        let data: [[String: Any]] = records.map { r in
            ["label": fmt.string(from: Date(timeIntervalSince1970: r.recordedAt)), "value": r.kg]
        }
        let payload: [String: Any] = [
            "type": "line",
            "title": "体重の推移",
            "yLabel": "kg",
            "data": data,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: jsonData, encoding: .utf8) else { return nil }
        return str
    }

    @MainActor
    private static func buildHbA1cChartJSON() -> String? {
        let records = HbA1cRecordStore.all().sorted { $0.recordedAt < $1.recordedAt }.suffix(30)
        guard records.count >= 2 else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ja_JP")
        fmt.dateFormat = "M/d"
        let data: [[String: Any]] = records.map { r in
            ["label": fmt.string(from: Date(timeIntervalSince1970: r.recordedAt)), "value": r.percent]
        }
        let payload: [String: Any] = [
            "type": "line",
            "title": "HbA1c の推移",
            "yLabel": "%",
            "data": data,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: jsonData, encoding: .utf8) else { return nil }
        return str
    }
}
