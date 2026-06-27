import SwiftUI

struct GmailView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var gmail = GmailSync.shared
    @StateObject private var auth  = GoogleOAuth.shared
    @State private var selectedThread: GmailThread? = nil
    @State private var searchText = ""
    @State private var showCompose = false

    var filteredThreads: [GmailThread] {
        if searchText.isEmpty { return gmail.threads }
        let q = searchText.lowercased()
        return gmail.threads.filter {
            $0.subject.lowercased().contains(q) ||
            $0.from.lowercased().contains(q) ||
            $0.snippet.lowercased().contains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel — thread list
            VStack(spacing: 0) {
                listHeader
                if !auth.isConnected {
                    notConnectedState
                } else if gmail.threads.isEmpty && !gmail.isSyncing {
                    emptyState
                } else {
                    threadList
                }
            }
            .frame(width: 320)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Right panel — message detail
            if let thread = selectedThread {
                ThreadDetailView(thread: thread)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noSelectionState
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposeView().environmentObject(appState)
        }
        .onAppear {
            if auth.isConnected && gmail.threads.isEmpty {
                Task { await gmail.sync() }
            }
        }
    }

    // MARK: - List header

    private var listHeader: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gmail").font(.system(size: 18, weight: .bold))
                    if let email = auth.email {
                        Text(email).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if gmail.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await gmail.sync() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 13))
                    }.buttonStyle(.plain).foregroundColor(.secondary)
                }
                Button { showCompose = true } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13))
                }.buttonStyle(.plain).foregroundColor(.accentColor)
                Button { appState.view = "chat" } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary).frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06)).clipShape(Circle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 10)

            if auth.isConnected {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 12))
                    TextField("検索", text: $searchText)
                        .textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.05)).cornerRadius(8)
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
        }
    }

    // MARK: - Thread list

    private var threadList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredThreads) { thread in
                    ThreadRowView(thread: thread, isSelected: selectedThread?.id == thread.id)
                        .onTapGesture {
                            selectedThread = thread
                            // Mark first unread as read
                            if let unread = thread.messages.first(where: \.isUnread) {
                                Task { try? await GmailSync.shared.markRead(unread.id) }
                            }
                        }
                    Divider().opacity(0.4)
                }
            }
        }
    }

    // MARK: - States

    private var notConnectedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 40)).foregroundColor(.secondary.opacity(0.5))
            Text("Google アカウント未接続")
                .font(.system(size: 14, weight: .semibold))
            Text("設定 → Google から接続してください")
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button { appState.showSettings = true } label: {
                Text("設定を開く")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12)).foregroundColor(.accentColor)
                    .cornerRadius(8)
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 36)).foregroundColor(.secondary.opacity(0.4))
            Text("受信トレイは空です")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSelectionState: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.open").font(.system(size: 40)).foregroundColor(.secondary.opacity(0.3))
            Text("メールを選択してください")
                .font(.system(size: 13)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Thread row

struct ThreadRowView: View {
    let thread: GmailThread
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(thread.hasUnread ? Color.accentColor : Color.clear)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(senderName(thread.from))
                        .font(.system(size: 12, weight: thread.hasUnread ? .semibold : .regular))
                        .foregroundColor(.primary).lineLimit(1)
                    Spacer()
                    Text(formatDate(thread.lastDate))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Text(thread.subject)
                    .font(.system(size: 12, weight: thread.hasUnread ? .medium : .regular))
                    .foregroundColor(.primary).lineLimit(1)
                Text(thread.snippet)
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.12) :
                    (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func senderName(_ from: String) -> String {
        if let range = from.range(of: "<") {
            return String(from[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return from
    }

    private func formatDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
            return fmt.string(from: d)
        }
        if cal.isDateInYesterday(d) { return "昨日" }
        let fmt = DateFormatter(); fmt.dateFormat = "M/d"
        return fmt.string(from: d)
    }
}

// MARK: - Thread detail

struct ThreadDetailView: View {
    let thread: GmailThread
    @State private var expandedId: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(thread.subject)
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 16)

                ForEach(thread.messages) { msg in
                    MessageBubble(msg: msg, isExpanded: expandedId == msg.id) {
                        expandedId = expandedId == msg.id ? nil : msg.id
                    }
                    Divider().opacity(0.4).padding(.horizontal, 24)
                }
            }
        }
        .onAppear {
            // Auto-expand latest message
            expandedId = thread.messages.last?.id
        }
    }
}

struct MessageBubble: View {
    let msg: GmailMessage
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                    .overlay(Text(initial(msg.from)).font(.system(size: 13, weight: .semibold)).foregroundColor(.accentColor))
                VStack(alignment: .leading, spacing: 1) {
                    Text(senderName(msg.from))
                        .font(.system(size: 13, weight: .semibold))
                    Text(formatDate(msg.date))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            if isExpanded {
                Text(msg.body.isEmpty ? msg.snippet : msg.body)
                    .font(.system(size: 13))
                    .padding(.leading, 40)
                    .textSelection(.enabled)
            } else {
                Text(msg.snippet)
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .lineLimit(2).padding(.leading, 40)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func initial(_ from: String) -> String {
        let name = senderName(from)
        return String(name.prefix(1)).uppercased()
    }

    private func senderName(_ from: String) -> String {
        if let r = from.range(of: "<") { return String(from[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return from
    }

    private func formatDate(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: d)
    }
}

// MARK: - Compose

struct ComposeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var isSending = false
    @State private var sendError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("新規メッセージ").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            VStack(spacing: 0) {
                composeField("宛先", text: $to)
                Divider()
                composeField("件名", text: $subject)
                Divider()
                TextEditor(text: $messageBody)
                    .font(.system(size: 13))
                    .frame(minHeight: 200)
                    .padding(8)
            }
            .padding(.horizontal, 8)

            if let e = sendError {
                Text(e).font(.system(size: 12)).foregroundColor(.red).padding(.horizontal, 16)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button {
                    Task {
                        isSending = true
                        do {
                            try await GmailSync.shared.sendEmail(to: to, subject: subject, body: messageBody)
                            dismiss()
                        } catch { self.sendError = error.localizedDescription }
                        isSending = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isSending { ProgressView().controlSize(.small) }
                        Text("送信")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(to.isEmpty ? Color.secondary.opacity(0.2) : Color.accentColor)
                    .foregroundColor(to.isEmpty ? .secondary : .white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(to.isEmpty || isSending)
            }
            .padding(16)
        }
        .frame(width: 560, height: 440)
    }

    private func composeField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(.secondary).frame(width: 36, alignment: .trailing)
            TextField("", text: text).textFieldStyle(.plain).font(.system(size: 13))
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
    }
}
