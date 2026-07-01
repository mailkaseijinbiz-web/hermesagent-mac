import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var isSettingsHovered = false

    private var hasUnreadTasks: Bool {
        appState.workTasks.contains(where: { $0.status == .todo })
    }

    private var isHomeView: Bool {
        appState.view == "home" || appState.view == "dashboard" || appState.view == "lifelog"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // macOS titlebar traffic lights spacing
            Spacer().frame(height: 52)

            // Core Menu Actions
            VStack(spacing: 4) {
                SidebarMenuButton(icon: "house.fill", title: "ホーム",
                                  isSelected: isHomeView) {
                    appState.view = "home"
                }
                SidebarMenuButton(icon: "newspaper", title: "ニュース",
                                  isSelected: appState.view == "news") {
                    appState.view = "news"
                }
                SidebarMenuButton(icon: "checklist", title: "タスク",
                                  hasBadge: hasUnreadTasks,
                                  isSelected: appState.view == "tasks") {
                    appState.view = "tasks"
                }
                SidebarMenuButton(icon: "tray.full", title: "コレクション",
                                  isSelected: appState.view == "collection") {
                    appState.view = "collection"
                }
                SidebarMenuButton(icon: "person.2.fill", title: "社員",
                                  isSelected: appState.view == "company") {
                    appState.view = "company"
                }
            }
            .padding(.horizontal, 12)

            Divider()
                .padding(.vertical, 12)
                .padding(.horizontal, 12)

            // Employee switcher (each employee = isolated context). チャット履歴・新しいチャットは
            // 各行のケバブ（⋮）から右ペインで開く（左ペインのセッション一覧は廃止）。
            if !appState.employees.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    // ピン留めを先頭にしたフラットな社員一覧（チームのセクション分けはしない）。
                    ForEach(appState.sidebarEmployees) { emp in employeeRow(emp) }

                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.dashed")
                            .font(.system(size: 20)).frame(width: 34, height: 34).foregroundColor(.secondary)
                        Text("全体（社員なし）")
                            .font(.system(size: 15))
                            .foregroundColor(appState.activeEmployeeId == nil ? .primary : .secondary)
                        Spacer()
                        globalKebab
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
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
                    .font(.system(size: 17))
                    .foregroundColor((appState.showSettings || isSettingsHovered) ? .primary : .secondary)
                Text("設定")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor((appState.showSettings || isSettingsHovered) ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                appState.openSettings()
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

    // 1社員の行。
    private func employeeRow(_ emp: Employee) -> some View {
        let active = appState.activeEmployeeId == emp.id
        let hasUnread = appState.employeeUnreadIds.contains(emp.id)
        return HStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                EmployeeAvatar(employee: emp, size: 34)
                if hasUnread {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                        .offset(x: 2, y: -2)
                }
            }
            if emp.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(.orange)
            }
            Text(emp.name)
                .font(.system(size: 15, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
            if appState.isEmployeeBusy(emp.id) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            employeeKebab(emp)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(active ? Color.primary.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { appState.switchEmployee(emp.id) }
        .draggable(emp.id) {
            HStack(spacing: 6) {
                EmployeeAvatar(employee: emp, size: 18)
                Text(emp.name).font(.system(size: 14, weight: .medium))
            }.padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first, dragged != emp.id else { return false }
            appState.moveEmployee(dragged, before: emp.id)
            return true
        }
        .contextMenu { employeeMenuItems(emp) }
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
        Divider()
        Button {
            appState.toggleProactiveEmployee(emp.id)
        } label: {
            Label(emp.isProactiveEnabled ? "能動的に話しかける（オン）" : "能動的に話しかける",
                  systemImage: emp.isProactiveEnabled ? "bell.badge.fill" : "bell.badge")
        }
        Button {
            appState.archiveEmployee(emp.id)
        } label: {
            Label("アーカイブ", systemImage: "archivebox")
        }
    }
}

struct SidebarMenuButton: View {
    let icon: String
    let title: String
    var hasBadge: Bool = false
    var isSelected: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 22, alignment: .center)
                    .foregroundColor(isSelected ? .primary : (isHovered ? .primary : .secondary))
                if hasBadge {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: 5, y: -4)
                }
            }
            Text(title)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : (isHovered ? .primary : .secondary))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Color.primary.opacity(0.08) : Color.clear)
        .cornerRadius(6)
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
