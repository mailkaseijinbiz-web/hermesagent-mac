import SwiftUI

/// Block types for AI-generated brief / review prose.
enum NewsProseBlock: Equatable {
    case paragraph(String)
    case heading(String)
    case bullet(String)
    case spacer
    case serendipityHeading(String)
    case serendipityCard(String)
}

/// Parsing context — weekly reviews enable serendipity section detection.
enum NewsProseContext: Equatable {
    case brief
    case weeklyReview
}

/// Parses plain-text daily briefs and weekly reviews into structured blocks.
enum NewsProseParser {

    private static let headingHints = [
        "今日の提案", "気づき", "来週への提案", "振り返り", "つながり", "まとめ", "提案", "所感", "来週", "今週"
    ]

    static func parse(_ text: String, context: NewsProseContext = .brief) -> [NewsProseBlock] {
        var blocks: [NewsProseBlock] = []
        var paragraphLines: [String] = []
        var inSerendipity = false

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(inSerendipity ? .serendipityCard(joined) : .paragraph(joined))
            }
            paragraphLines = []
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                if blocks.last != .spacer { blocks.append(.spacer) }
                continue
            }

            if let bullet = bulletText(line) {
                flushParagraph()
                blocks.append(inSerendipity ? .serendipityCard(bullet) : .bullet(bullet))
                continue
            }

            if isHeading(line) {
                flushParagraph()
                let title = cleanHeading(line)
                if isSerendipityHeading(title, context: context) {
                    inSerendipity = true
                    blocks.append(.serendipityHeading(title))
                } else {
                    inSerendipity = false
                    blocks.append(.heading(title))
                }
                continue
            }

            paragraphLines.append(line)
        }
        flushParagraph()
        return blocks
    }

    static func isSerendipityHeading(_ title: String, context: NewsProseContext) -> Bool {
        guard context == .weeklyReview else { return false }
        if title.contains("意外なつながり") { return true }
        if title.contains("つながり") { return true }
        return false
    }

    private static func bulletText(_ line: String) -> String? {
        let markers = ["・", "•", "●", "◦", "-", "*", "–", "—", "▪", "▸"]
        for m in markers {
            if line.hasPrefix(m) {
                let rest = String(line.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
        }
        if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            let rest = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    private static func isHeading(_ line: String) -> Bool {
        var s = line
        if s.hasPrefix("### ") { return true }
        if s.hasPrefix("## ") { return true }
        if s.hasPrefix("# ") { return true }
        if s.hasSuffix("：") || s.hasSuffix(":") {
            s = String(s.dropLast())
        }
        if s.count <= 24, headingHints.contains(where: { s == $0 || s.hasPrefix($0) }) {
            return true
        }
        if line.hasSuffix("：") || line.hasSuffix(":") {
            let body = line.trimmingCharacters(in: CharacterSet(charactersIn: "：:"))
            return !body.isEmpty && body.count <= 28
        }
        return false
    }

    private static func cleanHeading(_ line: String) -> String {
        var s = line
        for prefix in ["### ", "## ", "# "] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        while s.hasSuffix("：") || s.hasSuffix(":") {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Renders structured brief/review text with headings, bullets, and spacing.
struct NewsProseView: View {
    let text: String
    var context: NewsProseContext = .brief

    private var blocks: [NewsProseBlock] { NewsProseParser.parse(text, context: context) }

    var body: some View {
        if blocks.isEmpty {
            Text(text)
                .font(.system(size: 16))
                .lineSpacing(7)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                    blockView(block, index: idx)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func blockView(_ block: NewsProseBlock, index: Int) -> some View {
        switch block {
        case .paragraph(let body):
            Text(body)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, bottomPadding(after: block, at: index))

        case .heading(let title):
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.top, index == 0 ? 0 : 20)
                .padding(.bottom, 12)

        case .bullet(let body):
            HStack(alignment: .top, spacing: 8) {
                Text("・")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .leading)
                    .padding(.top, 1)
                Text(body)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, nextIsBullet(at: index) ? 6 : 10)

        case .serendipityHeading(let title):
            serendipitySectionHeader(title, index: index)

        case .serendipityCard(let body):
            serendipityCardBody(body, index: index)

        case .spacer:
            Spacer().frame(height: 10)
        }
    }

    private func serendipitySectionHeader(_ title: String, index: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.orange.opacity(0.9))
        }
        .padding(.top, index == 0 ? 0 : 20)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func serendipityCardBody(_ body: String, index: Int) -> some View {
        let isFirstCard = index == 0 || !isSerendipityCard(blocks[index - 1])
        let isLastCard = index + 1 >= blocks.count || !isSerendipityCard(blocks[index + 1])

        HStack(alignment: .top, spacing: 8) {
            Text("✦")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange.opacity(0.75))
                .frame(width: 14, alignment: .leading)
                .padding(.top, 3)
            Text(body)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 0.5)
        )
        .padding(.top, isFirstCard ? 0 : 6)
        .padding(.bottom, isLastCard ? 14 : 0)
    }

    private func isSerendipityCard(_ block: NewsProseBlock) -> Bool {
        if case .serendipityCard = block { return true }
        return false
    }

    private func nextIsBullet(at index: Int) -> Bool {
        guard index + 1 < blocks.count else { return false }
        if case .bullet = blocks[index + 1] { return true }
        return false
    }

    private func bottomPadding(after block: NewsProseBlock, at index: Int) -> CGFloat {
        guard index + 1 < blocks.count else { return 0 }
        switch blocks[index + 1] {
        case .heading, .bullet, .serendipityHeading, .serendipityCard: return 12
        case .spacer: return 0
        case .paragraph: return 10
        }
    }
}
