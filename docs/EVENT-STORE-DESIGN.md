# 統一イベントストア設計（フェーズ2の本丸）

状態: 設計のみ（2026-07-03）。実装は次セッションから。

## 問題

「今日なにがあったか」が7つの保存場所に散在し、タイムライン・ブリーフ・DayRecord・振り返りがそれぞれ別ルートで読む。日またぎ汚染・未来時刻・当日フィルタ漏れ系のバグはすべて「読み手ごとに集約規則を再実装している」ことが根因。

| ソース | 置き場所 | 書き手 |
|---|---|---|
| Macアプリ作業 | PrivateStore `mac-activity-<day>` | MacActivityLogger |
| Hermesセッション | 同上（kind=hermes） | recordHermesSession |
| メモ/体重/リンク | MacMemoStore（＋iOS LifeLogStore） | 両OS |
| 訪問/移動 | DayRecordStore visits ＋ iOS VisitStore | iOS→push |
| 写真 | iOS PhotoLogStore＋photoSummary push | iOS |
| 睡眠 | HubSleepRecord ＋「寝た/起きた」メモ | iOS/両OS |
| 健康数値 | AppState.dailyHistory（60日） | iOS→push |

## 設計

### スキーマ（HermesSharedに追加）

```swift
public struct HermesEvent: Codable, Identifiable, Sendable {
    public var id: String          // 冪等キー。source固有IDを埋め込む（例 "mac:<entryId>"）
    public var kind: String        // mac | hermes | memo | weight | visit | move | photo | sleep | screenshot
    public var start: Double       // epoch秒
    public var end: Double?        // 区間イベントのみ
    public var title: String       // 表示一行目（表示専用文言は持たない。導出はレンダラ）
    public var detail: String?
    public var source: String      // "mac" | "ios"
    public var payload: [String: String]?  // kind固有の小さな属性（url, kg, place等）
    public var updatedAt: Double   // last-write-wins
    public var deleted: Bool?      // 墓石
}
```

- 保存: Mac ハブの PrivateStore `events-<yyyy-MM-dd>`（1日1ファイル、暗号化は現行踏襲）
- 書き込みAPI: `EventStore.append(_:)` / `upsert(_:)`。**日付キーはstartから導出**（日またぎ汚染の構造的根絶）
- 読み出しAPI: `EventStore.events(on: Date)` は当日フィルタ込みでしか返さない（フィルタ漏れを型で防ぐ）
- iOS: 既存の `/api/*` を `GET/POST /api/events?date=` に集約。iOSローカル発生イベント（メモ・写真・訪問）はpush、表示はfetch

### 移行手順（各段階で旧経路と並走→検証→切替）

1. **H1 二重書き**: MacActivityLogger と MacMemoStore が既存保存に加え EventStore にも書く。読み手は旧のまま
2. **H2 読み手切替（Mac）**: DayTimelineGraph / DayRecordBuilder / brief文脈 を EventStore 読みに切替。旧読みと件数差分をログで1週間監視
3. **H3 iOS切替**: /api/events 提供、iOS LifeLogStore のタイムライン合成を events ベースに。visit/photo push も events 化
4. **H4 旧経路撤去**: 二重書き停止、旧キャッシュ読みを削除（Supabase撤去と同じ要領）

### 不変条件（テストで固定する）

- `events(on: d)` の全要素は `startOfDay(d) <= start < +86400`
- 同一idのupsertは updatedAt が新しい方が勝つ／deleted=true が最優先
- 「寝た/起きた」睡眠ウィンドウの畳み込みは events 上の純関数（既存 applySleepWindow を移植）
- 集約規則（5種超→1枚）は MacActivityAggregation を events 経由でも再利用

### やらないこと

- 汎用イベントバス化・リアルタイム購読（YAGNI。1日1ファイルのpull で足りる）
- 過去データの一括変換（H2以降、読んだ日にオンデマンド変換で十分）
