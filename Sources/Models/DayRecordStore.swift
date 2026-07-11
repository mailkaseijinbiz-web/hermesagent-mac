import HermesShared
import Foundation

// MARK: - 正規ライフログ（DayRecord）
// Mac活動・iOS訪問/睡眠/健康/写真メモ・振り返りを1つの構造化JSONに統合する。
// iOS/Macの表示とAIコンテキストはすべてこれを読む（単一の真実）。

/// タイムライン上の1イベント。kindとtagsで機械可読、title/detailで人間可読。
struct LifeEvent: Codable, Identifiable, Equatable {
    var id: String
    var kind: String          // sleep | visit | mac | photo | memo | reflection
    var start: Double         // epoch秒
    var end: Double? = nil
    var title: String
    var detail: String? = nil
    var place: String? = nil
    var tags: [String] = []   // 仕事/開発/健康/食事/移動/趣味/サウナ/記録 …
    var imageFile: String? = nil   // MacMemoStore画像ファイル名（写真イベント）
    var url: String? = nil
}

/// 24時間バンド（1日の構造を色帯で見せる）。
struct TimeBand: Codable, Equatable {
    var kind: String   // sleep | home | out | mac
    var start: Double
    var end: Double
}

struct DayMetrics: Codable, Equatable {
    var steps: Int? = nil
    var sleepHours: Double? = nil
    var moodScore: Int? = nil
    var restingHeartRate: Int? = nil
    var exerciseMinutes: Int? = nil
    var distanceKm: Double? = nil
    var activeEnergyKcal: Double? = nil
    var macHours: Double? = nil   // Mac作業合計（要約時もここが正）
}

struct DayRecord: Codable, Equatable {
    var dateKey: String
    var events: [LifeEvent] = []
    var bands: [TimeBand] = []
    var metrics = DayMetrics()
    var anomalies: [String] = []      // 「普段との差分」ハイライト（日本語1文ずつ）
    var summary: String? = nil        // AI日次要約
    var generatedAt: Double = 0
}

/// iOSからプッシュされる時刻つき訪問（LocationPointの上位互換）。
struct DayVisit: Codable, Equatable {
    var name: String
    var time: Double
    var lat: Double = 0
    var lon: Double = 0
}

/// iOSからプッシュされる睡眠スパン。
struct HubSleepRecord: Codable, Equatable {
    var start: Double
    var end: Double
    var hours: Double
}

// MARK: - Store

