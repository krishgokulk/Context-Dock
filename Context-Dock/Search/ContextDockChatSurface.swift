import SwiftUI

struct ContextDockChatSurface: View {
    let leadingInset: CGFloat
    let totalWidth: CGFloat
    let panelWidth: CGFloat
    let maxHeight: CGFloat
    let query: String
    let content: AnyView

    init(
        leadingInset: CGFloat,
        totalWidth: CGFloat,
        panelWidth: CGFloat,
        maxHeight: CGFloat,
        query: String,
        @ViewBuilder content: () -> some View
    ) {
        self.leadingInset = leadingInset
        self.totalWidth = totalWidth
        self.panelWidth = panelWidth
        self.maxHeight = maxHeight
        self.query = query
        self.content = AnyView(content())
    }

    var body: some View {
        LauncherTransparentPanelSurface(
            leadingInset: leadingInset,
            totalWidth: totalWidth,
            panelWidth: panelWidth,
            maxHeight: maxHeight,
            query: query
        ) {
            content
        }
        .id("context-dock-chat-surface")
    }
}

extension LauncherView {
    @ViewBuilder
    var contextDockChatSurface: some View {
        ContextDockChatSurface(
            leadingInset: resultsPanelLeadingInset,
            totalWidth: calculatedWidth,
            panelWidth: resultsPanelWidth,
            maxHeight: 500,
            query: searchState.query
        ) {
            resultsContentView
        }
    }
}
