import SwiftUI

/// Searchable model picker (Settings → 一般 → モデル). Lists the live OpenRouter
/// catalog grouped by provider, hides models a test ping proved non-working, and
/// lets the user test/select any model. Selecting applies it via `setModel`.
struct ModelPickerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var query = ""

    private var groups: [(provider: String, models: [AppState.ModelOption])] {
        let q = query.lowercased()
        return appState.modelsByProvider.compactMap { group in
            let models = group.models.filter { m in
                !appState.modelIsHidden(m.id)
                    && (q.isEmpty || m.id.lowercased().contains(q) || m.name.lowercased().contains(q))
            }
            return models.isEmpty ? nil : (group.provider, models)
        }
    }

    private var visibleCount: Int { groups.reduce(0) { $0 + $1.models.count } }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Divider()
            if appState.availableModels.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 580, height: 640)
        .background(colorScheme == .dark ? Color(red: 0.1, green: 0.1, blue: 0.11) : Color(nsColor: .windowBackgroundColor))
        .task { if appState.availableModels.isEmpty { await appState.fetchAvailableModels() } }
    }

    private var header: some View {
        HStack {
            Text("モデルを選択").font(.system(size: 16, weight: .bold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary).frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("モデルを検索（例: claude, gpt-4o, gemini）", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.05)).cornerRadius(8)

            HStack(spacing: 12) {
                Toggle(isOn: $appState.hideBrokenModels) {
                    Text("動作しないモデルを隠す").font(.system(size: 11))
                }.toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Text("\(visibleCount) 件").font(.system(size: 11)).foregroundColor(.secondary)
                if appState.isValidatingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await appState.revalidatePresets() } } label: {
                        HStack(spacing: 3) { Image(systemName: "checkmark.shield"); Text("おすすめを再検証") }
                            .font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundColor(.blue)
                }
                Button { Task { await appState.fetchAvailableModels() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.provider) { group in
                    Section {
                        ForEach(group.models) { m in row(m) }
                    } header: {
                        Text(group.provider.uppercased())
                            .font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.vertical, 5)
                            .background(.ultraThinMaterial)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func row(_ m: AppState.ModelOption) -> some View {
        let selected = appState.defaultModel == m.id
        let health = appState.modelHealth[m.id]
        let testing = appState.validatingModelId == m.id
        return HStack(spacing: 10) {
            Circle()
                .fill(health == true ? Color.green : (health == false ? Color.red : Color.secondary.opacity(0.35)))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Text(m.id).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if testing {
                ProgressView().controlSize(.small)
            } else {
                Button("テスト") { Task { await appState.validateModel(m.id) } }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.blue)
            }
            if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.purple) }
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(selected ? Color.purple.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await appState.setModel(m.id); dismiss() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView("モデル一覧を取得中…")
            Button("再取得") { Task { await appState.fetchAvailableModels() } }
                .font(.system(size: 12)).buttonStyle(.plain).foregroundColor(.blue)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
