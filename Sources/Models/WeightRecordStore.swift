import Foundation

struct WeightRecord: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kg: Double
    var recordedAt: Double
    var memoId: String?
    var source: String = "memo"
}

/// Encrypted weight history (`PrivateStore` via `AppState.saveJSON`).
@MainActor
enum WeightRecordStore {
    private static let key = "weightRecords"
    private static let maxRecords = 365

    static func all() -> [WeightRecord] {
        AppState.loadJSON(key) ?? []
    }

    static func latest() -> WeightRecord? {
        all().sorted { $0.recordedAt < $1.recordedAt }.last
    }

    @discardableResult
    static func append(kg: Double, at date: Date = Date(), memoId: String? = nil, source: String = "memo") -> WeightRecord? {
        guard normalize(kg) != nil else { return nil }
        if let memoId, all().contains(where: { $0.memoId == memoId }) { return nil }
        var records = all()
        let record = WeightRecord(kg: (kg * 10).rounded() / 10, recordedAt: date.timeIntervalSince1970, memoId: memoId, source: source)
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        AppState.saveJSON(records, key)
        return record
    }

    private static func normalize(_ kg: Double) -> Double? {
        guard kg >= 20, kg <= 300 else { return nil }
        return (kg * 10).rounded() / 10
    }
}
