import Foundation

// Cloud / iCloud sync logic extracted from AppState.swift (Phase G2).
extension AppState {
    // Supabase同期はCloudKit移行完了に伴い撤去（2026-07-03）。同期の正はCloudKitSync。

    /// The workspace key grouping this user's devices (explicit, else allowed email, else default).
    var effectiveCloudWorkspace: String {
        let w = cloudWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !w.isEmpty { return w }
        return mobileAllowedEmail.isEmpty ? "default" : mobileAllowedEmail
    }

    /// Write+read+delete one probe record in CloudKit to verify entitlements + account.
    func testICloud() async {
        isTestingICloud = true
        defer { isTestingICloud = false }
        icloudStatus = "テスト中…"
        do {
            icloudStatus = try await CloudKitSync.smokeTest()
        } catch {
            icloudStatus = "失敗: \(error.localizedDescription)"
        }
    }
    /// Record a delete so it wins over stale copies on other devices.
    func tombstone(_ id: String) { syncTombstones[id] = Date().timeIntervalSince1970 }

    /// True if `id` was deleted at/after the item's own last edit (so the delete wins).
    private func tombstoneWins(_ id: String, _ itemUpdated: Double) -> Bool {
        if let ts = syncTombstones[id], ts >= itemUpdated { return true }
        return false
    }

    /// Drop tombstones older than 60 days so the record doesn't grow without bound.
    private func prunedTombstones() -> [String: Double] {
        let cutoff = Date().timeIntervalSince1970 - 60 * 24 * 3600
        return syncTombstones.filter { $0.value >= cutoff }
    }

    /// Build the shared-fields payload from current local state (call after merge).
    private func localRosterPayload() -> CloudKitSync.RosterPayload {
        let emps = employees.map {
            CloudKitSync.EmployeeShared(
                id: $0.id, name: $0.name, role: $0.role.rawValue,
                provider: $0.provider, model: $0.model, mode: $0.mode.rawValue,
                personaOverride: $0.personaOverride, teamId: $0.teamId,
                createdAt: $0.createdAt, updatedAt: $0.updatedAt ?? $0.createdAt,
                archived: $0.isArchived, proactiveEnabled: $0.isProactiveEnabled)
        }
        // .file artifacts hold a device-local absolute path (like workspacePath, which
        // is deliberately not synced) — they'd render as broken rows on other devices, so
        // only sync the portable kinds (note/link). Their deletes still propagate via tombstones.
        return CloudKitSync.RosterPayload(employees: emps, teams: teams,
                                          tasks: workTasks,
                                          artifacts: artifacts.filter { $0.kind != .file },
                                          apps: apps, events: events,
                                          tombstones: prunedTombstones())
    }