actor DayRecordStore {
    static let shared = DayRecordStore()
    private init() {}

    private let dir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/dayrecords", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    // 生データ（訪問・睡眠）: dateKey → 値。DayRecordビルドの材料。
    private var visitsByDay: [String: [DayVisit]] = [:]
    private var sleepByDay: [String: HubSleepRecord] = [:]
    private var loadedRaw = false

    private var rawURL: URL { dir.appendingPathComponent("raw-inputs.json") }

    private struct RawInputs: Codable {
        var visits: [String: [DayVisit]] = [:]
        var sleep: [String: HubSleepRecord] = [:]
    }

    private func loadRawIfNeeded() {
        guard !loadedRaw else { return }
        loadedRaw = true
        if let data = try? Data(contentsOf: rawURL),
           let raw = try? JSONDecoder().decode(RawInputs.self, from: data) {
            visitsByDay = raw.visits
            sleepByDay = raw.sleep
        }
    }

    private func persistRaw() {
        // 30日より古い生データは破棄
        let cutoffKey = Self.dateKey(for: Date().addingTimeInterval(-30 * 86400))
        visitsByDay = visitsByDay.filter { $0.key >= cutoffKey }
        sleepByDay = sleepByDay.filter { $0.key >= cutoffKey }
        let raw = RawInputs(visits: visitsByDay, sleep: sleepByDay)
        if let data = try? JSONEncoder().encode(raw) {
            try? data.write(to: rawURL, options: .atomic)
        }
    }

    static func dateKey(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    // MARK: - iOS push ingestion

    func recordVisits(_ visits: [DayVisit], dateKey: String) {
        loadRawIfNeeded()
        guard !visits.isEmpty else { return }
        var list = visitsByDay[dateKey] ?? []
        for v in visits where !list.contains(where: { abs($0.time - v.time) < 60 && $0.name == v.name }) {
            list.append(v)
        }
        visitsByDay[dateKey] = list.sorted { $0.time < $1.time }
        persistRaw()
    }

    func recordSleep(_ sleep: HubSleepRecord, dateKey: String) {
        loadRawIfNeeded()
        sleepByDay[dateKey] = sleep
        persistRaw()
    }

    func visits(dateKey: String) -> [DayVisit] {
        loadRawIfNeeded()
        return visitsByDay[dateKey] ?? []
    }

    func sleep(dateKey: String) -> HubSleepRecord? {
        loadRawIfNeeded()
        return sleepByDay[dateKey]
    }

    // MARK: - DayRecord永続化（履歴＝異常検知のベースライン）

    private func recordURL(_ dateKey: String) -> URL {
        dir.appendingPathComponent("\(dateKey).json")
    }

    func persist(_ record: DayRecord) {
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: recordURL(record.dateKey), options: .atomic)
        }
    }

    func persisted(dateKey: String) -> DayRecord? {
        guard let data = try? Data(contentsOf: recordURL(dateKey)) else { return nil }
        return try? JSONDecoder().decode(DayRecord.self, from: data)
    }

    /// 直近days日の永続済みレコード（今日は含まない・古い順）。
    func history(days: Int, before dateKey: String) -> [DayRecord] {
        var out: [DayRecord] = []
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard let base = f.date(from: dateKey) else { return [] }
        for offset in stride(from: days, through: 1, by: -1) {
            let d = base.addingTimeInterval(-Double(offset) * 86400)
            if let r = persisted(dateKey: Self.dateKey(for: d)) { out.append(r) }
        }
        return out
    }
}

// MARK: - Builder（AppStateから今日のDayRecordを組み立てる）

enum DayRecordBuilder {

