import SwiftUI

struct MediaDockSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .id("media-dock-surface")
    }
}

extension LauncherView {
    @ViewBuilder
    var mediaDockSurface: some View {
        MediaDockSurface {
            mediaControlsInDock
        }
    }
}
