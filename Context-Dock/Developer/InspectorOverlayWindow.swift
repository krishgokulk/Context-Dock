#if DEBUG
import AppKit
import Combine
import SwiftUI

struct InspectorHighlight: Equatable {
    let frameInWindowRoot: CGRect
    let label: String
    let isLocked: Bool
}

/// One transparent child window per inspected DoraX window.
///
/// A child window rather than one screen-sized capture window, because the P0 contract is
/// per-window: frames live in a window's root space, so a highlight drawn in that same window
/// needs no second coordinate system to disagree with the first. It also means an overlay
/// cannot outlive its owner or drift across a Space.
///
/// `ignoresMouseEvents` is the load-bearing flag. The overlay is a drawing surface and nothing
/// else — the session's own monitors do the hit testing, and the product window underneath
/// keeps receiving every event exactly as it did before Inspect Mode existed.
@MainActor
final class InspectorOverlayController {
    private let windowID: InspectWindowID
    private weak var owner: NSWindow?
    private weak var rootView: NSView?
    private let overlay: NSPanel
    private let model = InspectorOverlayModel()

    var overlayWindowForTesting: NSPanel { overlay }

    init(windowID: InspectWindowID, owner: NSWindow, rootView: NSView) {
        self.windowID = windowID
        self.owner = owner
        self.rootView = rootView

        overlay = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        overlay.isReleasedWhenClosed = false

        overlay.contentView = NSHostingView(rootView: InspectorOverlayView(model: model))

        owner.addChildWindow(overlay, ordered: .above)
        followOwnerFrame()
    }

    func show(highlight: InspectorHighlight?) {
        model.highlight = highlight
        guard highlight != nil else {
            overlay.orderOut(nil)
            return
        }
        followOwnerFrame()
        overlay.orderFront(nil)
    }

    func followOwnerFrame() {
        guard let owner, let rootView else { return }
        let rootInWindow = rootView.convert(rootView.bounds, to: nil)
        overlay.setFrame(owner.convertToScreen(rootInWindow), display: false)
    }

    func tearDown() {
        model.highlight = nil
        overlay.orderOut(nil)
        owner?.removeChildWindow(overlay)
        overlay.contentView = nil
    }
}

@MainActor
final class InspectorOverlayModel: ObservableObject {
    @Published var highlight: InspectorHighlight?
}

/// The overlay's coordinate origin is the inspection root, and SwiftUI lays out from the top
/// left, which is the space the registry frames are already in — so the stored rect is used
/// verbatim rather than converted a second time.
private struct InspectorOverlayView: View {
    @ObservedObject var model: InspectorOverlayModel

    private var tint: Color {
        (model.highlight?.isLocked ?? false) ? .orange : .accentColor
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if let highlight = model.highlight {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.12)))
                    .frame(
                        width: highlight.frameInWindowRoot.width,
                        height: highlight.frameInWindowRoot.height
                    )
                    .offset(
                        x: highlight.frameInWindowRoot.minX,
                        y: highlight.frameInWindowRoot.minY
                    )

                Text(highlight.label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tint))
                    .foregroundStyle(Color.white)
                    .fixedSize()
                    .offset(
                        x: highlight.frameInWindowRoot.minX,
                        y: max(0, highlight.frameInWindowRoot.minY - 21)
                    )
            }
        }
        .allowsHitTesting(false)
    }
}
#endif
