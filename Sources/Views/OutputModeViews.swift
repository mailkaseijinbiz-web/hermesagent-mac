import SwiftUI
import AppKit

// MARK: - モード切替ピッカー

/// チャット画面上部に出すセグメント切替（💬チャット / 📰ニュース / 📝要約 / 🕑タイムライン / 📊テーブル）。
struct OutputModePicker: View {
    @Binding var mode: OutputViewMode

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(OutputViewMode.allCases) { m in
                Label(m.label, systemImage: m.icon).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 460)
    }
}

// MARK: - 振り分けコンテナ

/// `mode` に応じて構造化ビューへ振り分ける。`.chat` はここでは扱わない（呼び出し側が transcript を表示）。
struct StructuredOutputContainer: View {
    let entries: [NewsEntry]
    let mode: OutputViewMode

    var body: some View {
        if entries.isEmpty {
            EmptyStructuredState()
        } else {
            switch mode {
            case .news:     NewsCardsView(entries: entries)
            case .summary:  NewsSummaryView(entries: entries)
            case .timeline: NewsTimelineView(entries: entries)
            case .table:    NewsTableView(entries: entries)
            case .chat:     NewsCardsView(entries: entries)   // 念のためのフォールバック
            }
        }
    }
}

private struct EmptyStructuredState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "newspaper").font(.system(size: 34)).foregroundColor(.secondary.opacity(0.5))
            Text("この出力は構造化表示にできませんでした")
                .font(.system(size: 13)).foregroundColor(.secondary)
            Text("番号付きリストや見出しを含む要約だとカード化できます。")
                .font(.system(size: 11)).foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 60)
    }
}

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

// MARK: - 📝 要約

struct NewsSummaryView: View {
    let entries: [NewsEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(entries) { e in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "circle.fill").font(.system(size: 6))
                        .foregroundColor(.accentColor).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.primary)
                        if !e.summary.isEmpty {
                            Text(e.summary).font(.system(size: 12)).foregroundColor(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        SourceLinkRow(sources: e.sources)
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.02)).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

// MARK: - 🕑 タイムライン

struct NewsTimelineView: View {
    let entries: [NewsEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, e in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle().fill(Color.accentColor).frame(width: 11, height: 11)
                        if idx < entries.count - 1 {
                            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 2)
                        }
                    }
                    .frame(width: 11)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.primary)
                        if !e.summary.isEmpty {
                            Text(e.summary).font(.system(size: 12)).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SourceLinkRow(sources: e.sources)
                    }
                    .padding(.bottom, idx < entries.count - 1 ? 18 : 0)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.02)).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

// MARK: - 📊 テーブル

struct NewsTableView: View {
    let entries: [NewsEntry]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                cell("#", weight: .semibold).frame(width: 36)
                cell("タイトル", weight: .semibold)
                cell("出典", weight: .semibold).frame(width: 110)
            }
            .background(Color.primary.opacity(0.05))
            ForEach(entries) { e in
                Divider()
                GridRow {
                    cell("\(e.index)").frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.system(size: 12, weight: .medium)).foregroundColor(.primary)
                        if !e.summary.isEmpty {
                            Text(e.summary).font(.system(size: 11)).foregroundColor(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        SourceLinkRow(sources: e.sources)
                    }
                    .padding(8).frame(width: 110, alignment: .leading)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func cell(_ text: String, weight: Font.Weight = .regular) -> some View {
        Text(text).font(.system(size: 12, weight: weight)).foregroundColor(.primary)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
}