    /// Merge a fetched cloud roster into local state (item-level last-write-wins + tombstones).
    private func mergeRoster(_ cloud: CloudKitSync.RosterPayload) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }

        // Union tombstones (keep the newest deletion time per id).
        for (id, ts) in cloud.tombstones where (syncTombstones[id] ?? 0) < ts { syncTombstones[id] = ts }

        // Employees — LWW on shared fields; keep device-local fields (avatar/cwd/session).
        for ce in cloud.employees {
            guard let role = EmployeeRole(rawValue: ce.role) else { continue }
            if tombstoneWins(ce.id, ce.updatedAt) { continue }
            if let idx = employees.firstIndex(where: { $0.id == ce.id }) {
                let local = employees[idx].updatedAt ?? employees[idx].createdAt
                if ce.updatedAt > local {
                    employees[idx].name = ce.name
                    employees[idx].provider = ce.provider
                    employees[idx].model = ce.model
                    employees[idx].mode = AgentMode(rawValue: ce.mode) ?? role.defaultMode
                    employees[idx].personaOverride = ce.personaOverride
                    employees[idx].teamId = ce.teamId
                    employees[idx].updatedAt = ce.updatedAt
                    if let a = ce.archived { employees[idx].archived = a }
                    if let p = ce.proactiveEnabled { employees[idx].proactiveEnabled = p }
                }
            } else {
                var e = Employee(name: ce.name, role: role, provider: ce.provider,
                                 model: ce.model, mode: AgentMode(rawValue: ce.mode) ?? role.defaultMode)
                e.id = ce.id
                e.personaOverride = ce.personaOverride
                e.teamId = ce.teamId
                e.createdAt = ce.createdAt
                e.updatedAt = ce.updatedAt
                e.archived = ce.archived
                e.proactiveEnabled = ce.proactiveEnabled
                employees.append(e)
            }
        }
        employees.removeAll { tombstoneWins($0.id, $0.updatedAt ?? $0.createdAt) }

        // Teams
        for ct in cloud.teams {
            if tombstoneWins(ct.id, ct.updatedAt ?? 0) { continue }
            if let idx = teams.firstIndex(where: { $0.id == ct.id }) {
                if (ct.updatedAt ?? 0) > (teams[idx].updatedAt ?? 0) { teams[idx] = ct }
            } else {
                teams.append(ct)
            }
        }
        teams.removeAll { tombstoneWins($0.id, $0.updatedAt ?? 0) }

        // Tasks
        for ck in cloud.tasks {
            if tombstoneWins(ck.id, ck.updatedAt) { continue }
            if let idx = workTasks.firstIndex(where: { $0.id == ck.id }) {
                if ck.updatedAt > workTasks[idx].updatedAt { workTasks[idx] = ck }
            } else {
                workTasks.append(ck)
            }
        }
        workTasks.removeAll { tombstoneWins($0.id, $0.updatedAt) }

        // Artifacts (Phase E)
        for ca in cloud.artifacts {
            if tombstoneWins(ca.id, ca.updatedAt) { continue }
            if let idx = artifacts.firstIndex(where: { $0.id == ca.id }) {
                if ca.updatedAt > artifacts[idx].updatedAt { artifacts[idx] = ca }
            } else {
                artifacts.append(ca)
            }
        }
        artifacts.removeAll { tombstoneWins($0.id, $0.updatedAt) }

        // Apps (Phase F)
        for ca in cloud.apps {
            if tombstoneWins(ca.id, ca.updatedAt) { continue }
            if let idx = apps.firstIndex(where: { $0.id == ca.id }) {
                if ca.updatedAt > apps[idx].updatedAt { apps[idx] = ca }
            } else {
                apps.append(ca)
            }
        }
        apps.removeAll { tombstoneWins($0.id, $0.updatedAt) }

        // Events (Phase G)
        for ce in cloud.events {
            if tombstoneWins(ce.id, ce.updatedAt) { continue }
            if let idx = events.firstIndex(where: { $0.id == ce.id }) {
                if ce.updatedAt > events[idx].updatedAt { events[idx] = ce }
            } else {
                events.append(ce)
            }
        }
        events.removeAll { tombstoneWins($0.id, $0.updatedAt) }
    }
    /// Full sync: pull cloud, merge, then push the merged result.
    func syncRosterNow() async {
        guard icloudUsable else { icloudStatus = "iCloud同期がオフです"; return }
        isSyncingICloud = true
        defer { isSyncingICloud = false }
        icloudStatus = "iCloud同期中…"
        let ws = effectiveCloudWorkspace
        do {
            if let cloud = try await CloudKitSync.fetchRoster(workspace: ws) { mergeRoster(cloud) }
            let payload = localRosterPayload()
            try await CloudKitSync.pushRoster(payload, workspace: ws)
            lastPushedRosterSig = rosterSignature(payload)
            icloudStatus = "iCloud同期完了（社員\(employees.count)・チーム\(teams.count)・タスク\(workTasks.count)）"
        } catch {
            icloudStatus = "iCloud同期 失敗: \(error.localizedDescription)"
        }
    }

    /// Debounced push triggered by local edits (skips device-local-only churn).
    func scheduleICloudPush() {
        guard icloudUsable, !isApplyingRemote else { return }
        icloudPushTask?.cancel()
        icloudPushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pushRosterOnly()
        }
    }

    private func pushRosterOnly() async {
        guard icloudUsable else { return }
        let payload = localRosterPayload()
        let sig = rosterSignature(payload)
        guard sig != lastPushedRosterSig else { return }   // shared fields unchanged → skip
        do {
            try await CloudKitSync.pushRoster(payload, workspace: effectiveCloudWorkspace)
            lastPushedRosterSig = sig
        } catch {
            icloudStatus = "iCloud push失敗: \(error.localizedDescription)"
        }
    }

    private func rosterSignature(_ p: CloudKitSync.RosterPayload) -> Int {
        (try? JSONEncoder().encode(p))?.hashValue ?? 0
    }

    // MARK: - iCloud message mirror (Stage 2: one-way; state.db is CLI-owned / read-only)

    /// Cap one session's mirrored messages under CloudKit's ~1MB record limit: keep the
    /// most recent, dropping oldest until the JSON fits.
    private func capMessages(_ rows: [StateDB.MessageRow]) -> [CloudKitSync.MessageDTO] {
        var dtos = rows.suffix(1000).map {
            CloudKitSync.MessageDTO(id: $0.id, role: $0.role, content: $0.content,
                                    timestamp: $0.timestamp, tokenCount: $0.tokenCount)
        }
        while dtos.count > 1, let data = try? JSONEncoder().encode(dtos), data.count > 950_000 {
            dtos.removeFirst(max(1, dtos.count / 10))
        }
        return dtos
    }

    /// Mirror sessions + (changed) messages up to CloudKit. One-way — never written back.
    func mirrorMessagesNow() async {
        guard icloudUsable else { icloudStatus = "iCloud同期がオフです"; return }
        isMirroringMessages = true
        defer { isMirroringMessages = false }
        icloudStatus = "メッセージをミラー中…"
        let ws = effectiveCloudWorkspace
        let sessions = StateDB.shared.sessions(limit: 500)
        do {
            var metas: [CloudKitSync.SessionMeta] = []
            var pushed = 0, remaining = 0
            for s in sessions {
                metas.append(CloudKitSync.SessionMeta(
                    id: s.id, title: s.title, preview: s.preview, source: s.source,
                    archived: s.archived, messageCount: s.messageCount,
                    lastMessageId: s.lastMessageId, updatedAt: s.updatedAt))
                guard s.lastMessageId > (mirroredSessionMsgId[s.id] ?? -1) else { continue }
                if pushed >= mirrorLogsPerRun { remaining += 1; continue }
                let msgs = capMessages(StateDB.shared.messages(sessionId: s.id))
                try await CloudKitSync.pushSessionLog(ws: ws, sessionId: s.id, messages: msgs)
                mirroredSessionMsgId[s.id] = s.lastMessageId
                pushed += 1
            }
            try await CloudKitSync.pushSessionIndex(ws: ws, sessions: metas)
            icloudStatus = remaining > 0
                ? "メッセージをミラー（セッション\(metas.count)・更新\(pushed)、残り\(remaining)件は次回）"
                : "メッセージをミラーしました（セッション\(metas.count)・更新\(pushed)）"
            if remaining > 0 {   // more changed sessions remain → continue shortly
                mirrorPushTask?.cancel()
                mirrorPushTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    await self.mirrorMessagesNow()
                }
            }
        } catch {
            icloudStatus = "メッセージミラー失敗: \(error.localizedDescription)"
        }
    }

    /// Debounced auto-mirror, triggered by store changes when the toggle is on.
    func scheduleMessageMirror() {
        guard icloudUsable, icloudMirrorMessages, !isMirroringMessages else { return }
        mirrorPushTask?.cancel()
        mirrorPushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.mirrorMessagesNow()
        }
    }

    /// Read the mirror back from CloudKit to confirm the one-way round-trip works.
    func verifyCloudHistory() async {
        guard icloudUsable else { icloudStatus = "iCloud同期がオフです"; return }
        icloudStatus = "クラウド履歴を確認中…"
        do {
            let ws = effectiveCloudWorkspace
            let metas = try await CloudKitSync.fetchSessionIndex(ws: ws)
            let total = metas.reduce(0) { $0 + $1.messageCount }
            if let first = metas.first {
                let log = try await CloudKitSync.fetchSessionLog(ws: ws, sessionId: first.id)
                icloudStatus = "クラウド履歴: セッション\(metas.count)件・メタ合計\(total)msg（先頭「\(first.title)」のミラー\(log.count)msg）"
            } else {
                icloudStatus = "クラウド履歴: セッション0件（まだミラーされていません）"
            }
        } catch {
            icloudStatus = "履歴確認失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - iCloud live sync (Stage 3: near-realtime via lightweight polling)
    //
    // The public DB can't use CKDatabaseSubscription (private/shared only), and
    // CKQuerySubscription would need queryable indexes + a Push entitlement + an
    // AppDelegate. Polling while the app is open gives ~realtime reflection of other
    // devices' roster edits with zero extra setup. True APNs push is a later option.

    /// Pull + merge the roster without pushing (live poll / on focus). The
    /// `isApplyingRemote` guard inside `mergeRoster` prevents an echo push.
    func pullRosterOnly() async {
        guard icloudUsable else { return }
        do {
            if let cloud = try await CloudKitSync.fetchRoster(workspace: effectiveCloudWorkspace) {
                mergeRoster(cloud)
            }
        } catch {
            // 大半は一時的（オフライン/スロットリング）で次tickが再試行するが、デコード失敗など
            // 持続的な原因は無ログだと気づけない（社員名簿全消失の教訓）。ログにだけ残す。
            Log.failure("cloudsync", "pullRosterOnly", error)
        }
    }

    /// Reflect other devices' roster changes in ~realtime while the app is open.
    func startICloudLiveSync() {
        livePollTask?.cancel()
        guard icloudUsable else { livePollTask = nil; return }
        let interval = livePollInterval
        livePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self, self.icloudUsable else { break }
                await self.pullRosterOnly()
            }
        }
    }

    func stopICloudLiveSync() { livePollTask?.cancel(); livePollTask = nil }
}
