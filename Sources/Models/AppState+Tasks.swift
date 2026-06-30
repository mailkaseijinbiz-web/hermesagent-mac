import Foundation

// タスク板(Phase B)を AppState 本体から分離（#3 god object 分割の継続）。
// @Published workTasks は stored property のため本体に残し、タスクCRUD・状態/並び替え・
// チャットからのタスク追加コマンド解析(parseTaskAddCommand/bulletItems 等)を集約。
// nested enum TaskAddCommand と private classifyTaskTitle も同梱。
extension AppState {
    // MARK: - Tasks (Phase B)

    @discardableResult
    func createTask(title: String, assigneeId: String?) -> WorkTask {
        var t = WorkTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        t.assigneeId = assigneeId
        workTasks.insert(t, at: 0)
        return t
    }

    /// Result of parsing a "register this as a task" chat command.
    enum TaskAddCommand: Equatable {
        case single(String)   // explicit title
        case fromContext      // referential ("これら" / "上記" …) → expand from the preceding list
    }

    /// Detect an imperative "register this as a task" chat message. Returns `.single(title)` for
    /// an explicit title, or `.fromContext` when the object is a demonstrative ("これら"/"上記"/
    /// "これ" …) — the caller then expands the bullet list from the preceding message into one
    /// task per item. Deliberately conservative so ordinary chat *about* tasks isn't hijacked:
    /// only fires on an explicit leading command ("タスク追加: …" / "/task …") or a trailing
    /// imperative ("…のタスクを追加[して]"). See `handleSendMessage`.
    func parseTaskAddCommand(_ text: String) -> TaskAddCommand? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\n") else { return nil }   // single-line commands only

        // Leading explicit form.
        for p in ["/task ", "タスク追加:", "タスク追加：", "タスク作成:", "タスク作成：", "タスク:", "タスク："] {
            if t.hasPrefix(p) {
                let title = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? nil : classifyTaskTitle(title)
            }
        }

        // Trailing imperative form: strip politeness/punctuation, then a task-verb suffix.
        for tail in ["。", "．", ".", "！", "!", "？", "?", "してください", "して下さい", "してね",
                     "してくれ", "してほしい", "して", "お願いします", "おねがいします", "お願い",
                     "よろしく", "頼む", "たのむ"] {
            while t.hasSuffix(tail) { t = String(t.dropLast(tail.count)).trimmingCharacters(in: .whitespaces) }
        }