    /// 今日のDayRecordを全ソースから構築して永続化する。
    @MainActor
    static func buildToday(appState: AppState) async -> DayRecord {
        let dateKey = DayRecordStore.dateKey()
        var record = DayRecord(dateKey: dateKey)
        var events: [LifeEvent] = []

        // 睡眠（iOSプッシュ）
        let sleep = await DayRecordStore.shared.sleep(dateKey: dateKey)
        if let s = sleep {
            events.append(LifeEvent(
                id: "sleep-\(dateKey)", kind: "sleep", start: s.start, end: s.end,
                title: "睡眠", detail: String(format: "%.1f時間", s.hours), tags: ["健康"]))
            record.metrics.sleepHours = s.hours
        }

        // 訪問（iOSプッシュ・時刻つき）
        let visits = await DayRecordStore.shared.visits(dateKey: dateKey)
        let homeKw = appState.homeLocationKeyword
        for (i, v) in visits.enumerated() {
            let isHome = Self.isHome(v.name, keyword: homeKw)
            let name = isHome ? "自宅" : v.name
            let end = i + 1 < visits.count ? visits[i + 1].time : nil
            events.append(LifeEvent(
                id: "visit-\(Int(v.time))", kind: "visit", start: v.time, end: end,
                title: name, place: name,
                tags: Self.visitTags(name: name, isHome: isHome)))
        }

        // Mac作業（キャッシュに前日分が残ることがあるため今日の範囲でフィルタ）。
        // iOS/Mac表示と同一規則: フォーカスグループが5種を超える日は1イベントに要約。
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let dayEnd = dayStart + 86400
        let macEntries = MacActivityLogger.shared.todayEntriesFromDisk()
            .filter { $0.duration >= 30 && $0.startTime >= dayStart && $0.startTime < dayEnd }
        let macTotal = macEntries.reduce(0.0) { $0 + $1.duration }
        if !macEntries.isEmpty { record.metrics.macHours = (macTotal / 360).rounded() / 10 }
        if MacActivityAggregation.shouldCollapse(macEntries),
           let sum = MacActivityAggregation.collapsedSummary(macEntries) {
            let top = sum.topTitles
                .map { "\($0.title) \(Int($0.duration / 60))分" }.joined(separator: " · ")
            events.append(LifeEvent(
                id: "mac-summary-\(dateKey)", kind: "macSummary",
                start: sum.anchorTime, end: sum.lastEnd,
                title: "Macで過ごした時間",
                detail: "\(top)（合計\(String(format: "%.1f", sum.totalDuration / 3600))時間・\(sum.entryCount)件）",
                tags: ["Mac"]))
        } else {
            for e in macEntries {
                events.append(LifeEvent(
                    id: "mac-\(e.id)", kind: "mac", start: e.startTime, end: e.endTime,
                    title: e.label.isEmpty ? e.appName : e.label,
                    detail: e.appName,
                    tags: Self.macTags(appName: e.appName, kind: e.kind),
                    url: e.url))
            }
        }

        // メモ・写真（MacMemoStore: iOSのingest含む）
        for m in MacMemoStore.shared.todayMemos {
            let isMedia = m.mediaKind == "image" || m.mediaKind == "video"
            events.append(LifeEvent(
                id: "memo-\(m.id)", kind: isMedia ? "photo" : "memo",
                start: m.time.timeIntervalSince1970,
                title: isMedia ? (m.text.isEmpty ? "写真" : m.text) : m.text,
                tags: isMedia ? ["記録", "写真"] : ["記録"],
                imageFile: m.imagePaths?.first,
                url: m.link))
        }

        // 振り返り（気分・一言）
        if let entry = await ReflectionStore.shared.entry(dateKey: dateKey) {
            record.metrics.moodScore = entry.moodScore
            if let line = entry.oneLiner, !line.isEmpty {
                events.append(LifeEvent(
                    id: "refl-\(dateKey)", kind: "reflection",
                    start: entry.answeredAt ?? Date().timeIntervalSince1970,
                    title: line, tags: ["振り返り"]))
            }
        }

        // 健康メトリクス（今日の分のみ）
        if let h = appState.latestHealth,
           Calendar.current.isDateInToday(Date(timeIntervalSince1970: h.updatedAt)) {
            record.metrics.steps = h.steps
            record.metrics.restingHeartRate = h.restingHeartRate
            record.metrics.exerciseMinutes = h.exerciseMinutes
            record.metrics.distanceKm = h.distanceKm
            record.metrics.activeEnergyKcal = h.activeEnergyKcal
            if record.metrics.sleepHours == nil { record.metrics.sleepHours = h.sleepHours }
        }

        record.events = events.sorted { $0.start < $1.start }

        // 睡眠の推定（実測が無い日）: 「寝た/起きた」メモ > 行動シグナル推定
        if record.metrics.sleepHours == nil {
            let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let yesterKey = DayRecordStore.dateKey(for: Date().addingTimeInterval(-86400))
            let yesterEvents = await DayRecordStore.shared.persisted(dateKey: yesterKey)?.events ?? []
            let all = (yesterEvents + record.events).filter { $0.kind != "sleep" && $0.kind != "macSummary" }

            let sleepWords: Set<String> = ["寝た", "寝る", "就寝", "おやすみ"]
            let wakeWords: Set<String> = ["起きた", "起床", "おはよう"]
            var sleepMemoAt: Double? = nil
            var wakeMemoAt: Double? = nil
            var signals: [Double] = []
            for e in all {
                signals.append(e.start)
                if let end = e.end { signals.append(end) }
                guard e.kind == "memo" else { continue }
                let title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if sleepWords.contains(title) { sleepMemoAt = max(sleepMemoAt ?? e.start, e.start) }
                if wakeWords.contains(title) { wakeMemoAt = min(wakeMemoAt ?? e.start, e.start) }
            }
            let est = SleepEstimator.fromMemoPair(sleepAt: sleepMemoAt, wokeAt: wakeMemoAt, dayStart: dayStart)
                ?? SleepEstimator.estimate(signals: signals, dayStart: dayStart)
            if let est {
                record.metrics.sleepHours = est.hours
                record.events.append(LifeEvent(
                    id: "sleep-est-\(dateKey)", kind: "sleep", start: est.start, end: est.end,
                    title: "睡眠（推定）", detail: String(format: "%.1f時間（操作履歴から推定）", est.hours),
                    tags: ["健康"]))
                record.events.sort { $0.start < $1.start }
            }
        }
        // バンドはMac作業を要約していても粒度を保つ（生エントリから合成）
        let bandEvents = record.events.filter { $0.kind != "macSummary" } + macEntries.map {
            LifeEvent(id: "band-\($0.id)", kind: "mac", start: $0.startTime, end: $0.endTime, title: "")
        }
        record.bands = Self.deriveBands(events: bandEvents, sleep: sleep, homeKeyword: homeKw)
        if Calendar.current.isDateInToday(Date(timeIntervalSince1970: appState.lifelogSummaryAt)),
           !appState.lifelogSummary.isEmpty {
            record.summary = appState.lifelogSummary
        }

        let history = await DayRecordStore.shared.history(days: 14, before: dateKey)
        record.anomalies = Self.detectAnomalies(today: record, history: history)
        record.generatedAt = Date().timeIntervalSince1970

        await DayRecordStore.shared.persist(record)
        return record
    }

