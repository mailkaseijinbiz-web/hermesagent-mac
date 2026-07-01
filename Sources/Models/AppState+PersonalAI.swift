import Foundation

// パーソナルAI（デイリーブリーフ・週次レビュー）の生成ロジックを AppState 本体から分離（#3 継続）。
// @Published dailyBrief / weeklyReview / isGeneratingBrief / isGeneratingReview は stored property
// のため本体に残し、文脈構築・モデル呼び出し・フォールバック・タイマーをここに集約。

extension AppState {

    // MARK: - 文脈構築

    /// Compact factual snapshot of "today" fed to the AI brief writer.
    func dailyBriefContext() -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "ja_JP"); df.dateFormat = "M月d日(E)"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "ja_JP"); tf.dateFormat = "HH:mm"
        var lines: [String] = ["日付: \(df.string(from: Date()))"]
        let ev = todayEvents
        lines.append("今日の予定(\(ev.count)件): " + (ev.isEmpty ? "なし" :
            ev.prefix(8).map { ($0.allDay ? "終日 " : tf.string(from: Date(timeIntervalSince1970: $0.date)) + " ") + $0.title }.joined(separator: " / ")))
        let todo = tasks(status: .todo), doing = tasks(status: .doing)
        lines.append("タスク: 未着手\(todo.count) / 対応中\(doing.count) / 完了\(tasks(status: .done).count)")
        let pending = (doing + todo).prefix(8).map { t -> String in
            let who = t.assigneeId.flatMap { id in employees.first { $0.id == id }?.name }.map { "（\($0)）" } ?? ""
            return "\(t.title)\(who)"
        }
        if !pending.isEmpty { lines.append("対応中/未着手の主なタスク: " + pending.joined(separator: " / ")) }
        let building = apps.filter { $0.status == .building }
        if !building.isEmpty { lines.append("開発中アプリ: " + building.map { $0.name }.joined(separator: " / ")) }
        if !runningApps.isEmpty { lines.append("起動中アプリ: " + runningApps.map { $0.name }.joined(separator: " / ")) }
        lines.append("社員数: \(employees.count)人" + (busyEmployees.isEmpty ? "" : "（作業中: \(busyEmployees.map { $0.name }.joined(separator: "、"))）"))
        if monthlyBudgetUSD > 0 { lines.append(String(format: "今月のコスト: $%.2f / 予算 $%.2f", totalCostUSD, monthlyBudgetUSD)) }
        if let hl = healthSummaryLine { lines.append(hl) }
        let prof = personalProfileContext
        if !prof.isEmpty { lines.append("【ユーザーの目標・嗜好】\n" + prof) }
        let selfCtx = selfModelContext
        if !selfCtx.isEmpty { lines.append("【自分のリソース配分（頭のメモリ・稼働時間）】\n" + selfCtx) }
        if let loc = locationContext { lines.append(loc) }
        if let ph = photoContext { lines.append(ph) }
        let memoCtx = MemoContext.format(MacMemoStore.shared.todayMemos)
        if !memoCtx.isEmpty { lines.append("共有・備忘録:\n\(memoCtx)") }
        // Mac アクティビティ（今日使ったアプリ上位）
        let macEntries = MacActivityLogger.shared.todayEntriesFromDisk()
        if !macEntries.isEmpty {
            let top = macEntries.sorted { $0.duration > $1.duration }.prefix(6)
            let macSummary = top.map { e -> String in
                let m = Int(e.duration / 60)
                return m >= 60 ? "\(e.appName)(\(m/60)h\(m%60>0 ? "\(m%60)m":""))" : "\(e.appName)(\(m)m)"
            }.joined(separator: " / ")
            lines.append("今日のMac作業: \(macSummary)")
        }
        let timeline = timelineContextText()
        if !timeline.isEmpty { lines.append("【時系列】\n\(timeline)") }
        return lines.joined(separator: "\n")
    }

    /// Personalized news headlines for the daily brief (RSS, no LLM).
    func dailyBriefNewsContext(maxItems: Int = 6) async -> String {
        let json = await MobileServer.shared.fetchSaunaNewsJSON()
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([NewsFeedItem].self, from: data),
              !items.isEmpty else { return "" }
        return items.prefix(maxItems).map { item in
            let src = item.source.isEmpty ? "" : "（\(item.source)）"
            return "・\(item.title)\(src)"
        }.joined(separator: "\n")
    }

    /// Full context block for brief generation (data + lifelog + news).
    func buildDailyBriefContext() async -> String {
        var parts: [String] = [dailyBriefContext()]
        let lifelog = lifelogContext()
        if !lifelog.isEmpty { parts.append("【今日の活動】\n\(lifelog)") }
        if !lifelogSummary.isEmpty,
           Calendar.current.isDateInToday(Date(timeIntervalSince1970: lifelogSummaryAt)) {
            parts.append("【活動要約】\n\(lifelogSummary)")
        }
        let news = await dailyBriefNewsContext()
        if !news.isEmpty {
            parts.append("【関心トピックのニュース（関連があれば1〜2件だけ触れる）】\n\(news)")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - デイリーブリーフ生成

    /// Write today's daily brief with the agent (one-shot), persisting the result + time.
    /// Races the model against a timeout so a slow/stuck model can't pin the card on "生成中…";
    /// on timeout/failure it falls back to a deterministic computed brief.
    func generateDailyBrief() async {
        guard !isGeneratingBrief else { return }
        isGeneratingBrief = true
        defer { isGeneratingBrief = false }
        let hour = Calendar.current.component(.hour, from: Date())
        let frame: String = {
            switch hour {
            case 5..<11:  return "今日の見通しと、意味のある一手"
            case 11..<18: return "ここまでの振り返りと、残り時間の使い方"
            default:      return "今日一日の振り返りと、明日への示唆"
            }
        }()
        let ctx = await buildDailyBriefContext()
        let prompt = """
        あなたはユーザー専属のパーソナルコーチ兼参謀です。以下のデータを読み、「\(frame)」を日本語で書いてください。
        表面的な要約や一般論は避け、データのつながりから「意味のある洞察」を1つは必ず含めてください。

        構成（見出しをそのまま使う）:
        振り返り
        - 今日の行動・健康・予定・メモをつなげ、3〜4文で俯瞰する。単なる羅列は禁止。偏りやパターン（作業過多、外出不足、睡眠との関係など）があれば指摘する。

        つながり
        - ユーザーの目標・嗜好・共有メモ・ニュースのうち、今日と関連が深いものを1〜2点選び、「なぜ今の自分に意味があるか」を1〜3文で述べる。ニュースは関連がある場合のみ短く触れ、タイトル程度でよい。

        今日の提案
        - 最大3つ、各行先頭は「・」。具体的で今日〜明日実行可能な行動。健康・仕事・余暇のバランスを意識する。

        ルール:
        - 挨拶・前置き・「以上です」は書かない
        - 押し付けがましい励まし、お決まりのコーチング口調は避ける
        - 根拠のない推測や、データにない事実の捏造は禁止
        - 全体400〜550字程度（長文にしない）

        【データ】
        \(ctx)
        """
        let text = await runBriefPrompt(prompt)
        if text.isEmpty || looksLikeErrorResponse(text) {
            dailyBrief = computedBrief()
            dailyBriefAt = Date().timeIntervalSince1970
            let hint = looksLikeErrorResponse(text) ? "（モデルがエラーを返しました：\(String(text.prefix(80)))）" : "（モデルが応答しませんでした）"
            triggerToast(message: "簡易ブリーフを表示しました\(hint)")
        } else {
            dailyBrief = text
            dailyBriefAt = Date().timeIntervalSince1970
        }
    }

    /// Revise the existing daily brief per a free-text instruction from the mobile client.
    func reviseDailyBrief(instruction: String) async {
        let instr = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instr.isEmpty, !isGeneratingBrief else { return }
        isGeneratingBrief = true
        defer { isGeneratingBrief = false }
        let current = dailyBrief.isEmpty ? computedBrief() : dailyBrief
        let ctx = await buildDailyBriefContext()
        let prompt = """
        あなたは有能な参謀です。現在の「今日の振り返り」を、ユーザーの指示に従って書き直してください。
        構成は「振り返り」「つながり」「今日の提案」の3見出しを維持。洞察と具体性を損なわないこと。

        ルール: 挨拶や前置きは書かない。本文のみ。指示と無関係な重要情報は保持。ニュースは関連がある場合のみ短く。

        【現在の振り返り】
        \(current)

        【今日のデータ（参考）】
        \(ctx)

        【ユーザーの修正指示】
        \(instr)
        """
        let text = await runBriefPrompt(prompt)
        if !text.isEmpty && !looksLikeErrorResponse(text) {
            dailyBrief = text
            dailyBriefAt = Date().timeIntervalSince1970
        } else {
            triggerToast(message: "ブリーフの修正に失敗しました（モデル応答なし/エラー）")
        }
    }

    /// Directly set the daily brief text (manual edit from the mobile client).
    func setDailyBrief(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        dailyBrief = t
        dailyBriefAt = Date().timeIntervalSince1970
    }

    // MARK: - 週次メタ認知レビュー

    /// Generate a WEEKLY metacognitive review: patterns over the last ~2 weeks of dailyHistory
    /// + next-week advice, grounded in goals/likes/resource-allocation.
    func generateWeeklyReview() async {
        guard !isGeneratingReview else { return }
        let data = weeklyReviewContext()
        guard !data.isEmpty else {
            triggerToast(message: "まだ履歴がありません（数日使うと週次レビューを作れます）")
            return
        }
        isGeneratingReview = true
        defer { isGeneratingReview = false }
        let prompt = """
        あなたはユーザー専属のメタ認知コーチです。以下は直近2週間の日次データです。ユーザーの目標・好きなもの・リソース配分を踏まえ、一歩引いて俯瞰し、日本語でまとめてください。
        ルール:
        - 挨拶や前置きは書かない。
        - まず「気づき」として、データから読み取れるパターンや傾向（例: ある行動と睡眠/運動の相関、増減傾向）を根拠とともに2〜4点。
        - 続けて「来週への提案」として、目標に近づく具体的な行動を最大3つ。好きなことも無理なく絡める。
        - データが乏しい点は憶測で埋めない。

        【ユーザーの目標・嗜好】
        \(personalProfileContext)

        【リソース配分（頭のメモリ・稼働時間）】
        \(selfModelContext)

        【直近2週間の日次データ】
        \(data)
        """
        let text = await runBriefPrompt(prompt)
        if !text.isEmpty && !looksLikeErrorResponse(text) {
            weeklyReview = text
            weeklyReviewAt = Date().timeIntervalSince1970
        } else {
            triggerToast(message: "週次レビューの生成に失敗しました（モデル応答なし/エラー）")
        }
    }

    // MARK: - ライフログ要約

    /// 今日の Mac + iOS アクティビティを要約する（2〜4文）。
    /// 30分以内に生成済みなら skip（forceRefresh=true で強制再生成）。
    func generateLifelogSummary(forceRefresh: Bool = false) async {
        guard !isGeneratingLifelogSummary else { return }
        if !forceRefresh {
            let age = Date().timeIntervalSince1970 - lifelogSummaryAt
            let isToday = Calendar.current.isDateInToday(Date(timeIntervalSince1970: lifelogSummaryAt))
            if isToday && age < 1800 && !lifelogSummary.isEmpty { return }
        }
        isGeneratingLifelogSummary = true
        defer { isGeneratingLifelogSummary = false }

        let ctx = lifelogContext()
        guard !ctx.isEmpty else { return }

        let prompt = """
        あなたはユーザーの一日の活動を把握しているアシスタントです。以下のデータをもとに、今日の活動を日本語で簡潔に要約してください。
        ルール:
        - 挨拶・前置き不要。事実ベースで。
        - 2〜4文に収める。
        - Mac作業・外出・健康・メモの中で目立つものだけ取り上げる。
        - 「〜でした」「〜しました」調で、ひとことコメントを添えても良い。

        【今日のデータ】
        \(ctx)
        """
        let text = await runBriefPrompt(prompt)
        if !text.isEmpty && !looksLikeErrorResponse(text) {
            lifelogSummary = text
            lifelogSummaryAt = Date().timeIntervalSince1970
        }
    }

    /// ライフログ要約用のコンテキスト文字列を組み立てる。
    func lifelogContext() -> String {
        var lines: [String] = []

        // Mac アクティビティ（ディスクから）
        let macEntries = MacActivityLogger.shared.todayEntriesFromDisk()
        if !macEntries.isEmpty {
            let appGroups = Dictionary(grouping: macEntries.filter { $0.kind == "app" }, by: \.appName)
            let sorted = appGroups.map { (name: $0.key, dur: $0.value.reduce(0) { $0 + $1.duration }) }
                                  .sorted { $0.dur > $1.dur }.prefix(8)
            let macLine = sorted.map { item -> String in
                let m = Int(item.dur / 60)
                return m >= 60 ? "\(item.name)(\(m/60)h\(m%60>0 ? "\(m%60)m":""))" : "\(item.name)(\(m)m)"
            }.joined(separator: " / ")
            if !macLine.isEmpty { lines.append("Mac作業: \(macLine)") }

            let hermesEntries = macEntries.filter { $0.kind == "hermes" }
            if !hermesEntries.isEmpty {
                lines.append("Hermesチャット: \(hermesEntries.map { $0.appName }.joined(separator: ", "))")
            }
        }

        // iOS ヘルス
        if let h = latestHealth,
           Calendar.current.isDateInToday(Date(timeIntervalSince1970: h.updatedAt)) {
            var hp: [String] = []
            if let v = h.steps              { hp.append("歩数\(v)歩") }
            if let v = h.activeEnergyKcal   { hp.append("\(Int(v))kcal") }
            if let v = h.heartRate          { hp.append("心拍\(v)bpm") }
            if let v = h.restingHeartRate   { hp.append("安静心拍\(v)bpm") }
            if let v = h.sleepHours         { hp.append(String(format: "睡眠%.1fh", v)) }
            if let v = h.distanceKm         { hp.append(String(format: "%.1fkm", v)) }
            if !hp.isEmpty { lines.append("健康: \(hp.joined(separator: " / "))") }
        }

        // iOS 位置
        if !locationSummary.isEmpty,
           Calendar.current.isDateInToday(Date(timeIntervalSince1970: locationSummaryAt)) {
            lines.append("外出: \(resolvedLocationSummary(locationSummary))")
        }

        // iOS 写真
        if !photoSummary.isEmpty,
           Calendar.current.isDateInToday(Date(timeIntervalSince1970: photoSummaryAt)) {
            lines.append("写真: \(photoSummary)")
        }

        // メモ（共有・Web・写真）
        let memoCtx = MemoContext.format(MacMemoStore.shared.todayMemos)
        if !memoCtx.isEmpty { lines.append("共有・備忘録:\n\(memoCtx)") }

        return lines.joined(separator: "\n")
    }

    // MARK: - 起動時・定期実行

    /// 起動時に今日の振り返りがなければ自動生成する。
    func autoBriefIfStale() async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let briefDate = Date(timeIntervalSince1970: dailyBriefAt)
        guard dailyBriefAt == 0 || briefDate < today else { return }
        await generateDailyBrief()
    }

    /// 毎夜21:00に振り返りを自動生成するタイマーを起動する（30分ごとにチェック）。
    func startAutoBriefTimer() {
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cal = Calendar.current
            let hour = cal.component(.hour, from: Date())
            guard hour >= 21 else { return }
            let briefDate = Date(timeIntervalSince1970: self.dailyBriefAt)
            let evening = cal.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) ?? cal.startOfDay(for: Date())
            guard briefDate < evening else { return }
            Task { await self.generateDailyBrief() }
        }
    }

    // MARK: - 内部ヘルパー

    /// Run a brief prompt through the agent, racing a 40s timeout (the model may hang).
    /// Returns cleaned reply text, or "" on timeout/failure. Shared by generate + revise.
    func runBriefPrompt(_ prompt: String) async -> String {
        let stdout: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await HermesCLI.shared.exec(args: ["chat", "-q", prompt]).stdout }
            group.addTask { try? await Task.sleep(nanoseconds: 40_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return stdout.map { parseResponseText($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    /// Heuristic: does the model's text look like an error banner rather than a real reply?
    func looksLikeErrorResponse(_ text: String) -> Bool {
        let l = text.lowercased()
        let markers = ["api call failed", "http 4", "http 5", "429", "rate limit", "limit exceeded",
                       "too many tokens", "insufficient", "unauthorized", "invalid api key",
                       "no endpoints", "error:", "エラー:", "failed after"]
        return markers.contains { l.contains($0) } && text.count < 400
    }

    /// Deterministic fallback brief built directly from today's data (no model needed).
    func computedBrief() -> String {
        let ev = todayEvents
        let todo = tasks(status: .todo), doing = tasks(status: .doing)
        var reflection: [String] = []
        if !lifelogSummary.isEmpty,
           Calendar.current.isDateInToday(Date(timeIntervalSince1970: lifelogSummaryAt)) {
            reflection.append(lifelogSummary)
        } else {
            reflection.append(ev.isEmpty ? "本日の登録予定はありません。" : "本日の予定は\(ev.count)件です。")
            if let hl = healthSummaryLine { reflection.append(hl + "。") }
            let macEntries = MacActivityLogger.shared.todayEntriesFromDisk()
            if !macEntries.isEmpty {
                let top = macEntries.sorted { $0.duration > $1.duration }.prefix(3)
                let apps = top.map { $0.appName }.joined(separator: "、")
                reflection.append("Mac作業の中心は\(apps)でした。")
            }
        }
        reflection.append("未完了タスクは\(todo.count + doing.count)件（対応中\(doing.count)・未着手\(todo.count)）。")

        var body = "振り返り\n" + reflection.joined(separator: " ")
        let memoCtx = MemoContext.format(MacMemoStore.shared.todayMemos, max: 3, maxChars: 80)
        if !memoCtx.isEmpty {
            body += "\n\nつながり\n共有・備忘録から: \(memoCtx.replacingOccurrences(of: "\n", with: " / "))"
        }
        let focus = (doing + todo).prefix(3).map { "・\($0.title)" }
        if !focus.isEmpty { body += "\n\n今日の提案\n" + focus.joined(separator: "\n") }
        return body
    }
}
