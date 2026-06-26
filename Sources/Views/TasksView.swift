import SwiftUI

/// Phase B — task board (Kanban). Create tasks, assign to employees, move across
/// 未着手 / 対応中 / 完了, and hand a task to its assignee to start it.
struct TasksView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var newTitle = ""
    @State private var newAssignee: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                createBar
                HStack(alignment: .top, spacing: 14) {
                    column(.todo)
                    column(.doing)
                    column(.done)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: 1040)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("タスクボード").font(.system(size: 24, weight: .bold))
                Text("依頼を社員に割り当て、未着手→対応中→完了で管理します。")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            Button { appState.view = "chat" } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary).frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
    }

    private func employee(_ id: String?) -> Employee? {
        id.flatMap { eid in appState.employees.first { $0.id == eid } }
    }

    private var createBar: some View {
        HStack(spacing: 10) {
            TextField("新しいタスク（例: ログイン画面を実装）", text: $newTitle)
                .textFieldStyle(.plain).padding(8)
                .background(Color.primary.opacity(0.05)).cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))

            Menu {
                Button { newAssignee = nil } label: { Label("未割当", systemImage: newAssignee == nil ? "checkmark" : "") }
                ForEach(appState.sortedEmployees) { e in
                    Button { newAssignee = e.id } label: {
                        Label("\(e.role.emoji) \(e.name)", systemImage: newAssignee == e.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle").font(.system(size: 11))
                    Text(employee(newAssignee)?.name ?? "担当者").font(.system(size: 12))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }.foregroundColor(.secondary)
            }.menuStyle(.borderlessButton).fixedSize()

            Button {
                _ = appState.createTask(title: newTitle, assigneeId: newAssignee)
                newTitle = ""
            } label: {
                Text("追加").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .foregroundColor(colorScheme == .dark ? .black : .white).cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(Color.primary.opacity(0.02)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.05), lineWidth: 0.5))
    }

    private func column(_ status: TaskStatus) -> some View {
        let items = appState.tasks(status: status)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: status.icon).font(.system(size: 12)).foregroundColor(.secondary)
                Text(status.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                Text("\(items.count)").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 4)

            if items.isEmpty {
                Text("なし").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                ForEach(items) { task in TaskCard(task: task, assignee: employee(task.assigneeId)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(10)
        .background(Color.primary.opacity(0.03)).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.05), lineWidth: 0.5))
    }
}

struct TaskCard: View {
    @EnvironmentObject var appState: AppState
    let task: WorkTask
    let assignee: Employee?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title).font(.system(size: 13, weight: .medium)).lineLimit(3)

            HStack(spacing: 6) {
                if let a = assignee {
                    Text("\(a.role.emoji) \(a.name)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(a.role.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(a.role.color.opacity(0.12)).cornerRadius(4)
                } else {
                    Menu {
                        ForEach(appState.sortedEmployees) { e in
                            Button("\(e.role.emoji) \(e.name)") { appState.assignTask(task.id, to: e.id) }
                        }
                    } label: {
                        Text("＋ 担当者").font(.system(size: 10)).foregroundColor(.blue)
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                Menu {
                    ForEach(TaskStatus.allCases) { s in
                        Button(s.title) { appState.setTaskStatus(task.id, s) }
                    }
                    Divider()
                    Button(role: .destructive) { appState.deleteTask(task.id) } label: { Label("削除", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundColor(.secondary)
                }.menuStyle(.borderlessButton).fixedSize()
            }

            if task.status != .done, assignee != nil {
                Button { appState.startTask(task.id) } label: {
                    HStack(spacing: 4) { Image(systemName: "paperplane"); Text("担当者に依頼") }
                        .font(.system(size: 11)).foregroundColor(.blue)
                }.buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}
