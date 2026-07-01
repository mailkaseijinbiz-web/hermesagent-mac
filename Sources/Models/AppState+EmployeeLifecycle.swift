import Foundation

// 社員のライフサイクル/切替/委譲を分離（#3 分割の継続）: hire/fire、switchEmployee、
// セッション紐付け、delegate(マネージャ委譲)。stored(empMessages等/modelApplyTask)は本体残置・internal化済み。
extension AppState {
    // MARK: - AI employees ("会社")

    /// Hire a new employee with role defaults. Returns the created employee.
    @discardableResult
    func hireEmployee(name: String, role: EmployeeRole) -> Employee {
        let emp = Employee.make(name: name.trimmingCharacters(in: .whitespacesAndNewlines), role: role)
        employees.append(emp)
        ensureEmployeeWorkspace(emp.id)   // auto-assign a working folder on hire
        triggerToast(message: "\(emp.role.title)「\(emp.name)」を採用しました")
        if cloudSyncEnabled { Task { await pushEmployees() } }
        return emp
    }

    /// Fire (remove) an employee, with an Undo toast (avatar kept for restore).
    /// Cascades to the employee's per-employee data so nothing is orphaned: their
    /// artifacts are tombstoned+removed and their tasks are unassigned (kept on the
    /// board as 未割当). Undo restores all of it.
    func fireEmployee(_ id: String) {
        guard let removed = employees.first(where: { $0.id == id }) else { return }
        // Capture owned data before removal (for cascade + undo).
        let removedArtifacts = artifacts.filter { $0.employeeId == id }
        let unassignedTaskIds = workTasks.filter { $0.assigneeId == id }.map { $0.id }
        let unassignedAppIds = apps.filter { $0.assigneeId == id }.map { $0.id }
        let unassignedEventIds = events.filter { $0.assigneeId == id }.map { $0.id }

        employees.removeAll { $0.id == id }
        tombstone(id)
        // Cascade: tombstone+remove the employee's artifacts; unassign tasks/apps/events.
        for a in removedArtifacts { tombstone(a.id) }
        artifacts.removeAll { $0.employeeId == id }
        let nowFire = Date().timeIntervalSince1970
        for i in workTasks.indices where workTasks[i].assigneeId == id {
            workTasks[i].assigneeId = nil; workTasks[i].updatedAt = nowFire
        }
        for i in apps.indices where apps[i].assigneeId == id {
            apps[i].assigneeId = nil; apps[i].updatedAt = nowFire
        }
        for i in events.indices where events[i].assigneeId == id {
            events[i].assigneeId = nil; events[i].updatedAt = nowFire
        }

        if activeEmployeeId == id { switchEmployee(nil) }
        if cloudSyncEnabled { Task { await deleteCloudEmployee(id) } }
        triggerToast(message: "\(removed.role.title)「\(removed.name)」を解雇しました", actionLabel: "取り消し") { [weak self] in
            guard let self = self, !self.employees.contains(where: { $0.id == removed.id }) else { return }
            self.syncTombstones[removed.id] = nil      // undo the delete: clear its tombstone
            var restored = removed
            restored.updatedAt = Date().timeIntervalSince1970   // beat any stale tombstone on other devices
            self.employees.append(restored)
            // Restore cascaded data: clear tombstones, re-add artifacts, re-assign tasks.
            let now = Date().timeIntervalSince1970
            for a in removedArtifacts { self.syncTombstones[a.id] = nil }
            self.artifacts.append(contentsOf: removedArtifacts.map { var x = $0; x.updatedAt = now; return x })
            for tid in unassignedTaskIds {
                if let idx = self.workTasks.firstIndex(where: { $0.id == tid }) {
                    self.workTasks[idx].assigneeId = removed.id
                    self.workTasks[idx].updatedAt = now
                }
            }
            for aid in unassignedAppIds {
                if let idx = self.apps.firstIndex(where: { $0.id == aid }) {
                    self.apps[idx].assigneeId = removed.id; self.apps[idx].updatedAt = now
                }
            }
            for eid in unassignedEventIds {
                if let idx = self.events.firstIndex(where: { $0.id == eid }) {
                    self.events[idx].assigneeId = removed.id; self.events[idx].updatedAt = now
                }
            }
            if self.cloudSyncEnabled { Task { await self.pushEmployees() } }
            self.triggerToast(message: "「\(removed.name)」を戻しました")
        }
    }

