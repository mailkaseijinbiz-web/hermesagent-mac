import SwiftUI
import AppKit

// MARK: - Per-employee management (Phase E)
//
// A dedicated screen for ONE employee: their tasks, artifacts (成果物) and the files
// in their working folder. Opened from the company roster / sidebar context menu via
// `AppState.openEmployeeDetail`.

private let empDetailDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "M/d HH:mm"
    f.locale = Locale(identifier: "ja_JP")
    return f
}()

enum EmployeeDetailTab: String, CaseIterable, Identifiable {
    // 概要は「タブ」ではなくパネル上部に常時表示する（下の各ビュー参照）。タブは以下4つ。
    case tasks, artifacts, files, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tasks: return "タスク"
        case .artifacts: return "アーティファクト"
        case .files: return "ファイル"
        case .history: return "チャット履歴"
        }
    }
    var icon: String {
        switch self {
        case .tasks: return "checklist"
        case .artifacts: return "shippingbox"
        case .files: return "folder"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct EmployeeDetailView: View {
    @EnvironmentObject var appState: AppState
    @State private var tab: EmployeeDetailTab = .tasks

    var body: some View {
        // Read fresh each render so edits (workspace, artifacts, tasks) reflect live.
        if let emp = appState.detailEmployee {
            VStack(alignment: .leading, spacing: 0) {
                // Clear the floating header bar (its right-side icons live in this band).
                Spacer().frame(height: 44)
                header(emp)
                tabBar
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 概要（統計・作業フォルダ・クイック操作）は常にトップに表示。
                        EmpOverviewTab(employee: emp, tab: $tab)
                        Divider().opacity(0.4)
                        Group {
                            switch tab {
                            case .tasks:     EmpTasksTab(employee: emp)
                            case .artifacts: EmpArtifactsTab(employee: emp)
                            case .files:     EmpFilesTab(employee: emp)
                            case .history:   EmpHistoryTab(employee: emp)
                            }
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 22)
                    .frame(maxWidth: 940, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                // Reset per-employee tab @State (file browser dir/listing, etc.) when the
                // managed employee changes while the screen stays mounted.
                .id(emp.id)
            }
        } else {
            // Employee gone (e.g. fired) — bounce back to the roster.
            VStack(spacing: 12) {
                Text("社員が見つかりません").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                Button("社員に戻る") { appState.view = "company" }.buttonStyle(.plain).foregroundColor(.blue)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header

    private func header(_ emp: Employee) -> some View {
        let u = appState.usageByEmployee[emp.id]
        return HStack(alignment: .top, spacing: 14) {
            EmployeeAvatar(employee: emp, size: 56)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(emp.name).font(.system(size: 22, weight: .bold))
                    Text(emp.role.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(emp.role.color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(emp.role.color.opacity(0.12)).cornerRadius(5)
                    if appState.isEmployeeBusy(emp.id) {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("対応中").font(.system(size: 10, weight: .semibold)).foregroundColor(.purple)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Label(shortModel(emp.model), systemImage: "cpu")
                    Label(emp.mode == .code ? "コード" : "チャット", systemImage: emp.mode.icon)
                    if let u = u, u.tokens > 0 {
                        Label("\(CompanyFmt.tokens(u.tokens)) tok ・ \(CompanyFmt.cost(u.costUSD))", systemImage: "yensign.circle")
                    }
                }
                .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Button { appState.switchEmployee(emp.id) } label: {
                HStack(spacing: 5) { Image(systemName: "bubble.left"); Text("この社員と話す") }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.purple.opacity(0.14)).foregroundColor(.purple).cornerRadius(8)
            }.buttonStyle(.plain)
            Button { appState.view = "company" } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary).frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 32).padding(.top, 18).padding(.bottom, 14)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(EmployeeDetailTab.allCases) { t in
                let active = tab == t
                Button { tab = t } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 11))
                        Text(t.title).font(.system(size: 12, weight: active ? .semibold : .regular))
                        Text(countBadge(t)).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                            .opacity(countBadge(t).isEmpty ? 0 : 1)
                    }
                    .foregroundColor(active ? .primary : .secondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(active ? Color.primary.opacity(0.08) : Color.clear)
                    .cornerRadius(8)
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 28).padding(.bottom, 8)
    }

    private func countBadge(_ t: EmployeeDetailTab) -> String {
        guard let emp = appState.detailEmployee else { return "" }
        switch t {
        case .tasks:
            let n = appState.tasks(for: emp.id).count
            return n > 0 ? "\(n)" : ""
        case .artifacts:
            let n = appState.artifactsFor(emp.id).count
            return n > 0 ? "\(n)" : ""
        default: return ""
        }
    }

    private func shortModel(_ m: String) -> String {
        m.contains("/") ? String(m.split(separator: "/").last!) : m
    }
}

// MARK: - Overview tab

private struct EmpOverviewTab: View {
    @EnvironmentObject var appState: AppState
    let employee: Employee
    @Binding var tab: EmployeeDetailTab

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Workspace
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("作業フォルダ")
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundColor(.secondary)
                    Text(employee.workspacePath ?? "未設定（共通の作業フォルダで動作）")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(employee.workspacePath == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(employee.workspacePath == nil ? "設定" : "変更") { pickFolder() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(.blue)
                }
                .padding(12).background(Color.primary.opacity(0.03)).cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "作業フォルダを選択"
        panel.prompt = "設定"
        if let p = employee.workspacePath { panel.directoryURL = URL(fileURLWithPath: p) }
        if panel.runModal() == .OK, let url = panel.url {
            appState.setEmployeeWorkspace(employee.id, path: url.path)
        }
    }

    private func stat(_ label: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11)).foregroundColor(color)
                Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Text(value).font(.system(size: 22, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(Color.primary.opacity(0.03)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    private func action(_ label: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 6) { Image(systemName: icon); Text(label) }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .foregroundColor(.primary.opacity(0.85))
                .background(Color.primary.opacity(0.05)).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
    }
}

// MARK: - Tasks tab

private struct EmpTasksTab: View {
    @EnvironmentObject var appState: AppState
    let employee: Employee
    @State private var newTitle = ""
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Create bar — assignee fixed to this employee.
            HStack(spacing: 10) {
                TextField("\(employee.name) の新しいタスク", text: $newTitle)
                    .textFieldStyle(.plain).padding(8)
                    .background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .onSubmit(add)
                Button(action: add) {
                    Text("追加").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(6)
                }.buttonStyle(.plain)
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12).background(Color.primary.opacity(0.02)).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.05), lineWidth: 0.5))

            if appState.tasks(for: employee.id).isEmpty {
                emptyState("この社員のタスクはまだありません", "checklist")
            } else {
                ForEach(TaskStatus.allCases) { status in
                    let items = appState.tasks(for: employee.id, status: status)
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: status.icon).font(.system(size: 12)).foregroundColor(.secondary)
                                Text(status.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                                Text("\(items.count)").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.7))
                            }
                            ForEach(items) { task in
                                TaskCard(task: task, assignee: employee)
                            }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        appState.createTask(title: t, assigneeId: employee.id)
        newTitle = ""
    }

    private func emptyState(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundColor(.secondary.opacity(0.5))
            Text(text).font(.system(size: 12)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
    }
}

// MARK: - Artifacts tab

/// One target for the artifact editor sheet — a new artifact of `kind`, or an edit of
/// `existing`. A single `.sheet(item:)` avoids stacking two sheets on one view.
private struct ArtifactEditorTarget: Identifiable {
    let id = UUID()
    let kind: ArtifactKind
    let existing: Artifact?
}

private struct EmpArtifactsTab: View {
    @EnvironmentObject var appState: AppState
    let employee: Employee
    @State private var editorTarget: ArtifactEditorTarget? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("成果物・メモ・参照").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Menu {
                    Button { editorTarget = ArtifactEditorTarget(kind: .note, existing: nil) } label: { Label("メモを作成", systemImage: "note.text") }
                    Button { editorTarget = ArtifactEditorTarget(kind: .link, existing: nil) } label: { Label("リンクを追加", systemImage: "link") }
                    Button { addFile() } label: { Label("ファイルから追加", systemImage: "doc.badge.plus") }
                } label: {
                    HStack(spacing: 4) { Image(systemName: "plus"); Text("追加") }
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.blue)
                }.menuStyle(.borderlessButton).fixedSize()
            }

            let items = appState.artifactsFor(employee.id)
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox").font(.system(size: 30)).foregroundColor(.secondary.opacity(0.5))
                    Text("成果物はまだありません").font(.system(size: 12)).foregroundColor(.secondary)
                    Text("メモ・リンク・ファイルを追加するか、チャット返信を「成果物として保存」できます。")
                        .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 44)
            } else {
                ForEach(items) { a in
                    ArtifactRow(artifact: a, employee: employee,
                                onEdit: { editorTarget = ArtifactEditorTarget(kind: a.kind, existing: a) })
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            ArtifactEditorSheet(employeeId: employee.id, kind: target.kind, existing: target.existing)
                .environmentObject(appState)
        }
    }

    private func addFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "成果物として追加するファイルを選択"
        panel.prompt = "追加"
        if let p = employee.workspacePath { panel.directoryURL = URL(fileURLWithPath: p) }
        if panel.runModal() == .OK {
            for url in panel.urls {
                appState.addArtifact(employeeId: employee.id, title: url.lastPathComponent,
                                     kind: .file, body: url.path)
            }
        }
    }
}

