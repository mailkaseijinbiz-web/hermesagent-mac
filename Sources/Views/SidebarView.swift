import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var hoveredSessionId: String? = nil
    @State private var editingSessionId: String? = nil
    @State private var editingSessionText: String = ""
    @State private var isSettingsHovered = false
    @State private var pendingDeleteSession: Session? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // macOS titlebar traffic lights spacing
            Spacer().frame(height: 52)
            
            // Core Menu Actions
            VStack(spacing: 2) {
                SidebarMenuButton(icon: "doc.text", title: "新しいチャット") {
                    appState.handleNewChat()
                    appState.view = "chat"
                }
                SidebarMenuButton(icon: "person.3", title: "会社（AI社員）") {
                    appState.view = "company"
                }
                SidebarMenuButton(icon: "checklist", title: "タスク") {
                    appState.view = "tasks"
                }
                SidebarMenuButton(icon: "clock", title: "オートメーション") {
                    appState.view = "automations"
                    Task {
                        await appState.fetchCronJobs()
                    }
                }
            }
            .padding(.horizontal, 12)
            
            Divider()
                .padding(.vertical, 12)
                .padding(.horizontal, 12)

            // Employee switcher (each employee = isolated context)
            if !appState.employees.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("社員")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 2)

                    ForEach(appState.sortedEmployees) { emp in
                        let active = appState.activeEmployeeId == emp.id
                        HStack(spacing: 8) {
                            EmployeeAvatar(employee: emp, size: 22)
                            Text(emp.name)
                                .font(.system(size: 13, weight: active ? .semibold : .regular))
                                .foregroundColor(active ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer()
                            if appState.isEmployeeBusy(emp.id) {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(active ? Color.primary.opacity(0.08) : Color.clear)
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture { appState.switchEmployee(emp.id) }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.dashed")
                            .font(.system(size: 13)).frame(width: 22, height: 22).foregroundColor(.secondary)
                        Text("全体（社員なし）")
                            .font(.system(size: 13))
                            .foregroundColor(appState.activeEmployeeId == nil ? .primary : .secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(appState.activeEmployeeId == nil ? Color.primary.opacity(0.08) : Color.clear)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                    .onTapGesture { appState.switchEmployee(nil) }
                }
                .padding(.horizontal, 12)

                Divider()
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
            }

            // Sessions Section
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.activeEmployee.map { "\($0.name) のチャット" } ?? "チャット")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(appState.visibleSessions) { session in
                            let isActive = appState.currentSessionId == session.id
                            HStack {
                                if editingSessionId == session.id {
                                    TextField("", text: $editingSessionText, onCommit: {
                                        let newTitle = editingSessionText.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !newTitle.isEmpty && newTitle != session.title {
                                            Task {
                                                await appState.handleRenameSession(id: session.id, newTitle: newTitle)
                                            }
                                        }
                                        editingSessionId = nil
                                    })
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, weight: .light))
                                    .foregroundColor(.primary)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.05))
                                    .cornerRadius(4)
                                } else {
                                    Button(action: {
                                        appState.handleSelectSession(session)
                                        appState.view = "chat"
                                    }) {
                                        HStack {
                                            Text(session.title)
                                                .font(.system(size: 13, weight: isActive ? .medium : .light))
                                                .foregroundColor(isActive ? .primary : .secondary)
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }

                                if hoveredSessionId == session.id {
                                    Button(action: {
                                        pendingDeleteSession = session
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 11))
                                            .foregroundColor(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isActive ? Color.primary.opacity(0.08) : Color.clear)
                            .cornerRadius(6)
                            .onHover { isHovered in
                                if isHovered {
                                    hoveredSessionId = session.id
                                    NSCursor.pointingHand.push()
                                } else {
                                    if hoveredSessionId == session.id {
                                        hoveredSessionId = nil
                                    }
                                    NSCursor.pop()
                                }
                            }
                            .contextMenu {
                                Button(action: {
                                    editingSessionId = session.id
                                    editingSessionText = session.title
                                }) {
                                    Label("名前を変更", systemImage: "pencil")
                                }
                                
                                Divider()
                                
                                Button(role: .destructive, action: {
                                    pendingDeleteSession = session
                                }) {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.visible)   // thin rounded macOS overlay scrollbar
            }

            Spacer()

            // Footer
            Divider()
            
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .foregroundColor((appState.showSettings || isSettingsHovered) ? .primary : .secondary)
                Text("設定")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor((appState.showSettings || isSettingsHovered) ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                appState.showSettings = true
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isSettingsHovered = hovering
                }
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
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
}

struct SidebarMenuButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundColor(isHovered ? .primary : .secondary)
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(isHovered ? .primary : .secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
