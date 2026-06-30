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

    var hasImages: Bool { !(imagePaths ?? []).isEmpty }
}

@MainActor
final class MacMemoStore: ObservableObject {
    static let shared = MacMemoStore()
    @Published var todayMemos: [MacMemo] = []
    private let key     = "macLifeLogMemos"
    private let dateKey = "macLifeLogMemosDate"
    init() { loadToday() }

    /// 添付画像の保存先（`~/.hermes/memo-images/`）。
    static var imageDir: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/memo-images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 保存済み添付画像の絶対 URL を返す（UI 表示・配信用）。
    static func imageURL(_ filename: String) -> URL { imageDir.appendingPathComponent(filename) }

    /// テキストメモを追加。`images` を渡すと `~/.hermes/memo-images/` に書き出して紐付ける。
    /// 共有シート等からの取り込みは `source` を指定する。
    @discardableResult
    func addMemo(_ text: String, images: [Data] = [], source: String? = nil, at time: Date = Date()) -> MacMemo {
        var memo = MacMemo(text: text, time: time, source: source)
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
        todayMemos.append(memo); save()
        return memo
    }

    func updateMemo(id: String, text: String) {
        guard let i = todayMemos.firstIndex(where: { $0.id == id }) else { return }
        todayMemos[i].text = text; todayMemos[i].editedAt = Date(); save()
    }

    func deleteMemo(id: String) {
        if let m = todayMemos.first(where: { $0.id == id }) {
            for name in m.imagePaths ?? [] {
                try? FileManager.default.removeItem(at: Self.imageURL(name))
            }
        }
        todayMemos.removeAll { $0.id == id }; save()
    }

    private func loadToday() {
        let today = dayKey(Date())
        if UserDefaults.standard.string(forKey: dateKey) != today {
            todayMemos = []; UserDefaults.standard.set(today, forKey: dateKey); save(); return
        }
        if let data = UserDefaults.standard.data(forKey: key),
           let m = try? JSONDecoder().decode([MacMemo].self, from: data) { todayMemos = m }
    }
    private func save() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(todayMemos), forKey: key)
        } catch {
            Log.failure("app", "メモの保存に失敗", error)
        }
    }
    private func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
    }
}