private struct ArtifactRow: View {
    @EnvironmentObject var appState: AppState
    let artifact: Artifact
    let employee: Employee
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: artifact.kind.icon)
                .font(.system(size: 14)).foregroundColor(artifact.kind.color)
                .frame(width: 30, height: 30)
                .background(artifact.kind.color.opacity(0.12)).cornerRadius(7)

            VStack(alignment: .leading, spacing: 3) {
                Text(artifact.title.isEmpty ? "(無題)" : artifact.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(artifact.kind.title).foregroundColor(artifact.kind.color)
                    if artifact.kind == .file {
                        Text(fileExists ? subtitleDetail : "ファイルが見つかりません")
                            .foregroundColor(fileExists ? .secondary : .red.opacity(0.8))
                            .lineLimit(1).truncationMode(.middle)
                    } else if artifact.kind == .link {
                        Text(artifact.body).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(empDetailDateFmt.string(from: Date(timeIntervalSince1970: artifact.updatedAt)))
                            .foregroundColor(.secondary)
                    }
                }
                .font(.system(size: 10))
            }
            Spacer()

            Button(action: open) {
                Text(primaryActionLabel).font(.system(size: 11, weight: .semibold)).foregroundColor(.blue)
            }.buttonStyle(.plain)

            Menu {
                Button { open() } label: { Label(primaryActionLabel, systemImage: openIcon) }
                if artifact.kind == .note {
                    Button { copyBody() } label: { Label("本文をコピー", systemImage: "doc.on.doc") }
                }
                if artifact.kind == .file {
                    Button { reveal() } label: { Label("Finderで表示", systemImage: "folder") }
                    Button { relink() } label: { Label("ファイルを再リンク", systemImage: "arrow.triangle.2.circlepath") }
                }
                if artifact.kind != .file {
                    Button { onEdit() } label: { Label("編集", systemImage: "pencil") }
                }
                Divider()
                Button(role: .destructive) { appState.deleteArtifact(artifact.id) } label: {
                    Label("削除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundColor(.secondary).frame(width: 24, height: 24)
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(10)
        .background(Color.primary.opacity(0.02)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { open() }
    }

    private var fileExists: Bool { FileManager.default.fileExists(atPath: artifact.body) }
    private var subtitleDetail: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: artifact.body)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    private var openIcon: String {
        switch artifact.kind { case .note: return "doc.text"; case .file: return "arrow.up.forward.app"; case .link: return "safari" }
    }
    private var primaryActionLabel: String {
        switch artifact.kind { case .note: return "開く"; case .file: return "開く"; case .link: return "リンクを開く" }
    }

    private func open() {
        switch artifact.kind {
        case .note: onEdit()
        case .file:
            guard fileExists else { appState.triggerToast(message: "ファイルが見つかりません"); return }
            NSWorkspace.shared.open(URL(fileURLWithPath: artifact.body))
        case .link:
            var s = artifact.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.contains("://") { s = "https://" + s }
            if let url = URL(string: s) { NSWorkspace.shared.open(url) }
        }
    }
    private func reveal() {
        guard fileExists else { appState.triggerToast(message: "ファイルが見つかりません"); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.body)])
    }
    /// Re-point a file artifact at a new path (recovers a moved/renamed/missing file).
    private func relink() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "リンク先のファイルを選択"
        panel.prompt = "再リンク"
        if fileExists {
            panel.directoryURL = URL(fileURLWithPath: artifact.body).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            appState.updateArtifact(artifact.id, title: url.lastPathComponent, body: url.path)
        }
    }
    private func copyBody() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(artifact.body, forType: .string)
        appState.triggerToast(message: "コピーしました")
    }
}

