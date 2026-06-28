import SwiftUI
import AppKit

// ニュース系の構造化出力カード。`NewsView` から使用する。
// （かつてここにあった OutputModePicker / StructuredOutputContainer / summary・timeline・table
//  ビューは未配線の dead code だったため削除した。復活させる場合は git 履歴を参照。）

// MARK: - 共有：出典ボタン

private func openURL(_ raw: String) {
    guard let url = URL(string: raw) else { return }
    NSWorkspace.shared.open(url)
}

struct SourceLinkRow: View {
    let sources: [SourceLink]
    var body: some View {
        if !sources.isEmpty {
            HStack(spacing: 8) {
                ForEach(sources) { s in
                    Button { openURL(s.url) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link").font(.system(size: 9))
                            Text(s.label).font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundColor(.accentColor)
                        .background(Color.accentColor.opacity(0.1)).cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .help(s.url)
                }
            }
        }
    }
}

// MARK: - 📰 ニュースカード

struct NewsCardsView: View {
    let entries: [NewsEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(entries) { NewsEntryCard(entry: $0) }
        }
    }
}

struct NewsEntryCard: View {
    let entry: NewsEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(entry.index)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor).clipShape(Circle())
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            SourceLinkRow(sources: entry.sources)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.02)).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}
