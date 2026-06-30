import Foundation

// MARK: - Model

struct SelfGraphNode: Codable, Identifiable {
    var id: String
    var label: String
    var type: String       // self | goal | interest | project | tech | concept | person | place | memo
    var desc: String
    var size: Int          // visual weight: 8–22
    var createdAt: Double  // unix timestamp
}

struct SelfGraphLink: Codable {
    var source: String
    var target: String
    var weight: Int        // 1–4
}

struct SelfGraph: Codable {
    var nodes: [SelfGraphNode]
    var links: [SelfGraphLink]
}

// MARK: - Store

actor SelfGraphStore {
    static let shared = SelfGraphStore()
    private init() {}

    private let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("self-graph.json")
    }()

    private var cache: SelfGraph?

    func load() -> SelfGraph {
        if let c = cache { return c }
        if let data = try? Data(contentsOf: fileURL),
           let g = try? JSONDecoder().decode(SelfGraph.self, from: data) {
            cache = g; return g
        }
        let initial = SelfGraph(nodes: Self.seedNodes, links: Self.seedLinks)
        try? persist(initial)
        cache = initial
        return initial
    }

    func upsertNode(_ n: SelfGraphNode) throws {
        var g = load()
        if let i = g.nodes.firstIndex(where: { $0.id == n.id }) { g.nodes[i] = n }
        else { g.nodes.append(n) }
        try persist(g); cache = g
    }

    func deleteNode(id: String) throws {
        var g = load()
        g.nodes.removeAll { $0.id == id }
        g.links.removeAll { $0.source == id || $0.target == id }
        try persist(g); cache = g
    }

    func upsertLink(_ l: SelfGraphLink) throws {
        var g = load()
        g.links.removeAll {
            ($0.source == l.source && $0.target == l.target) ||
            ($0.source == l.target && $0.target == l.source)
        }
        g.links.append(l)
        try persist(g); cache = g
    }

    func deleteLink(source: String, target: String) throws {
        var g = load()
        g.links.removeAll {
            ($0.source == source && $0.target == target) ||
            ($0.source == target && $0.target == source)
        }
        try persist(g); cache = g
    }

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        return try enc.encode(load())
    }

    private func persist(_ g: SelfGraph) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try enc.encode(g).write(to: fileURL, options: .atomic)
    }

    // MARK: - Seed data

    static let seedNodes: [SelfGraphNode] = [
        .init(id: "self",       label: "自分",       type: "self",     desc: "すべての起点",                       size: 22, createdAt: 0),
        .init(id: "health",     label: "健康",       type: "goal",     desc: "最優先の目標。睡眠・運動・食事",       size: 18, createdAt: 0),
        .init(id: "growth",     label: "成長",       type: "goal",     desc: "継続的な学習と内省",                  size: 14, createdAt: 0),
        .init(id: "sauna",      label: "サウナ",     type: "interest", desc: "思考整理とリラックスの場",             size: 16, createdAt: 0),
        .init(id: "ai",         label: "AI・LLM",   type: "interest", desc: "深い関心・毎日活用",                  size: 17, createdAt: 0),
        .init(id: "running",    label: "運動",       type: "interest", desc: "日々のルーティン",                    size: 12, createdAt: 0),
        .init(id: "hermes",     label: "Hermes",    type: "project",  desc: "パーソナルAIシステム",                size: 20, createdAt: 0),
        .init(id: "ios",        label: "iOS開発",   type: "project",  desc: "スマホクライアント",                  size: 15, createdAt: 0),
        .init(id: "mac",        label: "Mac開発",   type: "project",  desc: "ハブサーバー",                        size: 15, createdAt: 0),
        .init(id: "claude",     label: "Claude",    type: "tech",     desc: "主要AIプロバイダー",                  size: 15, createdAt: 0),
        .init(id: "swift",      label: "Swift",     type: "tech",     desc: "開発言語",                            size: 14, createdAt: 0),
        .init(id: "sleep",      label: "睡眠",      type: "interest", desc: "健康の基盤",                          size: 12, createdAt: 0),
        .init(id: "reflection", label: "振り返り",  type: "concept",  desc: "1日を記録・内省する習慣",             size: 15, createdAt: 0),
        .init(id: "memo",       label: "メモ",      type: "concept",  desc: "思いついたことを即記録",              size: 13, createdAt: 0),
        .init(id: "lifeLog",    label: "ライフログ", type: "concept",  desc: "受動的な1日の記録",                  size: 14, createdAt: 0),
    ]

    static let seedLinks: [SelfGraphLink] = [
        .init(source: "self",       target: "health",     weight: 4),
        .init(source: "self",       target: "hermes",     weight: 4),
        .init(source: "self",       target: "ai",         weight: 4),
        .init(source: "self",       target: "growth",     weight: 3),
        .init(source: "self",       target: "sauna",      weight: 3),
        .init(source: "self",       target: "reflection", weight: 3),
        .init(source: "self",       target: "lifeLog",    weight: 2),
        .init(source: "self",       target: "memo",       weight: 2),
        .init(source: "health",     target: "sauna",      weight: 3),
        .init(source: "health",     target: "running",    weight: 3),
        .init(source: "health",     target: "sleep",      weight: 3),
        .init(source: "hermes",     target: "ios",        weight: 4),
        .init(source: "hermes",     target: "mac",        weight: 4),
        .init(source: "hermes",     target: "claude",     weight: 4),
        .init(source: "hermes",     target: "reflection", weight: 3),
        .init(source: "hermes",     target: "memo",       weight: 3),
        .init(source: "hermes",     target: "lifeLog",    weight: 3),
        .init(source: "ios",        target: "swift",      weight: 4),
        .init(source: "mac",        target: "swift",      weight: 3),
        .init(source: "ai",         target: "claude",     weight: 4),
        .init(source: "ai",         target: "hermes",     weight: 3),
        .init(source: "ai",         target: "growth",     weight: 2),
        .init(source: "reflection", target: "memo",       weight: 3),
        .init(source: "reflection", target: "sleep",      weight: 2),
        .init(source: "reflection", target: "lifeLog",    weight: 3),
        .init(source: "lifeLog",    target: "memo",       weight: 3),
        .init(source: "growth",     target: "ai",         weight: 3),
        .init(source: "growth",     target: "reflection", weight: 2),
    ]
}