    static func isHome(_ name: String, keyword: String) -> Bool {
        if name == "自宅" { return true }
        guard !keyword.isEmpty else { return false }
        return name.localizedCaseInsensitiveContains(keyword)
    }

    // MARK: - 自動タグ（ルールベース）

    static func macTags(appName: String, kind: String?) -> [String] {
        var tags = ["Mac"]
        let dev = ["Xcode", "Cursor", "Terminal", "iTerm", "Visual Studio", "Antigravity", "Finder"]
        let comm = ["Slack", "Mail", "LINE", "Messages", "Discord", "Zoom"]
        let media = ["YouTube", "Netflix", "Music", "Spotify", "Prime"]
        if kind == "hermes" { tags.append("Hermes") }
        if dev.contains(where: { appName.localizedCaseInsensitiveContains($0) }) { tags.append("開発") }
        else if comm.contains(where: { appName.localizedCaseInsensitiveContains($0) }) { tags.append("連絡") }
        else if media.contains(where: { appName.localizedCaseInsensitiveContains($0) }) { tags.append("娯楽") }
        else { tags.append("仕事") }
        return tags
    }

    static func visitTags(name: String, isHome: Bool) -> [String] {
        if isHome { return ["自宅"] }
        var tags = ["外出"]
        let food = ["店", "レストラン", "カフェ", "食堂", "餃子", "ラーメン", "寿司", "焼", "居酒屋", "バル", "食"]
        let sauna = ["サウナ", "温泉", "湯", "スパ"]
        let transit = ["駅", "空港", "バス"]
        let fitness = ["ジム", "フィットネス", "プール"]
        if sauna.contains(where: { name.contains($0) }) { tags.append("サウナ") }
        else if food.contains(where: { name.contains($0) }) { tags.append("食事") }
        else if transit.contains(where: { name.contains($0) }) { tags.append("移動") }
        else if fitness.contains(where: { name.contains($0) }) { tags.append("運動") }
        return tags
    }

    // MARK: - 24時間バンド

