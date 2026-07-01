import Foundation

// Cron / automation management — extracted from AppState.swift (Phase E1).
extension AppState {
    // MARK: - Automation suggestions

    /// Always-available curated automation ideas (no LLM needed).
    static let curatedAutomations: [AutomationSuggestion] = [
        .init(title: "毎朝のニュース要約", schedule: "0 8 * * *",
              prompt: "今日の主要なニュースを3つ、日本語で簡潔に要約して。",
              deliver: "local", icon: "newspaper", rationale: "毎朝の情報収集を自動化"),
        .init(title: "今日のTODO整理", schedule: "0 9 * * 1-5",
              prompt: "未完了のタスクと今日の予定を整理し、優先順位をつけて提案して。",
              deliver: "local", icon: "checklist", rationale: "平日の朝に1日の計画を準備"),
        .init(title: "週次の振り返りレポート", schedule: "0 18 * * 5",
              prompt: "今週の活動を振り返り、来週やるべきことを3点提案して。",
              deliver: "local", icon: "chart.line.uptrend.xyaxis", rationale: "毎週金曜にレビュー"),
        .init(title: "GitHub PRの確認", schedule: "0 10 * * 1-5",
              prompt: "自分が関係するオープンなPRとレビュー待ちを gh で一覧にして。",
              deliver: "local", icon: "chevron.left.forwardslash.chevron.right", rationale: "レビュー漏れを防ぐ"),
        .init(title: "受信メールの要約", schedule: "0 7,19 * * *",
              prompt: "新着の重要なメールを確認し、要点を箇条書きで要約して。",
              deliver: "local", icon: "envelope", rationale: "朝晩にメールを把握"),
    ]

    /// Prefill the create form from a suggestion (the user reviews, then 作成).
    func applyAutomationSuggestion(_ s: AutomationSuggestion) {
        newCronName = s.title
        newCronSchedule = s.schedule
        newCronPrompt = s.prompt
        newCronDeliver = s.deliver.isEmpty ? "local" : s.deliver
        newCronScript = ""
        newCronNoAgent = false
        showCronCreateSheet = true
    }

