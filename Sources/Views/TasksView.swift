import SwiftUI

/// Phase B — task board (Kanban). Create tasks, assign to employees, move across
/// 未着手 / 対応中 / 完了, and hand a task to its assignee to start it.
struct TasksView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var newTitle = ""
    @State private var newAssignee: String? = nil
    /// Which column is currently under a dragged card — drives the drop highlight.
    @State private var dropTarget: TaskStatus? = nil

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
            .padding(.horizontal, 32).padding(.top, 52).padding(.bottom, 24)
            .frame(maxWidth: 1040)
        }
        .ignoresSafeArea(edges: .top)
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
        let active = dropTarget == status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: status.icon).font(.system(size: 12)).foregroundColor(.secondary)
                Text(status.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                Text("\(items.count)").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 4)

            if items.isEmpty {
                Text(active ? "ここにドロップ" : "なし")
                    .font(.system(size: 11)).foregroundColor(active ? .accentColor : .secondary.opacity(0.6))
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                ForEach(items) { task in
                    TaskCard(task: task, assignee: employee(task.assigneeId))
                        .draggable(task.id) { dragPreview(task) }
                        .dropDestination(for: String.self) { ids, _ in
                            dropTarget = nil
                            guard let id = ids.first else { return false }
                            appState.moveTask(id, to: status, before: task.id)
                            return true
                        } isTargeted: { over in if over { dropTarget = status } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(10)
        .background(active ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(active ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.05),
                    lineWidth: active ? 1.5 : 0.5))
        .animation(.easeOut(duration: 0.12), value: active)
        .dropDestination(for: String.self) { ids, _ in
            dropTarget = nil
            guard let id = ids.first else { return false }
            appState.moveTask(id, to: status, before: nil)
            return true
        } isTargeted: { over in if over { dropTarget = status } }
    }

    /// Lightweight drag preview shown under the cursor while moving a card.
    @ViewBuilder private func dragPreview(_ task: WorkTask) -> some View {
        Text(task.title)
            .font(.system(size: 13, weight: .medium)).lineLimit(2)
            .padding(10).frame(maxWidth: 240, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor)).cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
    }
}

struct TaskCard: View {
    @EnvironmentObject var appState: AppState
    let task: WorkTask
    let assignee: Employee?
    @State private var showDetail = false
    @State private var confirmingDelete = false

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
                if let due = task.dueDate { dueChip(due) }
                Spacer()
                Menu {
                    Button { showDetail = true } label: { Label("詳細", systemImage: "doc.text") }
                    Divider()
                    ForEach(TaskStatus.allCases) { s in
                        Button(s.title) { appState.setTaskStatus(task.id, s) }
                    }
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("削除", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundColor(.secondary)
                }.menuStyle(.borderlessButton).fixedSize()
                    .confirmationDialog("このタスクを削除しますか？", isPresented: $confirmingDelete,
                                        titleVisibility: .visible) {
                        Button("削除", role: .destructive) { appState.deleteTask(task.id) }
                        Button("キャンセル", role: .cancel) {}
                    } message: {
                        Text("「\(task.title)」を削除します。この操作は取り消せません。")
                    }
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
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) {
            TaskDetailView(task: task) { showDetail = false }
                .environmentObject(appState)
        }
    }

    /// 締め切り期限チップ（期限切れ・未完了なら赤）。
    @ViewBuilder private func dueChip(_ due: Double) -> some View {
        let d = Date(timeIntervalSince1970: due)
        let overdue = d < Calendar.current.startOfDay(for: Date()) && task.status != .done
        HStack(spacing: 2) {
            Image(systemName: "calendar").font(.system(size: 8))
            Text(d.formatted(.dateTime.month(.defaultDigits).day()))
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(overdue ? .red : .secondary)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background((overdue ? Color.red : Color.secondary).opacity(0.12)).cornerRadius(4)
    }
}

/// タスク編集ポップオーバー：タイトル編集＋締め切り期限の設定/解除。
struct TaskEditView: View {
    @EnvironmentObject var appState: AppState
    let task: WorkTask
    let onClose: () -> Void
    @State private var title: String
    @State private var hasDue: Bool
    @State private var due: Date

    init(task: WorkTask, onClose: @escaping () -> Void) {
        self.task = task
        self.onClose = onClose
        _title = State(initialValue: task.title)
        _hasDue = State(initialValue: task.dueDate != nil)
        _due = State(initialValue: task.dueDate.map { Date(timeIntervalSince1970: $0) } ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("タスクを編集").font(.system(size: 13, weight: .semibold))

            TextField("タイトル", text: $title, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4)
                .padding(8).background(Color.primary.opacity(0.05)).cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))