    static func deriveBands(events: [LifeEvent], sleep: HubSleepRecord?, homeKeyword: String) -> [TimeBand] {
        var bands: [TimeBand] = []
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let dayEnd = dayStart + 86400
        if let s = sleep {
            bands.append(TimeBand(kind: "sleep", start: max(s.start, dayStart), end: min(s.end, dayEnd)))
        }
        // 訪問: 自宅=home、それ以外=out。次の訪問（または今）まで続くとみなす
        let visits = events.filter { $0.kind == "visit" }
        for v in visits {
            let end = v.end ?? min(Date().timeIntervalSince1970, dayEnd)
            let kind = (v.place == "自宅" || isHome(v.title, keyword: homeKeyword)) ? "home" : "out"
            if end > v.start {
                bands.append(TimeBand(kind: kind, start: v.start, end: end))
            }
        }
        // Mac作業（隣接10分以内は結合）
        let macs = events.filter { $0.kind == "mac" }.sorted { $0.start < $1.start }
        var current: TimeBand?
        for m in macs {
            let end = m.end ?? m.start
            if var c = current, m.start - c.end <= 600 {
                c.end = max(c.end, end)
                current = c
            } else {
                if let c = current, c.end - c.start >= 300 { bands.append(c) }
                current = TimeBand(kind: "mac", start: m.start, end: end)
            }
        }
        if let c = current, c.end - c.start >= 300 { bands.append(c) }
        return bands.sorted { $0.start < $1.start }
    }

    // MARK: - 普段との差分ハイライト

