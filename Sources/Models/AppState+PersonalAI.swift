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
                let dur = m >= 60 ? "\(m/60)h\(m%60>0 ? "\(m%60)m":"")" : "\(m)m"
                return "\(MacWorkFocus.workTitle(for: e))(\(dur))"
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

    /// モデルが見出しを崩して出力したときの正規化（「つなぎり」「つなぎ」→「つながり」等）。
    static func normalizeBriefHeadings(_ text: String) -> String {
        let fixes: [String: String] = [
            "つなぎり": "つながり", "つなぎ": "つながり", "繋がり": "つながり",
            "振返り": "振り返り", "ふりかえり": "振り返り",
        ]
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fixed = fixes[trimmed] { return fixed }
            return String(line)
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
            dailyBrief = Self.normalizeBriefHeadings(text)
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
        let reflections = await reflectionReviewBlock(days: 14)
        let prompt = """
        あなたはユーザー専属のメタ認知コーチです。以下は直近2週間の日次データです。ユーザーの目標・好きなもの・リソース配分を踏まえ、一歩引いて俯瞰し、日本語でまとめてください。
        ルール:
        - 挨拶や前置きは書かない。
        - まず「気づき」として、データから読み取れるパターンや傾向（例: ある行動と睡眠/運動の相関、増減傾向）を根拠とともに2〜4点。夜の振り返りの気分スコアや回答があれば、行動データとの関連を最優先で見る。
        - 続けて「来週への提案」として、目標に近づく具体的な行動を最大3つ。好きなことも無理なく絡める。
        - 最後に「今週の意外なつながり」として、セレンディピティ候補から1点（あれば）。押し付けない。
        - データが乏しい点は憶測で埋めない。

        【ユーザーの目標・嗜好】
        \(personalProfileContext)

        【リソース配分（頭のメモリ・稼働時間）】
        \(selfModelContext)

        \(serendipityReviewBlock())

        \(reflections)

        【直近2週間の日次データ】
        \(data)
        """
        let text = await runBriefPrompt(prompt)
        if !text.isEmpty && !looksLikeErrorResponse(text) {
            weeklyReview = text
            weeklyReviewAt = Date().timeIntervalSince1970
            // レビューと同じ材料で自己グラフの差分提案も更新する（承認制）。
            await generateSelfGraphProposals()
        } else {
            triggerToast(message: "週次レビューの生成に失敗しました（モデル応答なし/エラー）")
        }
    }

    // MARK: - ライフログ要約

    private static let lifelogSummaryContextHashKey = "lifelogSummaryContextHash"

    /// 今日の Mac + iOS アクティビティを要約する（2〜4文）。
    /// 30分以内に生成済みなら skip（forceRefresh=true で強制再生成）。
    /// notifyLiveActivity=false は iOS 起点の生成用 — クライアントは応答から自分で
    /// Live Activity を更新するので、APNs プッシュを重ねると訪問のたび通知になる。
    func generateLifelogSummary(forceRefresh: Bool = false, notifyLiveActivity: Bool = true) async {
        guard !isGeneratingLifelogSummary else { return }
        if !Calendar.current.isDateInToday(Date(timeIntervalSince1970: lifelogSummaryAt)) {
            lifelogSummary = ""
            lifelogSummaryAt = 0
        }

        let ctx = lifelogContext()
        let ctxHash = ctx.hashValue
        let storedHash = UserDefaults.standard.integer(forKey: Self.lifelogSummaryContextHashKey)
        if ctx.isEmpty {
            if !lifelogSummary.isEmpty {
                lifelogSummary = ""
                lifelogSummaryAt = 0
            }
            return
        }
        if !forceRefresh {
            let age = Date().timeIntervalSince1970 - lifelogSummaryAt
            let isToday = Calendar.current.isDateInToday(Date(timeIntervalSince1970: lifelogSummaryAt))
            let contextChanged = ctxHash != storedHash
            if isToday && age < 1800 && !lifelogSummary.isEmpty && !contextChanged { return }
        }
        isGeneratingLifelogSummary = true
        defer { isGeneratingLifelogSummary = false }

        let prompt = """
        あなたはユーザーの一日の活動を把握しているアシスタントです。以下のデータをもとに、今日の活動を日本語で簡潔に要約してください。
        ルール:
        - 挨拶・前置き不要。事実ベースで。
        - 2〜4文に収める。
        - 【時系列】に載っている出来事だけを書く。Mac作業・外出・健康・メモ・写真のうち、データに明確に現れているものだけ。
        - 5分未満の短いアプリ切り替え、ウィンドウタイトル、プロジェクト名、開発中アプリ名は要約に含めない。
        - データにない内容は推測しない。昨日や最近の作業を推測で書かない。
        - 「〜でした」「〜しました」調で、ひとことコメントを添えても良い。

        【今日のデータ】
        \(ctx)
        """
        let text = await runBriefPrompt(prompt)
        if !text.isEmpty && !looksLikeErrorResponse(text) {
            let previous = lifelogSummary
            lifelogSummary = text
            lifelogSummaryAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(ctxHash, forKey: Self.lifelogSummaryContextHashKey)
            // 内容が実際に変わったときだけ Live Activity を更新する
            if notifyLiveActivity, text != previous {
                pushLifeLogLiveActivity(headline: text, statusLabel: "今日")
            }
        }
    }

    /// ライフログ要約用のコンテキスト（タイムライン UI と同じ DayTimelineGraph 由来）。
    func lifelogContext() -> String {
        var parts: [String] = []
        let timeline = timelineSummaryContextText()
        if !timeline.isEmpty {
            parts.append("【時系列】\n\(timeline)")
        }
        let memoCtx = MemoContext.format(MacMemoStore.shared.todayMemos, max: 8, maxChars: 160)
        if !memoCtx.isEmpty {
            parts.append("【メモ・共有（詳細）】\n\(memoCtx)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// 正規DayRecordベースのAIコンテキスト（構造化イベント＋指標＋普段との差分）。
    /// 要約・振り返り質問・週次レビューはこちらを優先的に使う。
    func dayRecordContext() async -> String {
        let record = await DayRecordBuilder.buildToday(appState: self)
        guard !record.events.isEmpty else { return lifelogContext() }
        var ctx = DayRecordBuilder.aiContext(record)
        let memoCtx = MemoContext.format(MacMemoStore.shared.todayMemos, max: 8, maxChars: 160)
        if !memoCtx.isEmpty {
            ctx += "\n\n【メモ・共有（詳細）】\n\(memoCtx)"
        }
        return ctx
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

    /// 夜の振り返り v2 — 選んだ記録と感情から「今日のひとこと」+ AI振り返り文を生成。
    func generateEveningReflection(
        pickedLabel: String,
        pickedDetail: String,
        feelingText: String
    ) async -> EveningReflectionAIResult? {
        let label = pickedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = pickedDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        let feeling = feelingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feeling.isEmpty else { return nil }

        var record = label
        if !detail.isEmpty, detail != label {
            record += " — \(detail)"
        }

        var contextLines: [String] = []
        let timeline = timelineContextText()
        if !timeline.isEmpty { contextLines.append("【今日の流れ】\n\(timeline)") }
        if !lifelogSummary.isEmpty,
           Calendar.current.isDateInToday(Date(timeIntervalSince1970: lifelogSummaryAt)) {
            contextLines.append("【活動要約】\n\(lifelogSummary)")
        }
        let context = contextLines.joined(separator: "\n")

        let prompt = """
        あなたはユーザーの一日の振り返りを手伝うアシスタントです。ユーザーが選んだ記録と気持ちをもとに、JSONだけを返してください。
        形式: {"oneLiner":"...", "aiReflection":"..."}

        oneLiner: 今日のひとこと。日本語1文、30〜60字。選んだ記録と感情が自然に伝わること。
        aiReflection: Hermesからの振り返り。2〜3文、120〜200字。今日の流れと選んだ記録をつなげ、含蓄のある所感。一般論・お決まりの励ましは避ける。データにない推測はしない。

        【選んだ記録】\(record)
        【そのときの気持ち】\(feeling)
        \(context.isEmpty ? "" : "\n\(context)")
        """
        let text = await runBriefPrompt(prompt)
        if !text.isEmpty, !looksLikeErrorResponse(text), let parsed = EveningReflectionAIParser.parse(text) {
            return parsed
        }
        let oneLiner = await generateEveningReflectionOneLiner(
            pickedLabel: pickedLabel,
            pickedDetail: pickedDetail,
            feelingText: feelingText
        )
        guard !oneLiner.isEmpty else { return nil }
        return EveningReflectionAIResult(oneLiner: oneLiner, aiReflection: "")
    }

    /// 夜の振り返り v0 — 選んだ記録と感情から「今日のひとこと」を1文生成。
    func generateEveningReflectionOneLiner(
        pickedLabel: String,
        pickedDetail: String,
        feelingText: String
    ) async -> String {
        let label = pickedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = pickedDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        let feeling = feelingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feeling.isEmpty else { return "" }

        var record = label
        if !detail.isEmpty, detail != label {
            record += " — \(detail)"
        }

        let prompt = """
        あなたはユーザーの一日の振り返りを手伝うアシスタントです。ユーザーが選んだ記録と、そのときの気持ちをもとに「今日のひとこと」を日本語で1文だけ書いてください。
        ルール:
        - 挨拶・前置き不要。1文のみ。
        - 選んだ記録の内容と感情の両方が自然に伝わること。
        - 30〜60字程度。です・ます調でもよい。
        - データにない内容は推測しない。

        【選んだ記録】\(record)
        【そのときの気持ち】\(feeling)
        """
        let text = await runBriefPrompt(prompt)
        if !text.isEmpty && !looksLikeErrorResponse(text) {
            return text
        }
        return ""
    }

    // MARK: - 内部ヘルパー

    /// Vision caption for a lifelog photo (JPEG on disk). Deletes the temp file when done.
    func describePhoto(at imagePath: String) async -> String {
        let prompt = """
        この写真に写っている内容を日本語で1〜2文で説明してください。
        ルール: 挨拶不要。見えている事実だけ。人物・食べ物・場所・活動があれば具体的に。
        """
        let text = await runVisionPrompt(prompt, imagePath: imagePath)
        try? FileManager.default.removeItem(atPath: imagePath)
        guard !text.isEmpty, !looksLikeErrorResponse(text) else { return "" }
        return text
    }

    /// Run a brief prompt with an attached image through the agent CLI.
    func runVisionPrompt(_ prompt: String, imagePath: String) async -> String {
        let args = ["chat", "-q", prompt, "--image", imagePath]
        let stdout: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await HermesCLI.shared.exec(args: args, timeout: 45).stdout }
            group.addTask { try? await Task.sleep(nanoseconds: 45_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return stdout.map { parseResponseText($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

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
                let apps = top.map { MacWorkFocus.workTitle(for: $0) }.joined(separator: "、")
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
