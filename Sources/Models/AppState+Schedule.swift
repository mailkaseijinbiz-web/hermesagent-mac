import Foundation

// スケジュール(Phase G)関連を分離（#3 分割の継続）: カレンダーCRUD・会議(holdMeeting)・
// オートメーション登録・タスク委譲(startTask)・モバイル/送信整形。@Published scheduleEvents は本体残置。
extension AppState {
    // MARK: - Schedule (Phase G — calendar events)

    /// Events on a given calendar day (local time), earliest first.
    func events(on day: Date) -> [ScheduleEvent] {
        let cal = Calendar.current
        return events
            .filter { cal.isDate(Date(timeIntervalSince1970: $0.date), inSameDayAs: day) }
            .sorted { ($0.allDay ? 0 : 1, $0.date) < ($1.allDay ? 0 : 1, $1.date) }
    }
    /// True if a day has any events (for the calendar dot).
    func hasEvents(on day: Date) -> Bool {
        let cal = Calendar.current
        return events.contains { cal.isDate(Date(timeIntervalSince1970: $0.date), inSameDayAs: day) }
    }

    @discardableResult
    func addEvent(title: String, date: Double, allDay: Bool, detail: String = "", assigneeId: String? = nil) -> ScheduleEvent {
        var e = ScheduleEvent(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "予定" : title.trimmingCharacters(in: .whitespacesAndNewlines), date: date)
        e.allDay = allDay; e.detail = detail; e.assigneeId = assigneeId
        events.append(e)
        triggerToast(message: "予定を追加しました")
        return e
    }
    func updateEvent(_ id: String, title: String? = nil, date: Double? = nil, allDay: Bool? = nil,
                     detail: String? = nil, assigneeId: String?? = nil) {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        if let v = title?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { events[idx].title = v }
        if let v = date { events[idx].date = v }
        if let v = allDay { events[idx].allDay = v }
        if let v = detail { events[idx].detail = v }
        if let v = assigneeId { events[idx].assigneeId = v }
        events[idx].updatedAt = Date().timeIntervalSince1970
    }
    func deleteEvent(_ id: String) {
        tombstone(id); events.removeAll { $0.id == id }
    }

    /// Phase C — a meeting: ask each participant the topic (in their isolated context),
    /// then optionally have a manager synthesize. Reuses `delegate` per participant.
    func holdMeeting(topic: String, participantIds: [String], synthesize: Bool) async {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !t.isEmpty, !participantIds.isEmpty else { return }
        view = "chat"
        messages.append(Message(role: .system, content: "会議: \(t)"))

        var transcript: [(name: String, text: String)] = []
        for pid in participantIds {
            guard let emp = employees.first(where: { $0.id == pid }) else { continue }
            await delegate(to: pid, task: t)
            if let last = messages.last(where: { $0.delegatedName == emp.name && !$0.isError && !$0.content.isEmpty }) {
                transcript.append((emp.name, last.content))
            }
        }

        if synthesize, !transcript.isEmpty,
           let mgr = activeEmployee?.role == .manager ? activeEmployee : employees.first(where: { $0.role == .manager }) {
            let body = transcript.map { "【\($0.name)】\n\($0.text)" }.joined(separator: "\n\n")
            let prompt = "次の会議の各メンバーの意見をまとめ、結論と次のアクションを簡潔に示してください。\n\n\(body)"
            await delegate(to: mgr.id, task: prompt)
        }
    }

    /// Register an automation (cron) for a specific employee: preset the assignee (and
    /// optionally the prompt/name) and jump to the Automations screen to set the schedule.
    func registerAutomationForEmployee(_ employeeId: String, prompt: String? = nil) {
        newCronAssigneeId = employeeId
        if let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            newCronPrompt = p
        }
        if let emp = employees.first(where: { $0.id == employeeId }),
           newCronName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newCronName = "\(emp.name)の定期タスク"
        }
        openAutomationsSettings()
        triggerToast(message: "担当者を設定しました。スケジュールと指示を入力して作成してください。")
    }

    /// Hand a task to its assignee: switch to that employee, prefill the task as the
    /// prompt, mark it 対応中, and open the chat.
    func startTask(_ taskId: String) {
        guard let t = workTasks.first(where: { $0.id == taskId }) else { return }
        if let aid = t.assigneeId, employees.contains(where: { $0.id == aid }) {
            switchEmployee(aid)
        }
        setTaskStatus(taskId, .doing)
        inputValue = t.title + (t.detail.isEmpty ? "" : "\n\n\(t.detail)")
        view = "chat"
    }

    /// Mobile send wrap: explicit mode + optional employee (iOS picks the employee, not
    /// the Mac's active one). Sentinel-stripped from display like wrapForSend.
    func wrapForMobile(_ text: String, mode: AgentMode, employeeId: String?) -> String {
        var directive = ""
        if let eid = employeeId, let emp = employees.first(where: { $0.id == eid }) {
            directive += "あなたは「\(emp.name)」という名前の\(emp.role.title)です。\(emp.persona) "
        }
        directive += mode.directive
        return "\(text)\n\n\(AgentMode.sentinelOpen)\(directive)\(AgentMode.sentinelClose)"
    }

    /// The sentinel-wrapped directive for a send: active employee persona (if any) + mode.
    func wrapForSend(_ text: String) -> String {
        var directive = ""
        if let emp = activeEmployee {
            directive += "あなたは「\(emp.name)」という名前の\(emp.role.title)です。\(emp.persona) "
        }
        directive += agentMode.directive
        return "\(text)\n\n\(AgentMode.sentinelOpen)\(directive)\(AgentMode.sentinelClose)"
    }

}
