# HermesAgent 改善ロードマップ

両リポジトリ（[hermesagent-mac](https://github.com/mailkaseijinbiz-web/hermesagent-mac) / [hermesagent-ios](https://github.com/mailkaseijinbiz-web/hermesagent-ios)）を **6観点（アーキテクチャ / セキュリティ / コード品質 / 信頼性 / テスト&CI / プロダクト）** で監査した結果に基づく、優先度つきの長期計画。

## 現状評価
**強み**：`AgentBackend` 抽象化（Hermes/ACP/agy を統一・テスト可能）、社員ごとの並列実行（プロセス/ACP分離）、ステートレスな MobileServer、読み書き分離の永続化（read-only SQLite + WAL）、cron 自動化の完成度（株モニタ・Gmail→タスクの E2E 実証）。

**核心課題**：
1. 公開リポジトリ化に伴うセキュリティ露出
2. 自動化スタックの障害回復力（実際に LINE 401 障害が発生）
3. `AppState` が 5,041 行・122 `@Published` の神オブジェクト
4. テスト網羅率が低い（Mac 約2.6% / iOS 0%）※ただし CI 自体は正常稼働中
5. 単一ハブ依存（iOS はオフライン不可）

---

## 🔴 フェーズ0 — 今すぐ（0–4週）｜固める

| テーマ | 項目 | 状態 |
|---|---|---|
| Test | ローカル `swift test` を通す（`run_tests.sh`：フルXcode + xattrクリア） | ✅ 完了 |
| Sec | `~/.hermes/.env` を 0600 に / `.gitignore` で秘密ファイルを防御的除外 | ✅ 確認・強化 |
| Sec | ローカルAPIキー・Google client secret を Keychain へ（後述の注意あり） | ⬜ |
| Sec | MobileServer の CORS を `*` からホワイトリスト化 | ⬜ |
| Sec | バインドを loopback/Tailscale 限定に（iOS接続への影響を要設計） | ⬜ |
| Sec | `UpdateManager` の `zsh -lc` を Process配列実行へ（シェル注入対策） | ⬜ |
| Rel | LINE配信の自己回復（`/health`＋トークン失効検知＋再送デッドレターキュー） | ⬜ |
| Rel | 外部スクリプト（stock/gmail）をラッパー化（timeout＋指数バックオフ＋結果記録） | ⬜ |
| QA | 開発者個人ID（APNs `576D2UUHH5`／bundle）を空デフォルト＋設定プロンプト化 | ⬜ |
| Prod | 撤去済みの News/Gmail/Schedule/OutputModeViews を削除（dead code整理） | ⬜ |

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
