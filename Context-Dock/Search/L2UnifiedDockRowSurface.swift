import SwiftUI

struct L2GlobalSearchPresentation {
    let query: String
    let matches: [SearchResult]
    let menuPills: [DockPill]
    let appMenuGroups: [AppMenuGroup]
    let launchHint: (bundleId: String, appName: String, appPath: String?)?
    let scopedMenuAppName: String?
    let scopedMenuActionQuery: String
    let isLoading: Bool
}

struct L2DockRowPresentation {
    let query: String
    let pillQuery: String
    let pills: [DockPill]
    let showsFindToken: Bool
    let showsSubmenu: Bool
    let showsGlobalSearch: Bool
    let hasAnySelection: Bool
    let explicitAppBundleId: String?
    let dockAtBottom: Bool
    let globalSearch: L2GlobalSearchPresentation
}

struct L2UnifiedDockRowSurface: View {
    let presentation: L2DockRowPresentation
    let findTokenContent: AnyView
    let submenuContent: AnyView
    let globalSearchContent: AnyView
    let dockPillContent: AnyView

    init(
        presentation: L2DockRowPresentation,
        @ViewBuilder findTokenContent: () -> some View,
        @ViewBuilder submenuContent: () -> some View,
        @ViewBuilder globalSearchContent: () -> some View,
        @ViewBuilder dockPillContent: () -> some View
    ) {
        self.presentation = presentation
        self.findTokenContent = AnyView(findTokenContent())
        self.submenuContent = AnyView(submenuContent())
        self.globalSearchContent = AnyView(globalSearchContent())
        self.dockPillContent = AnyView(dockPillContent())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if presentation.showsFindToken {
                    findTokenContent
                        .transition(dropdownTransition)
                } else if presentation.showsSubmenu {
                    submenuContent
                        .transition(dropdownTransition)
                } else if presentation.showsGlobalSearch {
                    globalSearchContent
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    dockPillContent
                }
            }
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: presentation.hasAnySelection)
        }
        .padding(.horizontal, 2)
        .animation(
            .spring(response: 0.22, dampingFraction: 0.85),
            value: presentation.explicitAppBundleId
        )
    }

    private var dropdownTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(
                with: .scale(scale: 0.97, anchor: presentation.dockAtBottom ? .bottom : .top)
            ),
            removal: .opacity.combined(
                with: .scale(scale: 0.97, anchor: presentation.dockAtBottom ? .bottom : .top)
            )
        )
    }
}
