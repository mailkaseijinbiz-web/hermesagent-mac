import Foundation

/// 出力ビューのモード。`.chat` は従来の会話表示、それ以外は同じアシスタント出力を
/// 構造化レイアウトで描画する。`AgentMode`（AppState.swift）の label/icon パターンに倣う。
enum OutputViewMode: String, CaseIterable, Identifiable {
    case chat
    case news
    case summary
    case timeline
    case table

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat:     return "チャット"
        case .news:     return "ニュース"
        case .summary:  return "要約"
        case .timeline: return "タイムライン"
        case .table:    return "テーブル"
        }
    }

    var icon: String {
        switch self {
        case .chat:     return "bubble.left.and.bubble.right"
        case .news:     return "newspaper"
        case .summary:  return "list.bullet.rectangle"
        case .timeline: return "clock"
        case .table:    return "tablecells"
        }
    }

    /// チャット以外の構造化モード（チャット内ピッカーの非チャット選択肢）。
    static var structuredCases: [OutputViewMode] { allCases.filter { $0 != .chat } }
}

/// 出典リンク（生 URL を「出典」ボタンに畳むための表示用）。
struct SourceLink: Identifiable, Equatable {
    let id = UUID()
    var label: String
    var url: String
}

/// 構造化された1件の項目（ニュース1本／要約1点 など）。
struct NewsEntry: Identifiable, Equatable {
    let id = UUID()
    var index: Int
    var title: String
    var summary: String
    var sources: [SourceLink]
}

/// Newsページ集約用：ある社員／会話の出力から得られたエントリ群。
struct NewsFeedItem: Identifiable, Equatable {
    let id = UUID()
    var employeeName: String
    var employeeId: String?
    var entries: [NewsEntry]
}

/// アシスタントの Markdown 出力を `[NewsEntry]` に解析する。
/// エージェント側の出力形式は変更せず、既存の番号付きリスト（`1. **タイトル** 本文 ([出典](url))）を
/// その場で構造化する。
enum NewsParser {

