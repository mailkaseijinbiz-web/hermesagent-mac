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
                    .padding(.bottom, 24)

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

                // 出力ビュー切替（構造化できる出力があるときだけ表示）
                if appState.hasStructurableOutput {
                    OutputModePicker(mode: $appState.chatOutputMode)
                        .padding(.bottom, 8)
                        .frame(maxWidth: contentMaxWidth)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if appState.chatOutputMode == .chat {
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
                                    MessageBlock(msg: msg, isLast: msg.id == appState.messages.last?.id)
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
                } else {
                    // 構造化表示（ニュース/要約/タイムライン/テーブル）
                    ScrollView {
                        StructuredOutputContainer(entries: appState.latestAssistantEntries,
                                                  mode: appState.chatOutputMode)
                            .frame(maxWidth: contentMaxWidth, alignment: .leading)
                            .padding(.horizontal, 32)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4).padding(.bottom, 20)
                    }
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
                // Attached files (drag-drop / picker / paste): thumbnails with an × to remove.
                if !appState.attachedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(appState.attachedFiles) { f in
                                AttachmentThumbnail(file: f) { appState.removeAttachment(f.id) }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    }
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

                        // When talking to an employee: register the typed request as that
                        // employee's scheduled automation (jumps to the Automations screen).
                        if let emp = appState.activeEmployee {
                            Button {
                                appState.registerAutomationForEmployee(emp.id, prompt: appState.inputValue)
                            } label: {
                                Image(systemName: "clock.badge.plus")
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary.opacity(0.7))
                                    .frame(width: 24, height: 24)
                                    .background(Color.primary.opacity(0.05))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .help("この依頼を\(emp.name)のオートメーションに登録")
                        }

                        // Manager-only: delegate the typed task to a team member (Phase 2).
                        // Scoped to the manager's team if they lead one, else all members.
                        if appState.activeEmployee?.role == .manager {
                            let mgrId = appState.activeEmployeeId
                            let ledTeam = appState.teams.first { $0.managerId == mgrId }
                            let team = (ledTeam.map { appState.employees(inTeam: $0.id) }
                                        ?? appState.employees.filter { $0.role != .manager })
                                        .filter { $0.id != mgrId }
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
                            // Provider is fixed (Settings) — offer only models within it.
                            if appState.provider == AntigravityCLI.providerId {
                                Section("おすすめ（Antigravity）") {
                                    ForEach(AntigravityCLI.presetModels, id: \.self) { m in
                                        Button {
                                            Task { await appState.setModel(m) }
                                        } label: {
                                            if appState.defaultModel == m {
                                                Label(m, systemImage: "checkmark")
                                            } else {
                                                Text(m)
                                            }
                                        }
                                    }
                                }
                                Divider()
                                Button("カスタムモデルを入力…") {
                                    customModelText = appState.defaultModel
                                    showModelInput = true
                                }
                            } else {
                                Section("おすすめ") {
                                    ForEach(appState.currentModelPresets) { preset in
                                        Button {
                                            Task { await appState.setModel(preset.model) }
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
                                                        Task { await appState.setModel(m.id) }
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
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                handleFileDrop(providers)
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
        panel.allowsMultipleSelection = true       // attach several files at once
        panel.canChooseDirectories = false
        panel.canChooseFiles = true                // any file type (画像・PDF・テキスト等)
        panel.title = "ファイルを選択"
        panel.prompt = "添付"
        if panel.runModal() == .OK {
            for url in panel.urls { appState.attachFileURL(url) }
        }
    }

    /// Accept files/images dropped onto the composer → stage them as attachments.
    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            // Prefer a real file URL (so the agent gets a path it can read).
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    if let url = url { DispatchQueue.main.async { appState.attachFileURL(url) } }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                // Image dragged with no file URL (e.g. from a browser) → keep its bytes.
                handled = true
                provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage, let data = img.jpegData() {
                        DispatchQueue.main.async { appState.attachImageData(data) }
                    }
                }
            }
        }
        return handled
    }
}

/// One composer attachment: an image preview, or a file-type chip — with an × to remove.
struct AttachmentThumbnail: View {
    let file: AttachedFile
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let data = file.imageData, let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 3) {
                        Image(systemName: icon).font(.system(size: 16)).foregroundColor(.secondary)
                        Text(file.ext).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(width: 56, height: 56)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
        }
        .help(file.name)
    }

    private var icon: String {
        switch file.ext.lowercased() {
        case "pdf":                       return "doc.richtext"
        case "txt", "md", "rtf":          return "doc.text"
        case "csv", "xlsx", "xls", "numbers": return "tablecells"
        case "zip", "tar", "gz":          return "doc.zipper"
        case "mp4", "mov", "avi", "mkv":  return "film"
        case "mp3", "wav", "m4a", "aac":  return "music.note"
        case "json", "xml", "yml", "yaml", "swift", "py", "js", "ts", "html", "css": return "chevron.left.forwardslash.chevron.right"
        default:                          return "doc"
        }
    }
}

