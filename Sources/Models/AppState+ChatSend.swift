import Foundation
import AppKit

// Chat send / session selection / attachments (Phase G1).
extension AppState {
    // Actions
    func handleNewChat() {
        self.currentSessionId = nil
        self.messages = []
        self.inputValue = ""
        self.cwdOverride = nil   // a fresh chat is not an app-develop thread
        // A new chat for the active employee starts a fresh isolated thread.
        if let empId = activeEmployeeId, let idx = employees.firstIndex(where: { $0.id == empId }) {
            employees[idx].sessionId = nil
        }
        // Reset both the shared client and this employee's dedicated client.
        ACPClient.shared.resetSession()
        empACPClients[empKey()]?.resetSession()
        empMessages.removeValue(forKey: empKey())  // clear any stale shadow for this employee
        empMessageTouchAt.removeValue(forKey: empKey())
        pruneEmpMessageShadows()
    }

    func handleSelectSession(_ session: Session) {
        self.currentSessionId = session.id
        self.cwdOverride = nil   // viewing an existing chat is not an app-develop thread
        // Load the real conversation history from the store (was a placeholder before).
        let stored = messagesFromStore(session.id)
        self.messages = stored.isEmpty
            ? [Message(role: .system, content: "Resumed session: \(session.title)")]
            : stored
        self.inputValue = ""
        // Keep the active employee if this is one of THEIR chats (make it current);
        // otherwise (browsing 全体 / an automation result) detach the employee.
        if let empId = activeEmployeeId {
            let belongsToActive = sessionOwner[session.id] == empId
                || employees.first(where: { $0.id == empId })?.sessionId == session.id
            if belongsToActive {
                if let idx = employees.firstIndex(where: { $0.id == empId }) { employees[idx].sessionId = session.id }
            } else {
                activeEmployeeId = nil
            }
        }
        // Drop any live ACP session so the next send resumes THIS session.
        ACPClient.shared.resetSession()
        empACPClients[empKey()]?.resetSession()
    }
    