    /// Soft-archive: hide from roster/sidebar; data and assignments are kept.
    func archiveEmployee(_ id: String) {
        guard let idx = employees.firstIndex(where: { $0.id == id }), !employees[idx].isArchived else { return }
        let name = employees[idx].name
        employees[idx].archived = true
        employees[idx].proactiveEnabled = false
        employees[idx].updatedAt = Date().timeIntervalSince1970
        if activeEmployeeId == id { switchEmployee(nil) }
        triggerToast(message: "「\(name)」をアーカイブしました")
    }

    func unarchiveEmployee(_ id: String) {
        guard let idx = employees.firstIndex(where: { $0.id == id }), employees[idx].isArchived else { return }
        let name = employees[idx].name
        employees[idx].archived = false
        employees[idx].updatedAt = Date().timeIntervalSince1970
        triggerToast(message: "「\(name)」のアーカイブを解除しました")
    }

    func toggleProactiveEmployee(_ id: String) {
        guard let idx = employees.firstIndex(where: { $0.id == id }),
              !employees[idx].isArchived else { return }
        employees[idx].proactiveEnabled = !employees[idx].isProactiveEnabled
        employees[idx].updatedAt = Date().timeIntervalSince1970
        let on = employees[idx].isProactiveEnabled
        triggerToast(message: on ? "「\(employees[idx].name)」が能動的に話しかけます" : "能動連絡をオフにしました")
    }

