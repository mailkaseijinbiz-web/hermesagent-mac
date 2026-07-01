import Foundation

// インテンションカード — バイタル/文脈から意図仮説を生成し、タップで実行へ委譲する。
extension AppState {

    // MARK: - Vitality

    /// Internal vitality label fed to intention generation.
    func vitalityMode() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let h = latestHealth
        let sleep = h?.sleepHours
        let exercise = h?.exerciseMinutes ?? 0
        let mindful = h?.mindfulMinutes ?? 0

        if let s = sleep, s < 5 { return exercise >= 20 ? "recovering" : "depleted" }
        if let s = sleep, s < 6, hour < 11 { return "recovering" }
        if mindful >= 10, hour >= 12 { return "steady" }
        if let s = sleep, s >= 7, hour >= 9, hour < 16 {
            let energy = h?.activeEnergyKcal ?? 0
            if energy >= 150 || exercise >= 30 { return "peak" }
        }
        if let s = sleep, s < 6.5 { return "recovering" }
        if hour >= 22 || hour < 6 { return "recovering" }
        return "steady"
    }

    func vitalityHintLine() -> String {
        let mode = vitalityMode()
        var parts: [String] = []
        if let h = latestHealth {
            if let s = h.sleepHours { parts.append(String(format: "睡眠 %.1fh", s)) }
            if let r = h.restingHeartRate { parts.append("安静心拍 \(r)bpm") }
            if let e = h.exerciseMinutes, e > 0 { parts.append("運動 \(e)分") }
            if let m = h.mindfulMinutes, m > 0 { parts.append("マインドフル \(m)分") }
            if let st = h.steps, st > 0 { parts.append("歩数 \(st)歩") }
        }
        let modeLabel: String = {
            switch mode {
            case "depleted":   return "消耗気味"
            case "recovering": return "回復モード"
            case "peak":       return "集中に向く時間帯"
            default:           return "安定"
            }
        }()
        if parts.isEmpty { return modeLabel }
        return parts.joined(separator: " · ") + " — \(modeLabel)"
    }

    /// User dismissed or confirmed everything — honor silence (no auto-regenerate).
    var intentionIsSilent: Bool {
        guard !intentionCards.isEmpty else { return false }
        return visibleIntentionCards.isEmpty
    }

    var visibleIntentionCards: [IntentionCard] {
        intentionCards.filter { !intentionDismissedIds.contains($0.id) && intentionSelectedId != $0.id }
    }

    var intentionToday: IntentionToday {
        IntentionToday(
            vitalHint: intentionVitalHint,
            vitalityMode: intentionVitalityMode,
            cards: visibleIntentionCards,
            generatedAt: intentionCardsAt,
            selectedId: intentionSelectedId,
            dismissedIds: intentionDismissedIds
        )
    }

    func intentionTodayJSON() -> [String: Any] {
        let enc = JSONEncoder()
        guard let data = try? enc.encode(intentionToday),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["cards": [] as [[String: Any]], "generatedAt": intentionCardsAt]
        }
        return obj
    }

    // MARK: - Context

    /// Richer context block for intention generation (beyond dailyBriefContext).
    func intentionContext() -> String {
        var lines: [String] = []
        let hour = Calendar.current.component(.hour, from: Date())
        let band: String = {
            switch hour {
            case 5..<11:  return "朝"
            case 11..<14: return "昼"
            case 14..<18: return "午後"
            case 18..<23: return "夜"
            default:      return "深夜"
            }
        }()
        lines.append("時間帯: \(band)（\(hour)時）")
        lines.append("vitalityMode: \(vitalityMode())")

        let lifelog = lifelogContext()
        if !lifelog.isEmpty { lines.append("【今日の活動タイムライン】\n\(lifelog)") }

        let memoCtx = MemoContext.format(MacMemoStore.shared.todayMemos, max: 6)
        if !memoCtx.isEmpty { lines.append("【共有・備忘録】\n\(memoCtx)") }

        let timeline = timelineContextText()
        if !timeline.isEmpty { lines.append("【時系列グラフ】\n\(timeline)") }

        if !intentionDismissedKinds.isEmpty {
            lines.append("ユーザーが却下した方向（同系統の提案を避ける）: \(intentionDismissedKinds.joined(separator: ", "))")
        }
        if intentionSelectedId != nil {
            lines.append("ユーザーはすでに1つの意図を選んでいる。残りは控えめに。")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Generation

    func autoIntentionIfStale() async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let genDate = Date(timeIntervalSince1970: intentionCardsAt)
        guard intentionCardsAt == 0 || genDate < today || visibleIntentionCards.isEmpty else { return }
        await generateIntentionCards(resetDismissals: genDate < today)
    }

    /// Debounced refresh when new health/location/photo data arrives from iOS.
    func scheduleIntentionRefreshIfNeeded() {
        intentionRefreshTask?.cancel()
        intentionRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, !isGeneratingIntention, !intentionIsSilent else { return }
            let age = Date().timeIntervalSince1970 - intentionCardsAt
            let isToday = Calendar.current.isDateInToday(Date(timeIntervalSince1970: intentionCardsAt))
            guard intentionCardsAt == 0 || !isToday || age > 1800 || visibleIntentionCards.isEmpty else { return }
            await generateIntentionCards(preserveDismissals: isToday && intentionCardsAt > 0)
        }
    }

    func generateIntentionCards(preserveDismissals: Bool = false, resetDismissals: Bool = false) async {
        guard !isGeneratingIntention else { return }
        isGeneratingIntention = true
        defer { isGeneratingIntention = false }

        let prompt = """
        あなたはユーザーの意図を引き出すパーソナルパートナーです。以下のデータから、いま取りうる行動を**最大3つ**、JSONだけで返してください。
        ルール:
        - 挨拶・説明文は書かない。JSONのみ。
        - 各カードは短いタイトル(≤12字) + 具体的サブタイトル(≤40字)。
        - ユーザーの目標・好きなものに無理なく沿う。押し付けない。
        - 必ず「休む/軽くする」選択肢を1つ含める（kind=rest または recover）。
        - 却下された方向(kind)と同系統の提案は避ける。
        - icon は SF Symbols 名 (leaf, figure.walk, checklist, moon, flame, heart, sparkles 等)。
        - kind は recover | focus | rest | explore | task のいずれか。
        - action.type は task | markTask | chat | none。task なら taskTitle、既存タスクなら markTask+taskId、chat なら employeeRole と chatPrompt。

        出力形式:
        {"vitalHint":"1行の身体状態","vitalityMode":"recovering|steady|peak|depleted","cards":[
          {"id":"c1","title":"…","subtitle":"…","icon":"…","kind":"…","action":{"type":"task","taskTitle":"…"}},
          …
        ]}

        【概要データ】
        \(dailyBriefContext())

        【意図生成用の追加文脈】
        \(intentionContext())
        """
        let text = await runBriefPrompt(prompt)
        if let parsed = IntentionJSON.parse(text) {
            applyIntentionSet(
                vitalHint: parsed.vitalHint,
                vitalityMode: parsed.vitalityMode,
                cards: filterCardsByDismissedKinds(parsed.cards),
                preserveDismissals: preserveDismissals,
                resetDismissals: resetDismissals
            )
        } else {
            let fallback = computedIntentionCards()
            applyIntentionSet(
                vitalHint: fallback.vitalHint,
                vitalityMode: fallback.vitalityMode,
                cards: fallback.cards,
                preserveDismissals: preserveDismissals,
                resetDismissals: resetDismissals
            )
            if !text.isEmpty && looksLikeErrorResponse(text) {
                triggerToast(message: "意図カードをルールベースで生成しました")
            }
        }
    }

    private func filterCardsByDismissedKinds(_ cards: [IntentionCard]) -> [IntentionCard] {
        guard !intentionDismissedKinds.isEmpty else { return cards }
        let filtered = cards.filter { !intentionDismissedKinds.contains($0.kind) }
        return filtered.isEmpty ? cards : filtered
    }

    private func applyIntentionSet(
        vitalHint: String,
        vitalityMode: String,
        cards: [IntentionCard],
        preserveDismissals: Bool,
        resetDismissals: Bool
    ) {
        intentionVitalHint = vitalHint.isEmpty ? vitalityHintLine() : vitalHint
        intentionVitalityMode = vitalityMode
        intentionCards = cards
        intentionCardsAt = Date().timeIntervalSince1970
        if resetDismissals {
            intentionSelectedId = nil
            intentionDismissedIds = []
            intentionDismissedKinds = []
        } else if !preserveDismissals {
            intentionSelectedId = nil
            intentionDismissedIds = []
        }
    }

    /// Deterministic fallback when the model is unavailable.
    func computedIntentionCards() -> (vitalHint: String, vitalityMode: String, cards: [IntentionCard]) {
        let mode = vitalityMode()
        let hint = vitalityHintLine()
        var cards: [IntentionCard] = []
        let likes = personalProfile.likes
        let goals = personalProfile.goals
        let hour = Calendar.current.component(.hour, from: Date())
        let pending = (tasks(status: .doing) + tasks(status: .todo))

        if (mode == "depleted" || mode == "recovering") && !intentionDismissedKinds.contains("recover") {
            let sub = hour >= 18 ? "早めに休む" : "散歩15分かストレッチ"
            cards.append(IntentionCard(
                id: "recover", title: "軽く回復", subtitle: sub,
                icon: "leaf.fill", kind: "recover",
                action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
            ))
        } else if let top = pending.first, !intentionDismissedKinds.contains("focus") {
            cards.append(IntentionCard(
                id: "focus-\(top.id)", title: "今日の1つ", subtitle: top.title,
                icon: "checklist", kind: "focus",
                action: IntentionAction(type: "markTask", taskTitle: nil, taskId: top.id,
                                       employeeRole: "engineer", chatPrompt: "「\(top.title)」に取り掛かりたい。30分で進められる最初の一歩を一緒に考えて。")
            ))
        }

        if likes.contains("サウナ") || likes.lowercased().contains("sauna"),
           !intentionDismissedKinds.contains("explore") {
            let sub = hour < 17 ? "午後に整える" : "いま行けるなら"
            cards.append(IntentionCard(
                id: "sauna", title: "サウナで整える", subtitle: sub,
                icon: "flame.fill", kind: "explore",
                action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
            ))
        } else if goals.contains("健康") || goals.contains("運動"),
                  !intentionDismissedKinds.contains("explore"), hour < 20 {
            cards.append(IntentionCard(
                id: "walk", title: "体を動かす", subtitle: "20分の散歩で切り替え",
                icon: "figure.walk", kind: "explore",
                action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
            ))
        } else if mode == "peak", pending.count > 1, !intentionDismissedKinds.contains("task") {
            let t = pending[1]
            cards.append(IntentionCard(
                id: "focus2-\(t.id)", title: "もう1つ", subtitle: t.title,
                icon: "bolt.fill", kind: "task",
                action: IntentionAction(type: "markTask", taskTitle: nil, taskId: t.id,
                                       employeeRole: "assistant", chatPrompt: nil)
            ))
        }

        if !intentionDismissedKinds.contains("rest") {
            cards.append(IntentionCard(
                id: "rest", title: "今日は休む", subtitle: "予定を明日に回す",
                icon: "moon.fill", kind: "rest",
                action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
            ))
        }

        return (hint, mode, Array(filterCardsByDismissedKinds(cards).prefix(3)))
    }

    // MARK: - User actions

    @discardableResult
    func confirmIntentionCard(_ id: String) -> [String: Any] {
        guard let card = intentionCards.first(where: { $0.id == id }) else {
            return ["ok": false, "error": "unknown card"]
        }
        intentionSelectedId = id
        var result: [String: Any] = ["ok": true, "cardId": id, "kind": card.kind]

        switch card.action.type {
        case "task":
            let title = (card.action.taskTitle ?? card.subtitle).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let empId = employeeId(forRole: card.action.employeeRole)
                let t = createTask(title: title, assigneeId: empId)
                setTaskStatus(t.id, .doing)
                result["taskId"] = t.id
            }
        case "markTask":
            if let tid = card.action.taskId {
                setTaskStatus(tid, .doing)
                result["taskId"] = tid
            }
        case "chat":
            let role = card.action.employeeRole ?? "assistant"
            if let empId = employeeId(forRole: role) {
                switchEmployee(empId)
                if let prompt = card.action.chatPrompt, !prompt.isEmpty {
                    inputValue = prompt
                }
                result["employeeId"] = empId
            } else {
                view = "chat"
                if let prompt = card.action.chatPrompt { inputValue = prompt }
            }
        default:
            break
        }
        triggerToast(message: "「\(card.title)」を選びました")
        return result
    }

    func dismissIntentionCard(_ id: String) {
        guard let card = intentionCards.first(where: { $0.id == id }) else { return }
        if !intentionDismissedIds.contains(id) {
            intentionDismissedIds.append(id)
        }
        if !intentionDismissedKinds.contains(card.kind) {
            intentionDismissedKinds.append(card.kind)
        }
    }

    func employeeId(forRole role: String?) -> String? {
        guard let role, let r = EmployeeRole(rawValue: role) else { return nil }
        return employees.first { $0.role == r }?.id
    }
}
