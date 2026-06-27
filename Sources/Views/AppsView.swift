import SwiftUI
import AppKit

// MARK: - Apps (Phase F)
//
// Manage app projects the AI develops. Each app is a project FOLDER (auto-created under
// the shared dev base). "開発する" points the assigned employee's cwd at that folder and
// opens the chat in code mode with a build instruction — see `AppState.developApp`.

private let appsDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "M/d HH:mm"
    f.locale = Locale(identifier: "ja_JP")
    return f
}()

/// One target for the app editor sheet (new app, or edit existing). A single
/// `.sheet(item:)` avoids stacking two sheets on one view (which can misfire).
private struct AppEditorTarget: Identifiable {
    let id = UUID()
    let existing: AppProject?
}

struct AppsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var editor: AppEditorTarget? = nil
    /// Embedded inside the Settings panel: drop the outer ScrollView (settings scrolls) and
    /// the close-X (settings has its own close), and tighten padding.
    var embedded: Bool = false

    var body: some View {
        Group {
            if embedded {
                listContent
            } else {
                ScrollView { listContent }
            }
        }
        .sheet(item: $editor) { t in AppEditSheet(existing: t.existing).environmentObject(appState) }
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if appState.apps.isEmpty {
                emptyState
            } else {
                ForEach(appState.sortedApps) { app in
                    AppCard(app: app, onEdit: { editor = AppEditorTarget(existing: app) })
                }
            }
        }
        .padding(.horizontal, embedded ? 2 : 32).padding(.vertical, embedded ? 4 : 24)
        .frame(maxWidth: embedded ? .infinity : 940)
        .frame(maxWidth: .infinity, alignment: embedded ? .leading : .center)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("アプリ").font(.system(size: embedded ? 18 : 24, weight: .bold))
                Text("プロジェクトを作成し、担当のAI社員がフォルダ内で開発します。")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            Button { editor = AppEditorTarget(existing: nil) } label: {
                HStack(spacing: 6) { Image(systemName: "plus"); Text("新規アプリ") }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(8)
            }.buttonStyle(.plain)
            if !embedded {
                Button { appState.view = "chat" } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary).frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06)).clipShape(Circle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "hammer").font(.system(size: 40)).foregroundColor(.secondary.opacity(0.5))
            Text("まだアプリがありません").font(.system(size: 14, weight: .medium))
            Text("「新規アプリ」で作成すると、共通フォルダ配下にプロジェクトが作られ、担当社員が開発できます。")
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { editor = AppEditorTarget(existing: nil) } label: {
                Text("最初のアプリを作成").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color.blue.opacity(0.14)).foregroundColor(.blue).cornerRadius(8)
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

// MARK: - App card

struct AppCard: View {
    @EnvironmentObject var appState: AppState
    let app: AppProject
    let onEdit: () -> Void
    @State private var confirmingDelete = false

    private var assignee: Employee? { appState.employees.first { $0.id == app.assigneeId } }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Status-colored tile with the app initial.
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(app.status.color.opacity(0.16))
                Text(String(app.name.trimmingCharacters(in: .whitespaces).prefix(1)))
                    .font(.system(size: 20, weight: .bold)).foregroundColor(app.status.color)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(app.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    statusBadge
                    if appState.isAppRunning(app.id) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("起動中").font(.system(size: 10, weight: .semibold)).foregroundColor(.green)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.12)).cornerRadius(4)
                    }
                }
                if !app.detail.isEmpty {
                    Text(app.detail).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let a = assignee {
                        Label("\(a.role.emoji) \(a.name)", systemImage: "person.crop.circle")
                            .font(.system(size: 10)).foregroundColor(a.role.color)
                    } else {
                        Text("担当者なし").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Text("·").foregroundColor(.secondary)
                    Text((app.folderPath as NSString).lastPathComponent)
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("·").foregroundColor(.secondary)
                    Text(appsDateFmt.string(from: Date(timeIntervalSince1970: app.updatedAt)))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if appState.isAppRunning(app.id) {
                        Button { appState.stopApp(app.id) } label: {
                            HStack(spacing: 5) { Image(systemName: "stop.fill"); Text("停止") }
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Color.red.opacity(0.14)).foregroundColor(.red).cornerRadius(8)
                        }.buttonStyle(.plain)
                        Button { appState.openAppInWindow(app.id) } label: {
                            HStack(spacing: 5) { Image(systemName: "macwindow"); Text("別ウィンドウ") }
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Color.green.opacity(0.14)).foregroundColor(.green).cornerRadius(8)
                        }.buttonStyle(.plain)
                    } else {
                        Button { appState.launchApp(app.id) } label: {
                            HStack(spacing: 5) { Image(systemName: "play.fill"); Text("起動") }
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Color.green.opacity(0.16)).foregroundColor(.green).cornerRadius(8)
                        }.buttonStyle(.plain)
                    }
                    Button { appState.developApp(app.id) } label: {
                        HStack(spacing: 5) { Image(systemName: "hammer.fill"); Text("開発する") }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.blue.opacity(0.14)).foregroundColor(.blue).cornerRadius(8)
                    }.buttonStyle(.plain)
                }

                Menu {
                    if appState.isAppRunning(app.id) {
                        Button { appState.stopApp(app.id) } label: { Label("停止", systemImage: "stop.fill") }
                    } else {
                        Button { appState.launchApp(app.id) } label: { Label("起動", systemImage: "play.fill") }
                    }
                    Button { appState.openAppInWindow(app.id) } label: { Label("別ウィンドウで開く", systemImage: "macwindow") }
                    Button { appState.openAppFolder(app.id) } label: { Label("フォルダを開く", systemImage: "folder") }
                    Button { appState.openAppInTerminal(app.id) } label: { Label("ターミナルで開く", systemImage: "terminal") }
                    Button { appState.previewApp(app.id) } label: { Label("プレビュー（パネル）", systemImage: "safari") }
                    Divider()
                    Menu("担当者") {
                        Button { appState.assignApp(app.id, to: nil) } label: {
                            Label("なし", systemImage: app.assigneeId == nil ? "checkmark" : "minus")
                        }
                        ForEach(appState.sortedEmployees) { e in
                            Button { appState.assignApp(app.id, to: e.id) } label: {
                                Label("\(e.role.emoji) \(e.name)", systemImage: app.assigneeId == e.id ? "checkmark" : "")
                            }
                        }
                    }
                    Menu("状態") {
                        ForEach(AppStatus.allCases) { s in
                            Button { appState.setAppStatus(app.id, s) } label: {
                                Label(s.title, systemImage: app.status == s ? "checkmark" : s.icon)
                            }
                        }
                    }
                    Button { onEdit() } label: { Label("編集", systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("削除（フォルダは残ります）", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13)).foregroundColor(.secondary).frame(width: 26, height: 26)
                }.menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.02)).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .confirmationDialog("「\(app.name)」を削除しますか？", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) { appState.deleteApp(app.id) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("一覧から削除します（プロジェクトフォルダはディスクに残ります）。")
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: app.status.icon).font(.system(size: 9))
            Text(app.status.title).font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(app.status.color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(app.status.color.opacity(0.12)).cornerRadius(4)
    }
}

