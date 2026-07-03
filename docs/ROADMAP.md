# HermesAgent 長期改善ロードマップ

原則: **信頼できるデータ → 意味のある洞察 → 先回りする提案** の順にしか積み上がらない。

## フェーズ1: 基盤の信頼性（2026-07-03 完了）

- [x] 重複ロジックの一元化 — `../HermesShared` 共有パッケージ（WeightMemoParser / MacWorkFocus / MacActivityEntry / MacActivityAggregation / MacActivitySummarizer）
- [x] 純粋ロジックのテスト整備 — 共有17件＋Mac側10件。導入初日に実バグ2件検出（コロン体重表記の取りこぼし、`kg?`正規表現）
- [x] CloudKit移行の完了 — Supabase経路全撤去。同期の正はCloudKitのみ。**デプロイは`build_signed.sh`**（`build_app.sh`はiCloudエンタイトルメント無し）
- [x] ディスク清掃自動化 — LaunchAgent `com.hermes.disk-cleanup` 毎日04:15、空き25GB未満時のみ発動

## フェーズ2: データ統合と洞察の質（進行中）

- [x] 週次傾向の還流 — `WeeklyTrends`（今週7日vs先週7日: 睡眠/Mac作業/歩数/気分）をブリーフ文脈へ
- [x] 体重進捗の閉ループ — `WeightProgress`（7日前比・30日前比）をブリーフ文脈へ
- [ ] **統一イベントストア** — 設計は [EVENT-STORE-DESIGN.md](EVENT-STORE-DESIGN.md)。次セッションはここから
- [ ] SelfGraphの育成 — 「つながり」セクションが本人の履歴を引用するレベルへ
- [ ] 振り返り回答の傾向可視化（睡眠×作業×気分の相関）

## フェーズ3: 先回りする参謀（3〜6ヶ月）

- [ ] 文脈トリガーの提案（サウナ0回の金曜夜 / 睡眠不足3日連続→予定警告）
- [ ] Gmail→タスクの拡張（返信下書き・期日推定・カレンダー連携）
- [ ] 振り返りの対話化（一問一答→追い質問）
- [ ] 通知の質の自己評価

## フェーズ4: 認知拡張（6〜12ヶ月）

- [ ] 人生履歴RAG（「去年の今頃何してた？」に答える）
- [ ] プライバシー階層（外部モデルに出すデータの明示的線引き）
- [ ] Apple Watch / ウィジェット拡充

## 運用メモ

- 重複ロジックを新設しない。純粋ロジックは HermesShared へ、テスト付きで
- 共有パッケージのテスト: `DEVELOPER_DIR=<Xcode-beta> swift test --scratch-path /tmp/hermes-shared-build`（iCloud下ではCodeSignが壊れる）
- Mac側テスト: 同様に `--scratch-path /tmp/hermes-mac-tests`
