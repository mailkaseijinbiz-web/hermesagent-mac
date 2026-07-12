# HermesAgent 改善ロードマップ

両リポジトリ（[hermesagent-mac](https://github.com/mailkaseijinbiz-web/hermesagent-mac) / [hermesagent-ios](https://github.com/mailkaseijinbiz-web/hermesagent-ios)）を **6観点（アーキテクチャ / セキュリティ / コード品質 / 信頼性 / テスト&CI / プロダクト）** で監査した結果に基づく、優先度つきの長期計画。

> 役割分担：本ファイル（root）＝**技術負債/監査の日次ログ**、[docs/ROADMAP.md](docs/ROADMAP.md)＝**プロダクト方向（認知拡張ビジョン＋EVENT-STORE-DESIGN）**。（07-10 で挙げた二重管理の懸念に対する暫定線）

---

## 📅 2026-07-12 更新ログ

**前回（07-10）から進んだこと — 健康の閉ループが「Web ダッシュボード」で外部化**
- ✅ **健康ダッシュボードの Web 切り出し**（`345f24d`）：`GET /health` で Tailscale 内の任意ブラウザ（iPhone/iPad/他PC）から閲覧できる読み取り専用ビュー（`MobileServer+HealthWeb.swift`）。ネイティブ iOS を待たずに全デバイスから体重/HbA1c 等を見られる**現実的なパリティ手段**。設定画面に QR コードも追加（`c639678`）。
- ✅ **HbA1c 取り込み API**（`fe2a685`）：`POST /api/health/hba1c`、同日重複はスキップ。カードタップで推移詳細（`7dea85d`）。
- ✅ **睡眠時間の毎日推定 → DayRecord＋ブリーフ**（`d247b9b`）：健康コンテキスト還流の一環。
- ✅ **Mac ライフログに日/週/月/年スコープ**（`cf38272`, `MacLifeLogScopeViews.swift` +253）：iOS の HomeDateHelpers に合わせたスコープ切替を Mac 側にも実装（**逆方向のパリティ**）。
- ✅ **信頼性修正**（`b995c28`）：PUT/DELETE ボディの欠落を修正し、Google トークン失効を可視化。
- ✅ **CI**：`HermesShared` を兄弟ディレクトリに clone してからビルド（`cc10f04`）。

**現状メトリクス（2026-07-12）**
- `AppState.swift` **2,214 行**（07-10 の 2,211 とほぼ横ばい）。本体 `@Published` **157**／Sources 全体 **197**（07-10 と同数 = 状態集中の逆行は**止まった**が未反転）。
- `try?` は Sources 全体で **298 箇所**（07-10 の 295 から微増）。
- `TODO/FIXME/HACK` は **3 箇所のみ**（すべてコメント/文字列リテラルで実害なし、07-10 と同じ）。
- テスト：Mac **188 test funcs**（07-10 の 180 から +8。うち **`EventStoreTests` / `WeekSummaryServiceTests` の 2 ファイルは未コミット**）、iOS **46 funcs**（横ばい）。

**今日この場で対応した事項**
- ✅ **未コミットのテストをコミット**：`EventStoreTests.swift` / `WeekSummaryServiceTests.swift`（+ROADMAP更新）を1コミットに。`.agents/`（skills-manager由来のツール群）と`skills-lock.json`はアプリのソースではないため対象外のまま保留（要判断は別途）。
- ✅ **`/health` の URL クエリ鍵漏洩を修正**：`GET /health?key=...`は初回ブートストラップのみに限定し、`handleHealthWebPage`が`Set-Cookie: hermes_health_key=...; HttpOnly; SameSite=Strict`を発行するよう変更（`MobileServer.swift`, `MobileServer+HealthWeb.swift`）。フロントJSは`history.replaceState`でURLからキーを即座に消し、`/api/health/dashboard`はCookie経由（`credentials: "same-origin"`）で認証——Bearerヘッダの手動付与をやめた。`authorize()`に`extractCookie(_:name:)`を追加し定数時間比較で検証。QRコード自体は変更なし（初回スキャンのブートストラップ用途としては妥当）。
- ✅ **`EventStore.cache`の無効化API追加**：`EventStore.invalidate(on:)`を新設し、`PrivateStore.remove()`等でファイルを外部削除した際にactor内cacheが残留する問題（07-10発見）に対処。回帰テスト`testInvalidateClearsStaleCacheAfterExternalFileRemoval`を追加（cache残留の既知動作→invalidate後に正しく空になることの両方を確認）。`EventStoreTests`の`cleanup`ヘルパーもfile削除+cache無効化の両方を行うよう更新。
- ✅ **同期系`try?`を精査** — 結果、心配していた「デコード失敗の握り潰し」パターンは**再現しなかった**：
  - `CloudKitSync.swift`の実デコードは全て`try`（`try?`ではない）で例外が呼び出し元まで伝播し、`AppState+CloudSync.swift`側で`icloudStatus`にユーザー可視のエラー文言として surface 済み。
  - `MobileServer.swift`の83箇所中、大半（22+8+8+...）は**リクエストボディのパース**で、失敗時は`guard...else`から400/500をクライアントへ返しており沈黙していない。ポートフォリオ履歴キャッシュの`try? JSONDecoder().decode(HistCache...)`もキャッシュミス→再取得という正しいフォールバック。
  - 唯一の実質的な穴は`pullRosterOnly()`のcatchが完全無ログだったこと（コメントのみ）→ `Log.failure("cloudsync", "pullRosterOnly", error)`を追加（一時的なオフライン/スロットリングと持続的なデコード異常を区別できるように）。
  - **副産物の発見**：`try? JSONSerialization.jsonObject(with: data) as? [String: Any]`のリクエストボディパースパターンが、既存の`parseBody()`ヘルパーを使わず**21箇所に手書きで重複**している（`MobileServer.swift:908`他）。バグではないが簡素化余地——`parseBody()`への統一は別タスクとして残す（**S、`/simplify`向き**）。
- ✅ **回帰確認**：`run_tests.sh` 189 test funcs 全green（EventStoreTests+1件増）。ビルドは既存警告のみで新規エラーなし。

**今日見つかった懸念（要対応・優先度順）**
- 🟡 **iOS ネイティブ・パリティの方針決定が必要**（唯一の未着手項目・製品判断のため保留）：健康は「Web ダッシュボード」で当面パリティを取れたが、これは**恒久策か暫定策か**が未定。ネイティブ実装に進むなら `HermesShared` の iOS 取り込み（EventStore/DayRecord/振り返り系）が前提。Web 路線で行くなら iOS アプリの位置づけ（薄クライアント→Web ラッパー化）を [personal-ai-direction] に明記（**M〜L**）。ユーザー判断待ち。
- 🟡 **EventStore H2（リーダー切替）本体は依然未着手**：cache無効化APIは追加したが、`upsert`/`tombstone`の二重書きは継続中で読み手は旧経路のまま。差分監視→リーダー切替→旧経路撤去の順で着手が必要（**M**）。
- ⬜ **`parseBody()`未使用の21箇所重複**（今日発見・軽微）：`MobileServer.swift`内の手書き`try? JSONSerialization.jsonObject`を`parseBody()`呼び出しに統一する機械的リファクタ（**S**）。
- ⬜ **`.agents/` / `skills-lock.json`の扱い未決定**：アプリソースではなくツール設定なので今回はコミット対象外としたが、`.gitignore`に載せるか意図的にコミットするか方針化されていない（**S**）。

---

## 📅 2026-07-10 更新ログ

**前回（07-01）から進んだこと — フェーズ1「基盤の信頼性」がほぼ着地**
- ✅ **重複ロジックの一元化（`../HermesShared` 共有パッケージ）**：`WeightMemoParser` / `MacWorkFocus` / `MacActivityEntry` / `MacActivityAggregation` / `MacActivitySummarizer` / `HermesEvent`(+`HermesEventRules`) を Mac 本体から共有パッケージへ移管。**iOS も `project.yml` で `HermesShared` を依存追加**（`f95a24c`）。長年の「両リポにコピー」課題（[duplicated-logic-both-repos]）に構造的な解決線。
- ✅ **CloudKit 移行完了**：Supabase 経路を全撤去（`e4a87b1`）。同期の正は CloudKit のみ。デプロイは `build_signed.sh`。
- ✅ **健康・ライフログの閉ループ**：`WeeklyTrends`（今週7日 vs 先週7日）と `WeightProgress`（7日/30日前比）をデイリーブリーフ文脈へ還流（`59e355c` / `4019a2f`）。
- ✅ **統一イベントストア H1 着地**（`51af5d3`）：`EventStore` actor が `PrivateStore events-<day>`（暗号化）に1日1ファイルで保存。冪等 upsert（LWW＋墓石）、当日フィルタ込みでしか返さない `events(on:)`、`MacActivityLogger.saveToday` / `MacMemoStore` の add/update/delete から**二重書き**。読み手は旧経路のまま（H2 で差分監視後に切替）。
- ✅ **テスト網羅が大幅前進**：Mac **174 test funcs**（07-01 時点 115 → +59）、iOS **46 funcs**（07-01 時点 4 → +42）。`DayTimelineGraphTests` / `MacActivityLoggerTests` / `MacWorkFocusTests` / `MobileServerPeerTests` / `LiveActivityPushPayloadTests` など純粋ロジックの回帰が着実に増加。
- ✅ **信頼性の細かい修正**：アプリ前面デバイスへのプッシュ抑制（`f95a24c`）、アイドル検知で常時起動の待機を作業から除外（`f4be4ef`）、Mac 活動ログの日またぎ汚染修正（`62055e7`）、体重パーサーの助詞対応（`84e87c5`）。

**現状メトリクス（2026-07-10）**
- `AppState.swift` **2,211 行**（07-01 の 3,267 から縮小）。ただし本体 `@Published` は **157**（Sources 全体 **197**）で状態集中は横ばい〜微増。
- `try?` は Sources 全体で **295 箇所**（06-28 の 179 から増加）。
- `Sources/` の `TODO/FIXME/HACK` は 3 箇所のみ（いずれもコメント／文字列リテラルで実害なし）。

**今日この場で対応した事項**
- ✅ **`EventStoreTests.swift` を新設**（`Tests/`、6 funcs）：`HermesEventRules` 自体は `../HermesShared/Tests/HermesSharedTests/HermesEventTests.swift` に既存（merge/tombstone/normalized/dayKey は当初の懸念と異なりテスト済みだった）。未カバーだったのは actor `EventStore` 本体（`PrivateStore` 経由の暗号化ラウンドトリップ・冪等 upsert・`tombstone` 後の `events(on:)` 除外と `rawCount` 残存・日付跨ぎの隔離・`MacActivityLogger`/`MacMemoStore` からの二重書き変換）。テスト実装中に **actor の `cache` が `PrivateStore.remove()` では invalidate されない**（テスト分離のため隣接日付を使うと汚染する）ことを実発見。全 180 funcs green（`run_tests.sh`）。

**今日見つかった懸念（要対応・優先度順）**
- 🟡 **`EventStore.cache` はプロセス生存中クリアされない**：`PrivateStore.remove(key:)` は暗号化ファイルを消すだけで actor 内 `cache` dict は残留する。テストは日付を分離することで回避したが、**長時間起動したアプリで同日のデータを外部から削除/移行した場合にも同じ理由で古いキャッシュが残る**可能性がある。実害はまだ未確認だが、H2 着手時に cache 無効化 API の要否を検討（**S**）。
- 🟠 **状態集中の逆行が止まらない**：本体行数は縮小したが `@Published` 157。EventStore/lifelog/MacActivity 系の新状態が本体直書きの疑い。`AppState+Lifelog`（または `+Events`）extension への隔離で再描画範囲を絞る（**M**）。
- 🟡 **`try?` の精査が同期系で未完（295 箇所）**：永続化系は surface 化済みだが、CloudKit 移行で増えた同期経路と MobileServer レスポンス系の沈黙失敗は未点検。移行直後こそデコード失敗が名簿全消え（[codable-persisted-fields-rule]）に直結するため、CloudKit デコードの `try?` を優先精査（**M**）。
- 🟡 **ロードマップが二重管理**：本ファイル（root、6観点監査版）と `docs/ROADMAP.md`（認知拡張ビジョン＋`EVENT-STORE-DESIGN.md`）が併存し、進捗表現が乖離。[roadmap-event-store] は「docs が正」とするが、日次ログは root に付いている。→ **役割分担を両ファイル冒頭に明記**（root＝技術負債/監査、docs＝プロダクト方向）か一本化（**S**）。
- 🟡 **iOS パリティ**：`HermesShared` 依存は追加したが iOS Source 側は未 import で、EventStore/DayRecord/振り返りコーチ系は依然 Mac 先行。共有ロジックの iOS 取り込みと新機能の閲覧 UI が次の差分（**M〜L**）。

---

## 📅 2026-07-01 更新ログ

**`cursor/phase-0-hardening` ブランチ（Phase 0 追補）**
- ✅ **MobileServer Tailscale ウォッチドッグ** — 90秒ごとに `tailscale ip -4` を再確認し、IP 出現/変更時にリスナー再バインド
- ✅ **LINE 401 自己回復** — cron の LINE 401 検知時にブリッジをデバウンス再起動（既存 3 分ウォッチドッグ + `FailedDeliveryStore` と併用）
- ✅ **デッドレター再試行 UI** — オートメーション「最近の配信失敗」から `hermes cron run` 再送
- ✅ **HermesCLI ラッパー** — `exec` timeout + `execWithRetry`（指数バックオフ）を cron list/run に適用

**`cursor/intention-cards` ブランチで完了（Phase H）**
- ✅ **Collection**：Mac `CollectionStore` + Mobile API + UI、iOS 閲覧（`CollectionView`）
- ✅ **Home カレンダースコープ**：iOS `HomeView` に 日/週/月/年 切替（`HomeDateHelpers`）
- ✅ **Mac アクティビティ要約**：iOS タイムラインに `MacActivitySummarizer` 集約表示
- ✅ **CONCEPT**：creativity + serendipity ピラーを `CONCEPT.md` に追記
- ✅ **Serendipity**：`SerendipityEngine` + `IntentionCard.rationale` + 週次レビュー serendipity セクション
- ✅ **Home UI**：iOS タイムラインを `DisclosureGroup` で折りたたみ

**`cursor/intention-cards` ブランチで完了（Phase G）**
- ✅ **G1**：`AppState+ChatSend.swift` — 送信・セッション選択・添付・フィードバック（`handleSendMessage` 等）を本体から分離。`@Published` は本体 `// MARK: - Chat` に残置
- ✅ **G2**：`AppState+CloudSync.swift` — Supabase / iCloud roster・メッセージミラー・ライブ同期を分離。`@Published` は本体 `// MARK: - Cloud sync` に残置
- ✅ **G3**：push-to-start トークン scaffold — iOS `Activity.pushToStartTokenUpdates`（17.2+）→ `POST /api/push/live-activity-start-token`、Mac `liveActivityStartTokens`（cap 3）・`APNsSender.sendLiveActivityStart`（`aps.event = start`）、proactive 時に update トークンが無ければ start push
- ✅ **G4**：設定「接続」セクション — ローカル URL・Tailscale IPv4（best-effort）・公衆 IP 拒否の注記
- Mac 本体 `AppState.swift` 大幅縮小、Mac テスト +1 suite、iOS テスト +2 funcs

**`cursor/intention-cards` ブランチで完了（Phase F）**
- ✅ **F1**：ActivityKit push scaffold — iOS `pushType: .token` + `pushTokenUpdates` → Mac `/api/push/live-activity-token`、Mac `APNsSender.sendLiveActivityUpdate`（`apns-push-type: liveactivity`）、proactive 時に Dynamic Island 更新
- ✅ **F2**：`empMessages` メモリ上限（`maxShadowEmployeeKeys = 12`）+ LRU プルーニング（`pruneEmpMessageShadows`）
- ✅ **F3**：`NetworkPeerPolicy` 抽出 + `MobileServerPeerTests`（loopback / Tailscale / LAN / public 分類）
- Mac テスト +8 funcs（`EmpMessagePruneTests` +4、`MobileServerPeerTests` +4）

**`cursor/intention-cards` ブランチで完了**
- ✅ **B3/B4**：意図カード（Intention）Mac/iOS パリティ＋ウィジェット連携
- ✅ **C**：高機微 PII の PrivateStore 暗号化（`locationDaily` / `photoDaily` / `lifelogDaily` 等）
- ✅ **D1**：`dailyBrief` / `weeklyReview` を `briefDaily` / `weeklyReviewDaily` へ暗号化移行（UserDefaults → PrivateStore、起動時マイグレーション）
- ✅ **D2**：cron `lastError` を Mobile API JSON に追加、iOS オートメーション行にオレンジ表示
- ✅ **D3**：iOS `HermesAgentLogicTests` ターゲット＋CI `xcodebuild test`（JSON デコード回帰）
- ✅ **E1**：`AppState+Automation` へ cron 管理ロジック分離、`HermesCronJobParser` 抽出＋テスト
- ✅ **E2**：配信失敗デッドレターキュー（`FailedDeliveryStore`・暗号化永続化・オートメーション UI）
- ✅ **E3**：`MacLifeLogView` にライフログ記録インジケータ（記録中 / 記録オフ）
- Mac テスト 115 funcs（+8）、iOS テスト 4 funcs 新設、両リポ CI green

---

## 📅 2026-06-30 更新ログ（夕方・第2回）

**前回（本日午前の記載）から進んだこと**
- ✅ **巨大な未コミット差分が解消**：午前に懸念していた「未コミットの +1,655 行」は `03d7884 feat: lifelog/news/task improvements + Chrome tab tracking` としてコミット済み。ワーキングツリーは clean。
- ✅ **パストラバーサル境界を修正**（午前の 🟡 を解消）：`/api/employees/{id}/file` の許可判定を「`..`/`.` 除去 → symlink 解決 → 末尾 `/` 付き接頭辞 or 完全一致」に強化（`MobileServer.swift:1622-1634`）。兄弟ディレクトリ（`<ws>-evil`）の漏れを塞いだ。
- ✅ **PersonalAI ドメインを extension へ一部隔離**：`AppState+PersonalAI.swift`（321 行・`lifelogSummary` 生成/30分ステール判定、`dailyBriefContext` への iOS データ混合）を新設。
- ✅ **新機能群が着地**：`MacActivityLogger`（Chrome/Safari/Arc の現在タブURLを AXUIElement で8秒ポーリング記録）、`MacLifeLogView`（iOS健康/位置/写真×Macアクティビティ混合＋AI要約＋自宅登録）、`MacNewsView`（30日スパークライン）、`TasksView` 詳細シート編集、`MacMemoStore`/`SelfGraph`/`ChartBlockView` 追加。

**今日見つかった懸念（要対応・優先度順）**
- 🔴 **PII の at-rest 暗号化（残課題）**：`PrivateStore` + Keychain ラップ鍵で `locationPoints` / `personalProfile` / `selfModel` / `photoDaily` 等は **暗号化済み**（`saveJSON` → `~/.hermes/private/*.enc`）。起動時に `migrateLegacyUserDefaults()` で UserDefaults 残存分を一括移行。ただし **MacActivityLogger の閲覧URL履歴**など暗号化対象外の新規データは引き続き要検討。
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
- 🟠 **プライバシー（保存時暗号化）**：`PrivateStoreKeys` 経由の高機微 PII（位置・写真要約・プロフィール・自己モデル等）は **暗号化ファイルに移行済み**。残りは MacActivityLogger の URL 履歴など未暗号化ストアの方針決定。
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
| Sec | ローカルAPIキー・Google client secret を Keychain へ（後述の注意あり） | ✅ Google client secret は Keychain（起動時 UD マイグレーション）。API キーは `.env` 方針維持 |
| Sec | MobileServer の CORS を `*` からホワイトリスト化 | ✅ 完了（Origin 検証・deny 既定） |
| Sec | バインドを loopback/Tailscale 限定に（iOS接続への影響を要設計） | ✅ loopback + Tailscale IPv4。90秒ウォッチドッグで IP 変化時に再バインド |
| Sec | `UpdateManager` の `zsh -lc` を Process配列実行へ（シェル注入対策） | ✅ 完了（値を位置パラメータ化） |
| Rel | LINE配信の自己回復（`/health`＋トークン失効検知＋再送デッドレターキュー） | ✅ 401 検知→ブリッジ再起動、デッドレター UI から手動再試行、`hermes cron run` に timeout+バックオフ |
| Rel | 外部スクリプト（stock/gmail）をラッパー化（timeout＋指数バックオフ＋結果記録） | 🟡 `HermesCLI.execWithRetry` + list timeout（cron 経由の script 実行に適用） |
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
