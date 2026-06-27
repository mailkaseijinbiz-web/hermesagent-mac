import Foundation

/// Google Calendar API v3 sync.
/// Fetches events from the user's primary calendar and maps them to
/// `ScheduleEvent` (id prefixed with "gcal:" to distinguish from local events).
@MainActor
final class GoogleCalendarSync: ObservableObject {
    static let shared = GoogleCalendarSync()

    @Published var events: [ScheduleEvent] = []
    @Published var isSyncing: Bool = false
    @Published var lastSyncStatus: String = ""

    private let base = "https://www.googleapis.com/calendar/v3"
    private var syncTask: Task<Void, Never>? = nil

    private init() {}

    // MARK: - Sync

    func startPeriodicSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)  // 5 min
            }
        }
    }

    func stopPeriodicSync() { syncTask?.cancel(); syncTask = nil }

    func sync() async {
        guard GoogleOAuth.shared.isConnected else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let fetched = try await fetchEvents()
            events = fetched
            lastSyncStatus = "同期完了（\(fetched.count) 件）"
        } catch {
            lastSyncStatus = "同期失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    func events(on day: Date) -> [ScheduleEvent] {
        let cal = Calendar.current
        return events.filter { cal.isDate(Date(timeIntervalSince1970: $0.date), inSameDayAs: day) }
    }

    // MARK: - CRUD

    func createEvent(title: String, date: Date, allDay: Bool, detail: String) async throws -> ScheduleEvent {
        let token = try await GoogleOAuth.shared.validToken()
        let url = URL(string: "\(base)/calendars/primary/events")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = buildEventBody(title: title, date: date, allDay: allDay, detail: detail)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleError.invalidResponse
        }
        if let e = json["error"] as? [String: Any] {
            throw GoogleError.apiError((e["message"] as? String) ?? "unknown")
        }
        return mapEvent(json)
    }

    func deleteEvent(googleId: String) async throws {
        let token = try await GoogleOAuth.shared.validToken()
        let encoded = googleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? googleId
        var req = URLRequest(url: URL(string: "\(base)/calendars/primary/events/\(encoded)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: req)
        events.removeAll { $0.id == "gcal:\(googleId)" }
    }

    // MARK: - Private

    private func fetchEvents() async throws -> [ScheduleEvent] {
        let token = try await GoogleOAuth.shared.validToken()
        let now = Date()
        let tMin = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30 * 86400))
        let tMax = ISO8601DateFormatter().string(from: now.addingTimeInterval(90 * 86400))

        var comps = URLComponents(string: "\(base)/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin",      value: tMin),
            .init(name: "timeMax",      value: tMax),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy",      value: "startTime"),
            .init(name: "maxResults",   value: "250"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleError.invalidResponse
        }
        if let e = json["error"] as? [String: Any] {
            throw GoogleError.apiError((e["message"] as? String) ?? "unknown")
        }
        let items = json["items"] as? [[String: Any]] ?? []
        return items.map { mapEvent($0) }
    }

    private func mapEvent(_ json: [String: Any]) -> ScheduleEvent {
        let googleId = json["id"] as? String ?? UUID().uuidString
        let title = json["summary"] as? String ?? "（無題）"
        let detail = json["description"] as? String ?? ""

        var date: Double = Date().timeIntervalSince1970
        var allDay = false
        if let start = json["start"] as? [String: Any] {
            if let d = start["date"] as? String {
                // All-day: "2024-12-25"
                allDay = true
                let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
                date = fmt.date(from: d)?.timeIntervalSince1970 ?? date
            } else if let dt = start["dateTime"] as? String {
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let parsed = fmt.date(from: dt) { date = parsed.timeIntervalSince1970 }
                else {
                    let fmt2 = ISO8601DateFormatter()
                    date = fmt2.date(from: dt)?.timeIntervalSince1970 ?? date
                }
            }
        }

        var ev = ScheduleEvent(title: title, detail: detail, date: date, allDay: allDay)
        ev.id = "gcal:\(googleId)"
        return ev
    }

    private func buildEventBody(title: String, date: Date, allDay: Bool, detail: String) -> [String: Any] {
        var body: [String: Any] = ["summary": title]
        if !detail.isEmpty { body["description"] = detail }
        if allDay {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            let d = fmt.string(from: date)
            body["start"] = ["date": d]
            body["end"]   = ["date": d]
        } else {
            let fmt = ISO8601DateFormatter()
            let dt = fmt.string(from: date)
            body["start"] = ["dateTime": dt, "timeZone": TimeZone.current.identifier]
            body["end"]   = ["dateTime": fmt.string(from: date.addingTimeInterval(3600)),
                             "timeZone": TimeZone.current.identifier]
        }
        return body
    }

    enum GoogleError: LocalizedError {
        case invalidResponse
        case apiError(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse:  return "無効なレスポンス"
            case .apiError(let m):  return m
            }
        }
    }
}