    private static let linkRegex = try! NSRegularExpression(
        pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", options: [])

    /// 全文行頭の `N.` を検出して項目に分割。見つからなければ見出し/箇条書きにフォールバック。
    static func parse(_ markdown: String) -> [NewsEntry] {
        let text = AgentMode.strip(markdown)   // 内部ディレクティブが混ざっていても除去
        let lines = text.components(separatedBy: .newlines)

        // 1) 番号付きリスト（最優先：スクショの形式）。
        //    連続する番号が2件以上あるときだけ「リスト」と判定し誤検出を防ぐ。
        let nums = lines.compactMap { firstNumber(in: $0) }
        let isNumberedList = nums.count >= 2
        var entries = isNumberedList
            ? parseBlocks(lines, isStart: { firstNumber(in: $0) != nil })
            : []
        if !entries.isEmpty { return entries }

        // 2) 見出し（## / ### …）
        entries = parseBlocks(lines, isStart: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("#")
        })
        if !entries.isEmpty { return entries }

        // 3) 箇条書き（- / * / ・）。各行を1エントリに。
        entries = parseBlocks(lines, isStart: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("・")
        })
        return entries
    }

    // MARK: - Block splitting

    private static func parseBlocks(_ lines: [String], isStart: (String) -> Bool) -> [NewsEntry] {
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            if isStart(line) {
                if !current.isEmpty { blocks.append(current) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
            // 先頭ブロック開始前の行（前置き）は無視
        }
        if !current.isEmpty { blocks.append(current) }

        var result: [NewsEntry] = []
        for (i, block) in blocks.enumerated() {
            if let e = makeEntry(block, index: i + 1) { result.append(e) }
        }
        return result
    }

    private static func makeEntry(_ block: [String], index: Int) -> NewsEntry? {
        guard var first = block.first else { return nil }
        let rest = block.dropFirst().joined(separator: " ")

        // 行頭マーカー（"3."、"#"、"- " 等）を除去
        first = stripLeadingMarker(first)

        // タイトルと先頭本文を分離：**Title** 本文 / Title: 本文
        var title = first
        var leadingBody = ""
        if let m = matchBoldHead(first) {
            title = m.title
            leadingBody = m.rest
        } else if let colon = firstColon(in: first) {
            title = String(first[..<colon]).trimmingCharacters(in: .whitespaces)
            leadingBody = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        title = cleanInline(stripBold(title))

        let rawSummary = [leadingBody, rest].filter { !$0.isEmpty }.joined(separator: " ")
        let sources = extractLinks(from: title + " " + rawSummary)
        let summary = cleanInline(removeLinks(from: rawSummary))

        if title.isEmpty && summary.isEmpty && sources.isEmpty { return nil }
        return NewsEntry(index: index, title: title.isEmpty ? "（無題）" : title,
                         summary: summary, sources: sources)
    }

    // MARK: - Helpers

    private static func firstNumber(in line: String) -> Int? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let dot = t.firstIndex(of: ".") else { return nil }
        let head = t[..<dot]
        guard !head.isEmpty, head.allSatisfy({ $0.isNumber }) else { return nil }
        // 数字直後がドット＋空白（または末尾）であること
        let after = t.index(after: dot)
        if after < t.endIndex && t[after] != " " { return nil }
        return Int(head)
    }

    private static func stripLeadingMarker(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        // 番号
        if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy({ $0.isNumber }), !t[..<dot].isEmpty {
            t = String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            return t
        }
        // 見出し
        while t.hasPrefix("#") { t.removeFirst() }
        // 箇条書き
        for p in ["- ", "* ", "・", "-", "*"] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count)); break
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func matchBoldHead(_ s: String) -> (title: String, rest: String)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("**") else { return nil }
        let afterOpen = t.index(t.startIndex, offsetBy: 2)
        guard let closeRange = t.range(of: "**", range: afterOpen..<t.endIndex) else { return nil }
        let title = String(t[afterOpen..<closeRange.lowerBound])
        var rest = String(t[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(":") || rest.hasPrefix("：") { rest.removeFirst() }
        return (title.trimmingCharacters(in: .whitespaces), rest.trimmingCharacters(in: .whitespaces))
    }

    private static func firstColon(in s: String) -> String.Index? {
        // 短いタイトル＋コロンのみ対象（URL の :// を誤検出しないよう先頭30文字以内）
        guard let idx = s.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let dist = s.distance(from: s.startIndex, to: idx)
        if dist > 30 { return nil }
        // "://" は除外
        let next = s.index(after: idx)
        if next < s.endIndex && s[next] == "/" { return nil }
        return idx
    }

    private static func stripBold(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
    }

    private static func extractLinks(from s: String) -> [SourceLink] {
        let ns = s as NSString
        let matches = linkRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var out: [SourceLink] = []
        var seen = Set<String>()
        for m in matches where m.numberOfRanges >= 3 {
            let label = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let url = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard url.hasPrefix("http"), !seen.contains(url) else { continue }
            seen.insert(url)
            out.append(SourceLink(label: label.isEmpty ? "出典" : label, url: url))
        }
        return out
    }

    private static let wrappedLinkRegex = try! NSRegularExpression(
        pattern: "[\\(（]\\s*\\[[^\\]]+\\]\\([^)]+\\)\\s*[\\)）]", options: [])

    /// `（[出典](url)）` / `([出典](url))` / 裸の `[label](url)` を本文から取り除く。
    private static func removeLinks(from s: String) -> String {
        var t = s
        // 括弧で包まれたリンクごと除去
        t = wrappedLinkRegex.stringByReplacingMatches(
            in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
        // 残った裸リンク → ラベルのみ残す
        t = linkRegex.stringByReplacingMatches(
            in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "$1")
        return t
    }

    /// 余分な空白・空括弧・連続記号を整形。
    private static func cleanInline(_ s: String) -> String {
        var t = s
        for empty in ["（）", "()", "（ ）", "( )"] { t = t.replacingOccurrences(of: empty, with: "") }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
