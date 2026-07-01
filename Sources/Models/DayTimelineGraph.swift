import Foundation

/// One event on today's reconstructed timeline (multimodal context for intention AI).
struct DayTimelineEvent: Codable, Identifiable, Equatable {
    var id: String
    var time: Double       // unix seconds
    var kind: String       // mac | hermes | memo | health | location | photo
    var label: String
    var detail: String
    /// Session length in seconds (mac/hermes only).
    var duration: Double? = nil
    /// How many raw sessions this row represents after merging.
    var sessionCount: Int = 1
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
        photoLine: String?,
        day: Date = Date()
    ) -> [DayTimelineEvent] {
        var events: [DayTimelineEvent] = []

        for e in macEntries where e.duration >= 30 {
            let start = Date(timeIntervalSince1970: e.startTime)
            guard Calendar.current.isDate(start, inSameDayAs: day) else { continue }
            events.append(DayTimelineEvent(
                id: "mac-\(e.id)",
                time: e.startTime,
                kind: e.kind == "hermes" ? "hermes" : "mac",
                label: e.appName,
                detail: e.label,
                duration: e.duration,
                sessionCount: 1
            ))
        }

        for m in memos where Calendar.current.isDate(m.time, inSameDayAs: day) {
            let (label, detail) = memoLabelAndDetail(m)
            events.append(DayTimelineEvent(
                id: "memo-\(m.id)",
                time: m.time.timeIntervalSince1970,
                kind: "memo",
                label: label,
                detail: detail
            ))
        }

        if let t = healthUpdatedAt, let line = healthLine, !line.isEmpty,
           LifeLogDay.isSameDay(t, as: day) || t == LifeLogDay.noonTimestamp(on: day) {
            events.append(DayTimelineEvent(
                id: "health-\(Int(t))", time: t, kind: "health", label: "健康", detail: line
            ))
        }
        if let t = locationUpdatedAt, let line = locationLine, !line.isEmpty,
           LifeLogDay.isSameDay(t, as: day) || t == LifeLogDay.noonTimestamp(on: day) {
            events.append(DayTimelineEvent(
                id: "loc-\(Int(t))", time: t, kind: "location", label: "外出", detail: line
            ))
        }
        if let t = photoUpdatedAt, let line = photoLine, !line.isEmpty,
           LifeLogDay.isSameDay(t, as: day) || t == LifeLogDay.noonTimestamp(on: day) {
            events.append(DayTimelineEvent(
                id: "photo-\(Int(t))", time: t, kind: "photo", label: "写真", detail: line
            ))
        }

        return events.sorted { $0.time < $1.time }
    }

    static func memoLabelAndDetail(_ m: MacMemo) -> (label: String, detail: String) {
        if let kg = WeightMemoParser.parse(m.text) {
            return (WeightMemoParser.displayLabel(kg: kg), m.text)
        }
        let label: String = {
            switch m.mediaKind {
            case "url": return "共有リンク"
            case "image": return "写真"
            case "video": return "動画"
            default: return m.source == "web" ? "Web" : "メモ"
            }
        }()
        if m.mediaKind == "url", let link = m.link, !link.isEmpty {
            let title = (m.pageTitle?.isEmpty == false ? m.pageTitle! : m.text)
            return (label, title.isEmpty ? link : "\(title)\n\(link)")
        }
        let detail = (m.pageTitle?.isEmpty == false ? m.pageTitle! : m.text)
        return (label, detail)
    }

    /// UI向け: 近接する同一アプリを束ね、アプリ単位に要約し、上位のみ表示する。
    static func compactForDisplay(_ events: [DayTimelineEvent], maxMacApps: Int = 6) -> [DayTimelineEvent] {
        guard !events.isEmpty else { return [] }
        let merged = mergeAdjacentMac(events)
        let byApp = summarizeMacByApp(merged)
        return capTopMacApps(byApp, maxApps: maxMacApps)
    }

    /// 生イベント数と表示用イベント数が異なるか（UIの「まとめて表示」表示用）。
    static func isCompacted(raw: [DayTimelineEvent], display: [DayTimelineEvent]) -> Bool {
        if display.count < raw.count { return true }
        return display.contains { $0.sessionCount > 1 || $0.id.hasPrefix("bundle-") }
    }

    /// Keep the longest-used Mac apps; roll the rest into one 「その他」 row.
    private static func capTopMacApps(_ events: [DayTimelineEvent], maxApps: Int) -> [DayTimelineEvent] {
        let others = events.filter { !isMacLike($0.kind) }
        let mac = events.filter { isMacLike($0.kind) }
            .sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        guard mac.count > maxApps else {
            return (others + mac).sorted { $0.time < $1.time }
        }
        let top = Array(mac.prefix(maxApps))
        let rest = Array(mac.dropFirst(maxApps))
        let otherDur = rest.reduce(0.0) { $0 + ($1.duration ?? 0) }
        let otherSessions = rest.reduce(0) { $0 + $1.sessionCount }
        let otherLabels = Set(rest.map(\.label))
        let bundle = DayTimelineEvent(
            id: "bundle-other-\(Int(rest.map(\.time).min() ?? 0))",
            time: rest.map(\.time).min() ?? 0,
            kind: "mac",
            label: "その他 \(otherLabels.count)アプリ",
            detail: compactMacDetail(sessions: otherSessions, totalDur: otherDur),
            duration: otherDur > 0 ? otherDur : nil,
            sessionCount: otherSessions
        )
        return (others + top + [bundle]).sorted { $0.time < $1.time }
    }

    // MARK: - Display compaction

    private static func mergeAdjacentMac(_ events: [DayTimelineEvent], maxGap: TimeInterval = 1800) -> [DayTimelineEvent] {
        var result: [DayTimelineEvent] = []
        for e in events {
            if let last = result.last,
               isMacLike(last.kind), isMacLike(e.kind),
               last.label == e.label,
               e.time - macEndTime(last) <= maxGap {
                result[result.count - 1] = mergeMacEvents(last, e)
            } else {
                result.append(e)
            }
        }
        return result
    }

    private static func summarizeMacByApp(_ events: [DayTimelineEvent]) -> [DayTimelineEvent] {
        let others = events.filter { !isMacLike($0.kind) }
        let macEvents = events.filter { isMacLike($0.kind) }
        guard !macEvents.isEmpty else { return events }

        let grouped = Dictionary(grouping: macEvents, by: \.label)
        let summaries: [DayTimelineEvent] = grouped.map { label, items in
            let sorted = items.sorted { $0.time < $1.time }
            let first = sorted[0]
            let last = sorted[sorted.count - 1]
            let kind = sorted.contains(where: { $0.kind == "hermes" }) ? "hermes" : "mac"
            let sessions = sorted.reduce(0) { $0 + $1.sessionCount }
            let totalDur = sorted.reduce(0.0) { acc, e in
                acc + (e.duration ?? 0) + gapAfterPrevious(in: sorted, event: e)
            }
            let detail: String = {
                if sessions <= 1 {
                    let primary = first.detail.isEmpty ? label : first.detail
                    return primary
                }
                return compactMacDetail(sessions: sessions, totalDur: totalDur)
            }()
            return DayTimelineEvent(
                id: "bundle-\(label)-\(Int(first.time))",
                time: first.time,
                kind: kind,
                label: label,
                detail: detail,
                duration: totalDur > 0 ? totalDur : nil,
                sessionCount: sessions
            )
        }.sorted { $0.time < $1.time }

        return (others + summaries).sorted { $0.time < $1.time }
    }

    private static func mergeMacEvents(_ a: DayTimelineEvent, _ b: DayTimelineEvent) -> DayTimelineEvent {
        let gap = max(0, b.time - macEndTime(a))
        let totalDur = (a.duration ?? 0) + gap + (b.duration ?? 0)
        let sessions = a.sessionCount + b.sessionCount
        let primary = a.detail.isEmpty ? a.label : a.detail
        let detail: String = {
            if sessions <= 1 { return primary }
            return compactMacDetail(sessions: sessions, totalDur: totalDur)
        }()
        return DayTimelineEvent(
            id: a.id,
            time: a.time,
            kind: a.kind == "hermes" || b.kind == "hermes" ? "hermes" : a.kind,
            label: a.label,
            detail: detail,
            duration: totalDur > 0 ? totalDur : nil,
            sessionCount: sessions
        )
    }

    private static func compactMacDetail(sessions: Int, totalDur: Double) -> String {
        let durText = formatDuration(totalDur)
        if sessions <= 1 { return durText }
        return "\(durText) · \(sessions)回"
    }

    private static func gapAfterPrevious(in sorted: [DayTimelineEvent], event: DayTimelineEvent) -> Double {
        guard let idx = sorted.firstIndex(where: { $0.id == event.id }), idx > 0 else { return 0 }
        let prev = sorted[idx - 1]
        return max(0, event.time - macEndTime(prev))
    }

    private static func macEndTime(_ e: DayTimelineEvent) -> Double {
        e.time + (e.duration ?? 0)
    }

    private static func isMacLike(_ kind: String) -> Bool {
        kind == "mac" || kind == "hermes"
    }

    static func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "1分未満" }
        if m < 60 { return "\(m)分" }
        let h = m / 60
        let rem = m % 60
        return rem == 0 ? "\(h)時間" : "\(h)h\(rem)m"
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
}

