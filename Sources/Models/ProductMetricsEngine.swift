import Foundation

/// Pure aggregation + guardrails + improvement hints (productmetrics.md).
enum ProductMetricsEngine {

    static let agencyEventNames: Set<String> = [
        "intention.card_confirmed",
        "serendipity.saved",
        "environment.action_completed"
    ]

    static func recommendedKinds(for vitalityMode: String) -> Set<String> {
        switch vitalityMode {
        case "depleted", "recovering":
            return ["recover", "rest", "environment"]
        case "steady":
            return ["recover", "rest", "environment", "focus", "explore", "task"]
        case "peak":
            return ["focus", "explore", "task", "recover", "rest", "environment"]
        default:
            return ["recover", "rest", "focus", "explore", "environment"]
        }
    }

    static func isProductivityKind(_ kind: String) -> Bool {
        kind == "focus" || kind == "task"
    }

    static func isRecoveryKind(_ kind: String) -> Bool {
        kind == "recover" || kind == "rest" || kind == "environment"
    }

    /// GR-03: strip focus/task on depleted/recovering before showing cards.
    static func guardrailFilterCards(
        _ cards: [IntentionCard],
        vitalityMode: String
    ) -> (cards: [IntentionCard], warnings: [String]) {
        guard vitalityMode == "depleted" || vitalityMode == "recovering" else {
            return (cards, [])
        }
        let stripped = cards.filter { isProductivityKind($0.kind) }
        guard !stripped.isEmpty else { return (cards, []) }
        let kept = cards.filter { !isProductivityKind($0.kind) }
        let msg = "GR-03: \(vitalityMode) 日に focus/task \(stripped.count) 件を除外"
        return (kept, [msg])
    }

    static func summarize(events: [ProductMetricsEvent], windowDays: Int = 7, now: Date = Date()) -> ProductMetricsSummary {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -windowDays, to: now) ?? now
        let startTs = start.timeIntervalSince1970
        let recent = events.filter { $0.ts >= startTs }

        var summary = ProductMetricsSummary()
        summary.computedAt = now.timeIntervalSince1970
        summary.windowDays = windowDays
        summary.eventCount = recent.count

        let dayKeys = (0..<windowDays).compactMap { offset -> String? in
            guard let d = cal.date(byAdding: .day, value: -offset, to: now) else { return nil }
            return LifeLogDay.key(d)
        }
        let uniqueDays = Set(dayKeys)

        var agencyDays = Set<String>()
        for ev in recent where agencyEventNames.contains(ev.name) {
            agencyDays.insert(dayKey(for: ev.ts, calendar: cal))
        }
        summary.agencyDays7d = agencyDays.intersection(uniqueDays).count
        summary.nsmPerWeek = Double(summary.agencyDays7d)

        let confirms = recent.filter { $0.name == "intention.card_confirmed" }
        if !confirms.isEmpty {
            let fit = confirms.filter { ev in
                let mode = ev.props["vitality_mode"] ?? "steady"
                let kind = ev.props["kind"] ?? ""
                return recommendedKinds(for: mode).contains(kind)
            }
            summary.intentionFitRate = Double(fit.count) / Double(confirms.count)
        }

        let depletedDays = Set(recent.compactMap { ev -> String? in
            guard ev.name == "vitality.mode_snapshot",
                  ev.props["mode"] == "depleted" || ev.props["mode"] == "recovering" else { return nil }
            return dayKey(for: ev.ts, calendar: cal)
        })

        if !depletedDays.isEmpty {
            let restConfirms = confirms.filter { ev in
                depletedDays.contains(dayKey(for: ev.ts, calendar: cal)) && isRecoveryKind(ev.props["kind"] ?? "")
            }
            let depletedConfirmDays = Set(confirms.filter {
                depletedDays.contains(dayKey(for: $0.ts, calendar: cal))
            }.map { dayKey(for: $0.ts, calendar: cal) })
            summary.depletedRestRate = depletedConfirmDays.isEmpty
                ? 0
                : Double(restConfirms.count) / Double(depletedConfirmDays.count)

            let exploreOnDepleted = recent.filter { ev in
                (ev.name == "intention.card_shown" || ev.name == "intention.card_confirmed")
                    && ev.props["kind"] == "explore"
                    && depletedDays.contains(dayKey(for: ev.ts, calendar: cal))
            }
            let showOrConfirmDays = Set(recent.filter {
                ($0.name == "intention.card_shown" || $0.name == "intention.card_confirmed")
                    && depletedDays.contains(dayKey(for: $0.ts, calendar: cal))
            }.map { dayKey(for: $0.ts, calendar: cal) })
            summary.exploreOnDepletedRate = showOrConfirmDays.isEmpty
                ? 0
                : Double(exploreOnDepleted.count) / Double(max(1, showOrConfirmDays.count))
        }

