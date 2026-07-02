import Foundation

/// Local product-metrics event log (`~/.hermes/product-metrics/events.jsonl`).
@MainActor
final class ProductMetricsStore {
    static let shared = ProductMetricsStore()

    private static let maxEvents = 10_000
    private static let retentionDays = 90
    private static let summaryKey = "productMetricsLastSummary"
    private static let vitalitySnapshotDayKey = "productMetricsLastVitalitySnapshotDay"

    private var events: [ProductMetricsEvent] = []
    private var loaded = false

    private var eventsURL: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/product-metrics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.jsonl")
    }

    private init() {}

    func track(name: String, props: [String: String] = [:], source: String = "mac") {
        let ev = ProductMetricsEvent(
            name: name,
            ts: Date().timeIntervalSince1970,
            props: props,
            source: source
        )
        trackBatch([ev])
    }

    func trackBatch(_ batch: [ProductMetricsEvent]) {
        guard !batch.isEmpty else { return }
        ensureLoaded()
        events.append(contentsOf: batch)
        trimInMemory()
        persistAll()
    }

    func allEvents() -> [ProductMetricsEvent] {
        ensureLoaded()
        return events
    }

    func summary(windowDays: Int = 7) -> ProductMetricsSummary {
        ProductMetricsEngine.summarize(events: allEvents(), windowDays: windowDays)
    }

    func cachedSummary() -> ProductMetricsSummary? {
        guard let data = UserDefaults.standard.data(forKey: Self.summaryKey) else { return nil }
        return try? JSONDecoder().decode(ProductMetricsSummary.self, from: data)
    }

    /// Once per calendar day — vitality mode snapshot for NSM / guardrail context.
    func snapshotVitalityModeIfNeeded(mode: String, sleepH: String? = nil, restingHr: String? = nil) {
        let day = LifeLogDay.key(Date())
        guard UserDefaults.standard.string(forKey: Self.vitalitySnapshotDayKey) != day else { return }
        var props: [String: String] = ["mode": mode]
        if let sleepH { props["sleep_h"] = sleepH }
        if let restingHr { props["resting_hr"] = restingHr }
        track(name: "vitality.mode_snapshot", props: props)
        UserDefaults.standard.set(day, forKey: Self.vitalitySnapshotDayKey)
    }

    func recomputeAndApplyImprovements(windowDays: Int = 7) {
        let summary = summary(windowDays: windowDays)
        if let data = try? JSONEncoder().encode(summary) {
            UserDefaults.standard.set(data, forKey: Self.summaryKey)
        }
        let recs = summary.recommendations.joined(separator: " | ")
        Log.event(
            "metrics",
            "INFO",
            "recompute stage=\(summary.growthStage) nsm=\(summary.nsmPerWeek) fit=\(String(format: "%.2f", summary.intentionFitRate)) sync=\(String(format: "%.2f", summary.syncSuccessRate)) recs=\(recs)"
        )
    }

    // MARK: - Persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: eventsURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        events = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            try? decoder.decode(ProductMetricsEvent.self, from: Data(line.utf8))
        }
        trimInMemory()
    }

    private func trimInMemory() {
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86400).timeIntervalSince1970
        events = events.filter { $0.ts >= cutoff }
        if events.count > Self.maxEvents {
            events = Array(events.suffix(Self.maxEvents))
        }
    }

    private func persistAll() {
        let encoder = JSONEncoder()
        let lines = events.compactMap { ev -> String? in
            guard let data = try? encoder.encode(ev) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let body = lines.joined(separator: "\n")
        if body.isEmpty {
            try? FileManager.default.removeItem(at: eventsURL)
        } else {
            try? (body + "\n").write(to: eventsURL, atomically: true, encoding: .utf8)
        }
    }
}
