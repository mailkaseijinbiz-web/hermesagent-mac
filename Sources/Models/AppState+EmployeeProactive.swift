import Foundation

// MARK: - Proactive check-in prompts & scheduler

enum EmployeeProactivePrompt {
    /// Builds the agent instruction for a daily proactive check-in.
    static func checkIn(for emp: Employee, pendingTasks: [WorkTask], hour: Int) -> String {
        let greeting: String
        switch hour {
        case 5..<11: greeting = "おはようございます"
        case 11..<17: greeting = "こんにちは"
        case 17..<22: greeting = "お疲れさまです"
        default: greeting = "こんばんは"
        }
        var context = ""
        if !pendingTasks.isEmpty {
            let titles = pendingTasks.prefix(3).map(\.title).joined(separator: "、")
            context = "\n参考: 未完了タスク — \(titles)"
        }
        return """
        【社内チェックイン（能動連絡）】
        ユーザーはまだ話しかけていません。\(greeting)。\(emp.name)（\(emp.role.title)）として、短い挨拶と今日の優先事項・助言を1〜3文で能動的に伝えてください。質問は1つまで。箇条書きは避け、自然な口調で。\(context)
        """
    }
}

extension AppState {
    private static let proactiveDayKeyPrefix = "empProactiveDay-"

    /// Poll every 5 minutes; send a morning check-in once per employee per day (9:00–9:10).
    func startEmployeeProactiveScheduler() {
        proactiveSchedulerTimer?.invalidate()
        proactiveSchedulerTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runProactiveCheckInsIfDue() }
        }
        Task { @MainActor in runProactiveCheckInsIfDue() }
    }

    func runProactiveCheckInsIfDue() {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        guard hour == 9, minute < 10 else { return }
        let dayKey = Self.proactiveDayKey(for: now)
        for emp in activeEmployees where emp.isProactiveEnabled {
            let key = Self.proactiveDayKeyPrefix + emp.id
            guard UserDefaults.standard.string(forKey: key) != dayKey else { continue }
            sendProactiveCheckIn(to: emp.id)
            UserDefaults.standard.set(dayKey, forKey: key)
        }
    }

    private static func proactiveDayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Send a proactive check-in in the employee's own session without hijacking the UI.
    func sendProactiveCheckIn(to employeeId: String) {
        guard let emp = employees.first(where: { $0.id == employeeId }),
              !emp.isArchived, emp.isProactiveEnabled else { return }
        let key = employeeId
        guard !streamingEmployeeIds.contains(key) else { return }

        // Persist outgoing employee context (same as switchEmployee out-path).
        let outKey = empKey(activeEmployeeId)
        empMessages[outKey] = cappedShadow(messages)
        if let curId = activeEmployeeId,
           let idx = employees.firstIndex(where: { $0.id == curId }) {
            employees[idx].sessionId = currentSessionId
            recordSessionOwner(currentSessionId, curId)
        }

        let savedActive = activeEmployeeId
        let savedMessages = messages
        let savedSession = currentSessionId
        let savedStream = streamText

        activeEmployeeId = employeeId
        agentMode = emp.mode
        currentSessionId = emp.sessionId
        messages = emp.sessionId.map { messagesFromStore($0) } ?? []
        streamText = ""

        let hour = Calendar.current.component(.hour, from: Date())
        let pending = workTasks.filter { $0.assigneeId == employeeId && $0.status != .done }
        proactiveSendPrompt = EmployeeProactivePrompt.checkIn(for: emp, pendingTasks: pending, hour: hour)
        bypassCommandIntercept = true
        inputValue = "（能動チェックイン）"
        handleSendMessage()
        bypassCommandIntercept = false
        inputValue = ""

        // Restore the user's context immediately; streaming continues in the shadow.
        activeEmployeeId = savedActive
        currentSessionId = savedSession
        messages = savedMessages
        streamText = savedStream
    }
}
