import Foundation

/// A manually-entered HbA1c (%) lab reading. HealthKit has no standard quantity type for
/// HbA1c (it's a clinical lab result, not a sensor reading), so unlike steps/heart rate/
/// weight this is never auto-synced from iOS — the user enters it after a blood test.
struct HbA1cRecord: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var percent: Double
    var recordedAt: Double
    var source: String = "manual"
}

/// Encrypted HbA1c history (`PrivateStore` via `AppState.saveJSON`), mirroring
/// `WeightRecordStore`. Surfaced on the 健康アドバイザー dashboard.
@MainActor
enum HbA1cRecordStore {
    private static let key = "hba1cRecords"
    private static let maxRecords = 120

    static func all() -> [HbA1cRecord] {
        AppState.loadJSON(key) ?? []
    }

    static func latest() -> HbA1cRecord? {
        all().sorted { $0.recordedAt < $1.recordedAt }.last
    }

    @discardableResult
    static func append(percent: Double, at date: Date = Date(), source: String = "manual") -> HbA1cRecord? {
        guard let normalized = normalize(percent) else { return nil }
        var records = all()
        let record = HbA1cRecord(percent: normalized, recordedAt: date.timeIntervalSince1970, source: source)
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        AppState.saveJSON(records, key)
        return record
    }

    /// Plausible human HbA1c range (%); guards against fat-finger entry errors.
    private static func normalize(_ percent: Double) -> Double? {
        guard percent >= 3, percent <= 20 else { return nil }
        return (percent * 10).rounded() / 10
    }
}