// MARK: - Create / edit sheet

struct AppEditSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    /// nil → create; non-nil → edit.
    let existing: AppProject?

    @State private var name = ""
    @State private var detail = ""
    @State private var assigneeId: String? = nil
    @State private var previewURL = ""
    @State private var runCommand = ""

    private var assigneeName: String {
        appState.employees.first { $0.id == assigneeId }.map { "\($0.role.emoji) \($0.name)" } ?? "担当者を選択"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "新規アプリ" : "アプリを編集").font(.system(size: 18, weight: .bold))

            field("アプリ名") {
                TextField("例: タスク管理ツール", text: $name)
                    .textFieldStyle(.plain).padding(8)
                    .background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            }

            field("仕様・概要（任意）") {
                TextEditor(text: $detail)
                    .font(.system(size: 13)).frame(minHeight: 110).padding(6)
                    .background(Color.primary.opacity(0.04)).cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            }

            HStack(spacing: 12) {
                field("担当社員（任意）") {
                    Menu {
                        Button { assigneeId = nil } label: { Label("なし", systemImage: assigneeId == nil ? "checkmark" : "minus") }
                        ForEach(appState.sortedEmployees) { e in
                            Button { assigneeId = e.id } label: {
                                Label("\(e.role.emoji) \(e.name)", systemImage: assigneeId == e.id ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack { Text(assigneeName).font(.system(size: 12)); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)) }
                            .foregroundColor(.secondary).padding(8)
                            .background(Color.primary.opacity(0.05)).cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    }.menuStyle(.borderlessButton)
                }
            }

            HStack(spacing: 12) {
                field("プレビューURL（任意）") {
                    TextField("http://localhost:3000", text: $previewURL)
                        .textFieldStyle(.plain).padding(8)
                        .background(Color.primary.opacity(0.05)).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                }
                field("起動コマンド（任意）") {
                    TextField("npm run dev", text: $runCommand)
                        .textFieldStyle(.plain).padding(8)
                        .background(Color.primary.opacity(0.05)).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                }
            }

            if existing == nil {
                Text("作成すると \((appState.githubCloneBase as NSString).lastPathComponent)/ の下にアプリ名のフォルダが自動作成されます。")
                    .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8))
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button(action: save) {
                    Text(existing == nil ? "作成" : "保存").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(7)
                }.buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 540)
        .onAppear {
            if let e = existing {
                name = e.name; detail = e.detail; assigneeId = e.assigneeId
                previewURL = e.previewURL; runCommand = e.runCommand
            }
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            content()
        }
    }

    private func save() {
        if let e = existing {
            appState.updateApp(e.id, name: name, detail: detail, previewURL: previewURL, runCommand: runCommand)
            if assigneeId != e.assigneeId { appState.assignApp(e.id, to: assigneeId) }
        } else {
            appState.createApp(name: name, detail: detail, assigneeId: assigneeId,
                               previewURL: previewURL, runCommand: runCommand)
        }
        dismiss()
    }
}