        let syncOk = recent.filter { $0.name == "lifelog.sync_completed" }.count
        let syncFail = recent.filter { $0.name == "lifelog.sync_failed" }.count
        summary.syncFailureCount = syncFail
        let syncTotal = syncOk + syncFail
        summary.syncSuccessRate = syncTotal == 0 ? 1 : Double(syncOk) / Double(syncTotal)

        summary.guardrails = computeGuardrails(summary: summary, events: recent, calendar: cal)
        summary.growthStage = inferStage(summary: summary, events: recent)
        summary.recommendations = buildRecommendations(summary: summary)
        return summary
    }

    private static func dayKey(for ts: Double, calendar: Calendar) -> String {
        LifeLogDay.key(Date(timeIntervalSince1970: ts))
    }

    private static func computeGuardrails(
        summary: ProductMetricsSummary,
        events: [ProductMetricsEvent],
        calendar: Calendar
    ) -> [ProductGuardrailStatus] {
        var out: [ProductGuardrailStatus] = []

        let gr03Events = events.filter {
            ($0.name == "intention.card_shown" || $0.name == "guardrail.productivity_push")
                && isProductivityKind($0.props["kind"] ?? "")
                && ($0.props["vitality_mode"] == "depleted" || $0.props["vitality_mode"] == "recovering")
        }
        out.append(ProductGuardrailStatus(
            id: "GR-03",
            label: "消耗日の productivity push",
            level: gr03Events.isEmpty ? "green" : "red",
            detail: gr03Events.isEmpty ? "問題なし" : "\(gr03Events.count) 件検出"
        ))

        out.append(ProductGuardrailStatus(
            id: "GR-06",
            label: "Lifelog 同期失敗",
            level: summary.syncSuccessRate >= 0.9 ? "green" : (summary.syncSuccessRate >= 0.7 ? "yellow" : "red"),
            detail: String(format: "成功率 %.0f%% (%d 失敗)", summary.syncSuccessRate * 100, summary.syncFailureCount)
        ))

        out.append(ProductGuardrailStatus(
            id: "INT-01",
            label: "意図 Fit Rate",
            level: summary.intentionFitRate >= 0.7 ? "green" : (summary.intentionFitRate >= 0.5 ? "yellow" : "red"),
            detail: String(format: "%.0f%%", summary.intentionFitRate * 100)
        ))

        let cre02 = summary.exploreOnDepletedRate
        out.append(ProductGuardrailStatus(
            id: "CRE-02",
            label: "消耗日 explore",
            level: cre02 <= 0.05 ? "green" : (cre02 <= 0.2 ? "yellow" : "red"),
            detail: String(format: "率 %.0f%%", cre02 * 100)
        ))

        return out
    }

    private static func inferStage(summary: ProductMetricsSummary, events: [ProductMetricsEvent]) -> String {
        if summary.syncSuccessRate < 0.7 { return "S0" }
        let hasLife = events.contains { $0.name == "vitality.mode_snapshot" || $0.name == "lifelog.sync_completed" }
        if !hasLife { return "S1" }
        if summary.intentionFitRate < 0.5 && summary.agencyDays7d == 0 { return "S2" }
        if summary.agencyDays7d >= 3 { return "S3" }
        if events.contains(where: { $0.name == "serendipity.saved" }) { return "S4" }
        return summary.agencyDays7d > 0 ? "S3" : "S2"
    }

    private static func buildRecommendations(summary: ProductMetricsSummary) -> [String] {
        var rec: [String] = []
        if summary.guardrails.contains(where: { $0.id == "GR-03" && $0.level == "red" }) {
            rec.append("depleted/recovering 日の focus/task 生成を止める（自動フィルタを確認）")
        }
        if summary.intentionFitRate < 0.6 {
            rec.append("意図カード生成プロンプトに vitalityMode 別 kind 制約を強化")
        }
        if summary.syncSuccessRate < 0.9 {
            rec.append("Lifelog 同期エラーを調査（認証・キャンセル・ネットワーク）")
        }
        if summary.exploreOnDepletedRate > 0.1 {
            rec.append("explore カードを steady/peak に限定")
        }
        if summary.agencyDays7d < 2 {
            rec.append("rest/recover/environment カードの文言・可視性を見直す")
        }
        if rec.isEmpty {
            rec.append("指標は安定。週次で NSM と qualitative 監査を継続")
        }
        return rec
    }
}
