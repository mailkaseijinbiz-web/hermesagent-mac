import Foundation

// MARK: - Models

/// One AI-generated reflection question and the user's answer.
/// All new fields must stay Optional (Codable-persisted — see codable-persisted-fields rule).
struct ReflectionQA: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var question: String
    var answer: String? = nil
}

/// A single night's reflection: fixed questions (mood 1–5 + one-liner) plus 1–2
/// AI-generated questions built from that day's lifelog. Persisted encrypted via
/// PrivateStore (the most sensitive data in the system).
struct ReflectionEntry: Codable, Equatable {
    var dateKey: String                     // "2026-07-02"
    var moodScore: Int? = nil               // 固定質問: 今日の気分 1〜5
    var oneLiner: String? = nil             // 固定質問: 今日の一言
    var qa: [ReflectionQA] = []             // AI生成質問（0〜2問）
    var questionsGeneratedAt: Double? = nil // 21:30ジョブが質問を埋めた時刻
    var reminderSentAt: Double? = nil       // 22:00リマインダー送信済みガード
    var answeredAt: Double? = nil           // ユーザーが回答した時刻
}

// MARK: - Store

/// Encrypted persistence for nightly reflections. One PrivateStore blob per month
/// ("reflections-2026-07" → [dateKey: ReflectionEntry]) so files stay small and
/// old months never get rewritten.
actor ReflectionStore {
    static let shared = ReflectionStore()
    private init() {}

    private var cache: [String: [String: ReflectionEntry]] = [:]  // monthKey → dateKey → entry

    static func dateKey(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    private static func monthKey(forDateKey dateKey: String) -> String {
        "reflections-\(String(dateKey.prefix(7)))"   // "reflections-2026-07"
    }

    private func month(_ monthKey: String) -> [String: ReflectionEntry] {
        if let m = cache[monthKey] { return m }
        let m = PrivateStore.load([String: ReflectionEntry].self, key: monthKey) ?? [:]
        cache[monthKey] = m
        return m
    }

    func entry(dateKey: String) -> ReflectionEntry? {
        month(Self.monthKey(forDateKey: dateKey))[dateKey]
    }

    func upsert(_ entry: ReflectionEntry) {
        let mk = Self.monthKey(forDateKey: entry.dateKey)
        var m = month(mk)
        m[entry.dateKey] = entry
        cache[mk] = m
        try? PrivateStore.save(m, key: mk)
    }

    /// Entries for the last `days` days (missing days skipped), oldest first.
    func recent(days: Int) -> [ReflectionEntry] {
        let cal = Calendar.current
        var out: [ReflectionEntry] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            if let e = entry(dateKey: Self.dateKey(for: d)) { out.append(e) }
        }
        return out
    }
}

// MARK: - Self-graph proposals (週次レビューでのAI差分提案 → ユーザー承認制)

/// A proposed change to the self graph, generated weekly from reflections + lifelog.
/// Never applied automatically — the user approves or rejects each one.
struct SelfGraphProposal: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var kind: String            // addNode | addLink | strengthenLink
    var reason: String          // なぜこの変更を提案するか（1文）
    // addNode
    var nodeLabel: String? = nil
    var nodeType: String? = nil // goal | interest | project | tech | concept | person | place | memo
    var nodeDesc: String? = nil
    // addLink / strengthenLink（labelで指定 — LLMはidを知らない）
    var sourceLabel: String? = nil
    var targetLabel: String? = nil
    var createdAt: Double = Date().timeIntervalSince1970
    var status: String = "pending"   // pending | accepted | rejected
}

/// Plain-JSON store at ~/.hermes/self-graph-proposals.json (the graph itself is plain too).
actor SelfGraphProposalStore {
    static let shared = SelfGraphProposalStore()
    private init() {}

    private let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("self-graph-proposals.json")
    }()

    private var cache: [SelfGraphProposal]?

    func all() -> [SelfGraphProposal] {
        if let c = cache { return c }
        let list = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([SelfGraphProposal].self, from: $0) } ?? []
        cache = list
        return list
    }

    func pending() -> [SelfGraphProposal] { all().filter { $0.status == "pending" } }

    /// Replace all pending proposals with a fresh batch (old pendings are superseded weekly).
    func replacePending(with proposals: [SelfGraphProposal]) {
        var list = all().filter { $0.status != "pending" }
        list.append(contentsOf: proposals)
        persist(list)
    }

    func setStatus(id: String, status: String) -> SelfGraphProposal? {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        list[i].status = status
        persist(list)
        return list[i]
    }

    private func persist(_ list: [SelfGraphProposal]) {
        // Keep the file bounded: drop resolved proposals older than 90 days.
        let cutoff = Date().timeIntervalSince1970 - 90 * 86400
        let trimmed = list.filter { $0.status == "pending" || $0.createdAt > cutoff }
        cache = trimmed
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(trimmed).write(to: fileURL, options: .atomic)
    }
}
