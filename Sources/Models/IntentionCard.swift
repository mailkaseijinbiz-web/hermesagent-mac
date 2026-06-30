import Foundation

// MARK: - Intention cards (インテンション引き出し UI)

/// What happens when the user taps an intention card.
struct IntentionAction: Codable, Equatable {
    /// task | markTask | chat | none
    var type: String
    var taskTitle: String?
    var taskId: String?
    /// EmployeeRole raw value (assistant, engineer, …).
    var employeeRole: String?
    /// Prefilled chat message when opening a conversation.
    var chatPrompt: String?
}

/// A single intention hypothesis surfaced to the user.
struct IntentionCard: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var icon: String
    /// recover | focus | rest | explore | task
    var kind: String
    var action: IntentionAction
}

/// Today's intention set returned by `/api/intention/today`.
struct IntentionToday: Codable, Equatable {
    var vitalHint: String = ""
    var vitalityMode: String = "steady"
    var cards: [IntentionCard] = []
    var generatedAt: Double = 0
    var selectedId: String?
    var dismissedIds: [String] = []
}

enum IntentionJSON {
    /// Extract and decode intention cards from model output (raw JSON or ```json fence).
    static func parse(_ text: String) -> (vitalHint: String, vitalityMode: String, cards: [IntentionCard])? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let jsonText: String = {
            if let start = trimmed.range(of: "```json"),
               let end = trimmed.range(of: "```", range: start.upperBound..<trimmed.endIndex) {
                return String(trimmed[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let start = trimmed.range(of: "```"),
               let end = trimmed.range(of: "```", range: start.upperBound..<trimmed.endIndex) {
                return String(trimmed[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let s = trimmed.firstIndex(of: "{"), let e = trimmed.lastIndex(of: "}") {
                return String(trimmed[s...e])
            }
            return trimmed
        }()
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["cards"] as? [[String: Any]] else { return nil }
        let vitalHint = (root["vitalHint"] as? String) ?? ""
        let vitalityMode = (root["vitalityMode"] as? String) ?? "steady"
        var cards: [IntentionCard] = []
        for (i, item) in arr.prefix(3).enumerated() {
            guard let title = item["title"] as? String,
                  let subtitle = item["subtitle"] as? String else { continue }
            let id = (item["id"] as? String) ?? "card-\(i)"
            let icon = (item["icon"] as? String) ?? "sparkles"
            let kind = (item["kind"] as? String) ?? "focus"
            let act = item["action"] as? [String: Any] ?? [:]
            let action = IntentionAction(
                type: (act["type"] as? String) ?? "none",
                taskTitle: act["taskTitle"] as? String,
                taskId: act["taskId"] as? String,
                employeeRole: act["employeeRole"] as? String,
                chatPrompt: act["chatPrompt"] as? String
            )
            cards.append(IntentionCard(id: id, title: title, subtitle: subtitle, icon: icon, kind: kind, action: action))
        }
        guard !cards.isEmpty else { return nil }
        return (vitalHint, vitalityMode, cards)
    }
}
