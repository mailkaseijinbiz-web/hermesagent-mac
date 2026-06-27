import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var isSettingsHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // macOS titlebar traffic lights spacing
            Spacer().frame(height: 52)

            // Core Menu Actions
            VStack(spacing: 2) {
                SidebarMenuButton(icon: "square.grid.2x2", title: "ダッシュボード") {
                    appState.view = "dashboard"
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

            // Employee switcher (each employee = isolated context). チャット履歴・新しいチャットは
            // 各行のケバブ（⋮）から右ペインで開く（左ペインのセッション一覧は廃止）。
            if !appState.employees.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    // Pinned employees float to the top; stored order (drag-drop) within each group.
                    ForEach(appState.sidebarEmployees) { emp in
                        let active = appState.activeEmployeeId == emp.id
                        HStack(spacing: 8) {
                            EmployeeAvatar(employee: emp, size: 28)
                            if emp.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8)).foregroundColor(.orange)
                            }
                            Text(emp.name)
                                .font(.system(size: 13, weight: active ? .semibold : .regular))
                                .foregroundColor(active ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer()
                            if appState.isEmployeeBusy(emp.id) {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                            }
                            employeeKebab(emp)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(active ? Color.primary.opacity(0.08) : Color.clear)
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture { appState.switchEmployee(emp.id) }
                        // Drag-and-drop reorder: drag a row onto another to move it before it.
                        .draggable(emp.id) {
                            HStack(spacing: 6) {
                                EmployeeAvatar(employee: emp, size: 18)
                                Text(emp.name).font(.system(size: 12, weight: .medium))
                            }.padding(6)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let dragged = items.first, dragged != emp.id else { return false }
                            appState.moveEmployee(dragged, before: emp.id)
                            return true
                        }
                        .contextMenu { employeeMenuItems(emp) }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.dashed")
                            .font(.system(size: 16)).frame(width: 28, height: 28).foregroundColor(.secondary)
                        Text("全体（社員なし）")
                            .font(.system(size: 13))
                            .foregroundColor(appState.activeEmployeeId == nil ? .primary : .secondary)
                        Spacer()
                        globalKebab
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(appState.activeEmployeeId == nil ? Color.primary.opacity(0.08) : Color.clear)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                    .onTapGesture { appState.switchEmployee(nil) }
                }
                .padding(.horizontal, 12)
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
    }

    // 縦三点（⋮）のケバブアイコン。SF Symbols に縦 ellipsis が無いので水平を90°回転。
    private var kebabLabel: some View {
        Image(systemName: "ellipsis")
            .rotationEffect(.degrees(90))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }

    // 社員行のケバブ（⋮）メニュー: ピン留め / 新しいチャット / チャット履歴 / アプリ開発
    private func employeeKebab(_ emp: Employee) -> some View {
        Menu {
            employeeMenuItems(emp)
        } label: {
            kebabLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // 全体（社員なし）行のケバブ: 新しいチャット / チャット履歴
    private var globalKebab: some View {
        Menu {
            Button {
                appState.switchEmployee(nil)
                appState.handleNewChat()
                appState.view = "chat"
            } label: { Label("新しいチャット", systemImage: "square.and.pencil") }
            Button {
                appState.openChatHistoryPanel(nil)
            } label: { Label("チャット履歴", systemImage: "clock.arrow.circlepath") }
        } label: {
            kebabLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func employeeMenuItems(_ emp: Employee) -> some View {
        Button {
            appState.togglePinEmployee(emp.id)
        } label: {
            Label(emp.isPinned ? "ピン留めを外す" : "ピン留め",
                  systemImage: emp.isPinned ? "pin.slash" : "pin")
        }
        Button {
            appState.switchEmployee(emp.id)
            appState.handleNewChat()
            appState.view = "chat"
        } label: { Label("新しいチャット", systemImage: "square.and.pencil") }
        Button {
            appState.openChatHistoryPanel(emp.id)
        } label: { Label("チャット履歴", systemImage: "clock.arrow.circlepath") }
        Button {
            appState.switchEmployee(emp.id)
            appState.view = "apps"
        } label: { Label("アプリ開発", systemImage: "hammer") }
        Divider()
        Button { appState.openEmployeePanel(emp.id) } label: { Label("右パネルで管理", systemImage: "sidebar.right") }
        Button { appState.openEmployeeDetail(emp.id) } label: { Label("全画面で管理", systemImage: "square.grid.2x2") }
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
