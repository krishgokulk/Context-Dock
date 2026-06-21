import SwiftUI

struct LauncherResultPanelSurface<Content: View>: View {
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
                .id("launcher-results-card")
            Spacer(minLength: 0)
        }
        .frame(width: totalWidth, alignment: .leading)
        .id("launcher-results-panel")
        .animation(nil, value: query)
    }
}

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

struct LauncherListDockSurface<ListContent: View, DockContent: View>: View {
    let usesVerticalListLayout: Bool
    let dockAtBottom: Bool
    let width: CGFloat
    let isDark: Bool
    let listContent: ListContent
    let dockContent: DockContent

    init(
        usesVerticalListLayout: Bool,
        dockAtBottom: Bool,
        width: CGFloat,
        isDark: Bool,
        @ViewBuilder listContent: () -> ListContent,
        @ViewBuilder dockContent: () -> DockContent
    ) {
        self.usesVerticalListLayout = usesVerticalListLayout
        self.dockAtBottom = dockAtBottom
        self.width = width
        self.isDark = isDark
        self.listContent = listContent()
        self.dockContent = dockContent()
    }

    var body: some View {
        VStack(spacing: 0) {
            if usesVerticalListLayout && dockAtBottom {
                listBlock
                divider
                dockBlock
            } else {
                dockBlock
                if usesVerticalListLayout {
                    divider
                    listBlock
                }
            }
        }
        .frame(width: width, alignment: dockAtBottom ? .bottom : .top)
    }

    private var listBlock: some View {
        listContent
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    private var dockBlock: some View {
        dockContent
            .frame(width: width, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(isDark ? 0.08 : 0.10))
            .frame(height: 1)
            .padding(.horizontal, 22)
    }
}