        // 中央形「（Task|タスク|TODO）に <X>（を）追加/登録/作成」。英語の Task/TODO も許容。
        // 「タスクについて教えて」等の誤爆を避けるため、末尾が追加系の動詞の時だけ。
        let lower = t.lowercased()
        let middleLeads = ["task に", "taskに", "タスクに", "タスク に", "todoに", "todo に", "to do に"]
        if let lead = middleLeads.first(where: { lower.hasPrefix($0) }),
           ["追加", "登録", "作成"].contains(where: { t.hasSuffix($0) }) {
            var mid = String(t.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            for v in ["を追加", "に追加", "を登録", "を作成", "追加", "登録", "作成"] {
                if mid.hasSuffix(v) { mid = String(mid.dropLast(v.count)).trimmingCharacters(in: .whitespaces); break }
            }
            for tail in ["の", "を", "、", ",", "という", "って", "に"] {
                if mid.hasSuffix(tail) { mid = String(mid.dropLast(tail.count)).trimmingCharacters(in: .whitespaces) }
            }
            return classifyTaskTitle(mid)
        }
        let verbs = ["タスクとして追加", "タスクを追加", "タスクに追加", "タスクを作成", "タスクを登録",
                     "タスク追加", "タスク作成", "タスク登録", "TODOに追加", "ToDoに追加", "todoに追加"]
        for v in verbs where t.hasSuffix(v) {
            var title = String(t.dropLast(v.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            for tail in ["の", "を", "、", ",", "という", "って"] {
                if title.hasSuffix(tail) { title = String(title.dropLast(tail.count)).trimmingCharacters(in: .whitespaces) }
            }
            return classifyTaskTitle(title)
        }
        return nil
    }

    /// Classify a parsed task object: a demonstrative ("これら"/"上記"/"これ" …) means "expand the
    /// bullet list from the preceding message"; a too-vague word is rejected; else it's a real title.
    private func classifyTaskTitle(_ raw: String) -> TaskAddCommand? {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let referential: Set<String> = [
            "これ", "これら", "それ", "それら", "あれ", "あれら",
            "これら全部", "これらすべて", "これら全て", "それら全部", "それらすべて", "それら全て",
            "上記", "上記の", "上の", "以上", "全部", "すべて", "全て", "これ全部", "これ全て"
        ]
        if referential.contains(title) { return .fromContext }
        // Reject underspecified non-referential demonstratives/adjectives so we don't create junk.
        let stop: Set<String> = ["新しい", "この", "その", "あの", "次の", "新規", "ここに", "タスク", "task", "todo"]
        if title.count < 2 || stop.contains(title.lowercased()) { return nil }
        return .single(title)
    }

    /// For "これらをタスクに追加": pull list items from the most recent message that has any
    /// (assistant preferred — it's newest), so the preceding list becomes one task per item.
    func extractContextualTaskItems() -> [String] {
        for msg in messages.reversed().prefix(8) {
            guard msg.role == .assistant || msg.role == .user else { continue }
            let items = bulletItems(from: msg.content)
            if !items.isEmpty { return items }
        }
        return []
    }

    /// Pull list items (・ • - * / 1. 1)) from a markdown string, stripping bullet markers and
    /// **bold**. Lines without a bullet/number marker are ignored.
    func bulletItems(from content: String) -> [String] {
        let bulletChars: Set<Character> = ["・", "•", "‣", "◦", "-", "*", "–", "—", "●", "○", "▪", "▸", "◆", "·"]
        var out: [String] = []
        for rawLine in content.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var isBullet = false
            if let first = line.first, bulletChars.contains(first) {
                line.removeFirst(); isBullet = true
            } else if let m = line.range(of: #"^\d+[.\)、．]\s*"#, options: .regularExpression) {
                line = String(line[m.upperBound...]); isBullet = true
            }
            guard isBullet else { continue }
            line = line.replacingOccurrences(of: "**", with: "")
                       .replacingOccurrences(of: "__", with: "")
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " *_`~-–—"))
            // Require at least one letter/number so rules ("---") and bare markers are skipped.
            guard line.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { continue }
            out.append(line)
        }
        return out
    }
    func setTaskStatus(_ taskId: String, _ status: TaskStatus) {
        guard let idx = workTasks.firstIndex(where: { $0.id == taskId }) else { return }
        workTasks[idx].status = status
        workTasks[idx].updatedAt = Date().timeIntervalSince1970
    }

    /// タスクのタイトルを編集（空は無視）。
    func updateTaskTitle(_ taskId: String, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let idx = workTasks.firstIndex(where: { $0.id == taskId }) else { return }
        workTasks[idx].title = t
        workTasks[idx].updatedAt = Date().timeIntervalSince1970
    }

    func updateTaskDetail(_ taskId: String, _ detail: String) {
        guard let idx = workTasks.firstIndex(where: { $0.id == taskId }) else { return }
        workTasks[idx].detail = detail
        workTasks[idx].updatedAt = Date().timeIntervalSince1970
    }

    /// 締め切り期限を設定/解除（nil で解除）。
    func setTaskDue(_ taskId: String, _ due: Double?) {
        guard let idx = workTasks.firstIndex(where: { $0.id == taskId }) else { return }
        workTasks[idx].dueDate = due
        workTasks[idx].updatedAt = Date().timeIntervalSince1970
    }

    /// Drag-and-drop move on the task board. Sets the task's `status` and repositions it in
    /// the backing `workTasks` array: dropping on a card inserts just before it (`beforeId`),
    /// dropping on a column body (beforeId == nil) lands at the top of that column. Bumps
    /// `updatedAt` only on a real status change — array order is device-local (iCloud merge is
    /// by id/updatedAt, see the CloudKit merge), so a pure reorder shouldn't churn sync.
    func moveTask(_ taskId: String, to status: TaskStatus, before beforeId: String? = nil) {
        guard beforeId != taskId,
              let from = workTasks.firstIndex(where: { $0.id == taskId }) else { return }
        var task = workTasks.remove(at: from)
        if task.status != status {
            task.status = status
            task.updatedAt = Date().timeIntervalSince1970
        }
        let insertAt: Int
        if let beforeId, let target = workTasks.firstIndex(where: { $0.id == beforeId }) {
            insertAt = target
        } else {
            insertAt = workTasks.firstIndex(where: { $0.status == status }) ?? workTasks.count
        }
        workTasks.insert(task, at: min(max(0, insertAt), workTasks.count))
    }
    func assignTask(_ taskId: String, to assigneeId: String?) {
        guard let idx = workTasks.firstIndex(where: { $0.id == taskId }) else { return }
        workTasks[idx].assigneeId = assigneeId
        workTasks[idx].updatedAt = Date().timeIntervalSince1970
    }
    func deleteTask(_ taskId: String) {
        tombstone(taskId)
        workTasks.removeAll { $0.id == taskId }
    }
    func tasks(status: TaskStatus) -> [WorkTask] { workTasks.filter { $0.status == status } }

}
