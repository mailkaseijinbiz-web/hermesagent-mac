import SwiftUI

private struct MainScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MainScrollOffsetReporter: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: MainScrollOffsetKey.self,
                    value: geo.frame(in: .named("mainScrollSpace")).minY
                )
            }
        }
    }
}

extension View {
    /// Attach to the root content inside a vertical `ScrollView` that sits under `MainView`'s header.
    func reportMainScrollOffset() -> some View {
        modifier(MainScrollOffsetReporter())
    }

    /// Call on the `ScrollView` to publish scroll depth to `AppState.mainScrollOffset`.
    func onMainScrollOffsetChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        coordinateSpace(name: "mainScrollSpace")
            .onPreferenceChange(MainScrollOffsetKey.self) { minY in
                action(max(0, -minY))
            }
    }
}
