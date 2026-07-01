import Foundation

/// Date keys and discovery for multi-day LifeLog (`yyyy-MM-dd`).
enum LifeLogDay {
    static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func date(from key: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    static func isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }

    static func isSameDay(_ timestamp: Double, as day: Date) -> Bool {
        Calendar.current.isDate(Date(timeIntervalSince1970: timestamp), inSameDayAs: day)
    }

    /// Noon on `day` — stable sort anchor for daily snapshot rows (health/location/photo).
    static func noonTimestamp(on day: Date) -> Double {
        startOfDay(day).addingTimeInterval(12 * 3600).timeIntervalSince1970
    }

    /// Union of dailyHistory, Mac activity blobs, and memo archives (newest first).
    static func availableDates(history: [AppState.DayRecord]) -> [Date] {
        var keys = Set<String>()
        keys.insert(key(Date()))
        for r in history { keys.insert(r.date) }
        for k in MacActivityLogger.storedActivityDayKeys() { keys.insert(k) }
        for k in MacMemoStore.storedMemoDayKeys() { keys.insert(k) }
        return keys.compactMap { date(from: $0) }.sorted(by: >)
    }
}
