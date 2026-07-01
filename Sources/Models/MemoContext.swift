import Foundation

/// Compact memo lines for Personal AI prompts (no image bytes, truncated text).
enum MemoContext {

    static func format(_ memos: [MacMemo], max: Int = 8, maxChars: Int = 120) -> String {
        guard !memos.isEmpty else { return "" }
        return memos.suffix(max).map { line(for: $0, maxChars: maxChars) }.joined(separator: "\n")
    }

    static func line(for memo: MacMemo, maxChars: Int = 120) -> String {
        let icon: String = {
            switch memo.mediaKind {
            case "url": return "🔗"
            case "video": return "🎬"
            case "image": return "📷"
            default: return memo.source == "web" ? "🔗" : "📝"
            }
        }()
        if memo.mediaKind == "url", let link = memo.link, !link.isEmpty {
            let title = (memo.pageTitle?.isEmpty == false ? memo.pageTitle! : memo.text)
            let short = String(title.prefix(maxChars))
            return "\(icon) \(short) (\(link))"
        }
        let body = memo.pageTitle?.isEmpty == false ? memo.pageTitle! : memo.text
        return "\(icon) \(String(body.prefix(maxChars)))"
    }
}