extension AppState {
    func dayRecord(for date: Date) -> DayRecord? {
        let key = LifeLogDay.key(date)
        return dailyHistory.first { $0.date == key }
    }

    func healthSummaryLine(for record: DayRecord) -> String? {
        var parts: [String] = []
        if let v = record.steps { parts.append("歩数 \(v)歩") }
        if let v = record.activeEnergyKcal { parts.append("消費エネルギー \(v)kcal") }
        if let v = record.restingHeartRate { parts.append("安静時心拍 \(v)bpm") }
        if let v = record.sleepHours { parts.append(String(format: "睡眠 %.1f時間", v)) }
        guard !parts.isEmpty else { return nil }
        return "健康データ: " + parts.joined(separator: " / ")
    }

    func timelineEvents(for date: Date) -> [DayTimelineEvent] {
        let day = LifeLogDay.startOfDay(date)
        if LifeLogDay.isToday(day) {
            return todayTimelineEvents()
        }
        let record = dayRecord(for: day)
        let anchor = LifeLogDay.noonTimestamp(on: day)
        let healthLine = record.flatMap { healthSummaryLine(for: $0) }
        let locLine = record?.locations.isEmpty == false
            ? resolvedLocationSummary(record!.locations) : nil
        let photoLine = record?.photos.isEmpty == false ? record!.photos : nil
        return DayTimelineGraph.build(
            macEntries: MacActivityLogger.loadEntries(for: day),
            memos: MacMemoStore.shared.memos(for: day),
            healthUpdatedAt: healthLine != nil ? anchor : nil,
            healthLine: healthLine,
            locationUpdatedAt: locLine != nil ? anchor + 60 : nil,
            locationLine: locLine,
            photoUpdatedAt: photoLine != nil ? anchor + 120 : nil,
            photoLine: photoLine,
            day: day
        )
    }

    func todayTimelineEvents() -> [DayTimelineEvent] {
        let h = latestHealth
        return DayTimelineGraph.build(
            macEntries: MacActivityLogger.shared.todayEntriesFromDisk(),
            memos: MacMemoStore.shared.memos(for: Date()),
            healthUpdatedAt: h?.updatedAt,
            healthLine: healthSummaryLine,
            locationUpdatedAt: locationSummaryAt > 0 ? locationSummaryAt : nil,
            locationLine: locationSummary.isEmpty ? nil : resolvedLocationSummary(locationSummary),
            photoUpdatedAt: photoSummaryAt > 0 ? photoSummaryAt : nil,
            photoLine: photoSummary.isEmpty ? nil : photoSummary,
            day: Date()
        )
    }

    func timelineContextText() -> String {
        let raw = todayTimelineEvents()
        let compact = DayTimelineGraph.compactForDisplay(raw)
        return DayTimelineGraph.formatForContext(compact)
    }
}
