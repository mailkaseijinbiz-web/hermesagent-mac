import SwiftUI

/// Row for a single installed plugin (name, version, source, enable/uninstall).
/// Rendered inside the Settings modal's "プラグイン" section (see `SettingsModal`).
struct PluginRow: View {
    @EnvironmentObject var appState: AppState
    let plugin: HermesPlugin
    @State private var isPendingAction = false
    @State private var showUninstallConfirm = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 20))
                .foregroundColor(plugin.isEnabled ? .purple : .secondary)
                .frame(width: 32, height: 32)
                .background(Color.purple.opacity(plugin.isEnabled ? 0.1 : 0.03))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(plugin.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("v\(plugin.version)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(4)
                }

                Text("ソース: \(plugin.source)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isPendingAction {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 10)
            } else {
                Toggle("", isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { _ in
                        Task {
                            isPendingAction = true
                            await appState.handleTogglePlugin(plugin)
                            isPendingAction = false
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()

                Button(action: { showUninstallConfirm = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(.red.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.05))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .confirmationDialog("「\(plugin.name)」をアンインストールしますか？",
                                    isPresented: $showUninstallConfirm, titleVisibility: .visible) {
                    Button("アンインストール", role: .destructive) {
                        Task {
                            isPendingAction = true
                            await appState.handleUninstallPlugin(plugin)
                            isPendingAction = false
                        }
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("この操作は取り消せません。")
                }
            }
        }
    }
}