private struct ArtifactEditorSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    let employeeId: String
    let kind: ArtifactKind
    let existing: Artifact?

    @State private var title = ""
    @State private var body_ = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "\(kind.title)を追加" : "\(kind.title)を編集")
                .font(.system(size: 16, weight: .bold))

            VStack(alignment: .leading, spacing: 5) {
                Text("タイトル").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                TextField(kind == .link ? "例: 参考リンク" : "例: 設計メモ", text: $title)
                    .textFieldStyle(.plain).padding(8)
                    .background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(kind == .link ? "URL" : "本文（Markdown）")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                if kind == .link {
                    TextField("https://…", text: $body_)
                        .textFieldStyle(.plain).padding(8)
                        .background(Color.primary.opacity(0.05)).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                } else {
                    TextEditor(text: $body_)
                        .font(.system(size: 13))
                        .frame(minHeight: 180)
                        .padding(6)
                        .background(Color.primary.opacity(0.04)).cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                }
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button(action: save) {
                    Text("保存").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(7)
                }.buttonStyle(.plain)
                .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 520)
        .onAppear {
            if let e = existing { title = e.title; body_ = e.body }
        }
    }

    private func save() {
        if let e = existing {
            appState.updateArtifact(e.id, title: title, body: body_)
        } else {
            appState.addArtifact(employeeId: employeeId, title: title, kind: kind, body: body_)
        }
        dismiss()
    }
}

