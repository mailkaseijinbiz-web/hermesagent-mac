import SwiftUI
import AppKit

// MARK: - Decoded types (matches MobileServer JSON output)

private struct MacStockQuote: Codable, Identifiable {
    var id: String { ticker }
    let ticker: String
    let label: String
    let price: String
    let change: String
    let changePercent: String
    let isPositive: Bool
    let history: [Double]?   // 30日分の終値、古い順（nil = 未取得）
}

private struct MacNewsItem: Codable, Identifiable {
    var id: String { title + date }
    let title: String
    let link: String
    let date: String
}

// MARK: - View

struct MacNewsView: View {
    @EnvironmentObject var appState: AppState
    @State private var stocks: [MacStockQuote]  = []
    @State private var newsItems: [MacNewsItem] = []
    @State private var loadingStocks = false
    @State private var loadingNews   = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                briefSection
                reviewSection
                if !stocks.isEmpty    { stocksSection }
                if !newsItems.isEmpty { saunaSection }
            }
            .padding(.horizontal, 32)
            .padding(.top, 52)
            .padding(.bottom, 24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .ignoresSafeArea(edges: .top)
        .onAppear { loadAll() }
    }

    private func loadAll() {
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await loadStocks() }
                group.addTask { await loadNews()   }
            }
        }
    }

    private func loadStocks() async {
        loadingStocks = true
        let json = await MobileServer.shared.fetchStocksJSON()
        if let data  = json.data(using: .utf8),
           let items = try? JSONDecoder().decode([MacStockQuote].self, from: data) {
            await MainActor.run { stocks = items }
        }
        await MainActor.run { loadingStocks = false }
    }

    private func loadNews() async {
        loadingNews = true
        let json = await MobileServer.shared.fetchSaunaNewsJSON()
        if let data  = json.data(using: .utf8),
           let items = try? JSONDecoder().decode([MacNewsItem].self, from: data) {
            await MainActor.run { newsItems = items }
        }
        await MainActor.run { loadingNews = false }
    }

    // MARK: - Sections

    private var briefSection: some View {
        newsCard(title: "今日の振り返り", icon: "sparkles",
                 trailing: {
                     regenButton(generating: appState.isGeneratingBrief) {
                         Task { await appState.generateDailyBrief() }
                     }
                 }) {
            if appState.dailyBrief.isEmpty {
                Text(appState.isGeneratingBrief ? "生成中…" : "右の再生成ボタンで生成できます")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text(appState.dailyBrief)
                    .font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                if appState.dailyBriefAt > 0 {
                    Text(briefTimestamp(appState.dailyBriefAt))
                        .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 2)
                }
            }
        }
    }

    private var reviewSection: some View {
        newsCard(title: "週次メタ認知レビュー", icon: "brain.head.profile",
                 trailing: {
                     regenButton(generating: appState.isGeneratingReview) {
                         Task { await appState.generateWeeklyReview() }
                     }
                 }) {
            if appState.weeklyReview.isEmpty {
                Text(appState.isGeneratingReview ? "生成中…" : "数日〜1週間データがたまると生成できます")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text(appState.weeklyReview)
                    .font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
            }
        }
    }

    private var stocksSection: some View {
        newsCard(title: "ポートフォリオ", icon: "chart.line.uptrend.xyaxis",
                 trailing: {
                     Button { Task { await loadStocks() } } label: {
                         Image(systemName: "arrow.clockwise").font(.system(size: 12))
                     }
                     .buttonStyle(.plain).foregroundStyle(.secondary).disabled(loadingStocks)
                 }) {
            VStack(spacing: 1) {
                ForEach(stocks) { s in
                    StockRow(quote: s)
                }
            }
        }
    }

    private var saunaSection: some View {
        newsCard(title: "サウナニュース", icon: "flame.fill",
                 trailing: {
                     Button { Task { await loadNews() } } label: {
                         Image(systemName: "arrow.clockwise").font(.system(size: 12))
                     }
                     .buttonStyle(.plain).foregroundStyle(.secondary).disabled(loadingNews)
                 }) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(newsItems) { item in
                    Button {
                        if let url = URL(string: item.link) { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "newspaper")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                if !item.date.isEmpty {
                                    Text(item.date)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    if item.id != newsItems.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: - Helpers

    private func newsCard<C: View, T: View>(
        title: String, icon: String,
        @ViewBuilder trailing: () -> T,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                trailing()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    @ViewBuilder
    private func regenButton(generating: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if generating {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(generating)
    }

    private func briefTimestamp(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter(); f.dateFormat = "HH:mm に生成"
        return f.string(from: d)
    }
}

// MARK: - Stock row with sparkline

private struct StockRow: View {
    let quote: MacStockQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(quote.label.isEmpty ? quote.ticker : quote.label)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(quote.ticker)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(quote.price)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Text(quote.changePercent)
                        .font(.system(size: 11, design: .monospaced))
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
        .background(Color.primary.opacity(0.025))
        .cornerRadius(10)
        .padding(.vertical, 2)
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
                // 塗りつぶしグラデーション
                fillPath(in: rect)
                    .fill(LinearGradient(
                        colors: [color.opacity(0.18), color.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    ))
                // 折れ線
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
