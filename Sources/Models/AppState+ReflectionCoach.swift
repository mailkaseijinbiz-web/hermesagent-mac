import Foundation

// MARK: - 夜の振り返りコーチ
// 21:30にその日のライフログからAI質問を事前生成し、22:00にiOSへリマインダーを送る。
// 回答はReflectionEntryとしてPrivateStoreに暗号化保存され、週次レビューと
// SelfGraph差分提案の材料になる。

extension AppState {

    // MARK: - 質問の事前生成（21:30ジョブ）

    /// その日のlifelogContextからAI質問を1〜2問生成し、今日のReflectionEntryに保存する。
    /// 生成済み・回答済みの日はスキップ（force=trueで再生成）。
    func generateReflectionQuestions(force: Bool = false) async {
        let dateKey = ReflectionStore.dateKey()
        var entry = await ReflectionStore.shared.entry(dateKey: dateKey)
            ?? ReflectionEntry(dateKey: dateKey)
        if !force {
            guard entry.questionsGeneratedAt == nil, entry.answeredAt == nil else { return }
        }

        let ctx = await dayRecordContext()
        guard !ctx.isEmpty else { return }   // データなしの日は固定質問のみで成立

        let prompt = """
        あなたはユーザー専属のメタ認知コーチです。以下は今日のユーザーの活動データです。今夜の振り返りでユーザーに投げかける質問を1〜2個、JSONだけで返してください。
        形式: {"questions":["...", "..."]}
        ルール:
        - 各質問は日本語1文、40〜80字。データに明確に現れている出来事を具体的に踏まえること。
        - 「はい/いいえ」で終わらない、内省を促すオープンクエスチョンにする。
        - 説教・評価はしない。好奇心のトーンで。
        - データにない出来事を推測しない。

        【今日のデータ】
        \(ctx)
        """
        let text = await runBriefPrompt(prompt)
        guard !text.isEmpty, !looksLikeErrorResponse(text) else { return }
        let questions = Self.parseReflectionQuestions(text)
        guard !questions.isEmpty else { return }

        entry.qa = questions.prefix(2).map { ReflectionQA(question: $0) }
        entry.questionsGeneratedAt = Date().timeIntervalSince1970
        await ReflectionStore.shared.upsert(entry)
    }

    /// LLM応答からquestions配列を寛容にパースする（コードフェンス・前後テキスト対応）。
    static func parseReflectionQuestions(_ text: String) -> [String] {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return [] }
        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["questions"] as? [String] else { return [] }
        return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: - 回答の保存

