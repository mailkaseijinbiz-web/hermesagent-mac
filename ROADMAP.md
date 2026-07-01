# HermesAgent 改善ロードマップ

両リポジトリ（[hermesagent-mac](https://github.com/mailkaseijinbiz-web/hermesagent-mac) / [hermesagent-ios](https://github.com/mailkaseijinbiz-web/hermesagent-ios)）を **6観点（アーキテクチャ / セキュリティ / コード品質 / 信頼性 / テスト&CI / プロダクト）** で監査した結果に基づく、優先度つきの長期計画。

---

## 📅 2026-07-01 更新ログ

**`cursor/intention-cards` ブランチで完了**
- ✅ **B3/B4**：意図カード（Intention）Mac/iOS パリティ＋ウィジェット連携
- ✅ **C**：高機微 PII の PrivateStore 暗号化（`locationDaily` / `photoDaily` / `lifelogDaily` 等）
- ✅ **D1**：`dailyBrief` / `weeklyReview` を `briefDaily` / `weeklyReviewDaily` へ暗号化移行（UserDefaults → PrivateStore、起動時マイグレーション）
- ✅ **D2**：cron `lastError` を Mobile API JSON に追加、iOS オートメーション行にオレンジ表示
- ✅ **D3**：iOS `HermesAgentLogicTests` ターゲット＋CI `xcodebuild test`（JSON デコード回帰）
- ✅ **E1**：`AppState+Automation` へ cron 管理ロジック分離、`HermesCronJobParser` 抽出＋テスト
- ✅ **E2**：配信失敗デッドレターキュー（`FailedDeliveryStore`・暗号化永続化・オートメーション UI）
- ✅ **E3**：`MacLifeLogView` にライフログ記録インジケータ（記録中 / 記録オフ）
- Mac テスト 107 funcs（+4）、iOS テスト 4 funcs 新設、両リポ CI green

---

## 📅 2026-06-30 更新ログ（夕方・第2回）

**前回（本日午前の記載）から進んだこと**
- ✅ **巨大な未コミット差分が解消**：午前に懸念していた「未コミットの +1,655 行」は `03d7884 feat: lifelog/news/task improvements + Chrome tab tracking` としてコミット済み。ワーキングツリーは clean。
- ✅ **パストラバーサル境界を修正**（午前の 🟡 を解消）：`/api/employees/{id}/file` の許可判定を「`..`/`.` 除去 → symlink 解決 → 末尾 `/` 付き接頭辞 or 完全一致」に強化（`MobileServer.swift:1622-1634`）。兄弟ディレクトリ（`<ws>-evil`）の漏れを塞いだ。
- ✅ **PersonalAI ドメインを extension へ一部隔離**：`AppState+PersonalAI.swift`（321 行・`lifelogSummary` 生成/30分ステール判定、`dailyBriefContext` への iOS データ混合）を新設。
- ✅ **新機能群が着地**：`MacActivityLogger`（Chrome/Safari/Arc の現在タブURLを AXUIElement で8秒ポーリング記録）、`MacLifeLogView`（iOS健康/位置/写真×Macアクティビティ混合＋AI要約＋自宅登録）、`MacNewsView`（30日スパークライン）、`TasksView` 詳細シート編集、`MacMemoStore`/`SelfGraph`/`ChartBlockView` 追加。

**今日見つかった懸念（要対応・優先度順）**
- 🔴 **PII の at-rest 暗号化が未着手なまま、機微度だけ急上昇**：本日の `MacActivityLogger` で **ブラウザの閲覧URL履歴**が新たに永続対象に。既存の `locationPoints`/`photoSummary`/`personalProfile`/`selfModel` と合わせ、**すべて平文**（`saveJSON` は `UserDefaults.standard.set(JSONEncoder…)`＝`~/Library/Preferences` の plist 平文／`AppState.swift:776`）。位置履歴＋写真要約＋閲覧履歴＋自己モデルは「個人の行動を丸ごと再構成できる」レベル。**Keychain ラップ鍵で暗号化したファイル（`~/.hermes/private/`・0600）へ移すのを最優先**に格上げ。
- 🔴 **テスト網羅が午前から横ばい（45 funcs のまま）**：`03d7884` で約 +2,000 行が入ったが純粋ロジック（レイアウト `compact`/`overlaps`、`SelfModel` JSON 往復、`lifelogSummary` の 30分ステール判定、`MacActivityLogger` のURL正規化/重複圧縮）にテストが 1 件も足されていない。神オブジェクト分割で得た安全余地を無テストの大型機能で食い潰す構図が続く。**最小限の回帰テスト追加を継続最優先**。
- 🟠 **アーキ退行が止まっていない**：PersonalAI を extension に切ったのに、本体 `AppState.swift` の `@Published` は **140 → 144**（合計 155）と更に増加。`MacActivityLogger`/lifelog 系の状態が本体に直書きされた疑い。本体行数は 3,267 まで縮小したが状態の集中は逆行。`AppState+Lifelog`（または `+MacActivity`）への隔離が必要。
- 🟠 **`AXUIElement` でのブラウザタブ取得の権限/失敗系**：アクセシビリティ権限が無い/剥奪された場合の挙動、8秒ポーリングの CPU/電力影響、収集停止トグルの有無を確認すべき（プライバシー UX として「記録中」の可視化＋オフ手段が要る）。
- 🟡 **`try?` が Models 配下で 179 箇所**：午前に永続化系は surface 化済みだが残りは多い。次は同期系（CloudKit/Gmail/Calendar）と MobileServer レスポンス系を精査。
- ⬜ **LINE 自己回復・iOS テスト/CI・Google client secret 保護**は引き続き未着手。
- 🟡 **iOS パリティ**：lifelog/位置/写真の**送信側プロデューサ**と新ビュー群（MacLifeLog/MacNews/Dashboard）の iOS 反映が未実装で差が拡大中。

---

## 📅 2026-06-30 更新ログ

**前回（06-28）から進んだこと**
- 🚧 **大型の新機能「パーソナルAI ダッシュボード」が作業中（未コミット・約 +1,655 行 / -542 行）**。[personal-ai-direction] のビジョンを具体化する初の本格実装。内訳：
  - **ベントーUI**（`DashboardView.swift` +474）：ドラッグ/リサイズ可能なウィジェット盤（`WidgetTile`、`compact()` で自動詰め）。`view` の既定が `dashboard` に変更（起動時の着地点が会話→ダッシュボードへ）。
  - **MobileServer 大幅拡張**（+569 / 新ハンドラ 20・新ルート約22）：`/api/profile`（likes/goals/values）、`/api/self`＋`/api/self-graph`（自己モデル/グラフ）、`/api/location`・`/api/photos`（iOS から足あと・写真要約を受信）、`/api/review`（週次メタ認知レビュー生成）、`/api/dashboard/brief`、`/api/badge/clear`、`/api/stocks`・`/api/sauna-news`・`/api/mac-activity`、`/api/employees/{id}/file`。
  - **AppState 本体に +522**：`dashboardLayout` / `dailyHistory` / `weeklyReview` / `locationSummary`＋`locationPoints` / `photoSummary` / `personalProfile` / `selfModel` / `employeeUnreadIds` など **新規 @Published 約14** と新モデル群を追加。
  - 付随：`EmployeeDetailView`(+141)、`SidebarView`(+41 / 未読バッジ)、`ChatView`(+42)。
- ✅ **dead code 削除がステージ済み**：`StructuredOutput.swift` / `NewsView.swift` / `OutputModeViews.swift`（計 -354）。06-28 で「機能判断待ち」だった **News 本体も撤去方向で確定**。
- ✅ **`AppState` 分割の効果が数字に**：本体は **5,041 → 3,454 行**（22 extension へ継続切り出し）。Chat/Employee/Provider/Schedule/Lifecycle まで分離完了。

**今日見つかった懸念（要対応）**
- 🔴 **未コミットの巨大差分（+1,655 行）がテスト 0 のまま積み上がっている**。ユニットテストは **45 funcs のまま**で、新機能（レイアウト詰め `compact`/`overlaps`、`SelfModel` JSON 往復、レビュー生成パース）は純粋ロジックでテスト可能なのに未カバー。→ **コヒーレントな単位でコミット＋純粋ロジックの回帰テスト追加**を最優先（神オブジェクト分割で得た安全性を、無テストの大型機能で食い潰さない）。
- 🟠 **アーキ退行リスク**：新パーソナルAIドメインが分割規律に反して **本体 `AppState.swift` に直書き**され、本体 @Published が **126 → 140** に再増加。→ `#3` の作法に合わせ **`AppState+PersonalAI`（または `+Dashboard`）extension へ隔離**すべき。
- 🟠 **プライバシー（保存時暗号化）**：位置情報（`locationPoints`）・写真要約・`personalProfile`・`selfModel` という **高機微 PII が平文 UserDefaults に永続化**。認可は Google サインインゲート配下で OK だが、パーソナルAI化で機微度が上がったため **at-rest 暗号化方針**（Keychain ラップ鍵 + 暗号化ファイル等）の決定が必要。
- 🟡 **パストラバーサル境界**：`/api/employees/{id}/file` の許可判定が `full.hasPrefix(workspace)` のみ。`workspace` と兄弟ディレクトリ（`<ws>-evil`）を通す恐れ。→ **末尾 `/` を付与した接頭辞判定 or 正規化後の包含チェック**へ。
- 🟡 **iOS パリティ・ギャップが最大化**：`/api/location`・`/api/photos` の **送信側（iOS の足あと/写真要約プロデューサ）** とベントー盤の閲覧が iOS 未実装。新機能が Mac 先行で、薄クライアント方針の差分が開いた。

---

## 📅 2026-06-28 更新ログ

**前回から進んだこと（直近コミット `#3 cont` / `#5` 系）**
- ✅ **`AppState` 分割が始動**：6 ドメインを extension に切り出し（`+Teams` / `+Tasks` / `+Apps` / `+Channels` / `+GitHub` / `+StockMonitor`）。本体は **5,041 → 4,758 行**へ。ただし本体は依然 **127 `@Published`**（分割全体で 133）で、最大塊の **Chat / Employee / CloudSync** は未分割。
- ✅ **バックエンド・サーキットブレーカ**（`#5`）を `AppState` に実装。
- ✅ **CORS をホワイトリスト化**（`MobileServer` で Origin 検証、deny 既定）。フェーズ0の Sec 項目を解消。
- ✅ **Google トークンをファイル保存へ**（`~/.hermes/.oauth/<key>`, 0600）。未署名 dev ビルドのキーチェーン ACL でパスワードを毎回聞かれる問題を回避（キーチェーンに戻さない方針）。
- ✅ `/api/health`（HealthKit スナップショット受信）稼働。

**本日この場で対応した事項**
- ✅ **`UpdateManager` のシェル注入を解消**：`sh` を `(command, args, cwd)` 化し、ブランチ名/コミットSHA/リポジトリ・アプリパスを zsh の位置パラメータ（`$1`,`$2`）として渡すよう全呼び出しを変更（ログインシェルの env 互換は維持）。値がコードではなくデータとして扱われ、悪意あるブランチ名やメタ文字を含むパスでの脱出を防止。`UpdateManager.swift`。
- ✅ **開発者個人 Apple Team ID のハードコード除去**：`apnsTeamId` の既定を空に（`AppState.swift:345`）。あわせて `sendPushIfEnabled` のガードに `!apnsTeamId.isEmpty` を追加し、未設定時に不正な JWT を作らないようにした（`AppState.swift:1521`）。
- ✅ **未配線の構造化出力 dead code を除去**：`OutputModeViews.swift` から未使用の `OutputModePicker`/`StructuredOutputContainer`/`NewsSummaryView`/`NewsTimelineView`/`NewsTableView`/`EmptyStructuredState` を削除（`NewsView` が使う `NewsCardsView`/`NewsEntryCard`/`SourceLinkRow` は保持）。連動して全くレンダリングされていなかった `AppState.chatOutputMode`（`@Published`・UserDefaults 永続）と `OutputViewMode` enum も削除。**AppState の `@Published` は 127 → 126**、差分は約 -210 行。
- ✅ **永続化の沈黙失敗を surface 化（`#2` 着手）**：状態保存系の `try?` を `do/catch + Log.failure` 化 — `saveJSON`（teams/tasks/artifacts 汎用）/ `saveSessionOwner` / `saveEmployees` / `saveModelHealth` / フィードバックログ書込。**最重要は `loadEmployees`**：「データは在るのにデコード失敗→空配列で握り潰し→次の保存で名簿全消去」（過去の "社員が全員消えた" の典型症状）を必ず ERROR ログに残すよう変更。
- ✅ ビルド成功・既存ユニットテスト 45 件すべて green（`run_tests.sh`）。

**まだ開いている / 今日見つかった事項**
- 🟡 **沈黙失敗の残り**：永続化系は対応したが、`try?` は全体でまだ多数。残りの多くは正当（`Task.sleep` / ベストエフォートな `removeItem` クリーンアップ / Optional 機能のデコード既定値）。次は **同期系（CloudKit/Gmail/Calendar）と MobileServer のレスポンス系** を精査して必要なものだけ surface 化する。`#2` 継続。
- 🟡 **残る dead code 判断は機能レベル**：`NewsView`/`GmailView`/`ScheduleView` は `MainView` から依然参照 → News/Gmail/Schedule 機能を残すか撤去かの方針決定が先（独断で削除しない）。
- ⬜ **iOS テスト 0 のまま / iOS CI 未新設**。Mac は CI 正常・テスト 45 funcs。
- ⬜ **LINE 自己回復（health＋失効検知＋デッドレターキュー）未着手**。
- ⬜ **Google client secret の保護**：トークンは 0600 ファイルへ移行済みだが client secret は別途要対応。
- 🟡 **CloudKit Stage 1/2 は scaffold 済み**（`CloudKitSync.swift` に roster/message mirror）だが、オフラインファースト動作へは未接続。

---

## 現状評価
**強み**：`AgentBackend` 抽象化（Hermes/ACP/agy を統一・テスト可能）、社員ごとの並列実行（プロセス/ACP分離）、ステートレスな MobileServer、読み書き分離の永続化（read-only SQLite + WAL）、cron 自動化の完成度（株モニタ・Gmail→タスクの E2E 実証）。

**核心課題**：
1. 公開リポジトリ化に伴うセキュリティ露出（＋パーソナルAI化で **機微 PII の at-rest 暗号化**が新たに重要）
2. 自動化スタックの障害回復力（実際に LINE 401 障害が発生）
3. `AppState` 本体は 3,454 行まで縮小（5,041 から）も **@Published 140**。新パーソナルAIドメインを本体直書きで再肥大化させた退行に注意
4. テスト網羅率が低い（Mac 45 funcs / iOS 0%）。**未コミットの +1,655 行が無テスト**で積み上がり中
5. 単一ハブ依存（iOS はオフライン不可）＋ **新ダッシュボードで iOS パリティ差が拡大**

---

## 🔴 フェーズ0 — 今すぐ（0–4週）｜固める

| テーマ | 項目 | 状態 |
|---|---|---|
| Test | ローカル `swift test` を通す（`run_tests.sh`：フルXcode + xattrクリア） | ✅ 完了 |
| Sec | `~/.hermes/.env` を 0600 に / `.gitignore` で秘密ファイルを防御的除外 | ✅ 確認・強化 |
| Sec | ローカルAPIキー・Google client secret を Keychain へ（後述の注意あり） | 🟡 Google トークンは 0600 ファイルへ。client secret は要対応 |
| Sec | MobileServer の CORS を `*` からホワイトリスト化 | ✅ 完了（Origin 検証・deny 既定） |
| Sec | バインドを loopback/Tailscale 限定に（iOS接続への影響を要設計） | ⬜ |
| Sec | `UpdateManager` の `zsh -lc` を Process配列実行へ（シェル注入対策） | ✅ 完了（値を位置パラメータ化） |
| Rel | LINE配信の自己回復（`/health`＋トークン失効検知＋再送デッドレターキュー） | ⬜ |
| Rel | 外部スクリプト（stock/gmail）をラッパー化（timeout＋指数バックオフ＋結果記録） | ⬜ |
| QA | 開発者個人ID（APNs `576D2UUHH5`／bundle）を空デフォルト＋設定プロンプト化 | ✅ Team ID 空既定＋送信ガード追加（bundle は要検討） |
| Prod | 撤去済みの News/Gmail/Schedule/OutputModeViews を削除（dead code整理） | 🟡 未配線分（構造化出力＋chatOutputMode）は削除済。News/Gmail/Schedule 本体は機能判断待ち |

### ⚠️ 設計上の注意（監査の単純推奨をそのまま適用しない）
- **ローカルAPIキーの Keychain 化**：このキーは cron の外部スクリプト（`add-task.sh` 等）が `~/.hermes/.env` から読む「機械間インターフェース」。Keychain に移すとスクリプトが読めなくなる。→ キーは `.env`（0600）に残しつつ、**ローテーション＋アクセス記録**で緩和するのが現実解。Google client secret は UI でしか使わないため Keychain 化が適切。
- **バインドアドレス**：現状 `0.0.0.0` は Tailscale 越し iOS 接続のため。loopback 限定にすると iOS が繋がらない。→ **loopback ＋ Tailscale インターフェースIP** にバインドするのが正解（実装に Tailscale IP 解決が必要）。

---

## 🟡 フェーズ1 — 次（1–3ヶ月）｜整える

**基盤リファクタ（後続全ての前提）**
- **`AppState` をドメイン別マネージャに分割**（Chat / Employee / CloudSync / Automation / AppLaunch / Channel）。再描画範囲の縮小・テスト可能化・Swift6移行の前提。
- **66箇所の `try?` 沈黙失敗を排除** → 構造化ログ（`~/.hermes/logs/app.log`）＋ユーザートースト。
- iCloud同期/ミラーに指数バックオフ＋リトライ、`empMessages` のメモリ上限/プルーニング。

**信頼性/運用**
- **429 サーキットブレーカ**（再試行嵐の停止＋フォールバック誘導）。
- cron の `last_error` を UI 表示＋失敗トースト。
- バックエンド/ブリッジ/サーバのヘルスチェック＆ウォッチドッグ、未導入CLIの検知→案内。

**テスト/CI**
- iOS にテストターゲット＆ iOS CI（GitHub Actions / Xcode Cloud）新設。
- HTTP/API/同期の統合テスト、git tag からの動的バージョニング、リリース手順（署名アーティファクト）。

**iOSパリティ**
- iOS に cron 作成UI（現状は閲覧のみ）、社員詳細パネル＋ターミナル read-only、APNs登録フロー完結。

---

## 🟢 フェーズ2 — 将来（3–12ヶ月）｜広げる
- **単一ハブ脱却 → オフラインファースト**：CloudKit同期を Stage1+ まで実装（社員/タスク/イベントの CRDT・トゥームストーン）、MobileServer を read-only API 化して iOS をローカルキャッシュで自立動作。
- **Swift 6 strict-concurrency 完全移行**（分割後にマネージャ単位で安全に）。
- **マルチユーザ/マルチテナント**（ワークスペース・スコープ、Teams 実装 or 削除）、P2P同期（Bonjour）。
- **形式的データモデル＆スキーマ移行**、構造化オブザーバビリティ/テレメトリ。
- **プロダクト**：対話型オンボーディングウィザード、利用者向けクイックスタート、ポジショニング明確化。

---

*このロードマップは 6 並列監査（実コード根拠つき）に基づく。CI（`.github/workflows/ci.yml`）は現在正常稼働しており、`swift test` の失敗はローカル CommandLineTools ツールチェーン要因（`run_tests.sh` で解消）。*
