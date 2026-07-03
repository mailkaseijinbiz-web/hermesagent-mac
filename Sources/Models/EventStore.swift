import Foundation
import HermesShared

/// 統一イベントストア（docs/EVENT-STORE-DESIGN.md）。PrivateStore `events-<yyyy-MM-dd>` に
/// 1日1ファイルで保存。日付キーは必ずstartから導出し、読み出しは当日フィルタ込みでしか返さない。
/// H1段階: 既存ストアとの二重書きのみ（読み手は旧経路のまま）。
actor EventStore {
    static let shared = EventStore()

    private var cache: [String: [String: HermesEvent]] = [:]   // dayKey → id → event

    private func storeKey(_ dayKey: String) -> String { "events-\(dayKey)" }

    private static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func load(_ dayKey: String) -> [String: HermesEvent] {
        if let c = cache[dayKey] { return c }
        var out: [String: HermesEvent] = [:]
        if let data = PrivateStore.loadData(key: storeKey(dayKey)),
           let evs = try? JSONDecoder().decode([HermesEvent].self, from: data) {
            for e in evs { out[e.id] = e }
        }
        cache[dayKey] = out
        return out
    }

    /// 冪等upsert（同idはHermesEventRules.mergeで解決）。日付はstartから導出。
    func upsert(_ events: [HermesEvent]) {
        var byDay: [String: [HermesEvent]] = [:]
        for e in events { byDay[HermesEventRules.dayKey(for: e), default: []].append(e) }
        for (day, evs) in byDay {
            var map = load(day)
            var changed = false
            for e in evs {
                let merged = HermesEventRules.merge(existing: map[e.id], incoming: e)
                if merged != map[e.id] { map[e.id] = merged; changed = true }
            }
            guard changed else { continue }
            cache[day] = map
            if let data = try? JSONEncoder().encode(Array(map.values)) {
                try? PrivateStore.saveData(data, key: storeKey(day))
            }
        }
    }

    func tombstone(id: String, start: Double) {
        upsert([HermesEvent(id: id, kind: "memo", start: start, title: "",
                            source: "mac", updatedAt: Date().timeIntervalSince1970, deleted: true)])
    }

    /// 当日フィルタ・削除除外・昇順を保証して返す（不変条件は型の外に漏らさない）。
    func events(on day: Date) -> [HermesEvent] {
        HermesEventRules.normalized(Array(load(Self.dayKey(for: day)).values), day: day)
    }

    /// H2の差分監視用: 保存済み件数（フィルタ前）。
    func rawCount(on day: Date) -> Int {
        load(Self.dayKey(for: day)).count
    }
}

// MARK: - 既存モデル→HermesEvent 変換（二重書きフックから使用）

extension HermesEvent {
    static func from(_ e: MacActivityEntry) -> HermesEvent {
        HermesEvent(
            id: "mac:\(e.id)",
            kind: e.kind == "hermes" ? "hermes" : "mac",
            start: e.startTime, end: e.endTime,
            title: MacWorkFocus.workTitle(for: e),
            detail: e.appName,
            source: "mac",
            payload: e.url.map { ["url": $0] },
            updatedAt: e.endTime
        )
    }

    static func from(_ m: MacMemo) -> HermesEvent {
        let kg = WeightMemoParser.parse(m.text)
        return HermesEvent(
            id: "memo:\(m.id)",
            kind: kg != nil ? "weight" : (m.mediaKind == "image" ? "photo" : "memo"),
            start: m.time.timeIntervalSince1970,
            title: kg.map { WeightMemoParser.displayLabel(kg: $0) } ?? m.text,
            detail: m.pageTitle,
            source: m.source == "ios" ? "ios" : "mac",
            payload: m.link.map { ["url": $0] },
            updatedAt: (m.editedAt ?? m.time).timeIntervalSince1970
        )
    }
}
