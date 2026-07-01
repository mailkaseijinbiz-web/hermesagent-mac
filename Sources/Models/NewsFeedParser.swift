import Foundation

/// Parsed RSS headline for `/api/sauna-news` and Mac News UI.
struct NewsFeedItem: Codable, Identifiable, Equatable {
    let title: String
    let link: String
    let date: String
    let source: String
    var topic: String?
    /// Publisher site URL from RSS `<source url="…">`.
    var sourceURL: String?
    /// Thumbnail URL when present in RSS (`media:*`, `<img>`, enclosure).
    var imageURL: String?

    var id: String { link.isEmpty ? title : link }
}

enum NewsFeedParser {

    /// Up to 3 comma-separated interests from profile; defaults to sauna.
    static func topics(from likes: String) -> [String] {
        let parts = likes
            .split(whereSeparator: { ",、/|".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty { return ["サウナ"] }
        return Array(parts.prefix(3))
    }

    static func parseGoogleNewsRSS(_ xml: String, topic: String, limit: Int = 6) -> [NewsFeedItem] {
        var items: [NewsFeedItem] = []
        for part in xml.components(separatedBy: "<item>").dropFirst().prefix(limit) {
            let rawTitle = decodeEntities(xmlText(part, tag: "title"))
            let link = xmlText(part, tag: "link")
            let pub = xmlText(part, tag: "pubDate")
            guard !rawTitle.isEmpty, !link.isEmpty else { continue }
            let split = splitTitle(rawTitle)
            let when = relativeDateString(from: parsePubDate(pub))
            let desc = decodeEntities(xmlText(part, tag: "description"))
            let sourceURL = xmlAttribute(part, tag: "source", name: "url")
            let rssSource = xmlText(part, tag: "source")
            let sourceName = split.source.isEmpty ? rssSource : split.source
            let imageURL = extractImageURL(from: desc, itemXML: part)
            items.append(NewsFeedItem(
                title: split.title,
                link: link,
                date: when,
                source: sourceName,
                topic: topic,
                sourceURL: sourceURL.isEmpty ? nil : sourceURL,
                imageURL: imageURL
            ))
        }
        return items
    }

    /// Merge feeds, dedupe by link, cap total count.
    static func merge(_ groups: [[NewsFeedItem]], max: Int = 10) -> [NewsFeedItem] {
        var seen = Set<String>()
        var out: [NewsFeedItem] = []
        for group in groups {
            for item in group {
                let key = item.link.lowercased()
                guard seen.insert(key).inserted else { continue }
                out.append(item)
                if out.count >= max { return out }
            }
        }
        return out
    }

    // MARK: - Title / date helpers

    static func splitTitle(_ raw: String) -> (title: String, source: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: " - ", options: .backwards) {
            let title = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let source = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return (title, source) }
        }
        return (trimmed, "")
    }

    static func relativeDateString(from date: Date?) -> String {
        guard let date else { return "" }
        let sec = Date().timeIntervalSince(date)
        if sec < 60 { return "たった今" }
        if sec < 3600 { return "\(Int(sec / 60))分前" }
        if sec < 86400 { return "\(Int(sec / 3600))時間前" }
        if sec < 86400 * 7 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "E"
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d"
        return f.string(from: date)
    }

    static func parsePubDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ] {
            f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// Pull the first image URL from RSS description HTML or media tags.
    static func extractImageURL(from description: String, itemXML: String) -> String? {
        let thumb = xmlAttribute(itemXML, tag: "media:thumbnail", name: "url")
        if !thumb.isEmpty { return thumb }
        if itemXML.contains("media:content") {
            let url = xmlAttribute(itemXML, tag: "media:content", name: "url")
            if !url.isEmpty,
               itemXML.contains("medium=\"image\"") || url.contains(".jpg") || url.contains(".png") || url.contains(".webp") {
                return url
            }
        }
        if let enc = optionalNonEmpty(xmlAttribute(itemXML, tag: "enclosure", name: "url")),
           enc.contains(".jpg") || enc.contains(".png") || enc.contains(".webp") {
            return enc
        }
        let html = description
        if let src = firstAttribute(in: html, tag: "img", name: "src"), src.hasPrefix("http") {
            return src
        }
        return nil
    }

    static func firstAttribute(in html: String, tag: String, name: String) -> String? {
        guard let open = html.range(of: "<\(tag)", options: .caseInsensitive) else { return nil }
        let tail = html[open.lowerBound...]
        guard let close = tail.range(of: ">") else { return nil }
        let header = tail[..<close.upperBound]
        for quote in ["\"", "'"] {
            let needle = "\(name)=\(quote)"
            guard let a = header.range(of: needle) else { continue }
            let start = a.upperBound
            guard let b = header[start...].range(of: quote) else { continue }
            return String(header[start..<b.lowerBound])
        }
        return nil
    }

    static func xmlAttribute(_ src: String, tag: String, name: String) -> String {
        guard let open = src.range(of: "<\(tag)") else { return "" }
        let end = src.index(open.upperBound, offsetBy: 240, limitedBy: src.endIndex) ?? src.endIndex
        let tail = src[open.lowerBound..<end]
        for quote in ["\"", "'"] {
            let needle = "\(name)=\(quote)"
            guard let a = tail.range(of: needle) else { continue }
            let start = a.upperBound
            guard let b = tail[start...].range(of: quote) else { continue }
            return String(tail[start..<b.lowerBound])
        }
        return ""
    }

    private static func optionalNonEmpty(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }

    // MARK: - XML

    static func xmlText(_ src: String, tag: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let r1 = src.range(of: open),
              let r2 = src.range(of: close, range: r1.upperBound..<src.endIndex) else { return "" }
        var val = String(src[r1.upperBound..<r2.lowerBound])
        if val.hasPrefix("<![CDATA[") && val.hasSuffix("]]>") {
            val = String(val.dropFirst(9).dropLast(3))
        }
        return val.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
