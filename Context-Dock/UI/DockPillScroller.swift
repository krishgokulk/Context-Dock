// DockPillScroller.swift
// Context-Dock
//
// A pill of one fixed width whose icons scroll sideways inside it (#189). The running apps
// beside Global's field and an app's bar of pins and tabs both live in one: a launch, a
// quit or a new tab changes what scrolls, never how wide the dock is.

import SwiftUI

struct DockPillScroller<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    /// The ids the content gives its items (`.id(_:)`), in order: the arrow scrolls to the
    /// last of them and back to the first.
    let itemIDs: [String]
    /// How many items the width holds before the rest scroll.
    let visibleCount: Int
    let content: () -> Content

    init(
        width: CGFloat, height: CGFloat, itemIDs: [String], visibleCount: Int,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.width = width
        self.height = height
        self.itemIDs = itemIDs
        self.visibleCount = visibleCount
        self.content = content
    }

    /// The arrow has taken the row to its end; the next press takes it back.
    @State private var showsEnd = false

    private var overflows: Bool { itemIDs.count > visibleCount }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                content()
            }
            // The overflow arrow: what does not fit is one press away, and the edge it sits
            // on says which way the rest is.
            .overlay(alignment: showsEnd ? .leading : .trailing) {
                if overflows {
                    Button {
                        guard let target = showsEnd ? itemIDs.first : itemIDs.last else { return }
                        withAnimation(.smooth(duration: 0.3)) {
                            proxy.scrollTo(target, anchor: showsEnd ? .leading : .trailing)
                        }
                        showsEnd.toggle()
                    } label: {
                        Image(systemName: showsEnd ? "chevron.left" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: height)
                            .background(.regularMaterial)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showsEnd ? "Back to the start" : "More")
                    .accessibilityLabel(showsEnd ? "Scroll back" : "Show more")
                    .transition(.opacity)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule(style: .continuous))
        // A row that no longer overflows starts from its beginning again.
        .onChange(of: overflows) { _, overflows in if !overflows { showsEnd = false } }
    }
}