// MARK: - Files tab (working folder browser)

private struct DirEntry: Identifiable, Hashable {
    let id: String        // absolute path
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Date
    var url: URL { URL(fileURLWithPath: id) }
}

private struct EmpFilesTab: View {
    @EnvironmentObject var appState: AppState
    let employee: Employee
    @State private var current: String? = nil   // current directory within the workspace
    @State private var entries: [DirEntry] = []
    @State private var previewEntry: DirEntry? = nil  // non-nil → show inline file preview

    private var root: String? { employee.workspacePath }

    private static let previewExtensions: Set<String> = [
        "md", "markdown", "txt",
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry = previewEntry {
                FilePreviewPanel(entry: entry) { previewEntry = nil }
            } else if root == nil {
                noWorkspaceState
            } else {
                toolbar
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 28)).foregroundColor(.secondary.opacity(0.5))
                        Text("このフォルダは空です").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    ForEach(entries) { entry in fileRow(entry) }
                }
            }
        }
        .onAppear { if current == nil { current = root }; reload() }
        // Re-root if the workspace folder changed while the tab is open.
        .onChange(of: employee.workspacePath) { _, newRoot in
            current = newRoot
            previewEntry = nil
            reload()
        }
    }

    private var noWorkspaceState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark").font(.system(size: 34)).foregroundColor(.secondary.opacity(0.5))
            Text("作業フォルダが未設定です").font(.system(size: 13, weight: .medium))
            Text("社員ごとに作業フォルダを設定すると、その中身を一覧でき、エージェントもそのフォルダで動作します。")
                .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button { pickFolder() } label: {
                HStack(spacing: 5) { Image(systemName: "folder.badge.plus"); Text("作業フォルダを設定") }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.blue.opacity(0.14)).foregroundColor(.blue).cornerRadius(8)
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if canGoUp {
                Button { goUp() } label: {
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        .frame(width: 26, height: 26).background(Color.primary.opacity(0.05)).cornerRadius(6)
                }.buttonStyle(.plain).help("上の階層へ")
            }
            Image(systemName: "folder").font(.system(size: 11)).foregroundColor(.secondary)
            Text(relativePath).font(.system(size: 12, design: .monospaced)).foregroundColor(.primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { reload() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundColor(.secondary) }
                .buttonStyle(.plain).help("更新")
            Button { revealCurrent() } label: { Image(systemName: "macwindow.on.rectangle").font(.system(size: 12)).foregroundColor(.secondary) }
                .buttonStyle(.plain).help("Finderで開く")
            Button { pickFolder() } label: { Image(systemName: "folder.badge.gearshape").font(.system(size: 12)).foregroundColor(.secondary) }
                .buttonStyle(.plain).help("作業フォルダを変更")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.03)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    private func fileRow(_ entry: DirEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDir ? "folder.fill" : iconFor(entry.name))
                .font(.system(size: 14)).foregroundColor(entry.isDir ? .blue : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: 13, weight: entry.isDir ? .medium : .regular)).lineLimit(1)
                Text(entry.isDir ? "フォルダ" : "\(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)) ・ \(empDetailDateFmt.string(from: entry.modified))")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            if entry.isDir {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary.opacity(0.6))
            } else {
                Menu {
                    Button { NSWorkspace.shared.open(entry.url) } label: { Label("開く", systemImage: "arrow.up.forward.app") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Label("Finderで表示", systemImage: "folder") }
                    Button {
                        appState.addArtifact(employeeId: employee.id, title: entry.name, kind: .file, body: entry.id)
                    } label: { Label("成果物に追加", systemImage: "shippingbox") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13)).foregroundColor(.secondary).frame(width: 24, height: 24)
                }.menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.02)).cornerRadius(9)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.05), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDir {
                current = entry.id; reload()
            } else {
                let ext = (entry.name as NSString).pathExtension.lowercased()
                if Self.previewExtensions.contains(ext) {
                    previewEntry = entry
                } else {
                    NSWorkspace.shared.open(entry.url)
                }
            }
        }
    }

    // MARK: helpers

    private var canGoUp: Bool {
        guard let root = root, let cur = current else { return false }
        return cur != root && cur.hasPrefix(root)
    }
    private var relativePath: String {
        guard let root = root, let cur = current else { return current ?? "" }
        if cur == root { return (root as NSString).lastPathComponent }
        // Strip only the leading root prefix (not every occurrence) so a descendant
        // folder that re-contains the root string isn't mangled.
        let rel = cur.hasPrefix(root) ? String(cur.dropFirst(root.count)) : cur
        return (root as NSString).lastPathComponent + rel
    }

    private func goUp() {
        guard let cur = current, canGoUp else { return }
        current = (cur as NSString).deletingLastPathComponent
        reload()
    }
    private func revealCurrent() {
        if let cur = current { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cur)]) }
    }
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "作業フォルダを選択"
        panel.prompt = "設定"
        if let p = root { panel.directoryURL = URL(fileURLWithPath: p) }
        if panel.runModal() == .OK, let url = panel.url {
            appState.setEmployeeWorkspace(employee.id, path: url.path)
        }
    }

    private func reload() {
        guard let path = current else { entries = []; return }
        entries = Self.list(path)
    }

    private static func list(_ path: String) -> [DirEntry] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let out = items.map { u -> DirEntry in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return DirEntry(id: u.path, name: u.lastPathComponent,
                            isDir: v?.isDirectory ?? false,
                            size: Int64(v?.fileSize ?? 0),
                            modified: v?.contentModificationDate ?? .distantPast)
        }
        return out.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func iconFor(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "md", "markdown", "txt": return "doc.text"
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml": return "curlybraces"
        case "zip", "tar", "gz", "dmg": return "archivebox"
        case "mp4", "mov", "m4v": return "film"
        case "mp3", "wav", "m4a": return "music.note"
        default: return "doc"
        }
    }
}

