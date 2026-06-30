import Foundation

/// One event on today's reconstructed timeline (multimodal context for intention AI).
struct DayTimelineEvent: Codable, Identifiable, Equatable {
    var id: String
    var time: Double       // unix seconds
    var kind: String       // mac | hermes | memo | health | location | photo
    var label: String
    var detail: String
}

/// Merges Mac activity, memos, and iOS-derived snapshots into a sorted timeline.
enum DayTimelineGraph {

    static func build(
        macEntries: [MacActivityEntry],
        memos: [MacMemo],
        healthUpdatedAt: Double?,
        healthLine: String?,
        locationUpdatedAt: Double?,
        locationLine: String?,
        photoUpdatedAt: Double?,
        photoLine: String?
    ) -> [DayTimelineEvent] {
        var events: [DayTimelineEvent] = []

        for e in macEntries where e.duration >= 30 {
            events.append(DayTimelineEvent(
                id: "mac-\(e.id)",
                time: e.startTime,
                kind: e.kind == "hermes" ? "hermes" : "mac",
                label: e.appName,
                detail: e.label
            ))
        }

        for m in memos {
            events.append(DayTimelineEvent(
                id: "memo-\(m.id)",
                time: m.time.timeIntervalSince1970,
                kind: "memo",
                label: "メモ",
                detail: m.text
            ))
        }

        if let t = healthUpdatedAt, let line = healthLine, !line.isEmpty, isToday(t) {
            events.append(DayTimelineEvent(
                id: "health-\(Int(t))", time: t, kind: "health", label: "健康", detail: line
            ))
        }
        if let t = locationUpdatedAt, let line = locationLine, !line.isEmpty, isToday(t) {
            events.append(DayTimelineEvent(
                id: "loc-\(Int(t))", time: t, kind: "location", label: "外出", detail: line
            ))
        }
        if let t = photoUpdatedAt, let line = photoLine, !line.isEmpty, isToday(t) {
            events.append(DayTimelineEvent(
                id: "photo-\(Int(t))", time: t, kind: "photo", label: "写真", detail: line
            ))
        }

        return events.sorted { $0.time < $1.time }
    }

    /// Compact HH:mm lines for LLM context.
    static func formatForContext(_ events: [DayTimelineEvent], max: Int = 12) -> String {
        guard !events.isEmpty else { return "" }
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "ja_JP")
        tf.dateFormat = "HH:mm"
        return events.suffix(max).map { e in
            let t = tf.string(from: Date(timeIntervalSince1970: e.time))
            let d = e.detail.isEmpty ? e.label : e.detail
            return "\(t) \(e.label): \(d)"
        }.joined(separator: "\n")
    }

    private static func isToday(_ ts: Double) -> Bool {
        Calendar.current.isDateInToday(Date(timeIntervalSince1970: ts))
    }
}

extension AppState {
    func todayTimelineEvents() -> [DayTimelineEvent] {
        let h = latestHealth
        return DayTimelineGraph.build(
            macEntries: MacActivityLogger.shared.todayEntriesFromDisk(),
            memos: MacMemoStore.shared.todayMemos,
            healthUpdatedAt: h?.updatedAt,
            healthLine: healthSummaryLine,
            locationUpdatedAt: locationSummaryAt > 0 ? locationSummaryAt : nil,
            locationLine: locationSummary.isEmpty ? nil : resolvedLocationSummary(locationSummary),
            photoUpdatedAt: photoSummaryAt > 0 ? photoSummaryAt : nil,
            photoLine: photoSummary.isEmpty ? nil : photoSummary,
        )
    }

    func timelineContextText() -> String {
        DayTimelineGraph.formatForContext(todayTimelineEvents())
    }
}
