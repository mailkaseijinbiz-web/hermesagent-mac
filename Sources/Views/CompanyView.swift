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

    private var managers: [Employee] { appState.employees.filter { $0.role == .manager } }
    private var staff: [Employee] { appState.employees.filter { $0.role != .manager } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if appState.employees.isEmpty {
                    emptyState
                } else {
                    if !managers.isEmpty {
                        sectionLabel("マネジメント")
                        VStack(spacing: 8) { ForEach(managers) { EmployeeCard(employee: $0) } }
                        if !staff.isEmpty {
                            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 16)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    sectionLabel("メンバー")
                    VStack(spacing: 8) { ForEach(staff) { EmployeeCard(employee: $0) } }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: 820)
        }
        .sheet(isPresented: $showHire) { HireSheet().environmentObject(appState) }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("会社（AI社員）").font(.system(size: 24, weight: .bold))
                Text("役割を選んでAI社員を採用。社員ごとに会話コンテキストは分離されます。")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
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
            }

            Spacer()

            if isActive {
                Text("対応中").font(.system(size: 11, weight: .semibold)).foregroundColor(.purple)
            }
            if generating { ProgressView().controlSize(.small) }

            Menu {
                Button { appState.switchEmployee(employee.id) } label: { Label("この社員と話す", systemImage: "bubble.left") }
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