// MARK: - File preview panel (MD / image inline viewer)

private struct FilePreviewPanel: View {
    let entry: DirEntry
    let onDismiss: () -> Void

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif"]
    private static let textExtensions: Set<String> = ["md", "markdown", "txt"]

    private var ext: String { (entry.name as NSString).pathExtension.lowercased() }
    private var isImage: Bool { Self.imageExtensions.contains(ext) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar with back button
            HStack(spacing: 8) {
                Button(action: onDismiss) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("戻る").font(.system(size: 12))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                Divider().frame(height: 14)
                Image(systemName: isImage ? "photo" : "doc.text")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                } label: {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundColor(.secondary)
                }.buttonStyle(.plain).help("Finderで表示")
                Button {
                    NSWorkspace.shared.open(entry.url)
                } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11)).foregroundColor(.secondary)
                }.buttonStyle(.plain).help("外部アプリで開く")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.primary.opacity(0.03)).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))

            Spacer().frame(height: 12)

            if isImage {
                ImagePreview(path: entry.id)
            } else {
                MarkdownPreview(path: entry.id)
            }
        }
    }
}

private struct ImagePreview: View {
    let path: String

    var body: some View {
        if let img = NSImage(contentsOfFile: path) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(8)
                    .frame(maxWidth: .infinity)
            }
        } else {
            Text("画像を読み込めませんでした").font(.system(size: 12)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }
}

private struct MarkdownPreview: View {
    let path: String
    @State private var content: String = ""

    var body: some View {
        ScrollView {
            if let attr = try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .full)
            ) {
                Text(attr)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { loadContent() }
    }

