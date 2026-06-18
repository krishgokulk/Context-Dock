import SwiftUI

struct ContextDockChatSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .id("context-dock-chat-surface")
    }
}

extension LauncherView {
    @ViewBuilder
    var contextDockChatSurface: some View {
        ContextDockChatSurface {
            transparentResultsAlignedToSearchInput
        }
    }
}
