import Foundation

extension AppState {

    /// Poll Tailscale/LAN IPv4 and rebind MobileServer when they appear or change.
    func startMobileServerTailscaleWatchdog() {
        mobileServerTailscaleWatchdogTimer?.invalidate()
        // Immediate tick — don't wait 90s when Tailscale comes up right after launch.
        Task { @MainActor in await mobileServerTailscaleWatchdogTick() }
        mobileServerTailscaleWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.mobileServerTailscaleWatchdogTick() }
        }
    }

    private func mobileServerTailscaleWatchdogTick() async {
        let ts = await Task.detached(priority: .utility) { TailscaleIPv4.lookup() }.value
        let lan = HermesCLI.shared.getLocalIPAddress()
        MobileServer.shared.rebindIfAddressesChanged(tailscaleIPv4: ts, localLANIPv4: lan)
    }
}
