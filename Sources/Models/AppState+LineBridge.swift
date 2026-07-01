import Foundation

extension AppState {

    static let lineDeliveryAuthErrorMessage =
        "LINEのチャンネルアクセストークンが失効している可能性があります。hermes の LINE 設定を更新し、ブリッジを再起動してください。"

    /// True when a cron job's lastError looks like a LINE push 401 (token expired / invalid).
    nonisolated static func isLineDeliveryAuthError(_ error: String?) -> Bool {
        guard let e = error?.lowercased() else { return false }
        return e.contains("401") && e.contains("line")
    }

    /// Poll every 3 min: if the bridge is installed but the port is down, try ensureRunning().
    func startLineBridgeWatchdog() {
        lineBridgeWatchdogTimer?.invalidate()
        lineBridgeWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.lineBridgeWatchdogTick() }
        }
    }

    private func lineBridgeWatchdogTick() async {
        guard LineBridge.shared.isInstalled else { return }
        let health = LineBridge.shared.healthCheck()
        if health == .ok {
            isLineBridgeRunning = true
            if lineBridgeStatus.isEmpty || !lineBridgeStatus.contains("稼働") {
                lineBridgeStatus = "LINEブリッジ稼働中（:\(LineBridge.shared.port)）"
            }
            return
        }
        guard health == .portDown else { return }
        lineBridgeStatus = LineBridge.shared.ensureRunning()
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        let up = LineBridge.shared.healthCheck() == .ok
        isLineBridgeRunning = up
        if up {
            lineBridgeStatus = "LINEブリッジ稼働中（:\(LineBridge.shared.port)）"
        } else if !lineBridgeStatus.contains("失敗") {
            lineBridgeStatus = "ウォッチドッグが再起動を試みました（~/.hermes/line-bridge/bridge.log を確認）"
        }
    }

    /// Scan parsed cron jobs for LINE 401 delivery errors; toast once per new error text.
    func updateLineDeliveryAuthError(from jobs: [HermesCronJob]) {
        let current = Dictionary(
            uniqueKeysWithValues: jobs.compactMap { job -> (String, String)? in
                guard Self.isLineDeliveryAuthError(job.lastError), let err = job.lastError else { return nil }
                return (job.id, err)
            }
        )
        if current.isEmpty {
            lineDeliveryAuthError = nil
            previousLineAuthErrors = [:]
            return
        }
        lineDeliveryAuthError = Self.lineDeliveryAuthErrorMessage
        let hasNew = current.contains { id, err in previousLineAuthErrors[id] != err }
        if hasNew {
            triggerToast(message: Self.lineDeliveryAuthErrorMessage)
            scheduleLineBridgeRestartForAuthError()
        }
        previousLineAuthErrors = current
    }

    /// Debounced bridge restart when cron reports LINE 401 (token may have been rotated externally).
    private func scheduleLineBridgeRestartForAuthError() {
        guard !lineAuthBridgeRestartPending else { return }
        lineAuthBridgeRestartPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await restartLineBridge()
            lineAuthBridgeRestartPending = false
        }
    }
}