    private func loadContent() {
        guard let data = FileManager.default.contents(atPath: path),
              let str = String(data: data, encoding: .utf8)
               ?? String(data: data, encoding: .isoLatin1) else {
            content = "（ファイルを読み込めませんでした）"
            return
        }
        // Cap at 200 kB to avoid freezing the UI with huge files.
        if str.utf8.count > 200_000 {
            content = String(str.prefix(200_000)) + "\n\n…（以降省略）"
        } else {
            content = str
        }
    }
}

// MARK: - Right-side panel
//
// The same per-employee management (タスク / 成果物 / ファイル), but docked in the RIGHT
// sidebar and scoped to the ACTIVE employee — so you can keep chatting on the left while
// checking their work on the right. Reuses the detail tabs above.

// MARK: - Chat history tab

/// この社員のチャット履歴（セッション一覧）。行タップでその社員に切替えてチャットを開く。
private struct EmpHistoryTab: View {
    @EnvironmentObject var appState: AppState
    let employee: Employee

    var body: some View {
        let sessions = appState.employeeSessions(employee.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("チャット履歴").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Button {
                    appState.switchEmployee(employee.id)
                    appState.handleNewChat()
                    appState.view = "chat"
                } label: {
                    HStack(spacing: 5) { Image(systemName: "square.and.pencil"); Text("新しいチャット") }
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.accentColor)
                }.buttonStyle(.plain)
            }
            if sessions.isEmpty {
                Text("チャット履歴はありません。")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            } else {
                VStack(spacing: 4) {
                    ForEach(sessions) { s in
                        let isActive = appState.currentSessionId == s.id
                        Button {
                            appState.switchEmployee(employee.id)
                            appState.handleSelectSession(s)
                            appState.view = "chat"
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "bubble.left").font(.system(size: 11))
                                    .foregroundColor(isActive ? .accentColor : .secondary)
                                Text(s.title).font(.system(size: 13, weight: isActive ? .medium : .regular))
                                    .foregroundColor(.primary).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(isActive ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03))
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct EmployeeSidePanel: View {
    @EnvironmentObject var appState: AppState
    @State private var tab: EmployeeDetailTab = .tasks

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clear the floating header bar band.
            Spacer().frame(height: 44)
            if let emp = appState.activeEmployee {
                header(emp)
                Divider().opacity(0.5)
                tabBar
                Divider().opacity(0.4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 概要は常にトップに表示。
                        EmpOverviewTab(employee: emp, tab: $tab)
                        Divider().opacity(0.4)
                        Group {
                            switch tab {
                            case .tasks:     EmpTasksTab(employee: emp)
                            case .artifacts: EmpArtifactsTab(employee: emp)
                            case .files:     EmpFilesTab(employee: emp)
                            case .history:   EmpHistoryTab(employee: emp)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 14)
                }
                .id(emp.id)   // reset per-employee tab state when the active employee changes
            } else {
                noEmployee
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity),
            alignment: .leading
        )
    }

    private func header(_ emp: Employee) -> some View {
        HStack(spacing: 10) {
            EmployeeAvatar(employee: emp, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(emp.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(emp.role.title).font(.system(size: 10)).foregroundColor(emp.role.color)
            }
            Spacer()
            Button { appState.showRightSidebar = false; appState.openEmployeeDetail(emp.id) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("全画面で開く")
            Button { appState.showRightSidebar = false } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("閉じる")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(EmployeeDetailTab.allCases) { t in
                let active = tab == t
                Button { tab = t } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 10))
                        Text(shortLabel(t)).font(.system(size: 11, weight: active ? .semibold : .regular))
                    }
                    .foregroundColor(active ? .primary : .secondary)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(active ? Color.primary.opacity(0.08) : Color.clear)
                    .cornerRadius(7)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func shortLabel(_ t: EmployeeDetailTab) -> String {
        switch t {
        case .tasks: return "タスク"
        case .artifacts: return "成果物"
        case .files: return "ファイル"
        case .history: return "チャット履歴"
        }
    }

    private var noEmployee: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.crop.circle.dashed").font(.system(size: 32)).foregroundColor(.secondary.opacity(0.5))
            Text("社員が選択されていません").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            Text("社員を選ぶと、その社員のタスク・成果物・ファイルをここに表示します。")
                .font(.system(size: 11)).foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center).frame(maxWidth: 220)
            Button { appState.view = "company" } label: {
                Text("社員を開く").font(.system(size: 11, weight: .semibold)).foregroundColor(.blue)
            }.buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }
}
