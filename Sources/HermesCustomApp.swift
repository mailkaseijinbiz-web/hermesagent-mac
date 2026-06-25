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