struct MessageBlock: View {
    @EnvironmentObject var appState: AppState
    let msg: Message
    var isLast: Bool = false

    /// Selection cues — only treat a trailing list as choices when the reply actually
    /// asks the user to pick (avoids quick-replies on purely informational lists).
    private static let choiceCues = ["？", "?", "どちら", "どれ", "いずれ", "選んで", "選択", "ご希望", "教えていただけ"]

    /// Trailing run of numbered/bulleted items in an assistant reply, treated as selectable
    /// choices (e.g. "1. プランA / 2. プランB") — but only when the reply prompts a choice.
    /// Returns the choice texts (≥2) or [].
    static func choices(_ content: String) -> [String] {
        guard choiceCues.contains(where: { content.contains($0) }) else { return [] }
        var lastRun: [String] = []
        var run: [String] = []
        for block in blocks(content) {
            switch block {
            case .ordered(_, let t): run.append(t)
            case .bullet(let t): run.append(t)
            default:
                if run.count >= 2 { lastRun = run }
                run.removeAll()
            }
        }
        if run.count >= 2 { lastRun = run }
        return lastRun
    }

    /// Plain text for sending a chosen option (strip emphasis/code markers).
    static func plainChoice(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Render INLINE markdown (bold/italic/links/inline code) for one block, preserving
    /// whitespace. `.full` would parse block grammar but `AttributedString`+`Text` then
    /// collapses block boundaries (headings/lists/paragraph breaks) into one run — which
    /// is why we render block structure ourselves (see `blocks`) and only do inline here.
    static func markdown(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    /// A block-level element of prose (everything between fenced code blocks).
    enum Block {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case ordered(marker: String, text: String)
        case quote(text: String)
        case table(header: [String], rows: [[String]])
        case paragraph(String)
    }

    /// A GFM table delimiter row, e.g. `|---|:--:|` (only pipes/dashes/colons/space,
    /// with at least one dash and one pipe).
    static func isTableDelimiter(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        let allowed = Set("|:- ")
        return t.allSatisfy { allowed.contains($0) }
    }

    /// Split a `| a | b |` row into trimmed cells (tolerates missing outer pipes).
    static func tableCells(_ raw: String) -> [String] {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Split prose into block elements so headings/lists/paragraphs each render on their
    /// own line — `AttributedString` markdown alone would mash them into one paragraph.
    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flushPara() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.paragraph(t)) }
            para.removeAll()
        }
        let lines = s.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushPara(); i += 1; continue }
            // GFM table: a row with pipes whose NEXT line is a delimiter row.
            if line.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                flushPara()
                let header = tableCells(line)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let l = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty, l.contains("|") else { break }
                    rows.append(tableCells(l))
                    j += 1
                }
                out.append(.table(header: header, rows: rows))
                i = j
                continue
            }
            // ATX heading: #..###### followed by a space.
            if let h = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushPara()
                let hashes = line.prefix(while: { $0 == "#" }).count
                out.append(.heading(level: min(max(hashes, 1), 6), text: String(line[h.upperBound...])))
                i += 1; continue
            }
            // Blockquote: > text
            if let q = line.range(of: #"^>\s?"#, options: .regularExpression) {
                flushPara()
                out.append(.quote(text: String(line[q.upperBound...])))
                i += 1; continue
            }
            // Unordered list: -, *, • , then a space.
            if let b = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                flushPara()
                out.append(.bullet(text: String(line[b.upperBound...])))
                i += 1; continue
            }
            // Ordered list: 1. or 1) then a space.
            if let o = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushPara()
                let marker = String(line[line.startIndex..<line.index(before: o.upperBound)])
                    .trimmingCharacters(in: .whitespaces)
                out.append(.ordered(marker: marker, text: String(line[o.upperBound...])))
                i += 1; continue
            }
            para.append(rawLine)
            i += 1
        }
        flushPara()
        return out
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
                        if msg.typewriter {
                            ProgressView().controlSize(.small).scaleEffect(0.55)
                            Text("· 対応中…").font(.system(size: 10)).foregroundColor(.orange)
                        } else {
                            Text("· 委譲を受けて対応")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
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
                                        ProseView(text: t, isError: msg.isError)
                                    case .code(let lang, let body):
                                        CodeBlockView(language: lang, code: body)
                                    }
                                }
                            }
                        }
                    }

                    // Live "is it alive or stuck?" indicator while THIS (last) reply streams,
                    // even after content has started — shows 受信中 / 応答待ち（遅延）+ elapsed.
                    if msg.role == .assistant, isLast, msg.typewriter, appState.isStreaming {
                        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                            let s = LiveStreamStatus.compute(appState: appState, now: ctx.date)
                            HStack(spacing: 5) {
                                Circle().fill(s.color).frame(width: 6, height: 6)
                                Text(s.label).font(.system(size: 11, weight: .medium)).foregroundColor(s.color)
                                if let e = s.elapsedText {
                                    Text(e).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                }
                                if appState.streamedCharCount > 0 {
                                    Text("· \(appState.streamedCharCount)字").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
                                }
                            }
                            .padding(.top, 2)
                        }
                    }

                    // Retry affordance on a failed/empty reply.
                    if msg.isError {
                        Button { appState.retryLastUserMessage() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("再試行")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isStreaming)
                    }

                    // Quick-reply chips: when the latest reply offers choices, let the
                    // user pick by tapping instead of retyping.
                    if msg.role == .assistant, isLast, !msg.typewriter, !msg.isError {
                        let choices = MessageBlock.choices(msg.content)
                        if choices.count >= 2 {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(choices.enumerated()), id: \.offset) { idx, c in
                                    Button {
                                        appState.sendQuickReply(MessageBlock.plainChoice(c))
                                    } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text("\(idx + 1)")
                                                .font(.system(size: 11, weight: .bold)).foregroundColor(.blue)
                                                .frame(width: 16)
                                            Text(MessageBlock.markdown(c))
                                                .font(.system(size: 13)).foregroundColor(.primary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .lineLimit(2)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 9)
                                        .background(Color.blue.opacity(0.08))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.25), lineWidth: 0.5))
                                        .cornerRadius(8)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(appState.isStreaming)
                                }
                            }
                            .padding(.top, 4)
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
                        // Save this reply as an artifact for the active employee.
                        if let emp = appState.activeEmployee, msg.delegatedName == nil {
                            Button {
                                appState.saveReplyAsArtifact(msg.content, employeeId: emp.id)
                            } label: {
                                Image(systemName: "shippingbox")
                            }
                            .buttonStyle(.plain)
                            .help("\(emp.name)の成果物として保存")
                        } else if let did = (msg.delegatedId
                                    ?? msg.delegatedName.flatMap { n in appState.employees.first { $0.name == n }?.id }),
                                  appState.employees.contains(where: { $0.id == did }) {
                            // A delegated reply → save to the specialist who produced it
                            // (keyed by id, since names aren't unique).
                            Button {
                                appState.saveReplyAsArtifact(msg.content, employeeId: did)
                            } label: {
                                Image(systemName: "shippingbox")
                            }
                            .buttonStyle(.plain)
                            .help("この担当者の成果物として保存")
                        }
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

