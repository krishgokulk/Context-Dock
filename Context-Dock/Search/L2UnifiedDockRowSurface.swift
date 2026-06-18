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

struct L2UnifiedDockRowSurface<
    FindTokenContent: View,
    SubmenuContent: View,
    GlobalSearchContent: View,
    DockPillContent: View
>: View {
    let presentation: L2DockRowPresentation
    let findTokenContent: FindTokenContent
    let submenuContent: SubmenuContent
    let globalSearchContent: GlobalSearchContent
    let dockPillContent: DockPillContent

    init(
        presentation: L2DockRowPresentation,
        @ViewBuilder findTokenContent: () -> FindTokenContent,
        @ViewBuilder submenuContent: () -> SubmenuContent,
        @ViewBuilder globalSearchContent: () -> GlobalSearchContent,
        @ViewBuilder dockPillContent: () -> DockPillContent
    ) {
        self.presentation = presentation
        self.findTokenContent = findTokenContent()
        self.submenuContent = submenuContent()
        self.globalSearchContent = globalSearchContent()
        self.dockPillContent = dockPillContent()
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
