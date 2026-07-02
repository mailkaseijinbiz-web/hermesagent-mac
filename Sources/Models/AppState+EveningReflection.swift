import Foundation

extension AppState {
    private static let eveningReflectionDailyKey = "eveningReflectionDaily"

    func saveEveningReflectionDaily(dateKey: String, jsonBody: String) {
        var all: [String: String] = Self.loadJSON(Self.eveningReflectionDailyKey) ?? [:]
        all[dateKey] = jsonBody
        Self.saveJSON(all, Self.eveningReflectionDailyKey)
    }

    func eveningReflectionDailyJSON(dateKey: String) -> String? {
        let all: [String: String]? = Self.loadJSON(Self.eveningReflectionDailyKey)
        return all?[dateKey]
    }
}