/// Renders a prose segment as block elements — headings, bullet/ordered lists, and
/// paragraphs each on their own line — so a reply isn't mashed into one run-on block.
/// Inline markdown (bold/italic/code/links) is rendered within each block.
struct ProseView: View {
    let text: String
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(MessageBlock.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(MessageBlock.markdown(t))
                        .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                        .foregroundColor(isError ? .red : .primary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                case .bullet(let t):
                    listRow(marker: "•", text: t)
                case .ordered(let marker, let t):
                    listRow(marker: marker, text: t)   // marker already includes "." or ")"
                case .quote(let t):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                        Text(MessageBlock.markdown(t))
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 2)
                case .table(let header, let rows):
                    MarkdownTableView(header: header, rows: rows, isError: isError)
                case .paragraph(let t):
                    Text(MessageBlock.markdown(t))
                        .font(.system(size: 14))
                        .foregroundColor(isError ? .red : .primary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 17
        case 3: return 15
        default: return 14
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isError ? .red : .secondary)
            Text(MessageBlock.markdown(text))
                .font(.system(size: 14))
                .foregroundColor(isError ? .red : .primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// Renders a GFM markdown table as a bordered grid (header row tinted), so a reply's
/// `| a | b |` rows aren't shown as raw pipe text. Columns share the bubble width and
/// cells wrap; inline markdown renders within each cell.
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let isError: Bool

    private var colCount: Int { max(header.count, rows.map { $0.count }.max() ?? 0) }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<colCount, id: \.self) { c in
                    cell(c < header.count ? header[c] : "", header: true)
                }
            }
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(0..<colCount, id: \.self) { c in
                        cell(c < rows[r].count ? rows[r][c] : "", header: false)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ s: String, header: Bool) -> some View {
        Text(MessageBlock.markdown(s))
            .font(.system(size: 12, weight: header ? .semibold : .regular))
            .foregroundColor(isError ? .red : .primary)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(header ? Color.primary.opacity(0.06) : Color.clear)
            .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
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
    @EnvironmentObject var appState: AppState
    @State private var animate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hermes")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            // Tick every second so the elapsed/heartbeat updates even with no new tokens —
            // this is what tells the user it's alive vs frozen.
            TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                let s = LiveStreamStatus.compute(appState: appState, now: ctx.date)
                HStack(spacing: 6) {
                    Circle()
                        .fill(s.color)
                        .frame(width: 7, height: 7)
                        .scaleEffect(animate ? 1.0 : 0.45)
                        .animation(.easeInOut(duration: 0.6).repeatForever(), value: animate)
                    Text(s.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(s.color)
                    if let e = s.elapsedText {
                        Text(e)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if s.showStopHint {
                        Text("· 停止ボタンで中断できます")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.85))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onAppear { animate = true }
        }
    }
}

/// Derives a human-readable "is it alive or stuck?" status from the stream timers.
struct LiveStreamStatus {
    var label: String
    var color: Color
    var elapsedText: String?
    var showStopHint: Bool

