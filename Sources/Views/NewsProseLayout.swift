import SwiftUI

/// Block types for AI-generated brief / review prose.
enum NewsProseBlock: Equatable {
    case paragraph(String)
    case heading(String)
    case bullet(String)
    case spacer
}

/// Parses plain-text daily briefs and weekly reviews into structured blocks.
enum NewsProseParser {

    private static let headingHints = [
        "今日の提案", "気づき", "来週への提案", "振り返り", "つながり", "まとめ", "提案", "所感", "来週", "今週"
    ]

    static func parse(_ text: String) -> [NewsProseBlock] {
        var blocks: [NewsProseBlock] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
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
                blocks.append(.bullet(bullet))
                continue
            }

            if isHeading(line) {
                flushParagraph()
                blocks.append(.heading(cleanHeading(line)))
                continue
            }

            paragraphLines.append(line)
        }
        flushParagraph()
        return blocks
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

    private var blocks: [NewsProseBlock] { NewsProseParser.parse(text) }

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

        case .spacer:
            Spacer().frame(height: 10)
        }
    }

    private func nextIsBullet(at index: Int) -> Bool {
        guard index + 1 < blocks.count else { return false }
        if case .bullet = blocks[index + 1] { return true }
        return false
    }

    private func bottomPadding(after block: NewsProseBlock, at index: Int) -> CGFloat {
        guard index + 1 < blocks.count else { return 0 }
        switch blocks[index + 1] {
        case .heading, .bullet: return 12
        case .spacer: return 0
        case .paragraph: return 10
        }
    }
}
