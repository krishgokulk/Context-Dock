import SwiftUI


struct LauncherTransparentPanelSurface<Content: View>: View {
    let leadingInset: CGFloat
    let totalWidth: CGFloat
    let panelWidth: CGFloat
    let maxHeight: CGFloat
    let query: String
    let content: Content

    init(
        leadingInset: CGFloat,
        totalWidth: CGFloat,
        panelWidth: CGFloat,
        maxHeight: CGFloat,
        query: String,
        @ViewBuilder content: () -> Content
    ) {
        self.leadingInset = leadingInset
        self.totalWidth = totalWidth
        self.panelWidth = panelWidth
        self.maxHeight = maxHeight
        self.query = query
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: leadingInset)
            content
                .frame(minHeight: 0, maxHeight: maxHeight)
                .frame(width: panelWidth, alignment: .leading)
                .id("launcher-transparent-panel-content")
            Spacer(minLength: 0)
        }
        .frame(width: totalWidth, alignment: .leading)
        .id("launcher-transparent-panel")
        .animation(nil, value: query)
    }
}

