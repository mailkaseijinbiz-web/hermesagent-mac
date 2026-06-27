import Foundation

// 株モニタリング機能を AppState 本体から分離（#3 god object 分割の第一歩）。
// 編集バッファ stockPortfolioText / stockApiKey は @Published stored property のため
// AppState 本体に残し、関連ロジック（保存/読込/プリフィル等）をここへ集約した。
extension AppState {
    // MARK: - 株モニタリング (証券アナリスト × cron × LINE)

    /// cron の --script に渡す名前(~/.hermes/scripts/ 配下で解決される)。
    static let stockScriptName = "stock-monitor.py"
    static var stockPortfolioPath: String { NSHomeDirectory() + "/.hermes/scripts/portfolio.txt" }
    static var stockEnvPath: String { NSHomeDirectory() + "/.hermes/scripts/.env" }

    static func loadPortfolioText() -> String {
        (try? String(contentsOfFile: stockPortfolioPath, encoding: .utf8)) ?? ""
    }

    /// ~/.hermes/scripts/.env から TWELVEDATA_API_KEY を読む(無ければ空)。
    static func loadStockApiKey() -> String {
        guard let txt = try? String(contentsOfFile: stockEnvPath, encoding: .utf8) else { return "" }
        for raw in txt.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("TWELVEDATA_API_KEY=") {
                return String(l.dropFirst("TWELVEDATA_API_KEY=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        return ""
    }

    private func ensureStockScriptsDir() {
        try? FileManager.default.createDirectory(
            atPath: NSHomeDirectory() + "/.hermes/scripts", withIntermediateDirectories: true)
    }

    func savePortfolioText() {
        ensureStockScriptsDir()
        do {
            try stockPortfolioText.write(toFile: Self.stockPortfolioPath, atomically: true, encoding: .utf8)
            triggerToast(message: "保有銘柄を保存しました。")
        } catch {
            reportFailure("保有銘柄の保存に失敗 (\(Self.stockPortfolioPath))", error: error,
                          toast: "保有銘柄を保存できませんでした。")
        }
    }

    /// .env の TWELVEDATA_API_KEY 行だけを差し替え/追記して保存(他の行は保持)。
    func saveStockApiKey() {
        ensureStockScriptsDir()
        let key = stockApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if let txt = try? String(contentsOfFile: Self.stockEnvPath, encoding: .utf8) {
            lines = txt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("TWELVEDATA_API_KEY=") }
        }
        if !key.isEmpty { lines.append("TWELVEDATA_API_KEY=\(key)") }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        do {
            try body.write(toFile: Self.stockEnvPath, atomically: true, encoding: .utf8)
        } catch {
            reportFailure("株価APIキーの保存に失敗 (\(Self.stockEnvPath))", error: error,
                          toast: "株価APIキーを保存できませんでした。")
        }
    }

    /// 株モニタリングの担当=証券アナリスト社員を解決(名前に「証券」→ロール analyst →「アナリスト」)。
    var stockAnalyst: Employee? {
        employees.first { $0.name.contains("証券") }
            ?? employees.first { $0.role == .analyst }
            ?? employees.first { $0.name.contains("アナリスト") }
    }

    /// 登録済み LINE チャンネルの最初の channelId(無ければ nil)。
    var firstLineChannelId: String? {
        channels.first { $0.platform.lowercased() == "line" }?.channelId
    }

    /// 株モニタリングの cron 作成フォームを一括プリフィル(内容確認後に『タスクを作成』で確定)。
    /// 注: スケジュールはシステムのローカル時刻(日本なら JST)で解釈される。
    func prefillStockMonitor() {
        // 保有銘柄(コメント/空行以外)が1件も無ければ作成させない。
        let hasHolding = stockPortfolioText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { !$0.isEmpty && !$0.hasPrefix("#") }
        guard hasHolding else {
            triggerToast(message: "保有銘柄を入力してください（コメント行のみです）。")
            return
        }
        newCronName = "株モニタリング"
        newCronSchedule = "30 8,15 * * 1-5"   // 平日 8:30 / 15:30(ローカル時刻)
        newCronAssigneeId = stockAnalyst?.id
        newCronScript = Self.stockScriptName
        newCronNoAgent = false
        newCronDeliver = firstLineChannelId.map { "line:\($0)" } ?? "local"
        newCronPrompt = "次のスクリプト出力は、ユーザーの保有銘柄の最新株価(前日比)と関連ニュース見出しです。これを分析し、保有銘柄に影響しそうな重要な変動・ニュースを中心に、要点を日本語で簡潔にまとめて、LINE通知向けの短いレポートにしてください。各銘柄の前日比と注目すべきニュースの見出しを優先し、全体は読みやすい長さに。最後に「※投資助言ではなく情報整理です」と一言添えてください。"
        view = "automations"
        showCronCreateSheet = true   // 反映した内容を作成モーダルで開く
        if firstLineChannelId == nil {
            triggerToast(message: "LINE宛先が未登録のため配信先は『local』です（後で変更可）。")
        }
    }
}
