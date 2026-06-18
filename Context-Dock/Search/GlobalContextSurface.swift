import SwiftUI

struct GlobalContextSurface<
    FindTokenContent: View,
    SubmenuContent: View,
    GlobalSearchContent: View,
    DockPillContent: View
>: View {
    let presentation: L2DockRowPresentation
    let onPillQueryChange: (String) -> Void
    let onAppear: () -> Void
    let onFinderDesktopModeChange: (Bool) async -> Void
    let onSwipeDown: () -> Void
    let onSwipeUp: () -> Void
    let findTokenContent: FindTokenContent
    let submenuContent: SubmenuContent
    let globalSearchContent: GlobalSearchContent
    let dockPillContent: DockPillContent

    init(
        presentation: L2DockRowPresentation,
        onPillQueryChange: @escaping (String) -> Void,
        onAppear: @escaping () -> Void,
        onFinderDesktopModeChange: @escaping (Bool) async -> Void,
        onSwipeDown: @escaping () -> Void,
        onSwipeUp: @escaping () -> Void,
        @ViewBuilder findTokenContent: () -> FindTokenContent,
        @ViewBuilder submenuContent: () -> SubmenuContent,
        @ViewBuilder globalSearchContent: () -> GlobalSearchContent,
        @ViewBuilder dockPillContent: () -> DockPillContent
    ) {
        self.presentation = presentation
        self.onPillQueryChange = onPillQueryChange
        self.onAppear = onAppear
        self.onFinderDesktopModeChange = onFinderDesktopModeChange
        self.onSwipeDown = onSwipeDown
        self.onSwipeUp = onSwipeUp
        self.findTokenContent = findTokenContent()
        self.submenuContent = submenuContent()
        self.globalSearchContent = globalSearchContent()
        self.dockPillContent = dockPillContent()
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
            .id("global-context-surface")
            .onChange(of: presentation.pillQuery, perform: onPillQueryChange)
            .onAppear(perform: onAppear)
            .task {
                await onFinderDesktopModeChange(false)
            }
            .gesture(swipeGesture)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let dy = value.translation.height
                let dx = value.translation.width
                guard abs(dy) > abs(dx) else { return }
                if dy > 30 {
                    onSwipeDown()
                } else if dy < -30 {
                    onSwipeUp()
                }
            }
    }
}

extension LauncherView {
    @ViewBuilder
    var globalContextSurface: some View {
        makeGlobalContextSurface()
    }
}
