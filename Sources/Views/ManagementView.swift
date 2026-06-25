import SwiftUI

/// H3 management surface: view/edit built-in memory, browse installed skills,
/// and inspect MCP servers — all backed by the `hermes` CLI / memory files.
/// Rendered inside the Settings modal's "管理" section (see `SettingsModal`).
enum ManagementTab: String, CaseIterable, Identifiable {
    case memory = "メモリ"
    case skills = "スキル"
    case mcp = "MCP"
    var id: String { rawValue }
}

// MARK: - Memory

struct MemoryEditor: View {
    @EnvironmentObject var appState: AppState
    @State private var file: MemoryFile = .memory
    @State private var text: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("ファイル", selection: $file) {
                ForEach(MemoryFile.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
            .onChange(of: file) { _, newValue in text = appState.loadMemory(newValue) }

            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))

            HStack {
                Text(file.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("再読み込み") { text = appState.loadMemory(file) }
                Button("保存") { appState.saveMemory(file, text) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            if !loaded { text = appState.loadMemory(file); loaded = true }
        }
    }
}

// MARK: - Skills

struct SkillsList: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""

    private var filtered: [HermesSkill] {
        guard !query.isEmpty else { return appState.skills }
        let q = query.lowercased()
        return appState.skills.filter { $0.name.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("スキルを検索", text: $query).textFieldStyle(.plain)
                Spacer()
                Text("\(appState.skills.count) 件")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Button { Task { await appState.fetchSkills() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if appState.isFetchingSkills && appState.skills.isEmpty {
                ProgressView().frame(maxWidth: .infinity, alignment: .center).padding()
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { skill in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(skill.isEnabled ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(skill.name).font(.system(size: 13, weight: .medium))
                                if !skill.category.isEmpty {
                                    Text(skill.category).font(.system(size: 10)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Text(skill.source)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                            Toggle("", isOn: Binding(
                                get: { skill.isEnabled },
                                set: { _ in Task { await appState.toggleSkill(skill) } }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .onAppear { if appState.skills.isEmpty { Task { await appState.fetchSkills() } } }
    }
}

// MARK: - MCP

struct MCPList: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MCP サーバー")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await appState.fetchMCPServers() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain)
            }

            ScrollView {
                Text(appState.mcpRawOutput.isEmpty ? "（情報なし。更新してください）" : appState.mcpRawOutput)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text("追加: ターミナルで `hermes mcp add <name> --url <endpoint>` または `hermes mcp install <name>`")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .onAppear { Task { await appState.fetchMCPServers() } }
    }
}
