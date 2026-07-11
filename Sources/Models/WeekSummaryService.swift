import HermesShared
import Foundation

// MARK: - 週サマリー生成（GET /api/lifelog/week-summary の実体）
// キャッシュ規則・週キー計算は HermesShared の WeekSummaryRules（純粋関数）に従い、
// ここでは DayRecord の収集・コンパクト文脈の組み立て・AI呼び出し・キャッシュ保存を行う。

/// 生成中の週キー。同じ週への同時リクエストでCLIを二重起動しないためのガード
/// （AppState は @MainActor なので await 境界でしか割り込まれない）。
@MainActor private var generatingWeekKeys: Set<String> = []

/// 週サマリーの文脈組み立て（純粋関数・テスト対象）。
enum WeekSummaryContext {

    /// startKey の7日前（＝前週の開始日）を返す。不正な形式は nil。
    static func previousWeekStart(_ startKey: String) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        guard let d = f.date(from: startKey) else { return nil }
        return f.string(from: d.addingTimeInterval(-7 * 86400))
    }

    /// 1日分のコンパクトな文脈行。DayRecordBuilder.aiContext は冗長すぎるため、
    /// 指標＋訪問先＋メモ先頭3件（各40字まで）に絞る。
    static func dayLine(_ r: DayRecord) -> String {
        let inF = DateFormatter()
        inF.locale = Locale(identifier: "en_US_POSIX")
        inF.dateFormat = "yyyy-MM-dd"
        inF.timeZone = .current
        let outF = DateFormatter()
        outF.locale = Locale(identifier: "ja_JP")
        outF.dateFormat = "M/d(E)"
        let label = inF.date(from: r.dateKey).map { outF.string(from: $0) } ?? r.dateKey

        var metrics: [String] = []
        if let v = r.metrics.steps { metrics.append("歩数\(v)") }
        if let v = r.metrics.sleepHours { metrics.append(String(format: "睡眠%.1fh", v)) }
        if let v = r.metrics.moodScore { metrics.append("気分\(v)/5") }
        if let v = r.metrics.macHours { metrics.append(String(format: "Mac %.1fh", v)) }
        var parts: [String] = [metrics.isEmpty ? "指標なし" : metrics.joined(separator: " ")]

        // 訪問先（重複除去・順序維持・最大6件）
        var seen = Set<String>(), places: [String] = []
        for e in r.events where e.kind == "visit" {
            let name = e.place ?? e.title
            if !name.isEmpty, seen.insert(name).inserted { places.append(name) }
        }
        if !places.isEmpty { parts.append("訪問: " + places.prefix(6).joined(separator: "・")) }

        // メモ（先頭3件・各40字まで）
        let memos = r.events.filter { $0.kind == "memo" }.prefix(3)
            .map { String($0.title.prefix(40)) }
        if !memos.isEmpty { parts.append("メモ: " + memos.joined(separator: " / ")) }

        return "\(label): " + parts.joined(separator: "、")
    }
}

extension AppState {

    /// 指定週の週サマリーを返す。startKey はクライアント（iOS）の週開始日をそのまま使う
    /// （デバイスの週開始設定に従う。ハブ側では正規化しない）。不正な形式なら nil（→ 400）。
    /// キャッシュ規則は WeekSummaryRules.shouldUseCache（週明け後生成の過去週のみ恒久）。
    func weekSummary(startKey: String, force: Bool) async -> WeekSummary? {
        guard let keys = WeekSummaryRules.weekKeys(start: startKey) else { return nil }
        let endKey = keys[6]
        let todayKey = DayRecordStore.dateKey()
        let cacheKey = "weekSummary-\(startKey)"
        let cache = PrivateStore.load(WeekSummary.self, key: cacheKey)
        if WeekSummaryRules.shouldUseCache(cache, todayKey: todayKey,
                                           now: Date().timeIntervalSince1970, force: force) {
            return cache
        }

        // 今週分のレコード（今日は全ソースから再構築、過去日は永続化済みスナップショット）
        // 注: AppState.DayRecord（dailyHistory用）と名前が衝突するためモジュール修飾で
        //     トップレベルの DayRecord（DayRecordStore.swift）を指す。
        var records: [HermesCustom.DayRecord] = []
        for key in keys where key <= todayKey {
            if key == todayKey {
                records.append(await DayRecordBuilder.buildToday(appState: self))
            } else if let r = await DayRecordStore.shared.persisted(dateKey: key) {
                records.append(r)
            }
        }
        let days = records.count

        // 前週分（前週比の統計用・永続化済みのみ）
        var prevRecords: [HermesCustom.DayRecord] = []
        if let prevStart = WeekSummaryContext.previousWeekStart(startKey),
           let prevKeys = WeekSummaryRules.weekKeys(start: prevStart) {
            for key in prevKeys {
                if let r = await DayRecordStore.shared.persisted(dateKey: key) {
                    prevRecords.append(r)
                }
            }
        }
        let stats = WeeklyTrends.lines(recent: records, previous: prevRecords)

        // 記録ゼロの週は空サマリーをキャッシュして再スキャンを避ける
        if days == 0 {
            let empty = WeekSummary(startKey: startKey, endKey: endKey, stats: [],
                                    analysis: "", generatedAt: Date().timeIntervalSince1970, days: 0)
            try? PrivateStore.save(empty, key: cacheKey)
            return empty
        }

        // 同じ週を生成中なら二重にCLIを走らせない。pending=true の暫定を返し、
        // クライアント側に「生成中」を伝えて再取得を促す（保存はしない）。
        if generatingWeekKeys.contains(startKey) {
            return cache ?? WeekSummary(startKey: startKey, endKey: endKey, stats: stats,
                                        analysis: "", generatedAt: Date().timeIntervalSince1970,
                                        days: days, pending: true)
        }
        generatingWeekKeys.insert(startKey)
        defer { generatingWeekKeys.remove(startKey) }

        let dayLines = records.map { WeekSummaryContext.dayLine($0) }
        let prompt = """
        あなたはユーザー専属のメタ認知コーチです。以下は\(startKey)週（\(startKey)〜\(endKey)）の日次データです。この週がどんな週だったかを日本語で3〜5文に要約・分析してください。
        ルール:
        - 挨拶や前置きは書かない。
        - データから読み取れるパターン（睡眠・活動・気分・作業のバランス、特徴的だった日）を根拠つきで述べる。
        - データが乏しい点は憶測で埋めない。
        - 箇条書きではなく地の文で。

        【前週比つき統計】
        \(stats.isEmpty ? "（統計を出すにはデータ不足）" : stats.joined(separator: "\n"))

        【日次データ】
        \(dayLines.joined(separator: "\n"))
        """
        var analysis = await runBriefPrompt(prompt)
        if analysis.isEmpty || looksLikeErrorResponse(analysis) { analysis = "" }

        let summary = WeekSummary(startKey: startKey, endKey: endKey, stats: stats,
                                  analysis: analysis,
                                  generatedAt: Date().timeIntervalSince1970, days: days)
        // 生成失敗（analysis 空）はキャッシュしない — 次のリクエストで再試行させる
        if !analysis.isEmpty { try? PrivateStore.save(summary, key: cacheKey) }
        return summary
    }
}
