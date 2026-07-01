import Foundation
import Combine

struct FailedDeliveryRecord: Codable, Identifiable, Equatable {
    let id: String
    let jobId: String
    let jobName: String
    let deliver: String
    let error: String
    let recordedAt: Date
}

/// Persists recent cron delivery failures (dead-letter queue) encrypted via PrivateStore.
@MainActor
final class FailedDeliveryStore: ObservableObject {
    static let shared = FailedDeliveryStore()

    private static let storeKey = "failedDeliveries"
    private static let maxEntries = 30
    private static let dedupeWindow: TimeInterval = 3600

    @Published private(set) var records: [FailedDeliveryRecord] = []

    init() { load() }

    func record(from jobs: [HermesCronJob]) {
        let now = Date()
        var updated = records
        for job in jobs {
            guard let err = job.lastError, !err.isEmpty else { continue }
            guard FailedDeliveryLogic.shouldAppend(existing: updated, jobId: job.id, error: err, now: now) else { continue }
            updated.insert(FailedDeliveryRecord(
                id: UUID().uuidString,
                jobId: job.id,
                jobName: job.name,
                deliver: job.deliver,
                error: err,
                recordedAt: now
            ), at: 0)
        }
        updated = FailedDeliveryLogic.cap(updated, maxEntries: Self.maxEntries)
        updated = HermesExecPolicy.reconcileDeadLetters(records: updated, jobs: jobs)
        persist(updated)
    }

    /// Drop dead-letter rows for jobs whose `lastError` has cleared.
    func reconcile(with jobs: [HermesCronJob]) {
        let next = HermesExecPolicy.reconcileDeadLetters(records: records, jobs: jobs)
        guard next.count != records.count else { return }
        persist(next)
    }

    func clearAll() {
        persist([])
    }

    func clear(for jobId: String) {
        persist(records.filter { $0.jobId != jobId })
    }

    func clear(recordId: String) {
        persist(records.filter { $0.id != recordId })
    }

    // MARK: - Persistence

    private func load() {
        records = PrivateStore.load([FailedDeliveryRecord].self, key: Self.storeKey) ?? []
    }

    private func persist(_ next: [FailedDeliveryRecord]) {
        records = next
        try? PrivateStore.save(next, key: Self.storeKey)
    }
}

/// Pure dedupe/cap helpers (unit-testable without MainActor).
enum FailedDeliveryLogic {
    static let dedupeWindow: TimeInterval = 3600

    static func shouldAppend(
        existing: [FailedDeliveryRecord],
        jobId: String,
        error: String,
        now: Date,
        dedupeWindow: TimeInterval = FailedDeliveryLogic.dedupeWindow
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-dedupeWindow)
        return !existing.contains { rec in
            rec.jobId == jobId && rec.error == error && rec.recordedAt >= cutoff
        }
    }

    static func cap(_ records: [FailedDeliveryRecord], maxEntries: Int = 30) -> [FailedDeliveryRecord] {
        Array(records.prefix(maxEntries))
    }
}
