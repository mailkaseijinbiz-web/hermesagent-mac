import SwiftUI

/// ⌘K quick-jump: search across employees, sessions, views, settings and models.
struct CommandPaletteView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var query = ""
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let icon: String
        let run: () -> Void
    }

    private func close() { appState.showCommandPalette = false }

    private var items: [Item] {
        var out: [Item] = []
        out.append(Item(title: "新しいチャット", subtitle: "移動", icon: "square.and.pencil") {
            appState.handleNewChat(); appState.view = "chat"
        })
        out.append(Item(title: "会社（AI社員）", subtitle: "移動", icon: "person.3") { appState.view = "company" })
        out.append(Item(title: "オートメーション", subtitle: "移動", icon: "clock") {
            appState.view = "automations"; Task { await appState.fetchCronJobs() }
        })
        out.append(Item(title: "設定を開く", subtitle: "移動", icon: "gearshape") { appState.showSettings = true })

        for e in appState.sortedEmployees {
            out.append(Item(title: "\(e.role.emoji) \(e.name)", subtitle: "社員 ・ \(e.role.title)", icon: "person.crop.circle") {
                appState.switchEmployee(e.id)
            })
        }
        if !appState.employees.isEmpty {
            out.append(Item(title: "全体（社員なし）", subtitle: "社員", icon: "person.crop.circle.dashed") {
                appState.switchEmployee(nil)
            })
        }

        for s in appState.sessions.prefix(40) {
            out.append(Item(title: s.title, subtitle: "チャット", icon: "bubble.left") {
                appState.handleSelectSession(s); appState.view = "chat"
            })
        }

        // Models within the FIXED provider (provider is changed only in Settings).
        if appState.provider == AntigravityCLI.providerId {
            for m in AntigravityCLI.presetModels {
                out.append(Item(title: m, subtitle: "モデル", icon: "cpu") {
                    Task { await appState.setModel(m) }
                })
            }
        } else {
            for m in AppState.modelPresets {
                out.append(Item(title: m.label, subtitle: "モデル", icon: "cpu") {
                    Task { await appState.setModel(m.model) }
                })
            }
        }
        return out
    }

    private var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("社員・チャット・設定・モデルを検索…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { filtered.first?.run(); close() }
                Text("esc").font(.system(size: 10)).foregroundColor(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06)).cornerRadius(4)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { item in
                        Button { item.run(); close() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.icon).font(.system(size: 14))
                                    .foregroundColor(.secondary).frame(width: 20)
                                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(item.subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if filtered.isEmpty {
                        Text("該当なし").font(.system(size: 12)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 560)
        .background(colorScheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        .onExitCommand { close() }
        .onAppear { focused = true }
    }
}
