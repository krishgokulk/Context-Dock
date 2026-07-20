import SwiftUI

struct ContextDockSurface: View {
    let presentation: L2DockRowPresentation
    let isFinderDesktopOnlyMode: Bool
    let onPillQueryChange: (String) -> Void
    let onAppear: () -> Void
    let onFinderDesktopModeChange: (Bool) async -> Void
    let onSwipeDown: () -> Void
    let onSwipeUp: () -> Void
    let findTokenContent: AnyView
    let submenuContent: AnyView
    let globalSearchContent: AnyView
    let dockPillContent: AnyView

    init(
        presentation: L2DockRowPresentation,
        isFinderDesktopOnlyMode: Bool,
        onPillQueryChange: @escaping (String) -> Void,
        onAppear: @escaping () -> Void,
        onFinderDesktopModeChange: @escaping (Bool) async -> Void,
        onSwipeDown: @escaping () -> Void,
        onSwipeUp: @escaping () -> Void,
        @ViewBuilder findTokenContent: () -> some View,
        @ViewBuilder submenuContent: () -> some View,
        @ViewBuilder globalSearchContent: () -> some View,
        @ViewBuilder dockPillContent: () -> some View
    ) {
        self.presentation = presentation
        self.isFinderDesktopOnlyMode = isFinderDesktopOnlyMode
        self.onPillQueryChange = onPillQueryChange
        self.onAppear = onAppear
        self.onFinderDesktopModeChange = onFinderDesktopModeChange
        self.onSwipeDown = onSwipeDown
        self.onSwipeUp = onSwipeUp
        self.findTokenContent = AnyView(findTokenContent())
        self.submenuContent = AnyView(submenuContent())
        self.globalSearchContent = AnyView(globalSearchContent())
        self.dockPillContent = AnyView(dockPillContent())
    }

    var body: some View {
        L2UnifiedDockRowSurface(presentation: presentation) {
            findTokenContent
        } submenuContent: {
            submenuContent
        } globalSearchContent: {
            globalSearchContent
        } dockPillContent: {
            dockPillContent
        }
            .id("context-dock-surface")
            .onChange(of: presentation.pillQuery, perform: onPillQueryChange)
            .onAppear(perform: onAppear)
            .task(id: isFinderDesktopOnlyMode) {
                await onFinderDesktopModeChange(isFinderDesktopOnlyMode)
            }
    }
}

extension LauncherView {
    @ViewBuilder
    var contextDockSurface: some View {
        makeContextDockSurface()
    }
}
