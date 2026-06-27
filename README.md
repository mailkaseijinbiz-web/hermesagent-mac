# HermesAgent (Mac)

**AI社員（エージェント）を「会社」として雇い、チャット・タスク・定期自動実行（オートメーション）で働かせる macOS ハブアプリ。**

macOS ネイティブ（SwiftUI）アプリ `HermesCustom` が **ハブ** として動作し、ローカルの Hermes エージェント CLI を駆動します。iPhone / iPad の薄いクライアント（[hermesagent-ios](https://github.com/mailkaseijinbiz-web/hermesagent-ios)）は Tailscale 経由でこの Mac ハブに接続し、同じデータ・同じ機能をミラーします。

---

## 目次
- [概要](#概要)
- [アーキテクチャ](#アーキテクチャ)
- [主な機能](#主な機能)
- [技術スタック](#技術スタック)
- [必要要件](#必要要件)
- [ビルドと実行](#ビルドと実行)
- [設定（シークレット / 連携）](#設定シークレット--連携)
- [株モニタリングの仕組み](#株モニタリングの仕組み)
- [ディレクトリ構成](#ディレクトリ構成)
- [データと同期](#データと同期)
- [関連リポジトリ](#関連リポジトリ)
- [セキュリティ / 注意点](#セキュリティ--注意点)

---

## 概要

HermesAgent は、役割（マネージャー / エンジニア / リサーチャー / ライター / デザイナー / アナリスト / レビュアー / アシスタント）を持つ **AI 社員** を採用し、社員ごとに分離された会話コンテキストでやり取りしながら、タスク管理や定期的な自動実行までを 1 つのアプリで回すためのデスクトップ環境です。

- **マルチバックエンド**：チャットの実行系を `AgentBackend` で抽象化し、Hermes CLI / ACP / Antigravity(`agy`) を切り替え可能。
- **ハブ&スポーク**：Mac がハブ。iOS/iPad は Mac ハブの `/api/*` をプロキシ経由で叩く薄型クライアント（端末側に Google API キー等は置かない）。
- **自動化**：`hermes cron` によるスケジュール実行で、社員に定期タスクを任せ、結果を LINE などへ配信。

---

## アーキテクチャ

```
                          ┌───────────────────────────────────────────┐
                          │  Mac（ハブ） — HermesCustom.app            │
  iPhone / iPad           │                                           │
  (薄いクライアント)       │  ┌──────────────┐   ┌────────────────────┐ │
   hermesagent-ios ──Tailscale──▶ MobileServer │──▶│ AppState（状態/ロジック）│ │
                          │  │   :9119 /api  │   │ AgentBackend ルーター    │ │
                          │  └──────────────┘   │  Hermes / ACP / agy      │ │
                          │                     └──────────┬─────────────┘ │
                          │  LineBridge :8650              │ shell 実行      │
                          │  (LINE 送受信)                  ▼                │
                          │                     ┌────────────────────┐     │
                          │                     │  hermes CLI         │     │
                          │                     │  cron / gateway /   │     │
                          │                     │  state.db / config  │     │
                          │                     └────────────────────┘     │
                          └───────────────────────────────────────────┘
```

- **MobileServer (:9119)**：iOS/iPad 向けの API。Google サインインでアクセスを制限。
- **HermesCLI**：`hermes` をサブプロセス起動（`@MainActor` で同期実行するとUIが固まるため、ストリーミングは `Task.detached` + ドレイン後 wait + ウォッチドッグで実装）。
- **LineBridge (:8650)**：`~/.hermes/line-bridge/bridge.py` をアプリが自動起動・監視。LINE の受信（Webhook）と送信（`line-send.sh`）を仲介。
- **gateway**：`hermes gateway`（Telegram/LINE/API サーバ等のメッセージング常駐）。`hermes cron` のジョブもこの gateway が発火。

---

## 主な機能

| 機能 | 説明 |
|---|---|
| 🏢 **会社（AI社員）** | 役割つきの AI 社員を採用。社員ごとに会話コンテキスト・成果物・ファイルを分離管理。 |
| 💬 **チャット** | Markdown / テーブル描画、画像添付、ツール実行の可視化、思考（reasoning）表示。バックエンドは Hermes / ACP / Antigravity から選択。 |
| ✅ **タスクボード** | 未着手 / 対応中 / 完了 のカンバン。**カードをドラッグ&ドロップで移動・並べ替え**。⋯メニューから**タイトル編集**・**締め切り期限**設定（期限切れは赤チップ表示）。 |
| ⏰ **オートメーション** | `hermes cron` のジョブを GUI で作成・一時停止・削除・**テスト送信（今すぐ実行）**。担当社員・スケジュール・配信先（ドロップダウン: ローカル / 送信元 / 登録チャンネル）・スクリプトを指定。 |
| 📈 **株モニタリング** | 保有銘柄の株価（Twelve Data）と関連ニュース（Google News RSS）を証券アナリストが定期チェックし、要点を **LINE 通知**。→ [仕組み](#株モニタリングの仕組み) |
| 📊 **ダッシュボード** | デイリーブリーフなどの俯瞰。 |
| 🛠 **アプリ** | 社員が生成したアプリ/成果物のプレビュー。 |
| 🔌 **モデル/プロバイダー設定** | プロバイダー・モデルの切替（OpenRouter / Nous / Cerebras(custom) / Gemini CLI など）。 |
| ☁️ **iCloud 同期** | CloudKit で社員・チーム・タスク等を端末間同期。 |
| ⚡️ **コマンドパレット (⌘K)** | クイック移動。 |
| 🔄 **自動アップデート** | ビルドコミットを記録し、リモートと比較して更新。 |

> サイドバーのナビは用途に応じて整理されています（ダッシュボード / 新しいチャット / 会社 / タスク / アプリ / オートメーション）。Gmail・Google カレンダー連携などの統合コードも同梱しています。

---

## 技術スタック

- **言語/UI**：Swift 5 言語モード、SwiftUI（macOS 14+）
- **ビルド**：Swift Package Manager（`swift build`）＋ XcodeGen（署名ビルド用 `project.yml`）
- **永続化**：SQLite（`StateDB`, `libsqlite3` 直リンク）＋ JSON ストア（UserDefaults / ファイル）＋ CloudKit
- **外部プロセス**：`hermes`（エージェント本体）, `git` / `gh`, `agy`（Antigravity）, Python（ブリッジ/スクリプト）
- **非サンドボックス**：ローカルサーバ起動・サブプロセス実行・`~/.hermes` 参照のため App Sandbox は無効

---

## 必要要件

- **macOS 14.0+**
- **Xcode / Xcode-beta**（署名ビルド・iOS クライアント配備に使用）
- **`hermes` CLI**（`~/.local/bin/hermes`）— エージェント本体。チャット・cron・gateway を提供
- **Tailscale**（iOS/iPad クライアントから Mac ハブへ到達するため）
- 任意のシークレット類（[設定](#設定シークレット--連携)）

---

## ビルドと実行

### 開発ビルド（SPM）
```bash
# 型チェック/デバッグビルド
swift build

# .app バンドルを作成（release/HermesCustom.app）
./build_app.sh
open release/HermesCustom.app
```

`build_app.sh` は `swift build -c release` 後にバンドル化し、`Info.plist`・アプリアイコンを配置、ビルドコミット/ブランチを `release/.build-commit` 等に記録します（アプリ内アップデータが参照）。

### 署名ビルド（CloudKit 等を使う配布用）
```bash
# XcodeGen でプロジェクト生成 → Xcode-beta で署名ビルド
./build_signed.sh
```
> CloudKit のコンテナ署名はユーザーの Terminal から実行する必要があります（`project.yml` の `DEVELOPMENT_TEAM` を参照）。

### iOS / iPad クライアント
[hermesagent-ios](https://github.com/mailkaseijinbiz-web/hermesagent-ios) を XcodeGen + Xcode-beta + `devicectl` で実機へ配備します。

---

## 設定（シークレット / 連携）

シークレットは**リポジトリには含めず**、すべて `~/.hermes/` 配下（端末ローカル）に置きます。

| 場所 | 用途 |
|---|---|
| `~/.hermes/.env` | `LINE_CHANNEL_ACCESS_TOKEN`（gatewayの`hermes cron --deliver line:`が使用）, `TWELVEDATA_API_KEY` ほか |
| `~/.hermes/config.yaml` | Hermes 本体設定（`platforms.line.allowed_users` 等） |
| `~/.hermes/line-bridge/.env` | ブリッジ用 LINE トークン（`line-send.sh` が使用） |
| `~/.hermes/channel_directory.json` | 登録済み配信先（telegram / line など）。配信先ドロップダウンのソース |
| `~/.hermes/scripts/portfolio.txt` | 株モニタリングの保有銘柄リスト |

> **LINE トークンの注意**：送信経路が 2 つあり（ブリッジ用 `line-bridge/.env` と gateway 用 `.env`）、トークンが食い違うと cron 配信が `401` で失敗します。`GET https://api.line.me/v2/bot/info`（Bearer）で有効性を確認し、揃えたら `hermes gateway restart` で反映してください。

---

## 株モニタリングの仕組み

```
[平日の定時]  hermes cron
   └─ stock-monitor.py: 保有銘柄の株価(Twelve Data) + 関連ニュース(Google News RSS) を収集
        └─ 出力を 証券アナリスト(LLM) のプロンプトに注入（--script）
             └─ 重要な変動/ニュースを要約
                  └─ LINE(--deliver line:<chat_id>) に通知
```

- **株価**：`Twelve Data`（無料登録キー・日本株/米国株対応）。Yahoo Finance / Stooq は headless では bot 遮断されるため採用していません。
- **ニュース**：`Google News RSS`（鍵不要）。**キー未設定でもニュース監視は動作**します。
- 取得スクリプト `stock-monitor.py` は標準ライブラリのみ・全体タイムアウトつき（cron ハング防止）。アプリの「オートメーション → 株モニタリング」カードから保有銘柄・APIキーを編集し、ワンクリックで cron を作成できます。

---

## ディレクトリ構成

```
Sources/
├─ Models/         # 状態・ロジック・外部連携
│  ├─ AppState.swift          # 中核の ObservableObject（全機能のロジック集約）
│  ├─ AgentBackend.swift      # チャット実行系の抽象化（Hermes/ACP/agy）+ BackendRouter
│  ├─ HermesCLI.swift         # hermes サブプロセスの起動/ストリーミング
│  ├─ ACPClient.swift / AntigravityCLI.swift / AgyStore.swift
│  ├─ MobileServer.swift      # iOS/iPad 向け API (:9119)
│  ├─ LineBridge.swift        # LINE ブリッジ(:8650) の自動起動/監視
│  ├─ CloudKitSync.swift      # iCloud 同期
│  ├─ GoogleOAuth / GmailSync / GoogleCalendarSync / GoogleTokenVerifier
│  ├─ StateDB.swift           # SQLite セッションストア
│  ├─ APNsSender.swift / UpdateManager.swift など
│  └─ Employee.swift          # 社員・タスク・成果物などのモデル
└─ Views/          # SwiftUI 画面
   ├─ MainView / SidebarView / ChatView / CompanyView
   ├─ TasksView（カンバン）/ AutomationsView（cron+株モニタリング）
   ├─ DashboardView / AppsView / SettingsView / ModelPickerView
   └─ EmployeeDetailView / CommandPaletteView ほか

project.yml          # XcodeGen 定義（署名ビルド）
Package.swift        # SPM 定義
build_app.sh         # 開発バンドル作成
build_signed.sh      # 署名ビルド
```

---

## データと同期

- **セッション**：`~/.hermes/state.db`（SQLite）。`source`（cron/line/slack…）で自動実行結果を区別。
- **アプリ状態**：社員・チーム・タスク（`workTasks`）等は JSON 永続化（`@Published` の `didSet` で保存＋iCloud プッシュ）。
- **iCloud/CloudKit**：id と `updatedAt` でマージ。**並び順や絶対パスはデバイスローカル**（端末ごとに再導出。`workspacePath` や `.file` 成果物などは同期時に再解決）。

---

## 関連リポジトリ

- **iOS / iPad クライアント**：[mailkaseijinbiz-web/hermesagent-ios](https://github.com/mailkaseijinbiz-web/hermesagent-ios) — Mac ハブの `/api/*` をプロキシする薄型クライアント。

---

## セキュリティ / 注意点

- **シークレットはリポジトリに含めない**：LINE トークン・各種 API キー・取得スクリプトはすべて `~/.hermes/` 配下。公開リポジトリにコミットしないでください。
- **非サンドボックス動作**：`git`/`gh`/`hermes` 等のサブプロセス起動、ローカルサーバ、`~/.hermes` 参照を行うため App Sandbox は無効です。
- **外部送信**：オートメーションは LINE などへ実際にメッセージを送信します。テストは GUI の「テスト送信」から、宛先を確認のうえ実行してください。

---

*Bundle: `com.custom.hermesmac` / Product: `HermesCustom`*
