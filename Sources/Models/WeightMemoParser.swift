import Foundation

/// Extracts body weight (kg) from lifelog memo text.
enum WeightMemoParser {

    /// Parses weight in kilograms. Returns nil if not found or outside 20–300 kg.
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let patterns = [
            #"(?i)体重\s*(?:は|が|も)?\s*[:：]?\s*(\d{2,3}(?:\.\d)?)\s*kg?"#,
            #"(?i)(\d{2,3}(?:\.\d)?)\s*kg"#,
            #"体重\s*(?:は|が|も)?\s*(\d{2,3}(?:\.\d)?)"#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: t),
                  let raw = Double(t[r]) else { continue }
            return normalize(raw)
        }
        return nil
    }

    static func displayLabel(kg: Double) -> String {
        String(format: "体重 %.1fkg", kg)
    }

    private static func normalize(_ kg: Double) -> Double? {
        guard kg >= 20, kg <= 300 else { return nil }
        return (kg * 10).rounded() / 10
    }
}