    private func deleteCloudEmployee(_ id: String) async {
        guard let base = supabaseBase,
              let url = URL(string: "\(base)/rest/v1/employees?id=eq.\(id)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "DELETE"; req.timeoutInterval = 15; cloudHeaders(&req)
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Make an employee active: apply their model/persona/mode/cwd and load THEIR
    /// isolated session. nil → back to the default single-agent (no employee).
    func switchEmployee(_ id: String?) {
        cwdOverride = nil
        // Save the outgoing employee's current messages to their shadow (preserves streaming bubble).
        let outKey = empKey(activeEmployeeId)
        empMessages[outKey] = cappedShadow(messages)
        if let curId = activeEmployeeId, let idx = employees.firstIndex(where: { $0.id == curId }) {
            employees[idx].sessionId = currentSessionId
            recordSessionOwner(currentSessionId, curId)
        }
        activeEmployeeId = id
        if let id { employeeUnreadIds.remove(id) }
        let newKey = empKey(id)

        // If the full-screen employee detail is open, follow the sidebar selection so picking a
        // different employee on the left shows that employee's management on the right.
        if view == "employee", let id { detailEmployeeId = id }

        if let emp = activeEmployee {
            agentMode = emp.mode
            currentSessionId = emp.sessionId
            // If the incoming employee has an in-flight turn, show their live shadow messages
            // (includes the streaming bubble). Otherwise load from the store as usual.
            if streamingEmployeeIds.contains(newKey), let live = empMessages[newKey], !live.isEmpty {
                messages = live
                streamText = empStreamTexts[newKey] ?? ""
            } else {
                messages = emp.sessionId.map { messagesFromStore($0) } ?? []
                streamText = ""
            }
            let m = modelForFixedProvider(emp)
            modelApplyTask = Task { await applyModelSilently(model: m) }
        } else {
            currentSessionId = nil
            if streamingEmployeeIds.contains(newKey), let live = empMessages[newKey], !live.isEmpty {
                messages = live
                streamText = empStreamTexts[newKey] ?? ""
            } else {
                messages = []
                streamText = ""
            }
            modelApplyTask = nil
        }
        inputValue = ""
        // Liveness indicator: if the employee we switched to is mid-stream, we don't know the
        // original start time — approximate it as "now" so the elapsed/heartbeat keeps working;
        // otherwise clear it.
        if streamingEmployeeIds.contains(newKey) {
            streamStartedAt = Date()   // real start is unknown post-switch — approximate
            lastStreamActivityAt = Date()
        } else {
            streamStartedAt = nil; lastStreamActivityAt = nil
        }
        // Only reset this employee's dedicated ACP client if they are NOT currently streaming.
        // The shared ACP client (used for delegation) is independent — never reset here.
        if !streamingEmployeeIds.contains(newKey) { empACPClients[newKey]?.resetSession() }
        view = "chat"
    }

    /// Bind a session to a specific employee (context isolation) — used by the in-flight
    /// turn reconcile so a turn that finished after you switched away is attributed correctly.
    func bindSession(_ sid: String?, toEmployee empId: String?) {
        guard let empId = empId, let sid = sid,
              let idx = employees.firstIndex(where: { $0.id == empId }) else { return }
        if employees[idx].sessionId != sid { employees[idx].sessionId = sid }
        recordSessionOwner(sid, empId)
    }

    /// Bind the just-created hermes session to the active employee (context isolation).
    func bindCurrentSessionToActiveEmployee() {
        guard let empId = activeEmployeeId, let sid = currentSessionId,
              let idx = employees.firstIndex(where: { $0.id == empId }) else { return }
        if employees[idx].sessionId != sid { employees[idx].sessionId = sid }
        recordSessionOwner(sid, empId)
    }

    /// Phase 2 — Manager delegation. Run `task` in `target`'s ISOLATED context (their
    /// persona + session + workspace) and append the result to the current (manager's)
    /// chat, attributed to the specialist. Does not change the active employee or model.
    func delegate(to employeeId: String, task: String) async {
        guard !isStreaming, let target = employees.first(where: { $0.id == employeeId }) else { return }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Visible: the assignment (synthetic user bubble) + the specialist's reply bubble.
        messages.append(Message(role: .user, content: "［委譲→\(target.role.title)・\(target.name)］\(trimmed)"))
        let msgId = UUID()
        messages.append(Message(id: msgId, role: .assistant, content: "", typewriter: true,
                                delegatedName: target.name, delegatedRole: target.role,
                                delegatedId: employeeId))
        let delegateKey = empKey()
        streamingEmployeeIds.insert(delegateKey)  // manager's chat slot is occupied
        activeStatus = "thinking"
        busyEmployeeIds.insert(employeeId)   // the specialist is now working (spinner)
        recordSessionOwner(target.sessionId, employeeId)
        let started = Date()

        let directive = "あなたは「\(target.name)」という名前の\(target.role.title)です。\(target.persona) \(target.mode.directive)"
        let wrapped = "\(trimmed)\n\n\(AgentMode.sentinelOpen)\(directive)\(AgentMode.sentinelClose)"
        let cwd = target.workspacePath ?? effectiveCwd
        let kind = BackendRouter.selectKind(provider: provider, useACP: useACPTransport)

        func finishDelegate() {
            busyEmployeeIds.remove(employeeId)
            streamingEmployeeIds.remove(delegateKey)
            if streamingEmployeeIds.isEmpty && busyEmployeeIds.isEmpty { activeStatus = "online" }
        }

        // agy install check (clear hint) at the call site.
        if kind == .antigravity, await AntigravityCLI.shared.resolveBinaryAsync() == nil {
            if let i = messages.firstIndex(where: { $0.id == msgId }) {
                messages[i].content = AntigravityCLI.installHint; messages[i].isError = true; messages[i].typewriter = false
            }
            finishDelegate(); await fetchSessions(); return
        }

        // Run on the specialist's MODEL (provider fixed), then restore the manager's —
        // Hermes/ACP only (agy carries its model in the request, no Hermes config swap).
        var swapModel = false
        var mgrModel = defaultModel
        if kind != .antigravity {
            await modelApplyTask?.value
            mgrModel = defaultModel
            let targetModel = modelForFixedProvider(target)
            swapModel = (targetModel != mgrModel)
            if swapModel { await setHermesModelConfig(model: targetModel) }
        }

        let req = AgentRequest(
            prompt: wrapped,
            agyPrompt: antigravityPrompt(trimmed, employee: target, mode: target.mode),
            imagePath: nil, cwd: cwd,
            sessionId: target.sessionId, startFresh: target.sessionId == nil,
            agyModel: modelForFixedProvider(target))

        var acc = ""
        let backend = BackendRouter.make(kind, acp: .shared)
        let result = await backend.send(
            req,
            onStart: { [weak self] proc in self?.delegationProcess = proc },
            onEvent: { [weak self] event in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    guard case .chunk(let t) = event,
                          let i = self.messages.firstIndex(where: { $0.id == msgId }) else { return }
                    acc += t
                    switch kind {       // delegation UI shows only the reply (no reasoning/tool cards)
                    case .hermesCLI:   self.messages[i].content = self.parseResponseText(acc)
                    case .antigravity: self.messages[i].content = AntigravityCLI.clean(acc)
                    case .acp:         self.messages[i].content = acc
                    }
                }
            })

        self.delegationProcess = nil
        let final: String
        switch kind {
        case .hermesCLI:   final = parseResponseText(acc)
        case .antigravity: final = AntigravityCLI.clean(acc)
        case .acp:         final = acc
        }
        if let i = messages.firstIndex(where: { $0.id == msgId }) {
            messages[i].typewriter = false
            messages[i].elapsed = Date().timeIntervalSince(started)
            if kind == .acp, let t = result.tokens { messages[i].tokens = t }
            if final.isEmpty {
                if kind == .acp {
                    messages[i].content = result.ok ? "(空の応答)" : "委譲に失敗しました"; messages[i].isError = !result.ok
                } else {
                    messages[i].content = "委譲に失敗しました"; messages[i].isError = true
                }
            } else {
                messages[i].content = final
            }
        }

        // Per-kind specialist-session adoption.
        switch kind {
        case .antigravity:
            if !final.isEmpty {
                let sid = AgyStore.shared.record(sessionId: target.sessionId, employeeId: employeeId,
                                                 userText: trimmed, assistantText: final, timestamp: Date().timeIntervalSince1970)
                if let ti = employees.firstIndex(where: { $0.id == employeeId }) {
                    employees[ti].sessionId = sid; recordSessionOwner(sid, employeeId)
                }
            }
        case .acp:
            // Only adopt a brand-new specialist session; never overwrite an existing id.
            if target.sessionId == nil, let ti = employees.firstIndex(where: { $0.id == employeeId }),
               let hsid = result.hermesSessionId {
                employees[ti].sessionId = hsid; recordSessionOwner(hsid, employeeId)
            }
            // Reset the shared ACP client so the manager's next message resumes their session.
            ACPClient.shared.resetSession()
        case .hermesCLI:
            if target.sessionId == nil {
                await fetchSessions()
                if let ti = employees.firstIndex(where: { $0.id == employeeId }), let first = sessions.first {
                    employees[ti].sessionId = first.id; recordSessionOwner(first.id, employeeId)
                }
            }
        }

        if swapModel { await setHermesModelConfig(model: mgrModel) }
        finishDelegate()
        await fetchSessions()
    }

    /// Temporarily set the hermes MODEL (provider is fixed) WITHOUT touching the published
    /// provider/defaultModel — used to run a delegated task on a specialist's model, then
    /// restore the manager's.
    private func setHermesModelConfig(model: String) async {
        // Antigravity isn't a Hermes provider — it runs via `agy`, not the Hermes config.
        guard provider != AntigravityCLI.providerId else { return }
        await writeHermesModelConfig(provider: provider, model: model)
    }

}
