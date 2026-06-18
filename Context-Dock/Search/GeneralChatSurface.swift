import SwiftUI

struct GeneralChatSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .id("general-chat-surface")
    }
}

extension LauncherView {
    @ViewBuilder
    var generalChatSurface: some View {
        GeneralChatSurface {
            transparentResultsAlignedToSearchInput
        }
    }
}