    /// iOSからの回答POSTを反映する。渡されたフィールドだけ更新（部分更新可）。
    func saveReflectionAnswers(dateKey: String, moodScore: Int?, oneLiner: String?,
                               answers: [String: String]) async -> ReflectionEntry {
        var entry = await ReflectionStore.shared.entry(dateKey: dateKey)
            ?? ReflectionEntry(dateKey: dateKey)
        if let mood = moodScore, (1...5).contains(mood) { entry.moodScore = mood }
        if let line = oneLiner?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            entry.oneLiner = line
        }
        for i in entry.qa.indices {
            if let a = answers[entry.qa[i].id]?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
                entry.qa[i].answer = a
            }
        }
        entry.answeredAt = Date().timeIntervalSince1970
        await ReflectionStore.shared.upsert(entry)
        return entry
    }

    // MARK: - 定期実行（15分ごとにチェック）

    /// 21:30に質問生成、22:00に未回答ならAPNsリマインダー。ガードはエントリ内の
    /// タイムスタンプ（questionsGeneratedAt / reminderSentAt）なので多重起動しない。
    func startReflectionCoachTimer() {
        Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.reflectionCoachTick() }
        }
        Task { await reflectionCoachTick() }   // 起動直後にも1回評価（21:30以降の起動に対応）
    }

    func reflectionCoachTick() async {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)

        // 21:30〜: 質問生成
        if hour > 21 || (hour == 21 && minute >= 30) {
            await generateReflectionQuestions()
        }

        // 22:00〜: 未回答ならリマインダー（1日1回）
        if hour >= 22 {
            let dateKey = ReflectionStore.dateKey()
            var entry = await ReflectionStore.shared.entry(dateKey: dateKey)
                ?? ReflectionEntry(dateKey: dateKey)
            guard entry.answeredAt == nil, entry.reminderSentAt == nil else { return }
            entry.reminderSentAt = now.timeIntervalSince1970
            await ReflectionStore.shared.upsert(entry)
            sendPushIfEnabled(
                title: "今日の振り返り",
                body: "今夜の質問が届いています。1分だけ、今日を振り返りませんか？",
                sessionId: nil,
                proactive: true
            )
        }
    }

    // MARK: - 週次レビューへの還流

    /// 直近daysの気分スコアと回答をレビュー用テキストに整形する。
    func reflectionReviewBlock(days: Int = 14) async -> String {
        let entries = await ReflectionStore.shared.recent(days: days)
        guard !entries.isEmpty else { return "" }
        var lines: [String] = []
        for e in entries {
            var parts: [String] = [e.dateKey]
            if let m = e.moodScore { parts.append("気分\(m)/5") }
            if let l = e.oneLiner, !l.isEmpty { parts.append("「\(l)」") }
            lines.append(parts.joined(separator: " "))
            for qa in e.qa {
                guard let a = qa.answer, !a.isEmpty else { continue }
                lines.append("  Q: \(qa.question)")
                lines.append("  A: \(a)")
            }
        }
        return "【夜の振り返り（気分と回答）】\n" + lines.joined(separator: "\n")
    }

    // MARK: - SelfGraph差分提案（週次・承認制）

    /// 直近1週間の振り返り＋ライフログから自己グラフの差分を提案する。
    /// 生成した提案はpendingとして保存され、ユーザーが承認したものだけ反映される。
    func generateSelfGraphProposals() async {
        let graphData = (try? await SelfGraphStore.shared.encoded()) ?? Data()
        let graphJSON = String(data: graphData, encoding: .utf8) ?? "{}"
        let reflections = await reflectionReviewBlock(days: 7)
        let weekData = weeklyReviewContext()
        guard !reflections.isEmpty || !weekData.isEmpty else { return }

        let prompt = """
        あなたはユーザーの自己グラフ（興味・目標・プロジェクトのネットワーク）を保守するアシスタントです。今週のデータをもとに、グラフへの変更を0〜4件、JSONだけで提案してください。
        形式: {"proposals":[{"kind":"addNode|addLink|strengthenLink","reason":"...","nodeLabel":"...","nodeType":"interest","nodeDesc":"...","sourceLabel":"...","targetLabel":"..."}]}
        ルール:
        - addNode: 今週明確に繰り返し現れた新しい関心・活動のみ。nodeLabel/nodeType/nodeDesc必須。typeはgoal|interest|project|tech|concept|person|placeから。
        - addLink / strengthenLink: sourceLabel/targetLabel必須。既存ノードのlabelを正確に使うこと。
        - reasonは日本語1文で、データ上の根拠を書く。
        - 確信が持てない変更は提案しない。0件なら {"proposals":[]} を返す。

        【現在のグラフ】
        \(graphJSON)

        \(reflections)

        【今週の日次データ】
        \(weekData)
        """
        let text = await runBriefPrompt(prompt)
        guard !text.isEmpty, !looksLikeErrorResponse(text) else { return }
        let proposals = Self.parseSelfGraphProposals(text)
        await SelfGraphProposalStore.shared.replacePending(with: proposals)
        selfGraphProposalsUpdatedAt = Date().timeIntervalSince1970
    }

    static func parseSelfGraphProposals(_ text: String) -> [SelfGraphProposal] {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["proposals"] as? [[String: Any]] else { return [] }
        return arr.compactMap { p in
            guard let kind = p["kind"] as? String,
                  ["addNode", "addLink", "strengthenLink"].contains(kind),
                  let reason = p["reason"] as? String, !reason.isEmpty else { return nil }
            var prop = SelfGraphProposal(kind: kind, reason: reason)
            prop.nodeLabel = p["nodeLabel"] as? String
            prop.nodeType = p["nodeType"] as? String
            prop.nodeDesc = p["nodeDesc"] as? String
            prop.sourceLabel = p["sourceLabel"] as? String
            prop.targetLabel = p["targetLabel"] as? String
            if kind == "addNode", prop.nodeLabel == nil { return nil }
            if kind != "addNode", prop.sourceLabel == nil || prop.targetLabel == nil { return nil }
            return prop
        }
    }

    /// 提案を承認/却下する。承認時はグラフへ反映してから状態を更新する。
    /// 戻り値は更新後の提案（見つからなければnil）。
    func decideSelfGraphProposal(id: String, accept: Bool) async -> SelfGraphProposal? {
        guard accept else {
            return await SelfGraphProposalStore.shared.setStatus(id: id, status: "rejected")
        }
        let pending = await SelfGraphProposalStore.shared.pending()
        guard let prop = pending.first(where: { $0.id == id }) else { return nil }
        let graph = await SelfGraphStore.shared.load()

        func nodeId(forLabel label: String?) -> String? {
            guard let label else { return nil }
            return graph.nodes.first { $0.label == label }?.id
        }

        switch prop.kind {
        case "addNode":
            guard let label = prop.nodeLabel else { return nil }
            if nodeId(forLabel: label) == nil {
                let node = SelfGraphNode(
                    id: UUID().uuidString, label: label,
                    type: prop.nodeType ?? "concept", desc: prop.nodeDesc ?? "",
                    size: 12, createdAt: Date().timeIntervalSince1970
                )
                try? await SelfGraphStore.shared.upsertNode(node)
                // 新ノードは自分と接続しておく（孤立防止）
                try? await SelfGraphStore.shared.upsertLink(
                    SelfGraphLink(source: "self", target: node.id, weight: 2))
            }
        case "addLink":
            guard let s = nodeId(forLabel: prop.sourceLabel),
                  let t = nodeId(forLabel: prop.targetLabel) else { return nil }
            try? await SelfGraphStore.shared.upsertLink(SelfGraphLink(source: s, target: t, weight: 2))
        case "strengthenLink":
            guard let s = nodeId(forLabel: prop.sourceLabel),
                  let t = nodeId(forLabel: prop.targetLabel) else { return nil }
            let current = graph.links.first {
                ($0.source == s && $0.target == t) || ($0.source == t && $0.target == s)
            }?.weight ?? 1
            try? await SelfGraphStore.shared.upsertLink(
                SelfGraphLink(source: s, target: t, weight: min(4, current + 1)))
        default:
            return nil
        }
        return await SelfGraphProposalStore.shared.setStatus(id: id, status: "accepted")
    }
}
