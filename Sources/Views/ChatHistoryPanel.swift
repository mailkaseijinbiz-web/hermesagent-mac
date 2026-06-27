import SwiftUI

/// Right-pane panel listing the active employee's chat history (sessions). Opened from the
/// sidebar kebab menu → チャット履歴. Mirrors the sidebar session list (select / rename / delete)
/// but lives in the right sidebar so the chat stays visible on the left.
struct ChatHistoryPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var hoveredSessionId: String? = nil
    @State private var editingSessionId: String? = nil
    @State private var editingSessionText: String = ""
    @State private var pendingDeleteSession: Session? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clear the floating header bar band.
            Spacer().frame(height: 44)

            header
            Divider().opacity(0.5)
            newChatButton
            Divider().opacity(0.4)

            if appState.visibleSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(appState.visibleSessions) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .scrollIndicators(.visible)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity),
            alignment: .leading
        )
        .confirmationDialog(
            "「\(pendingDeleteSession?.title ?? "")」を削除しますか？",
            isPresented: Binding(get: { pendingDeleteSession != nil },
                                 set: { if !$0 { pendingDeleteSession = nil } }),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let s = pendingDeleteSession {
                    Task { await appState.handleDeleteSession(id: s.id) }
                }
                pendingDeleteSession = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeleteSession = nil }
        } message: {
            Text("この操作は取り消せません。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let emp = appState.activeEmployee {
                EmployeeAvatar(employee: emp, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(emp.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("チャット履歴").font(.system(size: 10)).foregroundColor(.secondary)
                }
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16)).foregroundColor(.secondary).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("全体").font(.system(size: 13, weight: .semibold))
                    Text("チャット履歴").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button { appState.showRightSidebar = false } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("閉じる")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var newChatButton: some View {
        Button {
            appState.handleNewChat()
            appState.view = "chat"
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.system(size: 12))
                Text("新しいチャット").font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ session: Session) -> some View {
        let isActive = appState.currentSessionId == session.id
        return HStack(spacing: 6) {
            if editingSessionId == session.id {
                TextField("", text: $editingSessionText, onCommit: {
                    let newTitle = editingSessionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !newTitle.isEmpty && newTitle != session.title {
                        Task { await appState.handleRenameSession(id: session.id, newTitle: newTitle) }
                    }
                    editingSessionId = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.05)).cornerRadius(4)
            } else {
                Button {
                    appState.handleSelectSession(session)
                    appState.view = "chat"
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 11))
                            .foregroundColor(isActive ? .accentColor : .secondary)
                        Text(session.title)
                            .font(.system(size: 13, weight: isActive ? .medium : .regular))
                            .foregroundColor(isActive ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if hoveredSessionId == session.id && editingSessionId != session.id {
                Button { pendingDeleteSession = session } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundColor(.red.opacity(0.8))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isActive ? Color.primary.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        .onHover { hovering in
            if hovering { hoveredSessionId = session.id }
            else if hoveredSessionId == session.id { hoveredSessionId = nil }
        }
        .contextMenu {
            Button {
                editingSessionId = session.id
                editingSessionText = session.title
            } label: { Label("名前を変更", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { pendingDeleteSession = session } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28)).foregroundColor(.secondary.opacity(0.5))
            Text("チャット履歴はありません")
                .font(.system(size: 12)).foregroundColor(.secondary)
            Text("「新しいチャット」から会話を始めましょう。")
                .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
    }
}
