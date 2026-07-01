import SwiftUI

struct MacCollectionView: View {
    @ObservedObject private var store = CollectionStore.shared
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("コレクション")
                        .font(.system(size: 28, weight: .bold))
                        .padding(.bottom, 4)

                    if store.items.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(store.items) { item in
                                collectionRow(item)
                                    .id(item.id)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            store.delete(id: item.id)
                                        } label: {
                                            Label("削除", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 52)
                .padding(.bottom, 32)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, alignment: .center)
                .reportMainScrollOffset()
            }
            .onChange(of: appState.highlightedCollectionItemId) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let id = appState.highlightedCollectionItemId {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .onMainScrollOffsetChange { AppState.shared.mainScrollOffset = $0 }
        .ignoresSafeArea(edges: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("まだコレクションがありません")
                .font(.system(size: 15, weight: .medium))
            Text("iOSの共有シートから保存したURL・テキスト・写真がここに集まります。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func collectionRow(_ item: CollectionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: item.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent(for: item.kind))
                .frame(width: 32, height: 32)
                .background(accent(for: item.kind).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle(item))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)

                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !item.text.isEmpty, item.kind != "text" || item.title.isEmpty {
                    Text(item.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if !item.url.isEmpty {
                    Link(item.url, destination: URL(string: item.url) ?? URL(fileURLWithPath: "/"))
                        .font(.system(size: 11))
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(relativeDate(item.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if !item.imagePaths.isEmpty {
                        Text("📷 \(item.imagePaths.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                store.delete(id: item.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("削除")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            appState.highlightedCollectionItemId == item.id
                ? Color.accentColor.opacity(0.12)
                : Color.primary.opacity(0.04)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(
                appState.highlightedCollectionItemId == item.id
                    ? Color.accentColor.opacity(0.45)
                    : Color.primary.opacity(0.07),
                lineWidth: appState.highlightedCollectionItemId == item.id ? 1.5 : 0.5
            )
        )
    }

    private func displayTitle(_ item: CollectionItem) -> String {
        if !item.title.isEmpty { return item.title }
        if !item.text.isEmpty { return String(item.text.prefix(80)) }
        if !item.url.isEmpty { return item.url }
        switch item.kind {
        case "image": return "共有された写真"
        case "video": return "共有された動画"
        default: return "保存されたアイテム"
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "url":   return "link"
        case "image": return "photo"
        case "video": return "film"
        default:      return "doc.text"
        }
    }

    private func accent(for kind: String) -> Color {
        switch kind {
        case "url":   return .blue
        case "image": return .purple
        case "video": return .orange
        default:      return .secondary
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