    /// Ask the agent to propose automations (best-effort; parsed from pipe-delimited lines).
    func generateAutomationSuggestions() async {
        isGeneratingSuggestions = true
        defer { isGeneratingSuggestions = false }
        let prompt = """
        役立つ定期自動実行タスク（cron）を3つ提案してください。各行を厳密に次の形式（パイプ区切り、余計な装飾なし）で3行だけ出力:
        タイトル | cronスケジュール | エージェントへの指示
        例: 毎朝のニュース要約 | 0 8 * * * | 今日の主要ニュースを3つ日本語で要約して
        """
        let res = await HermesCLI.shared.exec(args: ["chat", "-q", prompt])
        let text = parseResponseText(res.stdout)
        var parsed: [AutomationSuggestion] = []
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[1].contains(" ") || parts[1].contains("*") else { continue }
            parsed.append(.init(title: parts[0], schedule: parts[1], prompt: parts[2],
                                deliver: "local", icon: "sparkles", rationale: "AIの提案"))
        }
        if parsed.isEmpty {
            triggerToast(message: "提案を生成できませんでした。もう一度お試しください。")
        } else {
            aiSuggestions = Array(parsed.prefix(3))
        }
    }

    // MARK: - Cron list & UI handlers

    func fetchCronJobs() async {
        isFetchingCronJobs = true
        let res = await HermesCLI.shared.exec(args: ["cron", "list"])
        isFetchingCronJobs = false

        guard res.success else { return }

        let jobs = HermesCronJobParser.parseList(stdout: res.stdout)
        cronJobs = jobs
        updateLineDeliveryAuthError(from: jobs)
        FailedDeliveryStore.shared.record(from: jobs)
    }

    func handleToggleCronJob(_ job: HermesCronJob) async {
        let action = job.isActive ? "pause" : "resume"
        triggerToast(message: "ジョブを\(job.isActive ? "一時停止" : "再開")中...")
        let res = await HermesCLI.shared.exec(args: ["cron", action, job.id])
        if res.success {
            triggerToast(message: "ジョブを\(job.isActive ? "一時停止" : "開始")しました。")
            await fetchCronJobs()
        } else {
            triggerToast(message: "操作に失敗しました。")
        }
    }

    func handleDeleteCronJob(_ job: HermesCronJob) async {
        triggerToast(message: "ジョブを削除中...")
        let res = await HermesCLI.shared.exec(args: ["cron", "delete", job.id])
        if res.success {
            triggerToast(message: "ジョブを削除しました。")
            await fetchCronJobs()
        } else {
            triggerToast(message: "削除に失敗しました。")
        }
    }

    // MARK: - Cron ops for the mobile API (no UI side effects)

    func cronJobsJSON() async -> [[String: Any]] {
        await fetchCronJobs()
        return cronJobs.map { j in
            ["id": j.id, "name": j.name, "schedule": j.schedule, "deliver": j.deliver,
             "status": j.status, "nextRun": j.nextRun, "script": j.script ?? "", "lastRun": j.lastRun ?? "",
             "lastError": j.lastError ?? ""]
        }
    }

    func cronCreate(schedule: String, prompt: String, name: String, deliver: String, script: String, noAgent: Bool) async -> Bool {
        let s = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        var args = ["cron", "create", s]
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { args.append(p) }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { args.append(contentsOf: ["--name", n]) }
        let d = deliver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { args.append(contentsOf: ["--deliver", d]) }
        let sc = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sc.isEmpty { args.append(contentsOf: ["--script", sc]) }
        if noAgent { args.append("--no-agent") }
        let res = await HermesCLI.shared.exec(args: args)
        if res.success { await fetchCronJobs() }
        return res.success
    }

    func cronSetPaused(id: String, paused: Bool) async -> Bool {
        let res = await HermesCLI.shared.exec(args: ["cron", paused ? "pause" : "resume", id])
        if res.success { await fetchCronJobs() }
        return res.success
    }

    func cronDelete(id: String) async -> Bool {
        let res = await HermesCLI.shared.exec(args: ["cron", "delete", id])
        if res.success { await fetchCronJobs() }
        return res.success
    }

    /// テスト実行: ジョブを今すぐ実行キューに入れる(`hermes cron run`)。
    func cronRunNow(id: String) async -> Bool {
        let res = await HermesCLI.shared.exec(args: ["cron", "run", id])
        if res.success {
            triggerToast(message: "テスト実行をトリガーしました。まもなく配信先に届きます。")
            await fetchCronJobs()
            fetchAutomationResults()
        } else {
            triggerToast(message: "テスト実行に失敗: \(res.stderr)")
        }
        return res.success
    }

    /// 既存のスケジュールタスクを編集（`hermes cron edit`）。
    func cronEdit(id: String, schedule: String, name: String, deliver: String) async -> Bool {
        var args = ["cron", "edit", id]
        let s = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { args.append(contentsOf: ["--schedule", s]) }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { args.append(contentsOf: ["--name", n]) }
        let d = deliver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { args.append(contentsOf: ["--deliver", d]) }
        guard args.count > 3 else { return false }
        let res = await HermesCLI.shared.exec(args: args)
        if res.success {
            triggerToast(message: "スケジュールタスクを更新しました。")
            await fetchCronJobs()
        } else {
            triggerToast(message: "更新に失敗: \(res.stderr)")
        }
        return res.success
    }

    @discardableResult
    func handleCreateCronJob() async -> Bool {
        let name = newCronName.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = newCronSchedule.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = newCronPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let aid = newCronAssigneeId, let emp = employees.first(where: { $0.id == aid }), !prompt.isEmpty {
            prompt = "あなたは「\(emp.name)」という名前の\(emp.role.title)です。\(emp.persona)\n\n\(prompt)"
        }
        let deliver = newCronDeliver.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = newCronScript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !schedule.isEmpty else {
            triggerToast(message: "スケジュールを入力してください。")
            return false
        }

        isCreatingCronJob = true
        triggerToast(message: "スケジュールタスクを作成中...")

        var args = ["cron", "create", schedule]
        if !prompt.isEmpty { args.append(prompt) }
        if !name.isEmpty { args.append(contentsOf: ["--name", name]) }
        if !deliver.isEmpty { args.append(contentsOf: ["--deliver", deliver]) }
        if !script.isEmpty { args.append(contentsOf: ["--script", script]) }
        if newCronNoAgent { args.append("--no-agent") }

        let res = await HermesCLI.shared.exec(args: args)
        if res.success {
            triggerToast(message: "タスクを作成しました。")
            newCronName = ""
            newCronSchedule = ""
            newCronPrompt = ""
            newCronDeliver = "local"
            newCronScript = ""
            newCronAssigneeId = nil
            newCronNoAgent = false
            await fetchCronJobs()
        } else {
            triggerToast(message: "作成に失敗しました: \(res.stderr)")
        }
        isCreatingCronJob = false
        return res.success
    }

    /// 作成フォームを初期状態へリセット（モーダルを「新規作成」で開く前に呼ぶ）。
    func resetNewCronForm() {
        newCronName = ""
        newCronSchedule = ""
        newCronPrompt = ""
        newCronDeliver = "local"
        newCronScript = ""
        newCronAssigneeId = nil
        newCronNoAgent = false
    }
}
