import Foundation

// インテンションカード — バイタル/文脈から意図仮説を生成し、タップで実行へ委譲する。
extension AppState {

    // MARK: - Vitality

    /// Internal vitality label fed to intention generation.
    func vitalityMode() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let sleep = latestHealth?.sleepHours
        if let s = sleep, s < 5 { return "depleted" }
        if let s = sleep, s < 6, hour < 11 { return "recovering" }
        if let s = sleep, s >= 7, hour >= 9, hour < 16 {
            let energy = latestHealth?.activeEnergyKcal ?? 0
            if energy >= 150 { return "peak" }
        }
        if let s = sleep, s < 6.5 { return "recovering" }
        return "steady"
    }

    func vitalityHintLine() -> String {
        let mode = vitalityMode()
        var parts: [String] = []
        if let h = latestHealth {
            if let s = h.sleepHours { parts.append(String(format: "睡眠 %.1fh", s)) }
            if let r = h.restingHeartRate { parts.append("安静心拍 \(r)bpm") }
            if let st = h.steps, st > 0 { parts.append("歩数 \(st)歩") }
        }
        let modeLabel: String = {
            switch mode {
            case "depleted":  return "消耗気味"
            case "recovering": return "回復モード"
            case "peak":      return "集中に向く時間帯"
            default:          return "安定"
            }
        }()
        if parts.isEmpty { return modeLabel }
        return parts.joined(separator: " · ") + " — \(modeLabel)"
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

    // MARK: - Generation

    func autoIntentionIfStale() async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let genDate = Date(timeIntervalSince1970: intentionCardsAt)
        guard intentionCardsAt == 0 || genDate < today || visibleIntentionCards.isEmpty else { return }
        await generateIntentionCards()
    }

    func generateIntentionCards() async {
        guard !isGeneratingIntention else { return }
        isGeneratingIntention = true
        defer { isGeneratingIntention = false }

        let prompt = """
        あなたはユーザーの意図を引き出すパーソナルパートナーです。以下のデータから、いま取りうる行動を**最大3つ**、JSONだけで返してください。
        ルール:
        - 挨拶・説明文は書かない。JSONのみ。
        - 各カードは短いタイトル(≤12字) + 具体的サブタイトル(≤40字)。
        - ユーザーの目標・好きなものに無理なく沿う。押し付けない。
        - 必ず「休む/軽くする」選択肢を1つ含める。
        - icon は SF Symbols 名 (leaf, figure.walk, checklist, moon, flame, heart, sparkles 等)。
        - kind は recover | focus | rest | explore | task のいずれか。
        - action.type は task | markTask | chat | none。task なら taskTitle、既存タスクなら markTask+taskId、chat なら employeeRole と chatPrompt。

        出力形式:
        {"vitalHint":"1行の身体状態","vitalityMode":"recovering|steady|peak|depleted","cards":[
          {"id":"c1","title":"…","subtitle":"…","icon":"…","kind":"…","action":{"type":"task","taskTitle":"…"}},
          …
        ]}

        【データ】
        \(dailyBriefContext())
        """
        let text = await runBriefPrompt(prompt)
        if let parsed = IntentionJSON.parse(text) {
            applyIntentionSet(vitalHint: parsed.vitalHint, vitalityMode: parsed.vitalityMode, cards: parsed.cards)
        } else {
            let fallback = computedIntentionCards()
            applyIntentionSet(vitalHint: fallback.vitalHint, vitalityMode: fallback.vitalityMode, cards: fallback.cards)
            if !text.isEmpty && looksLikeErrorResponse(text) {
                triggerToast(message: "意図カードをルールベースで生成しました")
            }
        }
    }

    private func applyIntentionSet(vitalHint: String, vitalityMode: String, cards: [IntentionCard]) {
        intentionVitalHint = vitalHint.isEmpty ? vitalityHintLine() : vitalHint
        intentionVitalityMode = vitalityMode
        intentionCards = cards
        intentionCardsAt = Date().timeIntervalSince1970
        intentionSelectedId = nil
        intentionDismissedIds = []
    }

    /// Deterministic fallback when the model is unavailable.
    func computedIntentionCards() -> (vitalHint: String, vitalityMode: String, cards: [IntentionCard]) {
        let mode = vitalityMode()
        let hint = vitalityHintLine()
        var cards: [IntentionCard] = []
        let likes = personalProfile.likes
        let hour = Calendar.current.component(.hour, from: Date())
        let pending = (tasks(status: .doing) + tasks(status: .todo))

        if mode == "depleted" || mode == "recovering" {
            cards.append(IntentionCard(
                id: "recover", title: "軽く回復", subtitle: "散歩15分か、早めに休む",
                icon: "leaf.fill", kind: "recover",
                action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
            ))
        } else if let top = pending.first {
            cards.append(IntentionCard(
                id: "focus-\(top.id)", title: "今日の1つ", subtitle: top.title,
                icon: "checklist", kind: "focus",
                action: IntentionAction(type: "markTask", taskTitle: nil, taskId: top.id,
                                       employeeRole: "engineer", chatPrompt: "「\(top.title)」に取り掛かりたい。30分で進められる最初の一歩を一緒に考えて。")
            ))
        }

        if likes.contains("サウナ") || likes.lowercased().contains("sauna") {
            let sub = hour < 17 ? "午後に整える" : "いま行けるなら"
            cards.append(IntentionCard(
                id: "sauna", title: "サウナで整える", subtitle: sub,
                icon: "flame.fill", kind: "explore",
                action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
            ))
        } else if mode == "peak", pending.count > 1 {
            let t = pending[1]
            cards.append(IntentionCard(
                id: "focus2-\(t.id)", title: "もう1つ", subtitle: t.title,
                icon: "bolt.fill", kind: "task",
                action: IntentionAction(type: "markTask", taskTitle: nil, taskId: t.id,
                                       employeeRole: "assistant", chatPrompt: nil)
            ))
        }

        cards.append(IntentionCard(
            id: "rest", title: "今日は休む", subtitle: "予定を明日に回す",
            icon: "moon.fill", kind: "rest",
            action: IntentionAction(type: "none", taskTitle: nil, taskId: nil, employeeRole: nil, chatPrompt: nil)
        ))

        return (hint, mode, Array(cards.prefix(3)))
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
        if !intentionDismissedIds.contains(id) {
            intentionDismissedIds.append(id)
        }
    }

    func employeeId(forRole role: String?) -> String? {
        guard let role, let r = EmployeeRole(rawValue: role) else { return nil }
        return employees.first { $0.role == r }?.id
    }
}