    static func detectAnomalies(today: DayRecord, history: [DayRecord]) -> [String] {
        var out: [String] = []
        guard history.count >= 3 else { return out }

        func avg(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        if let steps = today.metrics.steps,
           let a = avg(history.compactMap { $0.metrics.steps.map(Double.init) }), a > 500 {
            let ratio = Double(steps) / a
            if ratio >= 1.8 { out.append("歩数\(steps)歩は普段の平均\(Int(a))歩の\(String(format: "%.1f", ratio))倍と大きく増加") }
            else if ratio <= 0.35 { out.append("歩数\(steps)歩は普段の平均\(Int(a))歩より大幅に少ない") }
        }
        if let sleep = today.metrics.sleepHours,
           let a = avg(history.compactMap(\.metrics.sleepHours)), a > 3 {
            if sleep <= a - 1.5 { out.append(String(format: "睡眠%.1f時間は普段の平均%.1f時間より1.5時間以上短い", sleep, a)) }
            else if sleep >= a + 2 { out.append(String(format: "睡眠%.1f時間は普段より2時間以上長い", sleep, a)) }
        }
        // 初めての場所
        let knownPlaces = Set(history.flatMap { $0.events.filter { $0.kind == "visit" }.compactMap(\.place) })
        for e in today.events where e.kind == "visit" {
            if let p = e.place, p != "自宅", !knownPlaces.contains(p) {
                out.append("「\(p)」は直近2週間で初めて訪れた場所")
            }
        }
        // Mac作業合計
        let todayMac = today.metrics.macHours ?? (today.events.filter { $0.kind == "mac" }
            .reduce(0.0) { $0 + (($1.end ?? $1.start) - $1.start) } / 3600)
        let histMac = history.map { r in
            r.metrics.macHours ?? (r.events.filter { $0.kind == "mac" }
                .reduce(0.0) { $0 + (($1.end ?? $1.start) - $1.start) } / 3600)
        }
        if let a = avg(histMac), a > 0.5, todayMac >= a * 1.6, todayMac >= 3 {
            out.append(String(format: "Mac作業%.1f時間は普段の平均%.1f時間を大きく超過", todayMac, a))
        }
        // 気分の急落
        if let mood = today.metrics.moodScore,
           let a = avg(history.compactMap { $0.metrics.moodScore.map(Double.init) }), a > 0,
           Double(mood) <= a - 1.5 {
            out.append("気分スコア\(mood)は普段の平均\(String(format: "%.1f", a))より大きく低い")
        }
        return Array(out.prefix(5))
    }

    // MARK: - AIコンテキスト（コンパクトなテキスト表現）

    static func aiContext(_ r: DayRecord) -> String {
        var lines: [String] = ["【DayRecord \(r.dateKey)】"]
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        func t(_ epoch: Double) -> String { tf.string(from: Date(timeIntervalSince1970: epoch)) }

        var metrics: [String] = []
        if let v = r.metrics.steps { metrics.append("歩数\(v)") }
        if let v = r.metrics.sleepHours { metrics.append(String(format: "睡眠%.1fh", v)) }
        if let v = r.metrics.moodScore { metrics.append("気分\(v)/5") }
        if let v = r.metrics.restingHeartRate { metrics.append("安静心拍\(v)") }
        if let v = r.metrics.exerciseMinutes { metrics.append("運動\(v)分") }
        if !metrics.isEmpty { lines.append("指標: " + metrics.joined(separator: " ")) }

        for e in r.events.prefix(60) {
            var line = "\(t(e.start))"
            if let end = e.end { line += "-\(t(end))" }
            line += " [\(e.kind)] \(e.title)"
            if !e.tags.isEmpty { line += " #" + e.tags.joined(separator: "#") }
            lines.append(line)
        }
        if !r.anomalies.isEmpty {
            lines.append("【普段との差分】")
            lines.append(contentsOf: r.anomalies.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}


// MARK: - 週次傾向（今週7日 vs 先週7日の方向性。ブリーフ/振り返りへ還流）

enum WeeklyTrends {
    /// 過去14日のDayRecord（昇順）から「先週→今週」の傾向行を作る。
    static func lines(history: [DayRecord]) -> [String] {
        guard history.count >= 4 else { return [] }
        let recent = Array(history.suffix(7))
        let previous = Array(history.dropLast(7).suffix(7))
        return lines(recent: recent, previous: previous)
    }

    static func lines(recent: [DayRecord], previous: [DayRecord]) -> [String] {
        var out: [String] = []
        func avg(_ v: [Double]) -> Double? { v.count >= 2 ? v.reduce(0, +) / Double(v.count) : nil }

        if let r = avg(recent.compactMap(\.metrics.sleepHours)) {
            var line = String(format: "睡眠 平均%.1fh", r)
            if let p = avg(previous.compactMap(\.metrics.sleepHours)) {
                let d = r - p
                line += abs(d) >= 0.4 ? String(format: "（前週%.1fh、%+.1fh）", p, d) : "（前週から横ばい）"
            }
            out.append(line)
        }
        if let r = avg(recent.compactMap(\.metrics.macHours)) {
            var line = String(format: "Mac作業 平均%.1fh/日", r)
            if let p = avg(previous.compactMap(\.metrics.macHours)) {
                let d = r - p
                line += abs(d) >= 0.7 ? String(format: "（前週%.1fh、%+.1fh）", p, d) : "（前週から横ばい）"
            }
            out.append(line)
        }
        if let r = avg(recent.compactMap { $0.metrics.steps.map(Double.init) }), r > 0 {
            var line = "歩数 平均\(Int(r))歩"
            if let p = avg(previous.compactMap { $0.metrics.steps.map(Double.init) }), p > 500 {
                let ratio = r / p - 1
                line += abs(ratio) >= 0.2 ? String(format: "（前週比%+.0f%%）", ratio * 100) : "（前週から横ばい）"
            }
            out.append(line)
        }
        if let r = avg(recent.compactMap { $0.metrics.moodScore.map(Double.init) }),
           let p = avg(previous.compactMap { $0.metrics.moodScore.map(Double.init) }) {
            let d = r - p
            if abs(d) >= 0.7 {
                out.append(String(format: "気分スコア 平均%.1f（前週%.1f、%@）", r, p, d > 0 ? "上向き" : "下向き"))
            }
        }
        return out
    }
}
