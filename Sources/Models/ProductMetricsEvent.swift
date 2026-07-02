import Foundation

/// Local-only product analytics event (productmetrics.md §7.1). No PII / raw vitals.
struct ProductMetricsEvent: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var ts: Double
    var props: [String: String] = [:]
    var source: String = "mac"
}

/// Aggregated dashboard payload for GET /api/metrics/summary.
struct ProductMetricsSummary: Codable, Equatable {
    var computedAt: Double = 0
    var windowDays: Int = 7
    var agencyDays7d: Int = 0
    var nsmPerWeek: Double = 0
    var intentionFitRate: Double = 0
    var depletedRestRate: Double = 0
    var exploreOnDepletedRate: Double = 0
    var syncSuccessRate: Double = 0
    var syncFailureCount: Int = 0
    var growthStage: String = "S0"
    var guardrails: [ProductGuardrailStatus] = []
    var recommendations: [String] = []
    var eventCount: Int = 0
}

struct ProductGuardrailStatus: Codable, Equatable {
    var id: String
    var label: String
    var level: String // green | yellow | red
    var detail: String
}
