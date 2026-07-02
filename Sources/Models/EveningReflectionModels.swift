import Foundation

struct EveningReflectionAIResult: Equatable {
    var oneLiner: String
    var aiReflection: String
}

enum EveningReflectionAIParser {
    static func parse(_ text: String) -> EveningReflectionAIResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let one = (json["oneLiner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reflection = (json["aiReflection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !one.isEmpty else { return nil }
        return EveningReflectionAIResult(oneLiner: one, aiReflection: reflection)
    }
}
