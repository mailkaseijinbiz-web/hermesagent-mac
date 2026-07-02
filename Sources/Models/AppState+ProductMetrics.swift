import Foundation

extension AppState {

    func trackProductMetric(name: String, props: [String: String] = [:], source: String = "mac") {
        ProductMetricsStore.shared.track(name: name, props: props, source: source)
    }

    /// Daily vitality snapshot + recompute guardrails/recommendations (call on launch / after events).
    func runProductMetricsLoop() {
        let mode = vitalityMode()
        var sleepH: String?
        var restingHr: String?
        if let h = latestHealth {
            if let s = h.sleepHours { sleepH = String(format: "%.1f", s) }
            if let r = h.restingHeartRate { restingHr = String(r) }
        }
        ProductMetricsStore.shared.snapshotVitalityModeIfNeeded(
            mode: mode,
            sleepH: sleepH,
            restingHr: restingHr
        )
        ProductMetricsStore.shared.recomputeAndApplyImprovements()
    }
}