    @MainActor
    static func compute(appState: AppState, now: Date) -> LiveStreamStatus {
        let started = appState.streamStartedAt
        let elapsed = started.map { max(0, now.timeIntervalSince($0)) }
        let sinceActivity = appState.lastStreamActivityAt.map { max(0, now.timeIntervalSince($0)) } ?? .infinity
        let chars = appState.streamedCharCount

        let elapsedText = elapsed.map { fmt($0) }
        // Receiving: a token/thought arrived within the last ~2s → clearly progressing.
        if sinceActivity < 2.0, chars > 0 {
            return .init(label: "受信中", color: .green, elapsedText: elapsedText, showStopHint: false)
        }
        // Long silence → likely slow or stuck; flag it and point at the stop button.
        if sinceActivity >= 30 || (elapsed ?? 0) >= 60 {
            return .init(label: "応答待ち（遅延）", color: .orange, elapsedText: elapsedText, showStopHint: true)
        }
        // Normal compute window (reasoning before first token, between tokens).
        return .init(label: chars > 0 ? "応答中" : "考え中", color: .secondary, elapsedText: elapsedText, showStopHint: false)
    }

    private static func fmt(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        return t < 60 ? "\(t)秒" : String(format: "%d分%02d秒", t / 60, t % 60)
    }
}

/// NSTextView that draws its own placeholder when empty (and not mid-IME-composition),
/// so the placeholder visibility never depends on a SwiftUI binding round-trip.
final class PlaceholderTextView: NSTextView {
    var placeholderString: String = ""

    /// Catch Cmd+V at the key-event level (this SwiftUI app has no Edit-menu Paste item, so
    /// Cmd+V is NOT wired to the `paste:` action). If the clipboard holds an image/file, attach
    /// it; otherwise fall back to the normal text paste.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            if attachFromPasteboard(NSPasteboard.general) { return true }
            super.paste(nil)   // plain text → normal paste
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Cmd+V via the Edit menu (if present): same image/file-attach behavior.
    override func paste(_ sender: Any?) {
        if attachFromPasteboard(NSPasteboard.general) { return }
        super.paste(sender)   // text → default paste
    }

    /// If `pb` carries image bytes or a copied file, stage it as a composer attachment and
    /// return true. Plain text / web links → false (caller does the normal text paste).
    private func attachFromPasteboard(_ pb: NSPasteboard) -> Bool {
        // A plain-text copy (no image) must paste as text.
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff,
            .init("public.jpeg"), .init("com.compuserve.gif"), .init("public.heic"), .init("public.image")]
        if pb.availableType(from: imageTypes) != nil {
            // Read the raw bytes for whichever image type is present (most robust).
            for t in imageTypes {
                if let data = pb.data(forType: t), let img = NSImage(data: data), let jpeg = img.jpegData() {
                    DispatchQueue.main.async { AppState.shared.attachImageData(jpeg) }
                    return true
                }
            }
            if let img = NSImage(pasteboard: pb), let jpeg = img.jpegData() {
                DispatchQueue.main.async { AppState.shared.attachImageData(jpeg) }
                return true
            }
        }
        // Copied file(s) from Finder → attach by path (skip web links, which are strings).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let files = urls.filter { $0.isFileURL }
            if !files.isEmpty {
                DispatchQueue.main.async { for u in files { AppState.shared.attachFileURL(u) } }
                return true
            }
        }
        return false
    }

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