    // Overload for mobile API — select session by ID string
    func handleSelectSession(sessionId: String) async {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            handleSelectSession(session)
        } else {
            // Refresh and try again
            await fetchSessions()
            if let session = sessions.first(where: { $0.id == sessionId }) {
                handleSelectSession(session)
            }
        }
    }
    
    func handleDeleteSession(id: String) async {
        // agy sessions live in the AgyStore, not the Hermes CLI's store.
        if AgyStore.isAgySession(id) {
            AgyStore.shared.delete(id)
            if self.currentSessionId == id { handleNewChat() }
            await fetchSessions()
            return
        }
        let res = await HermesCLI.shared.exec(args: ["sessions", "delete", "--yes", id])
        if res.success {
            if self.currentSessionId == id {
                handleNewChat()
            }
            await fetchSessions()
        }
    }
    
    // Parse a raw streaming chunk for the mobile API
    func parseStreamChunk(_ raw: String) -> String {
        return parseResponseText(raw)
    }
    
    /// Send a tapped quick-reply choice as the next message (from the choice chips).
    func sendQuickReply(_ text: String) {
        guard !isStreaming, !text.isEmpty else { return }
        inputValue = text
        handleSendMessage()
    }

    // MARK: - 回答へのフィードバック（誤対応を指摘しやすく）

    /// 回答に👍/👎を付ける。👎のときは note（何が違ったか）を受け取り、ログに残す。
    /// 記録は ~/.hermes/feedback.jsonl に追記（後で改善の材料にできる）。
    func giveMessageFeedback(_ id: UUID, positive: Bool, note: String = "") {
        messageFeedback[id] = positive ? 1 : -1
        logFeedback(messageId: id, positive: positive, note: note)
        if positive { triggerToast(message: "フィードバックを記録しました 👍") }
    }

    private func logFeedback(messageId: UUID, positive: Bool, note: String) {
        let entry: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "employee": activeEmployee?.name ?? "全体",
            "sessionId": currentSessionId ?? "",
            "messageId": messageId.uuidString,
            "rating": positive ? "up" : "down",
            "note": note,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("feedback.jsonl")
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            if let d = line.data(using: .utf8) { fh.write(d) }
        } else {
            do { try line.data(using: .utf8)?.write(to: url) }
            catch { Log.failure("app", "フィードバックログの書き込みに失敗 (\(url.path))", error) }
        }
    }

    /// 👎のあと、直前の回答の訂正をエージェントに依頼する（フィードバックを実際の修正につなげる）。
    func sendCorrectionForLastReply(note: String) {
        guard !isStreaming else { triggerToast(message: "応答中です。完了までお待ちください。"); return }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        inputValue = n.isEmpty
            ? "先ほどの回答が正しくありませんでした。誤りを見直して、正しく回答し直してください。"
            : "先ほどの回答について修正をお願いします。誤っていた点: \(n)"
        handleSendMessage()
    }

    func handleSendMessage() {
        let text = inputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachedFiles
        let imgData = files.first(where: { $0.isImage })?.imageData
        guard !text.isEmpty || !files.isEmpty else { return }
        // Block only if THIS employee already has an in-flight turn (other employees can still send).
        let curKey = empKey()
        if streamingEmployeeIds.contains(curKey) {
            triggerToast(message: "応答中です。完了までお待ちください。"); return
        }

        // App-managed task command: "…のタスクを追加" / "タスク追加: …" actually creates a
        // WorkTask assigned to the active employee. The chat agent runs in a separate
        // process and can't touch the app's task store, so without this it just hallucinates
        // a "added it" reply (the bug). Handled locally → real task + deterministic confirm.
        if !bypassCommandIntercept, files.isEmpty, let cmd = parseTaskAddCommand(text) {
            messages.append(Message(role: .user, content: text))
            let who = activeEmployee.map { "（\($0.name)）" } ?? ""
            switch cmd {
            case .single(let title):
                let task = createTask(title: title, assigneeId: activeEmployeeId)
                messages.append(Message(role: .system, content: "✅ タスクを追加しました\(who)：「\(task.title)」（未着手）"))
                triggerToast(message: "タスクを追加：\(task.title)")
            case .fromContext:
                // 「これら」= 直前メッセージの箇条書きを1項目ずつタスク化。
                let items = extractContextualTaskItems()
                if items.isEmpty {
                    messages.append(Message(role: .system, content: "直前のメッセージから箇条書きの項目を見つけられませんでした。追加したい内容を箇条書きで送ってください。"))
                } else {
                    // createTask は先頭に挿入するので、リスト順を保つため逆順で追加。
                    for it in items.reversed() { _ = createTask(title: it, assigneeId: activeEmployeeId) }
                    let list = items.map { "・\($0)" }.joined(separator: "\n")
                    messages.append(Message(role: .system, content: "✅ \(items.count)件のタスクを追加しました\(who)（すべて未着手）：\n\(list)"))
                    triggerToast(message: "タスクを\(items.count)件追加しました")
                }
            }
            inputValue = ""
            attachedFiles = []
            return
        }

        // App-managed action command: "〇〇アプリで〜を作成/更新して" performs a REAL data
        // operation inside the registered app — routed to the agent running in the app's folder
        // (which uses the app's HTTP API or data files; see chatControllableRequirement).
        if !bypassCommandIntercept, files.isEmpty, let action = parseAppActionCommand(text) {
            inputValue = ""
            attachedFiles = []
            if action.destructive {
                // Deletes/overwrites of real data → require an explicit confirmation tap.
                let app = action.app
                messages.append(Message(role: .user, content: text))
                messages.append(Message(role: .system, content: "⚠️ これは「\(app.name)」の実データを変更・削除する操作です。問題なければ実行してください。"))
                triggerToast(message: "データ変更を含む操作です", actionLabel: "実行する") { [weak self] in
                    self?.runAppAction(app: app, command: text)
                }
            } else {
                runAppAction(app: action.app, command: text)
            }
            return
        }

        // App-managed launch command: "〇〇アプリを開いて / 起動して" actually launches the
        // registered app (starts its dev-server + opens the preview). Handled locally so the
        // chat agent doesn't just describe it.
        if !bypassCommandIntercept, files.isEmpty, let app = parseAppLaunchCommand(text) {
            messages.append(Message(role: .user, content: text))
            let running = isAppRunning(app.id)
            messages.append(Message(role: .system, content: running
                ? "🪟 「\(app.name)」を開きます（起動中）"
                : "▶️ 「\(app.name)」を起動します…"))
            inputValue = ""
            attachedFiles = []
            launchApp(app.id)
            return
        }

        // App-managed send command: "LINEに〜を送って" actually delivers the message to the
        // registered LINE channel via the bridge (the chat agent can't reach it). Handled
        // locally → real send + deterministic confirmation. The user typed the instruction
        // themselves, so acting on it is authorized.
        if !bypassCommandIntercept, files.isEmpty, looksLikeLineSend(text) {
            if let cmd = parseLineSendCommand(text) {
                messages.append(Message(role: .user, content: text))
                inputValue = ""
                attachedFiles = []
                let sendingId = UUID()
                messages.append(Message(id: sendingId, role: .system, content: "📤 LINE（\(cmd.channel.name)）に送信中…「\(cmd.message)」"))
                Task { @MainActor in
                    let r = await self.sendToChannel(cmd.channel, text: cmd.message)
                    if let idx = self.messages.firstIndex(where: { $0.id == sendingId }) {
                        if r.ok {
                            self.messages[idx].content = "✅ LINE（\(cmd.channel.name)）に送信しました：「\(cmd.message)」"
                        } else {
                            self.messages[idx].content = "⚠️ LINE送信に失敗しました：\(String(r.detail.prefix(120)))"
                            self.messages[idx].isError = true
                        }
                    }
                    self.triggerToast(message: r.ok ? "LINEに送信しました" : "LINE送信に失敗しました")
                }
                return
            }
            // Looks like a LINE-send request but no LINE channel is registered.
            if !channels.contains(where: { $0.platform.lowercased() == "line" }) {
                messages.append(Message(role: .user, content: text))
                messages.append(Message(role: .system, content: "⚠️ 送信先のLINEチャンネルが登録されていません。設定 → チャンネル でLINEのIDを追加してください。"))
                inputValue = ""; attachedFiles = []
                return
            }
        }

        let imagePath: String? = imgData.flatMap { writeTempImage($0) }
        // Show the attached file names in the user bubble so the history reflects them.
        let displayText: String = {
            guard !files.isEmpty else { return text }
            let names = files.map { "📎 \($0.name)" }.joined(separator: "  ")
            return text.isEmpty ? names : "\(text)\n\(names)"
        }()

        let proactivePrompt = proactiveSendPrompt
        proactiveSendPrompt = nil

        self.messages.append(Message(role: .user, content: displayText, imageData: imgData))
        self.inputValue = ""
        self.attachedFiles = []
        streamingEmployeeIds.insert(curKey)  // mark THIS employee as streaming
        self.activeStatus = "thinking"
        self.streamText = ""
        empStreamTexts[curKey] = ""
        let now = Date()
        self.streamStartedAt = now
        self.lastStreamActivityAt = now
        self.streamedCharCount = 0

        let trendChartPrefix: String = {
            guard let emp = activeEmployee, emp.isHealthAdvisor else { return "" }
            return HealthTrendQuery.chartBlock(for: text).map { $0 + "\n\n" } ?? ""
        }()

        // Stable id for the streaming bubble — updated in place by chunk events.
        let assistantId = UUID()
        self.messages.append(Message(id: assistantId, role: .assistant, content: trendChartPrefix, typewriter: true))
        // Snapshot current messages into the shadow (background streaming keeps chunks here).
        empMessages[curKey] = cappedShadow(messages)
        touchEmpMessageShadow(forKey: curKey)
        pruneEmpMessageShadows()
        // Mark this assistantId as the live turn for curKey (guards against late/superseded events).
        streamingAssistantIds[curKey] = assistantId

        // Reference attached files by their local path so the agent (which has file tools) can
        // open them. Images beyond the first — and all non-image files — go here; the first
        // image additionally rides --image for vision.
        let fileRefs: String = {
            let paths = files.map { $0.url.path }
            guard !paths.isEmpty else { return "" }
            let list = paths.map { "- \($0)" }.joined(separator: "\n")
            return "\n\n【添付ファイル】以下のローカルファイルを読んで対応してください:\n\(list)"
        }()
        // 健康アドバイザー社員とのチャットには、最新の健康データ(HealthKit由来)を文脈として
        // 前置する（表示メッセージには出さない）。「今日の歩数は？」等に答えられるように。
        let healthContext: String = {
            guard let emp = activeEmployee, emp.isHealthAdvisor,
                  let line = healthSummaryLine else { return "" }
            return "【参考データ（連携中のHealthKit）】\(line)\n\n"
        }()

        var effectivePrompt = proactivePrompt ?? text
        if effectivePrompt.isEmpty { effectivePrompt = imagePath != nil ? "添付した画像について説明してください。" : "添付したファイルを確認してください。" }
        effectivePrompt += fileRefs
        if !healthContext.isEmpty { effectivePrompt = healthContext + effectivePrompt }
        let sentPrompt = wrapForSend(effectivePrompt)
        let kind = BackendRouter.selectKind(provider: provider, useACP: useACPTransport)

        var agyPrompt = ""
        if kind == .antigravity {
            if imagePath != nil && text.trimmingCharacters(in: .whitespaces).isEmpty {
                finishSendError(assistantId, imagePath, "Antigravity CLI (agy) は画像入力に対応していません。テキストで指定してください。", owningKey: curKey)
                return
            }
            var userText = text.isEmpty ? "添付したファイルを確認してください。" : text
            userText += fileRefs
            if imagePath != nil { userText += "\n\n（注: 添付画像は Antigravity CLI では無視されます）" }
            if !healthContext.isEmpty { userText = healthContext + userText }
            agyPrompt = antigravityPrompt(userText, employee: activeEmployee, mode: agentMode)
        }

        let req = AgentRequest(
            prompt: sentPrompt, agyPrompt: agyPrompt,
            imagePath: (kind == .antigravity ? nil : imagePath),
            cwd: effectiveCwd, sessionId: currentSessionId, startFresh: currentSessionId == nil,
            agyModel: modelForFixedProvider(activeEmployee))
        let userText = text
        let started = Date()
        // Capture owning context at send time — survives any mid-stream switch.
        let owningEmployeeId = activeEmployeeId
        let owningSessionId = currentSessionId
        let owningKey = curKey

        Task { @MainActor in
            if kind != .antigravity { await self.modelApplyTask?.value }
            if kind == .antigravity, await AntigravityCLI.shared.resolveBinaryAsync() == nil {
                self.finishSendError(assistantId, imagePath, AntigravityCLI.installHint, owningKey: owningKey)
                return
            }

            // Dedicated ACP client per employee enables truly parallel ACP turns.
            // HermesCLI/agy already spawn independent processes — no sharing needed.
            let acp = kind == .acp ? self.getOrCreateACPClient(for: owningKey) : ACPClient.shared
            let backend = BackendRouter.make(kind, acp: acp)

            let result = await backend.send(
                req,
                onStart: { [weak self] proc in
                    guard let proc = proc else { return }
                    self?.empProcesses[owningKey] = proc
                },
                onEvent: { [weak self] event in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        // Drop events that arrive after this turn finalized, or after a newer turn
                        // started for the same employee — otherwise a late chunk overwrites the
                        // finalized bubble or re-creates a leaked empStreamTexts entry.
                        guard self.streamingAssistantIds[owningKey] == assistantId else { return }
                        let isActive = (self.activeEmployeeId == owningEmployeeId)
                        // Heartbeat: a real event just arrived → the turn is progressing, not stuck.
                        if isActive {
                            self.lastStreamActivityAt = Date()
                            if case .chunk(let t) = event { self.streamedCharCount += t.count }
                            else if case .thought(let t) = event { self.streamedCharCount += t.count }
                        }
                        switch event {
                        case .chunk(let t):
                            self.empStreamTexts[owningKey, default: ""] += t
                            let rawText = self.empStreamTexts[owningKey] ?? ""
                            let parsed: String
                            switch kind {
                            case .hermesCLI:   parsed = self.parseResponseText(rawText)
                            case .antigravity: parsed = AntigravityCLI.clean(rawText)
                            case .acp:         parsed = rawText
                            }
                            // Always update the shadow (background streaming).
                            if let idx = self.empMessages[owningKey]?.firstIndex(where: { $0.id == assistantId }) {
                                self.empMessages[owningKey]![idx].content = parsed
                            }
                            // Update visible messages + streamText only when this is the active employee.
                            if isActive {
                                if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                                    self.messages[idx].content = parsed
                                }
                                self.streamText = rawText
                            }
                        case .thought(let t):
                            if let idx = self.empMessages[owningKey]?.firstIndex(where: { $0.id == assistantId }) {
                                self.empMessages[owningKey]![idx].thinking += t
                            }
                            if isActive, let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                                self.messages[idx].thinking += t
                            }
                        case .toolActivity(let calls):
                            if let idx = self.empMessages[owningKey]?.firstIndex(where: { $0.id == assistantId }) {
                                self.empMessages[owningKey]![idx].toolCalls = calls
                            }
                            if isActive, let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                                self.messages[idx].toolCalls = calls
                            }
                        }
                    }
                })

            // Clean up this employee's streaming state.
            self.streamingEmployeeIds.remove(owningKey)
            self.empProcesses.removeValue(forKey: owningKey)
            let rawStream = self.empStreamTexts.removeValue(forKey: owningKey) ?? ""

            let isActive = (self.activeEmployeeId == owningEmployeeId)
            if isActive { self.streamText = ""; self.streamStartedAt = nil; self.lastStreamActivityAt = nil }
            if self.streamingEmployeeIds.isEmpty { self.activeStatus = "online" }

            let final: String
            switch kind {
            case .hermesCLI:   final = self.parseResponseText(rawStream)
            case .antigravity: final = AntigravityCLI.clean(rawStream)
            case .acp:         final = rawStream
            }
            // Backend health: a real reply = healthy; an empty turn = a failure signal.
            self.recordBackendOutcome(ok: !final.isEmpty)

            // Mark this employee as having an unread response if the user switched away.
            if !isActive, !final.isEmpty, let empId = owningEmployeeId {
                self.employeeUnreadIds.insert(empId)
            }

            // Finalize the bubble in the shadow array (always — needed if user switches back).
            if let idx = self.empMessages[owningKey]?.firstIndex(where: { $0.id == assistantId }) {
                self.empMessages[owningKey]![idx].elapsed = Date().timeIntervalSince(started)
                if final.isEmpty {
                    self.empMessages[owningKey]![idx].content = self.emptyTurnMessage(kind: kind, ok: result.ok, raw: rawStream)
                    self.empMessages[owningKey]![idx].isError = true
                    self.empMessages[owningKey]![idx].typewriter = false
                } else {
                    self.empMessages[owningKey]![idx].content = final
                    if kind == .acp { self.empMessages[owningKey]![idx].tokens = result.tokens }
                }
            }
            // Finalize visible messages only when still viewing this employee.
            if isActive, let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                self.messages[idx].elapsed = Date().timeIntervalSince(started)
                if final.isEmpty {
                    self.messages[idx].content = self.emptyTurnMessage(kind: kind, ok: result.ok, raw: rawStream)
                    self.messages[idx].isError = true
                    self.messages[idx].typewriter = false
                    if self.rawIndicatesNoToolSupport(rawStream) { self.modelHealth[self.defaultModel] = false }
                } else {
                    self.messages[idx].content = final
                    if kind == .acp { self.messages[idx].tokens = result.tokens }
                }
            }
            if let imagePath = imagePath { try? FileManager.default.removeItem(atPath: imagePath) }

            // Session reconcile attributed to the owning employee.
            let stillViewing = isActive
            var turnSession: String? = owningSessionId
            switch kind {
            case .acp:
                turnSession = acp.hermesSessionId ?? owningSessionId
                if stillViewing, let s = turnSession { self.currentSessionId = s }
                await self.fetchSessions()
            case .antigravity:
                if !final.isEmpty {
                    let sid = AgyStore.shared.record(sessionId: owningSessionId, employeeId: owningEmployeeId,
                                                     userText: userText, assistantText: final, timestamp: Date().timeIntervalSince1970)
                    turnSession = sid
                    if stillViewing { self.currentSessionId = sid }
                    await self.fetchSessions()
                }
            case .hermesCLI:
                await self.fetchSessions()
                if turnSession == nil {
                    if self.sessions.first == nil {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await self.fetchSessions()
                    }
                    turnSession = self.sessions.first?.id
                    if stillViewing, self.currentSessionId == nil { self.currentSessionId = turnSession }
                }
            }
            self.bindSession(turnSession, toEmployee: owningEmployeeId)

            // ライフログ: Hermes チャットセッションを Mac アクティビティとして記録
            if !final.isEmpty {
                let empName = self.employees.first { $0.id == owningEmployeeId }?.name ?? "Hermes"
                let sessionTitle = self.sessions.first { $0.id == turnSession }?.title ?? ""
                MacActivityLogger.shared.recordHermesSession(
                    employeeName: empName,
                    sessionTitle: sessionTitle,
                    start: started,
                    end: Date()
                )
            }

            // Turn complete — the store is authoritative; clear the in-flight shadow. Clearing the
            // live-turn marker makes any still-queued onEvent callbacks no-op. Only clear if it's
            // still OURS (a newer turn for this key may have already claimed the slot).
            self.empMessages.removeValue(forKey: owningKey)
            self.empMessageTouchAt.removeValue(forKey: owningKey)
            self.pruneEmpMessageShadows()
            if self.streamingAssistantIds[owningKey] == assistantId {
                self.streamingAssistantIds.removeValue(forKey: owningKey)
            }

            // If the agent produced a PDF (e.g. an invoice), surface it — open the file so it
            // "comes back" to the user. Only opens a real on-disk .pdf the reply names.
            if !final.isEmpty, owningEmployeeId == self.activeEmployeeId {
                self.openReferencedPDF(in: final)
            }

            // Auto-repair follow-through: this turn was an AI fix for a failed app launch —
            // re-launch the app now that the fix is done (a brief pause lets files settle).
            if let relaunchId = self.pendingRelaunchAppId {
                self.pendingRelaunchAppId = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.terminalOutput += "\n🔄 修復が完了しました。再起動します…\n"
                    self.launchApp(relaunchId)
                }
            }
        }
    }

    /// Finalize a send turn with an error bubble (agy image-only / not-installed pre-checks).
    private func finishSendError(_ assistantId: UUID, _ imagePath: String?, _ msg: String, owningKey: String) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].content = msg
            messages[idx].isError = true
            messages[idx].typewriter = false
        }
        streamingEmployeeIds.remove(owningKey)
        streamText = ""
        empStreamTexts.removeValue(forKey: owningKey)
        empMessages.removeValue(forKey: owningKey)
        empMessageTouchAt.removeValue(forKey: owningKey)
        pruneEmpMessageShadows()
        streamingAssistantIds.removeValue(forKey: owningKey)
        if owningKey == empKey() { streamStartedAt = nil; lastStreamActivityAt = nil }
        if streamingEmployeeIds.isEmpty { activeStatus = "online" }
        if let imagePath = imagePath { try? FileManager.default.removeItem(atPath: imagePath) }
    }

    func cancelStreaming() {
        let key = empKey()
        empProcesses[key]?.terminate()
        empProcesses.removeValue(forKey: key)
        // Shut down and remove the dedicated ACP client (will be recreated on next send).
        empACPClients[key]?.shutdown()
        empACPClients.removeValue(forKey: key)
        streamingEmployeeIds.remove(key)
        streamText = ""
        empStreamTexts.removeValue(forKey: key)
        empMessages.removeValue(forKey: key)
        empMessageTouchAt.removeValue(forKey: key)
        pruneEmpMessageShadows()
        streamingAssistantIds.removeValue(forKey: key)   // late onEvent callbacks now no-op
        streamStartedAt = nil; lastStreamActivityAt = nil
        if streamingEmployeeIds.isEmpty { activeStatus = "online" }
    }

    /// Re-send the most recent user message (after a failed/empty reply). Drops the
    /// failed turn and re-runs it.
    func retryLastUserMessage() {
        guard !isStreaming else { return }
        guard let userIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        let text = messages[userIdx].content
        let img = messages[userIdx].imageData
        messages.removeSubrange(userIdx...)   // drop the failed user+assistant turn
        inputValue = text
        attachedFiles = []
        if let img = img, let path = writeTempImage(img) {
            attachedFiles = [AttachedFile(url: URL(fileURLWithPath: path), imageData: img)]
        }
        handleSendMessage()
    }

    /// Write attached image bytes to a temp file for the CLI's --image flag.
    private func writeTempImage(_ data: Data) -> String? {
        let path = NSTemporaryDirectory() + "hermes_compose_\(UUID().uuidString).jpg"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    // MARK: - Composer attachments

    /// Stage a file (drop / picker) as a composer attachment. De-dupes by path; loads image
    /// bytes for a preview when it's an image. Capped so the composer can't be flooded.
    func attachFileURL(_ url: URL) {
        guard attachedFiles.count < 10,
              !attachedFiles.contains(where: { $0.url.path == url.path }) else { return }
        var imgData: Data? = nil
        if AttachedFile.isImagePath(url), let img = NSImage(contentsOf: url) {
            imgData = img.jpegData() ?? (try? Data(contentsOf: url))
        }
        attachedFiles.append(AttachedFile(url: url, imageData: imgData))
    }

    /// Stage raw image bytes (dragged from a browser / pasted) → write a temp file so the
    /// attachment has a local path the agent can read.
    func attachImageData(_ data: Data) {
        guard attachedFiles.count < 10, let path = writeTempImage(data) else { return }
        attachedFiles.append(AttachedFile(url: URL(fileURLWithPath: path), imageData: data))
    }

    func removeAttachment(_ id: UUID) { attachedFiles.removeAll { $0.id == id } }
}
