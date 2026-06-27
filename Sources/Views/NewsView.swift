import SwiftUI

/// トップレベル「ニュース」ページ。読み込み済みの各会話のアシスタント出力を解析し、
/// 社員ごとにカード化したフィードを表示する（`AppState.allNewsEntries`）。
struct NewsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                let feed = appState.allNewsEntries
                if feed.isEmpty {
                    emptyState
                } else {
                    ForEach(feed) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 13)).foregroundColor(.secondary)
                                Text(item.employeeName)
                                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.primary)
                                Text("·  \(item.entries.count)件")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            NewsCardsView(entries: item.entries)
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ニュース").font(.system(size: 24, weight: .bold))
                Text("社員の収集・要約結果をまとめて表示")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            Button { appState.view = "chat" } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary).frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper").font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))
            Text("まだニュースがありません")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
            Text("リサーチャー社員に「AI Techニュースを収集して」と話しかけると、ここにまとまります。")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button { appState.view = "chat" } label: {
                Text("チャットを開く").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12)).foregroundColor(.accentColor)
                    .cornerRadius(8)
            }.buttonStyle(.plain).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}
