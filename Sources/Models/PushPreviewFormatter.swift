import Foundation

/// Formats assistant message text for APNs — never show raw ```json fences or JSON blobs.
enum PushPreviewFormatter {

    static func body(from raw: String, sessionTitle: String? = nil, limit: Int = 140) -> String {
        let cleaned = collapseWhitespace(stripMarkdownNoise(extractReadableText(from: raw)))
        if !cleaned.isEmpty {
            return String(cleaned.prefix(limit))
        }
        let title = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty, title != "(無題)" {
            return String("\(title)から新しい応答".prefix(limit))
        }
        return "新しい応答があります"
    }

    /// Pull human-readable text from model output (JSON blocks, intention cards, prose).
    static func extractReadableText(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let parsed = IntentionJSON.parse(trimmed) {
            if let card = parsed.cards.first {
                let sub = card.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sub.isEmpty { return sub }
                return card.title
            }
            let hint = parsed.vitalHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hint.isEmpty { return hint }
        }

        if let fromJSON = summaryFromJSONObject(trimmed) { return fromJSON }

        let unfenced = stripCodeFences(trimmed)
        if unfenced != trimmed, let fromJSON = summaryFromJSONObject(unfenced) { return fromJSON }

        if looksLikeJSONBlob(unfenced) { return "" }
        return unfenced
    }

    // MARK: - Private

    private static func stripCodeFences(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "```") {
            guard let close = s.range(of: "```", range: open.upperBound..<s.endIndex) else {
                s = String(s[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            let inner = String(s[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let before = String(s[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(s[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            s = [before, inner, after].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeJSONBlob(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return false }
        return first == "{" || first == "["
    }

    private static func summaryFromJSONObject(_ text: String) -> String? {
        let jsonText: String = {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let s = t.firstIndex(of: "{"), let e = t.lastIndex(of: "}") { return String(t[s...e]) }
            if let s = t.firstIndex(of: "["), let e = t.lastIndex(of: "]") { return String(t[s...e]) }
            return t
        }()
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let dict = root as? [String: Any] {
            for key in ["message", "text", "content", "summary", "body", "vitalHint", "title"] {
                if let s = dict[key] as? String {
                    let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !v.isEmpty { return v }
                }
            }
            if let cards = dict["cards"] as? [[String: Any]] {
                for card in cards {
                    if let sub = card["subtitle"] as? String {
                        let v = sub.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { return v }
                    }
                    if let title = card["title"] as? String {
                        let v = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { return v }
                    }
                }
            }
        }
        return nil
    }

    private static func stripMarkdownNoise(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