            Toggle(isOn: $hasDue) { Text("締め切り期限").font(.system(size: 12)) }
                .toggleStyle(.switch)
            if hasDue {
                DatePicker("期限", selection: $due, displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden()
            }

            HStack(spacing: 10) {
                Spacer()
                Button("キャンセル") { onClose() }.buttonStyle(.plain).font(.system(size: 12))
                Button {
                    appState.updateTaskTitle(task.id, title)
                    appState.setTaskDue(task.id, hasDue ? due.timeIntervalSince1970 : nil)
                    onClose()
                } label: {
                    Text("保存").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.accentColor).foregroundColor(.white).cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 300)
    }
}

/// タスク詳細シート：全フィールドを表示・編集できる。
struct TaskDetailView: View {
    @EnvironmentObject var appState: AppState
    let task: WorkTask
    let onClose: () -> Void

    @State private var title: String
    @State private var detail: String
    @State private var status: TaskStatus
    @State private var assigneeId: String?
    @State private var hasDue: Bool
    @State private var due: Date

    init(task: WorkTask, onClose: @escaping () -> Void) {
        self.task = task
        self.onClose = onClose
        _title = State(initialValue: task.title)
        _detail = State(initialValue: task.detail)
        _status = State(initialValue: task.status)
        _assigneeId = State(initialValue: task.assigneeId)
        _hasDue = State(initialValue: task.dueDate != nil)
        _due = State(initialValue: task.dueDate.map { Date(timeIntervalSince1970: $0) } ?? Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("タスク詳細").font(.system(size: 16, weight: .bold))
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // タイトル
                    fieldBlock(label: "タイトル", icon: "textformat") {
                        TextField("タイトル", text: $title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1...5)
                            .padding(10)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    }

                    // 詳細メモ
                    fieldBlock(label: "詳細・メモ", icon: "note.text") {
                        TextEditor(text: $detail)
                            .font(.system(size: 13))
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    }

                    // ステータス + 担当者 横並び
                    HStack(alignment: .top, spacing: 16) {
                        fieldBlock(label: "ステータス", icon: "circle.badge.checkmark") {
                            Picker("", selection: $status) {
                                ForEach(TaskStatus.allCases) { s in
                                    Label(s.title, systemImage: s.icon).tag(s)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        fieldBlock(label: "担当者", icon: "person.crop.circle") {
                            Menu {
                                Button { assigneeId = nil } label: {
                                    Label("未割当", systemImage: assigneeId == nil ? "checkmark" : "")
                                }
                                ForEach(appState.sortedEmployees) { e in
                                    Button { assigneeId = e.id } label: {
                                        Label("\(e.role.emoji) \(e.name)", systemImage: assigneeId == e.id ? "checkmark" : "")
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if let eid = assigneeId,
                                       let emp = appState.employees.first(where: { $0.id == eid }) {
                                        Text("\(emp.role.emoji) \(emp.name)")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(emp.role.color)
                                    } else {
                                        Text("未割当").font(.system(size: 13)).foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }

                    // 締め切り
                    fieldBlock(label: "締め切り期限", icon: "calendar") {
                        HStack(spacing: 12) {
                            Toggle("", isOn: $hasDue).toggleStyle(.switch).labelsHidden()
                            if hasDue {
                                DatePicker("", selection: $due, displayedComponents: .date)
                                    .datePickerStyle(.field).labelsHidden()
                            } else {
                                Text("なし").font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    }

                    // タイムスタンプ
                    HStack(spacing: 20) {
                        Label("作成: \(formatDate(task.createdAt))", systemImage: "clock")
                        Label("更新: \(formatDate(task.updatedAt))", systemImage: "pencil.and.clock")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
                .padding(24)
            }

            Divider()

            // フッター
            HStack {
                Button(role: .destructive) {
                    appState.deleteTask(task.id)
                    onClose()
                } label: {
                    Label("削除", systemImage: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("キャンセル") { onClose() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button {
                    appState.updateTaskTitle(task.id, title)
                    appState.updateTaskDetail(task.id, detail)
                    appState.setTaskStatus(task.id, status)
                    appState.assignTask(task.id, to: assigneeId)
                    appState.setTaskDue(task.id, hasDue ? due.timeIntervalSince1970 : nil)
                    onClose()
                } label: {
                    Text("保存")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 520, height: 560)
    }

    @ViewBuilder
    private func fieldBlock<C: View>(label: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDate(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
