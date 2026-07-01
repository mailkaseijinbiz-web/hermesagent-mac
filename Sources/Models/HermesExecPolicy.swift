import Foundation

/// Timeout / retry policy for Hermes CLI subprocess calls (unit-testable).
enum HermesExecPolicy {
    static let defaultListTimeout: TimeInterval = 45
    static let defaultRunTimeout: TimeInterval = 180
    static let maxRetryAttempts = 3

    /// Exponential backoff capped at 60s (attempt 0 → base, 1 → 2×, …).
    static func backoffDelay(attempt: Int, base: TimeInterval = 2) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(base * pow(2, Double(attempt - 1)), 60)
    }

    /// Keep dead-letter rows only for jobs that still report `lastError`.
    static func reconcileDeadLetters(
        records: [FailedDeliveryRecord],
        jobs: [HermesCronJob]
    ) -> [FailedDeliveryRecord] {
        let failing = Set(
            jobs.compactMap { job -> String? in
                guard let err = job.lastError, !err.isEmpty else { return nil }
                return job.id
            }
        )
        return records.filter { failing.contains($0.jobId) }
    }
}

struct HermesExecOutcome: Equatable {
    var success: Bool
    var stdout: String
    var stderr: String
    var timedOut: Bool = false
    var attempts: Int = 1
}
