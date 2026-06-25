import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var voice = VoiceManager.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var composerHeight: CGFloat = CustomTextEditor.minHeight
    @State private var showModelInput = false
    @State private var customModelText = ""

    // Cap the message/composer column width (centered) so text doesn't stretch
    // edge-to-edge on wide windows — a comfortable reading measure.
    private let contentMaxWidth: CGFloat = 820

    // Show just the model id's last path component to keep the composer compact.
    private func shortModelName(_ model: String) -> String {
        if let slash = model.lastIndex(of: "/") {
            return String(model[model.index(after: slash)...])
        }
        return model
    }

    var body: some View {
        if appState.messages.isEmpty && !appState.isStreaming {
            // Initial screen: vertically centered
            VStack(spacing: 0) {
                Spacer()
                
                Text("何を作りましょうか？")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.primary.opacity(0.9))
                    .padding(.bottom, 32)

                composerView
                    .frame(maxWidth: contentMaxWidth)

                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        } else {
            // Chat screen: messages + bottom composer
            VStack(spacing: 0) {
                // Header padding — just enough to clear the floating header bar.
                Spacer().frame(height: 40)

                // Messages Scroll
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(appState.messages) { msg in
                                // Hide the assistant bubble only when it has nothing at all
                                // (no text, image, tool activity, or reasoning yet).
                                if msg.role == .assistant && msg.content.isEmpty && msg.imageData == nil
                                    && msg.toolCalls.isEmpty && msg.thinking.isEmpty {
                                    EmptyView()
                                } else {
                                    MessageBlock(msg: msg)
                                        .id(msg.id)
                                }
                            }

                            // Thinking indicator only while nothing has streamed yet.
                            if appState.isStreaming, let last = appState.messages.last,
                               last.content.isEmpty, last.toolCalls.isEmpty, last.thinking.isEmpty {
                                ThinkingBlock()
                                    .id("thinking")
                            }

                            // Bottom padding
                            Spacer().frame(height: 100).id("bottom_anchor")
                        }
                        .frame(maxWidth: contentMaxWidth, alignment: .leading)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                    }
                    .onChange(of: appState.messages) { _, _ in
                        if let last = appState.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    // Subtle fade only at the very top edge (scroll-under-header), so the
                    // first lines of a message stay fully readable.
                    .mask(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.03),
                                .init(color: .black, location: 1.0)
                            ]),
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                }

                // Composer at bottom (capped width, centered)
                composerView
                    .frame(maxWidth: contentMaxWidth)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 24)
            }
        }
    }
    
    private var composerView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Attached image thumbnail (drag-drop or picker)
                if let data = appState.attachedImageData, let img = NSImage(data: data) {
                    HStack {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button(action: { appState.attachedImageData = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                }

                CustomTextEditor(text: $appState.inputValue, height: $composerHeight) {
                    appState.handleSendMessage()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 0)
                .frame(height: composerHeight)
                
                // Toolbar
                HStack {
                    // Left group
                    HStack(spacing: 8) {
                        Button(action: {
                            selectFileToAttach()
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary.opacity(0.7))
                                .frame(width: 24, height: 24)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        // Manager-only: delegate the typed task to a team member (Phase 2).
                        if appState.activeEmployee?.role == .manager {
                            let team = appState.employees.filter { $0.role != .manager }
                            Menu {
                                if team.isEmpty {
                                    Text("委譲できる社員がいません")
                                } else {
                                    ForEach(team) { emp in
                                        Button {
                                            let task = appState.inputValue
                                            appState.inputValue = ""
                                            Task { await appState.delegate(to: emp.id, task: task) }
                                        } label: {
                                            Text("\(emp.role.emoji) \(emp.name)（\(emp.role.title)）")
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                                    Text("委譲").font(.system(size: 11))
                                }
                                .foregroundColor(.purple)
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(Color.purple.opacity(0.1)).cornerRadius(6)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(team.isEmpty || appState.isStreaming
                                      || appState.inputValue.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Spacer()
                    
                    // Right group
                    HStack(spacing: 12) {
                        // Chat vs Code mode (Claude Code風). Behavioral only.
                        Menu {
                            ForEach(AgentMode.allCases) { m in
                                Button {
                                    appState.agentMode = m
                                } label: {
                                    if appState.agentMode == m {
                                        Label(m.label, systemImage: "checkmark")
                                    } else {
                                        Label(m.label, systemImage: m.icon)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: appState.agentMode.icon)
                                    .font(.system(size: 10))
                                    .foregroundColor(.primary.opacity(0.6))
                                Text(appState.agentMode.label)
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary.opacity(0.6))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8))
                                    .foregroundColor(.primary.opacity(0.4))
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        Menu {
                            Section("おすすめ") {
                                ForEach(AppState.modelPresets) { preset in
                                    Button {
                                        Task { await appState.setModel(provider: preset.provider, model: preset.model) }
                                    } label: {
                                        if appState.defaultModel == preset.model {
                                            Label(preset.label, systemImage: "checkmark")
                                        } else {
                                            Text(preset.label)
                                        }
                                    }
                                }
                            }
                            // Live OpenRouter catalog, grouped by provider (never stale).
                            if !appState.availableModels.isEmpty {
                                Menu("すべてのモデル（\(appState.availableModels.count)）") {
                                    ForEach(appState.modelsByProvider, id: \.provider) { group in
                                        Menu(group.provider) {
                                            ForEach(group.models.filter { !appState.modelIsHidden($0.id) }) { m in
                                                Button {
                                                    Task { await appState.setModel(provider: "openrouter", model: m.id) }
                                                } label: {
                                                    if appState.defaultModel == m.id {
                                                        Label(m.name, systemImage: "checkmark")
                                                    } else {
                                                        Text(m.name)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("モデル一覧を更新") {
                                Task { await appState.fetchAvailableModels() }
                            }
                            Button("カスタムモデルを入力…") {
                                customModelText = appState.defaultModel
                                showModelInput = true
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(shortModelName(appState.defaultModel))
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary.opacity(0.6))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8))
                                    .foregroundColor(.primary.opacity(0.4))
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        Button(action: {
                            voice.toggle(base: appState.inputValue) { text in
                                appState.inputValue = text
                            }
                        }) {
                            Image(systemName: voice.isListening ? "mic.fill" : "mic")
                                .font(.system(size: 13))
                                .foregroundColor(voice.isListening ? .red : .primary.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help(voice.unavailable ? "音声認識が利用できません（権限を確認）" : "音声入力")
                        
                        Button(action: {
                            if appState.isStreaming {
                                appState.cancelStreaming()
                            } else {
                                appState.handleSendMessage()
                            }
                        }) {
                            Image(systemName: appState.isStreaming ? "stop.fill" : "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(colorScheme == .dark ? .black : .white)
                                .frame(width: 24, height: 24)
                                .background(
                                    appState.inputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appState.isStreaming
                                    ? (colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.3))
                                    : (colorScheme == .dark ? Color.white : Color.black)
                                )
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.inputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appState.isStreaming)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            .background(colorScheme == .dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 10, x: 0, y: 5)
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                handleImageDrop(providers)
            }
            
            // Badges
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(appState.workspaceName)
                }
                Text("ローカルで作業")
                HStack(spacing: 4) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text("main")
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary.opacity(0.6))
            .padding(.top, 12)
        }
        .alert("カスタムモデル", isPresented: $showModelInput) {
            TextField("例: openai/gpt-4o-mini", text: $customModelText)
            Button("設定") {
                Task { await appState.setCustomModel(customModelText) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("使用するモデルIDを入力してください（現在のプロバイダー: \(appState.provider)）。")
        }
        // H2 approval flow: agent is requesting permission to run a tool.
        .alert(appState.pendingPermission?.title ?? "ツールの実行許可",
               isPresented: Binding(
                    get: { appState.pendingPermission != nil },
                    set: { if !$0 { appState.resolvePermission(nil) } })) {
            if let perm = appState.pendingPermission {
                ForEach(perm.options) { opt in
                    Button(opt.name, role: opt.isAllow ? nil : .destructive) {
                        appState.resolvePermission(opt.optionId)
                    }
                }
                Button("キャンセル", role: .cancel) { appState.resolvePermission(nil) }
            }
        } message: {
            Text(appState.pendingPermission?.detail ?? "")
        }
    }

    private func selectFileToAttach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK, let url = panel.url {
            // Images become an attachment thumbnail; other files append as text.
            if let img = NSImage(contentsOf: url), let data = img.jpegData() {
                appState.attachedImageData = data
                return
            }
            let filename = url.lastPathComponent
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let attachmentText = "\n\n--- [ファイル添付: \(filename)] ---\n\(content)\n---------------------------------\n"
                appState.inputValue += attachmentText
            } else {
                appState.inputValue += " [添付ファイル: \(url.path)] "
            }
        }
    }

    /// Accept an image dropped onto the composer → show it as a thumbnail.
    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { obj, _ in
                if let img = obj as? NSImage, let data = img.jpegData() {
                    DispatchQueue.main.async { appState.attachedImageData = data }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let url = url, let img = NSImage(contentsOf: url), let data = img.jpegData() {
                    DispatchQueue.main.async { appState.attachedImageData = data }
                }
            }
            return true
        }
        return false
    }
}

struct MessageBlock: View {
    let msg: Message

    /// Render markdown (bold/italic/links/inline code/structure). Falls back to plain.
    static func markdown(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    /// A piece of a reply: prose or a fenced code block.
    enum Segment {
        case text(String)
        case code(lang: String, body: String)
    }

    /// Split a reply on ``` fences so code renders monospace with a copy button.
    static func segments(_ s: String) -> [Segment] {
        guard s.contains("```") else { return [.text(s)] }
        var segs: [Segment] = []
        var inCode = false
        var lang = ""
        var buf: [String] = []
        func flushText() {
            let t = buf.joined(separator: "\n")
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segs.append(.text(t)) }
            buf.removeAll()
        }
        func flushCode() {
            segs.append(.code(lang: lang, body: buf.joined(separator: "\n")))
            buf.removeAll(); lang = ""
        }
        for line in s.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { flushCode(); inCode = false }
                else {
                    flushText(); inCode = true
                    lang = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                }
            } else {
                buf.append(line)
            }
        }
        if inCode { flushCode() } else { flushText() }
        return segs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if msg.role != .system {
                if let dname = msg.delegatedName, let drole = msg.delegatedRole {
                    HStack(spacing: 5) {
                        Text(drole.emoji).font(.system(size: 12))
                        Text("\(dname)（\(drole.title)）")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(drole.color)
                        Text("· 委譲を受けて対応")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(msg.role == .user ? "あなた" : "Hermes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            
            if msg.role == .system {
                Text(msg.content)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(6)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // Reasoning (collapsible) shown above the reply.
                    if msg.role == .assistant && !msg.thinking.isEmpty {
                        ReasoningView(text: msg.thinking)
                    }
                    // Tool activity cards (ACP tool_call / tool_call_update).
                    if !msg.toolCalls.isEmpty {
                        ForEach(msg.toolCalls) { call in
                            ToolCallCard(call: call)
                        }
                    }
                    if let data = msg.imageData, let img = NSImage(data: data) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 260, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if !msg.content.isEmpty {
                        if msg.typewriter {
                            // Plain during streaming (partial markdown would flicker).
                            TypewriterText(fullText: msg.content)
                                .font(.system(size: 14))
                                .foregroundColor(msg.isError ? .red : .primary)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        } else {
                            // Final: split fenced code blocks out for monospace + copy.
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(MessageBlock.segments(msg.content).enumerated()), id: \.offset) { _, seg in
                                    switch seg {
                                    case .text(let t):
                                        Text(MessageBlock.markdown(t))
                                            .font(.system(size: 14))
                                            .foregroundColor(msg.isError ? .red : .primary)
                                            .lineSpacing(4)
                                            .textSelection(.enabled)
                                    case .code(let lang, let body):
                                        CodeBlockView(language: lang, code: body)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(msg.role == .user ? Color.primary.opacity(0.05) : Color.clear)
                .cornerRadius(8)

                // Meta: read-aloud + elapsed time + token count (assistant replies)
                if msg.role == .assistant, !msg.content.isEmpty {
                    HStack(spacing: 10) {
                        Button {
                            VoiceManager.shared.speak(msg.content)
                        } label: {
                            Image(systemName: "speaker.wave.2")
                        }
                        .buttonStyle(.plain)
                        .help("読み上げ")
                        if let e = msg.elapsed {
                            Label(String(format: "%.1fs", e), systemImage: "clock")
                        }
                        if let t = msg.tokens {
                            Label("\(t) tokens", systemImage: "number")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A fenced code block: language header, copy button, horizontally scrollable
/// monospace body.
struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "コピー済み" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

/// Activity card for one ACP tool invocation: kind icon, title, status, and an
/// expandable body showing the command (input) and result (output).
struct ToolCallCard: View {
    let call: ACPToolCall
    @State private var expanded = false

    private var statusColor: Color {
        switch call.status {
        case "completed": return .green
        case "failed":    return .red
        case "in_progress", "pending": return .orange
        default:          return .secondary
        }
    }

    private var statusSymbol: String {
        switch call.status {
        case "completed": return "checkmark.circle.fill"
        case "failed":    return "xmark.octagon.fill"
        default:          return "circle.dotted"
        }
    }

    private var hasBody: Bool {
        !call.input.isEmpty || !call.output.isEmpty || !call.locations.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row (tap to expand)
            Button {
                if hasBody { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: call.symbol)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    Text(call.title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if call.status == "in_progress" || call.status == "pending" {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: statusSymbol)
                            .font(.system(size: 11))
                            .foregroundColor(statusColor)
                    }
                    if hasBody {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !call.locations.isEmpty {
                        ForEach(call.locations, id: \.self) { path in
                            Label(path, systemImage: "doc")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if !call.input.isEmpty {
                        Text(call.input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.7))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !call.output.isEmpty {
                        if !call.input.isEmpty { Divider() }
                        Text(call.output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(call.status == "failed" ? .red.opacity(0.85) : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }
}

/// Collapsible reasoning (agent_thought_chunk) shown above the reply.
struct ReasoningView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                    Text("思考")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.5)
                }
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Reveals text one character at a time (with a catch-up step for long text),
/// so streamed assistant replies appear as a typewriter.
struct TypewriterText: View {
    let fullText: String
    @State private var count = 0
    private let timer = Timer.publish(every: 0.012, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(String(Array(fullText).prefix(count)))
            .onReceive(timer) { _ in
                let total = fullText.count
                if count < total {
                    count = min(count + max(1, (total - count) / 40), total)
                } else if count > total {
                    count = total // text shrank (e.g. switched message)
                }
            }
    }
}

struct ThinkingBlock: View {
    @State private var animate = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hermes")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animate ? 1.0 : 0.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(0.0), value: animate)
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animate ? 1.0 : 0.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(0.15), value: animate)
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animate ? 1.0 : 0.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(0.3), value: animate)
                
                Text("Thinking...")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onAppear {
                animate = true
            }
        }
    }
}

/// NSTextView that draws its own placeholder when empty (and not mid-IME-composition),
/// so the placeholder visibility never depends on a SwiftUI binding round-trip.
final class PlaceholderTextView: NSTextView {
    var placeholderString: String = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.4),
            .font: font ?? NSFont.systemFont(ofSize: 15, weight: .light)
        ]
        let pad = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + pad, y: textContainerInset.height)
        placeholderString.draw(at: origin, withAttributes: attrs)
    }
}

struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var onCommit: () -> Void

    // Single-line by default, grows up to maxHeight, then scrolls.
    static let minHeight: CGFloat = 40
    static let maxHeight: CGFloat = 150

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay

        let textView = PlaceholderTextView()
        textView.placeholderString = "何でもできます"
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 15, weight: .light)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 12)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            if textView.string != text {
                textView.string = text
                textView.needsDisplay = true   // refresh placeholder on programmatic change (e.g. send clears)
            }
            context.coordinator.recalcHeight(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true   // keep the placeholder in sync with content
            recalcHeight(textView)
        }

        // Measure the laid-out text height and update the SwiftUI frame binding.
        @MainActor
        func recalcHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  textView.bounds.width > 0 else { return }

            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer).height
            let total = used + textView.textContainerInset.height * 2
            let clamped = min(max(total, CustomTextEditor.minHeight), CustomTextEditor.maxHeight)

            if abs(parent.height - clamped) > 0.5 {
                let newHeight = clamped
                Task { @MainActor [weak self] in
                    self?.parent.height = newHeight
                }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    return false
                } else {
                    parent.onCommit()
                    return true
                }
            }
            return false
        }
    }
}
