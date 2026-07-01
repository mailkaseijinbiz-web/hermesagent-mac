import Foundation

extension AppState {

    /// Poll Tailscale IPv4 and rebind MobileServer when it appears or changes.
    func startMobileServerTailscaleWatchdog() {
        mobileServerTailscaleWatchdogTimer?.invalidate()
        mobileServerTailscaleWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.mobileServerTailscaleWatchdogTick() }
        }
    }

    private func mobileServerTailscaleWatchdogTick() async {
        let ts = await Task.detached(priority: .utility) { TailscaleIPv4.lookup() }.value
        MobileServer.shared.rebindIfTailscaleChanged(detected: ts)
    }
}
