import SwiftUI
import AppKit

// MARK: - Decoded types

private struct MacStockQuote: Codable, Identifiable {
    var id: String { ticker }
    let ticker: String
    let label: String
    let price: String
    let change: String
    let changePercent: String
    let isPositive: Bool
    let history: [Double]?
}

// MARK: - View

struct MacNewsView: View {
    @EnvironmentObject var appState: AppState
    @State private var stocks: [MacStockQuote] = []
    @State private var newsItems: [NewsFeedItem] = []
    @State private var loadingStocks = false
    @State private var loadingNews = false
    @State private var newsLoadedAt: Date?

    private var newsTopics: [String] {
        NewsFeedParser.topics(from: appState.personalProfile.likes)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader
                briefSection
                reviewSection
                if loadingStocks || !stocks.isEmpty { stocksSection }
                newsSection
            }
            .padding(.horizontal, 32)
            .padding(.top, 52)
            .padding(.bottom, 32)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .center)
            .reportMainScrollOffset()
        }
        .onMainScrollOffsetChange { appState.mainScrollOffset = $0 }
        .ignoresSafeArea(edges: .top)
        .onAppear { loadAll() }
    }

    // MARK: - Header

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greetingLine)
                .font(.system(size: 28, weight: .bold))
            Text(headerDateLine)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private var greetingLine: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11:  return "おはようございます"
        case 11..<17: return "こんにちは"
        case 17..<22: return "お疲れさまです"
        default:      return "おやすみなさい"
        }
    }

    private var headerDateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f.string(from: Date())
    }

    // MARK: - Data

    private func loadAll() {
        Task {
            if appState.dailyBrief.isEmpty, !appState.isGeneratingBrief {
                await appState.generateDailyBrief()
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await loadStocks() }
                group.addTask { await loadNews() }
            }
        }
    }

    private func loadStocks() async {
        loadingStocks = true
        defer { loadingStocks = false }
        let json = await MobileServer.shared.fetchStocksJSON()
        if let data = json.data(using: .utf8),
           let items = try? JSONDecoder().decode([MacStockQuote].self, from: data) {
            await MainActor.run { stocks = items }
        }
    }

    private func loadNews() async {
        loadingNews = true
        defer { loadingNews = false }
        let json = await MobileServer.shared.fetchSaunaNewsJSON()
        if let data = json.data(using: .utf8),
           let items = try? JSONDecoder().decode([NewsFeedItem].self, from: data) {
            await MainActor.run {
                newsItems = items
                newsLoadedAt = Date()
            }
        }
    }

    // MARK: - Brief

    private var briefSection: some View {
        NewsPanel(title: "今日の振り返り", icon: "sparkle", tint: .purple) {
            HStack(spacing: 8) {
                if appState.isGeneratingBrief {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                panelAction(icon: "arrow.clockwise") {
                    Task { await appState.generateDailyBrief() }
                }
                .disabled(appState.isGeneratingBrief)
            }
        } content: {
            if appState.dailyBrief.isEmpty {
                Text(appState.isGeneratingBrief ? "AIが今日の流れを整理しています…" : "データがたまると自動で生成されます")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            } else {
                NewsProseView(text: appState.dailyBrief)
                if appState.dailyBriefAt > 0 {
                    Text(timestampLabel(appState.dailyBriefAt))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 14)
                }
            }
        }
    }

    // MARK: - Review

    private var reviewSection: some View {
        NewsPanel(title: "週次メタ認知レビュー", icon: "brain.head.profile", tint: .indigo) {
            panelAction(icon: "arrow.clockwise") {
                Task { await appState.generateWeeklyReview() }
            }
            .disabled(appState.isGeneratingReview)
        } content: {
            if appState.isGeneratingReview && appState.weeklyReview.isEmpty {
                Text("行動パターンを分析中…")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            } else if appState.weeklyReview.isEmpty {
                Text("数日〜1週間のデータがたまると、気づきと来週への提案を生成できます")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            } else {
                NewsProseView(text: appState.weeklyReview)
                if appState.weeklyReviewAt > 0 {
                    Text(timestampLabel(appState.weeklyReviewAt))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 14)
                }
            }
        }
    }

    // MARK: - Stocks

    private var stocksSection: some View {
        NewsPanel(title: "ポートフォリオ", icon: "chart.line.uptrend.xyaxis", tint: .green) {
            if loadingStocks {
                ProgressView().controlSize(.small)
            } else {
                panelAction(icon: "arrow.clockwise", title: "更新") {
                    Task { await loadStocks() }
                }
            }
        } content: {
            if loadingStocks && stocks.isEmpty {
                loadingPlaceholder(rows: 2)
            } else {
                VStack(spacing: 8) {
                    ForEach(stocks) { StockRow(quote: $0) }
                }
            }
        }
    }

    // MARK: - News feed

    private var newsSection: some View {
        NewsPanel(title: "あなたへのニュース", icon: "newspaper.fill", tint: .orange) {
            HStack(spacing: 8) {
                if loadingNews {
                    ProgressView().controlSize(.small)
                }
                if let t = newsLoadedAt {
                    Text(timeLabel(t))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                panelAction(icon: "arrow.clockwise", title: "更新") {
                    Task { await loadNews() }
                }
                .disabled(loadingNews)
            }
        } content: {
            if !newsTopics.isEmpty {
                FlowTopics(topics: newsTopics)
                    .padding(.bottom, 4)
            }

            if loadingNews && newsItems.isEmpty {
                loadingPlaceholder(rows: 4)
            } else if newsItems.isEmpty {
                Text("ニュースを取得できませんでした。プロフィールの「好きなもの」に関心キーワードを登録すると、パーソナライズされます。")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(newsItems.enumerated()), id: \.element.id) { idx, item in
                        NewsArticleRow(item: item)
                        if idx < newsItems.count - 1 {
                            Divider().padding(.leading, 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func timestampLabel(_ ts: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 HH:mm 更新"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm 取得"
        return f.string(from: d)
    }

    @ViewBuilder
    private func panelAction(icon: String, title: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let title {
                    Label(title, systemImage: icon)
                } else {
                    Image(systemName: icon)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(title ?? "再生成")
    }

    @ViewBuilder
    private func loadingPlaceholder(rows: Int) -> some View {
        VStack(spacing: 10) {
            ForEach(0..<rows, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 72)
            }
        }
    }
}

// MARK: - News article row

private struct NewsArticleRow: View {
    let item: NewsFeedItem
    @State private var hovered = false
    @State private var thumbnail: NSImage?
    @State private var loadingThumb = true

    private let thumbSize: CGFloat = 72

    var body: some View {
        Button {
            if let url = URL(string: item.link) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                newsThumbnail
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let topic = item.topic, !topic.isEmpty {
                            Text(topic)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12))
                                .cornerRadius(4)
                        }
                        if !item.source.isEmpty {
                            Text(item.source)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if !item.date.isEmpty {
                            Text(item.date)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(item.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .opacity(hovered ? 1 : 0.35)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .task(id: item.id) {
            loadingThumb = true
            thumbnail = await NewsThumbnailLoader.load(for: item)
            loadingThumb = false
        }
    }

    private var newsThumbnail: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else if loadingThumb {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                    ProgressView().controlSize(.small)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: thumbSize, height: thumbSize)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Topic chips

private struct FlowTopics: View {
    let topics: [String]

    var body: some View {
        HStack(spacing: 6) {
            Text("関心")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            ForEach(topics, id: \.self) { t in
                Text(t)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
            }
        }
    }
}

// MARK: - Panel shell

private struct NewsPanel<Trailing: View, Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                trailing()
            }
            content()
                .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - Stock row

private struct StockRow: View {
    let quote: MacStockQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(quote.label.isEmpty ? quote.ticker : quote.label)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(quote.ticker)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(quote.price)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    Text(quote.changePercent)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(quote.isPositive ? Color.green : Color.red)
                }
            }
            if let hist = quote.history, hist.count >= 2 {
                SparklineView(values: hist, isPositive: quote.isPositive)
                    .frame(height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(10)
    }
}

// MARK: - Sparkline

private struct SparklineView: View {
    let values: [Double]
    let isPositive: Bool

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let color: Color = isPositive ? .green : .red
            ZStack {
                fillPath(in: rect)
                    .fill(LinearGradient(
                        colors: [color.opacity(0.18), color.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    ))
                linePath(in: rect)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }

    private func normalizedPoints(in rect: CGRect) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let minV = values.min()!, maxV = values.max()!
        let range = maxV == minV ? 1.0 : maxV - minV
        let n = values.count
        return values.enumerated().map { i, v in
            CGPoint(
                x: rect.minX + CGFloat(i) / CGFloat(n - 1) * rect.width,
                y: rect.maxY - CGFloat((v - minV) / range) * rect.height
            )
        }
    }

    private func linePath(in rect: CGRect) -> Path {
        let pts = normalizedPoints(in: rect)
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        return path
    }

    private func fillPath(in rect: CGRect) -> Path {
        let pts = normalizedPoints(in: rect)
        var path = Path()
        guard let first = pts.first, let last = pts.last else { return path }
        path.move(to: first)
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
