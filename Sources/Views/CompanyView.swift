import SwiftUI

// MARK: - Avatar

/// An employee's avatar: a cached/AI-generated image if present, else a deterministic
/// role-colored tile with the initial + a role emoji badge.
struct EmployeeAvatar: View {
    let employee: Employee
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let p = employee.avatarImagePath, let img = NSImage(contentsOfFile: p) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    employee.role.color.opacity(0.22)
                    Text(employee.initials)
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundColor(employee.role.color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(employee.role.color.opacity(0.45), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            Text(employee.role.emoji)
                .font(.system(size: size * 0.3))
                .padding(2)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .offset(x: size * 0.12, y: size * 0.12)
        }
    }
}

// MARK: - Company (roster + hire + org)

struct CompanyView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var showHire = false
    @State private var showMeeting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if appState.employees.isEmpty {
                    emptyState
                } else {
                    teamsSection
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: 820)
        }
        .sheet(isPresented: $showHire) { HireSheet().environmentObject(appState) }
        .sheet(isPresented: $showMeeting) { MeetingSheet().environmentObject(appState) }
        .onAppear { appState.refreshUsage() }
    }

    // MARK: - Org & teams (Phase A)

    private var teamsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("チーム")
                Spacer()
                Button { _ = appState.createTeam(name: "新しいチーム") } label: {
                    HStack(spacing: 4) { Image(systemName: "plus"); Text("チームを作成") }.font(.system(size: 11))
                }.buttonStyle(.plain).foregroundColor(.blue)
            }

            ForEach(appState.teams) { team in teamGroup(team) }

            let unassigned = appState.unassignedEmployees
            if !unassigned.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel(appState.teams.isEmpty ? "メンバー" : "未配属")
                    ForEach(unassigned) { EmployeeCard(employee: $0) }
                }
            }
        }
    }

    private func teamGroup(_ team: Team) -> some View {
        let members = appState.employees(inTeam: team.id)
        let manager = team.managerId.flatMap { mid in appState.employees.first { $0.id == mid } }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill").foregroundColor(.purple).font(.system(size: 12))
                Text(team.name).font(.system(size: 13, weight: .semibold))
                if let m = manager {
                    Text("リーダー: \(m.name)").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Text("\(members.count)名").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Menu {
                    Menu("リーダーを設定") {
                        Button("なし") { appState.setTeamManager(team.id, managerId: nil) }
                        ForEach(appState.employees.filter { $0.role == .manager }) { m in
                            Button(m.name) { appState.setTeamManager(team.id, managerId: m.id) }
                        }
                    }
                    Button(role: .destructive) { appState.deleteTeam(team.id) } label: {
                        Label("チームを削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if members.isEmpty {
                Text("メンバーがいません（社員カードの … →「チームに配属」）")
                    .font(.system(size: 10)).foregroundColor(.secondary).padding(.leading, 4)
            } else {
                ForEach(members) { EmployeeCard(employee: $0) }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.02)).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("会社（AI社員）").font(.system(size: 24, weight: .bold))
                Text("役割を選んでAI社員を採用。社員ごとに会話コンテキストは分離されます。")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            if appState.employees.count >= 2 {
                Button { showMeeting = true } label: {
                    HStack(spacing: 6) { Image(systemName: "person.2.wave.2"); Text("会議") }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.purple.opacity(0.15)).foregroundColor(.purple).cornerRadius(8)
                }.buttonStyle(.plain)
            }
            Button { showHire = true } label: {
                HStack(spacing: 6) { Image(systemName: "person.badge.plus"); Text("採用") }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                    .cornerRadius(8)
            }.buttonStyle(.plain)
            Button { appState.view = "chat" } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary).frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.3.sequence")
                .font(.system(size: 40)).foregroundColor(.secondary.opacity(0.5))
            Text("まだ社員がいません").font(.system(size: 14, weight: .medium))
            Text("「採用」から最初のAI社員（まずはマネージャーがおすすめ）を雇いましょう。")
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button { showHire = true } label: {
                Text("最初の社員を採用").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color.purple.opacity(0.15)).foregroundColor(.purple).cornerRadius(8)
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

// MARK: - Employee card

struct EmployeeCard: View {
    @EnvironmentObject var appState: AppState
    let employee: Employee
    @State private var generating = false
    @State private var renaming = false
    @State private var newName = ""

    private var isActive: Bool { appState.activeEmployeeId == employee.id }
    private var shortModel: String {
        employee.model.contains("/") ? String(employee.model.split(separator: "/").last!) : employee.model
    }

    var body: some View {
        HStack(spacing: 12) {
            EmployeeAvatar(employee: employee, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(employee.name).font(.system(size: 14, weight: .semibold))
                    Text(employee.role.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(employee.role.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(employee.role.color.opacity(0.12)).cornerRadius(4)
                }
                Text("\(shortModel) ・ \(employee.mode == .code ? "コード" : "チャット")")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                if let u = appState.usageByEmployee[employee.id], u.tokens > 0 {
                    Text("\(CompanyFmt.tokens(u.tokens)) tok ・ \(CompanyFmt.cost(u.costUSD))")
                        .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8))
                }
            }

            Spacer()

            if appState.isEmployeeBusy(employee.id) {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("対応中").font(.system(size: 11, weight: .semibold)).foregroundColor(.purple)
                }
            } else if isActive {
                Text("選択中").font(.system(size: 11, weight: .semibold)).foregroundColor(.purple)
            }
            if generating { ProgressView().controlSize(.small) }

            Button { appState.openEmployeePanel(employee.id) } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("タスク・成果物・ファイルを右パネルで管理")

            Menu {
                Button { appState.openEmployeePanel(employee.id) } label: { Label("右パネルで管理", systemImage: "sidebar.right") }
                Button { appState.openEmployeeDetail(employee.id) } label: { Label("全画面で管理", systemImage: "square.grid.2x2") }
                Button { appState.switchEmployee(employee.id) } label: { Label("この社員と話す", systemImage: "bubble.left") }
                Button { newName = employee.name; renaming = true } label: { Label("名前を変更", systemImage: "pencil") }
                Menu {
                    Button { appState.assignEmployee(employee.id, toTeam: nil) } label: {
                        Label("未配属", systemImage: employee.teamId == nil ? "checkmark" : "minus")
                    }
                    ForEach(appState.teams) { t in
                        Button { appState.assignEmployee(employee.id, toTeam: t.id) } label: {
                            Label(t.name, systemImage: employee.teamId == t.id ? "checkmark" : "person.3")
                        }
                    }
                    Divider()
                    Button("新規チームへ") {
                        let t = appState.createTeam(name: "新しいチーム")
                        appState.assignEmployee(employee.id, toTeam: t.id)
                    }
                } label: { Label("チームに配属", systemImage: "person.3") }
                Button { appState.registerAutomationForEmployee(employee.id) } label: {
                    Label("オートメーションに登録", systemImage: "clock.badge.plus")
                }
                Button {
                    generating = true
                    Task { await appState.generateAIAvatar(for: employee.id); generating = false }
                } label: { Label("AIアバターを生成", systemImage: "wand.and.stars") }
                Divider()
                Button(role: .destructive) { appState.fireEmployee(employee.id) } label: {
                    Label("解雇", systemImage: "person.badge.minus")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundColor(.secondary)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(12)
        .background(isActive ? Color.purple.opacity(0.08) : Color.primary.opacity(0.02))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Color.purple.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { appState.switchEmployee(employee.id) }
        .alert("名前を変更", isPresented: $renaming) {
            TextField("名前", text: $newName)
            Button("変更") { appState.renameEmployee(employee.id, name: newName) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(employee.name)」の表示名を変更します。")
        }
    }
}

// MARK: - Hire sheet

struct HireSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var name = ""
    @State private var role: EmployeeRole = .manager

    private let cols = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AI社員を採用").font(.system(size: 18, weight: .bold))

            Text("役割を選択").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(EmployeeRole.catalog) { r in RoleChip(role: r, selected: role == r) { role = r } }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("名前（任意）").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                TextField("例: ハル", text: $name)
                    .textFieldStyle(.plain).padding(8)
                    .background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button {
                    let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? role.title : name
                    let emp = appState.hireEmployee(name: finalName, role: role)
                    appState.switchEmployee(emp.id)
                    dismiss()
                } label: {
                    Text("採用する").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(7)
                }.buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// Compact formatting for usage/cost figures.
enum CompanyFmt {
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
    static func cost(_ usd: Double) -> String {
        if usd <= 0 { return "$0" }
        if usd < 0.01 { return "<$0.01" }
        let yen = Int((usd * 150).rounded())
        return String(format: "$%.2f (¥%d)", usd, yen)
    }
}

// MARK: - Meeting (Phase C)

struct MeetingSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var topic = ""
    @State private var selected: Set<String> = []
    @State private var synthesize = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("会議を開く").font(.system(size: 18, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                Text("議題").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                TextField("例: 新機能の設計方針について意見を出して", text: $topic)
                    .textFieldStyle(.plain).padding(8)
                    .background(Color.primary.opacity(0.05)).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            }

            Text("参加者").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(appState.sortedEmployees) { e in
                        Button {
                            if selected.contains(e.id) { selected.remove(e.id) } else { selected.insert(e.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(e.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selected.contains(e.id) ? .purple : .secondary)
                                Text("\(e.role.emoji) \(e.name)").font(.system(size: 13))
                                Text(e.role.title).font(.system(size: 10)).foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(selected.contains(e.id) ? Color.purple.opacity(0.08) : Color.clear)
                            .cornerRadius(6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 220)

            Toggle(isOn: $synthesize) {
                Text("マネージャーが結論をまとめる").font(.system(size: 12))
            }.toggleStyle(.switch).controlSize(.small)

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button {
                    let ids = appState.employees.map { $0.id }.filter { selected.contains($0) }
                    let t = topic
                    dismiss()
                    Task { await appState.holdMeeting(topic: t, participantIds: ids, synthesize: synthesize) }
                } label: {
                    Text("開催する").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(7)
                }.buttonStyle(.plain)
                .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
            }
        }
        .padding(24).frame(width: 480)
    }
}

struct RoleChip: View {
    let role: EmployeeRole
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(role.emoji).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.title).font(.system(size: 13, weight: .semibold))
                    Text(role.blurb).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(selected ? role.color.opacity(0.14) : Color.primary.opacity(0.03))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? role.color : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
