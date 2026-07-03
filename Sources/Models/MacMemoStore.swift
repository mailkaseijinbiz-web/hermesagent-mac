import HermesShared
import Foundation

struct MacMemo: Codable, Identifiable, Equatable {
    var id: String   = UUID().uuidString
    var text: String
    var time: Date
    var editedAt: Date? = nil
    /// 添付画像のファイル名（`MacMemoStore.imageDir` 配下）。Optional：既存の保存データと互換。
    var imagePaths: [String]? = nil
    /// 取り込み元（例: "share" = iOS 共有シート, "web" = URL 共有）。Optional：手書きメモは nil。
    var source: String? = nil
    /// 共有 URL（Web ページ等）。
    var link: String? = nil
    var pageTitle: String? = nil
    /// url | image | video | text
    var mediaKind: String? = nil

    var hasImages: Bool { !(imagePaths ?? []).isEmpty }
}

@MainActor
final class MacMemoStore: ObservableObject {
    static let shared = MacMemoStore()
    @Published var todayMemos: [MacMemo] = []
    private let legacyKey = "macLifeLogMemos"
    private let legacyDateKey = "macLifeLogMemosDate"
    private var loadedDayKey = ""

    init() {
        migrateLegacyUserDefaultsIfNeeded()
        reloadTodayIfNeeded()
    }

    /// 添付画像の保存先（`~/.hermes/memo-images/`）。
    static var imageDir: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/memo-images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var memoArchiveDir: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/memo-by-day")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func storedMemoDayKeys() -> [String] {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/memo-by-day")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            return String(name.dropLast(5))
        }
    }

    /// 保存済み添付画像の絶対 URL を返す（UI 表示・配信用）。
    static func imageURL(_ filename: String) -> URL { imageDir.appendingPathComponent(filename) }

    func memos(for date: Date) -> [MacMemo] {
        if LifeLogDay.isToday(date) {
            reloadTodayIfNeeded()
            return todayMemos
        }
        return loadMemosFromDisk(for: date)
    }

    /// 日付が変わったら今日のメモファイルを読み直す。
    func reloadTodayIfNeeded() {
        let today = LifeLogDay.key(Date())
        guard loadedDayKey != today else { return }
        loadedDayKey = today
        todayMemos = loadMemosFromDisk(for: Date())
    }

    /// テキストメモを追加。`images` を渡すと `~/.hermes/memo-images/` に書き出して紐付ける。
    @discardableResult
    func addMemo(
        _ text: String,
        images: [Data] = [],
        source: String? = nil,
        at time: Date = Date(),
        link: String? = nil,
        pageTitle: String? = nil,
        mediaKind: String? = nil
    ) -> MacMemo {
        reloadTodayIfNeeded()
        if let link, !link.isEmpty,
           let existing = todayMemos.first(where: { $0.link == link && Calendar.current.isDate($0.time, inSameDayAs: time) }) {
            return existing
        }
        var memo = MacMemo(text: text, time: time, source: source, link: link, pageTitle: pageTitle, mediaKind: mediaKind)
        if !images.isEmpty {
            var names: [String] = []
            for (i, data) in images.enumerated() {
                let name = "\(memo.id)-\(i).jpg"
                do {
                    try data.write(to: Self.imageURL(name))
                    names.append(name)
                } catch {
                    Log.failure("app", "メモ画像の保存に失敗 (\(name))", error)
                }
            }
            if !names.isEmpty { memo.imagePaths = names }
        }
        todayMemos.append(memo)
        saveToday()
        let ev = HermesEvent.from(memo)
        Task { await EventStore.shared.upsert([ev]) }
        if let kg = WeightMemoParser.parse(text) {
            AppState.shared.recordWeightFromMemo(kg: kg, at: time, memoId: memo.id, source: "memo")
        }
        return memo
    }

    func updateMemo(id: String, text: String) {
        reloadTodayIfNeeded()
        guard let i = todayMemos.firstIndex(where: { $0.id == id }) else { return }
        todayMemos[i].text = text
        todayMemos[i].editedAt = Date()
        saveToday()
        let ev = HermesEvent.from(todayMemos[i])
        Task { await EventStore.shared.upsert([ev]) }
        if let kg = WeightMemoParser.parse(text) {
            AppState.shared.recordWeightFromMemo(kg: kg, at: todayMemos[i].time, memoId: id, source: "memo")
        }
    }

    func deleteMemo(id: String) {
        reloadTodayIfNeeded()
        if let m = todayMemos.first(where: { $0.id == id }) {
            for name in m.imagePaths ?? [] {
                try? FileManager.default.removeItem(at: Self.imageURL(name))
            }
        }
        if let m = todayMemos.first(where: { $0.id == id }) {
            let ts = m.time.timeIntervalSince1970
            Task { await EventStore.shared.tombstone(id: "memo:\(id)", start: ts) }
        }
        todayMemos.removeAll { $0.id == id }
        saveToday()
    }

    private func memoFileURL(for date: Date) -> URL {
        Self.memoArchiveDir.appendingPathComponent("\(LifeLogDay.key(date)).json")
    }

    private func loadMemosFromDisk(for date: Date) -> [MacMemo] {
        let url = memoFileURL(for: date)
        guard let data = try? Data(contentsOf: url),
              let memos = try? JSONDecoder().decode([MacMemo].self, from: data) else { return [] }
        return memos
    }

    private func saveMemosToDisk(_ memos: [MacMemo], for date: Date) {
        let url = memoFileURL(for: date)
        do {
            let data = try JSONEncoder().encode(memos)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.failure("app", "メモの保存に失敗 (\(LifeLogDay.key(date)))", error)
        }
    }

    private func saveToday() {
        saveMemosToDisk(todayMemos, for: Date())
    }

    private func migrateLegacyUserDefaultsIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let memos = try? JSONDecoder().decode([MacMemo].self, from: data),
              !memos.isEmpty else { return }
        let dateStr = UserDefaults.standard.string(forKey: legacyDateKey) ?? LifeLogDay.key(Date())
        if let d = LifeLogDay.date(from: dateStr) {
            saveMemosToDisk(memos, for: d)
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: legacyDateKey)
    }
}
