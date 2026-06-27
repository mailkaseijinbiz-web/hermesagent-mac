import SwiftUI

@main
struct HermesCustomApp: App {
    @StateObject private var appState = AppState.shared
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 650)
                .background(VisualEffectView(material: .sidebar, blendingMode: .withinWindow))
                .task {
                    // Auto version-up: check the git remote on launch (+ every 6h). When a
                    // new version exists, the auto-update toggle applies it, else we notify.
                    let updater = UpdateManager.shared
                    updater.startPeriodic()
                    await updater.checkForUpdates(auto: true)
                    if updater.updateAvailable && !updater.autoUpdate {
                        appState.triggerToast(message: "新しいバージョンがあります（設定 → 一般 → アップデート）")
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

// macOS Visual Effect View helper for translucent window backgrounds
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .followsWindowActiveState
    }
}
