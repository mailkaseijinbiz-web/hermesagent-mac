import Foundation

struct CollectionItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    /// url | image | text | video
    var kind: String
    var title: String = ""
    var note: String = ""
    var url: String = ""
    var text: String = ""
    var imagePaths: [String] = []
    var source: String = "share"
    var createdAt: Date = Date()
}

@MainActor
final class CollectionStore: ObservableObject {
    static let shared = CollectionStore()
    static let maxItems = 500
    static let dedupeWindow: TimeInterval = 24 * 3600

    @Published private(set) var items: [CollectionItem] = []

    private let fileURL: URL
    private let imageDirURL: URL

    init(fileURL: URL? = nil, imageDir: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.imageDirURL = imageDir ?? Self.defaultImageDir
        try? FileManager.default.createDirectory(at: self.imageDirURL, withIntermediateDirectories: true)
        load()
    }

    static var defaultFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/collection.json")
    }

    nonisolated static var defaultImageDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/collection-images")
    }

    func imageURL(_ filename: String) -> URL {
        imageDirURL.appendingPathComponent(filename)
    }

    @discardableResult
    func add(
        kind: String,
        title: String = "",
        note: String = "",
        url: String = "",
        text: String = "",
        images: [Data] = [],
        source: String? = nil
    ) -> CollectionItem {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            let cutoff = Date().addingTimeInterval(-Self.dedupeWindow)
            if let existing = items.first(where: { $0.url == trimmedURL && $0.createdAt >= cutoff }) {
                return existing
            }
        }

        var item = CollectionItem(
            kind: kind,
            title: title,
            note: note,
            url: trimmedURL,
            text: text,
            source: source ?? (kind == "url" ? "web" : "share")
        )

        if !images.isEmpty {
            var names: [String] = []
            for (i, data) in images.enumerated() {
                let name = "\(item.id)-\(i).jpg"
                do {
                    try data.write(to: imageURL(name))
                    names.append(name)
                } catch {
                    Log.failure("app", "コレクション画像の保存に失敗 (\(name))", error)
                }
            }
            item.imagePaths = names
        }

        items.insert(item, at: 0)
        trimToCap()
        save()
        return item
    }

    func delete(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        for name in items[idx].imagePaths {
            try? FileManager.default.removeItem(at: imageURL(name))
        }
        items.remove(at: idx)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CollectionItem].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.failure("app", "コレクションの保存に失敗", error)
        }
    }

    private func trimToCap() {
        guard items.count > Self.maxItems else { return }
        let dropped = items.suffix(from: Self.maxItems)
        for item in dropped {
            for name in item.imagePaths {
                try? FileManager.default.removeItem(at: imageURL(name))
            }
        }
        items = Array(items.prefix(Self.maxItems))
    }
}
