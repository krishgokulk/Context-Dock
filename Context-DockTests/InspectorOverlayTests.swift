import AppKit
import Foundation
import Testing

@testable import Context_Dock

// The overlay must be a drawing surface and nothing else. Every assertion here is about that:
// it is a child of its owner, it ignores mouse events so the product window underneath keeps
// receiving them, it follows its owner's frame, and it detaches cleanly however many times
// teardown is called.

@MainActor
struct InspectorOverlayTests {
    private func makeOwner(origin: CGPoint) -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: 500, height: 400)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        return (window, window.contentView!)
    }

    @Test func theOverlayIsANonActivatingBorderlessChildOfItsOwner() {
        let (owner, root) = makeOwner(origin: CGPoint(x: 100, y: 120))
        let controller = InspectorOverlayController(
            windowID: InspectWindowID(rawValue: 3), owner: owner, rootView: root
        )
        defer { controller.tearDown() }

        let overlay = controller.overlayWindowForTesting
        #expect(overlay.styleMask.contains(.borderless))
        #expect(overlay.styleMask.contains(.nonactivatingPanel))
        #expect(overlay.isOpaque == false)
        #expect(overlay.backgroundColor == .clear)
        #expect(overlay.ignoresMouseEvents)
        #expect(owner.childWindows?.contains(overlay) == true)
    }

    @Test func theOverlayCoversTheOwnerContentAndFollowsItWhenItMoves() {
        let (owner, root) = makeOwner(origin: CGPoint(x: 100, y: 120))
        let controller = InspectorOverlayController(
            windowID: InspectWindowID(rawValue: 4), owner: owner, rootView: root
        )
        defer { controller.tearDown() }

        let expected = owner.convertToScreen(root.convert(root.bounds, to: nil))
        #expect(controller.overlayWindowForTesting.frame == expected)

        owner.setFrameOrigin(CGPoint(x: 260, y: 300))
        controller.followOwnerFrame()

        let moved = owner.convertToScreen(root.convert(root.bounds, to: nil))
        #expect(controller.overlayWindowForTesting.frame == moved)
    }

    @Test func clearingTheHighlightOrdersTheOverlayOut() {
        let (owner, root) = makeOwner(origin: .zero)
        let controller = InspectorOverlayController(
            windowID: InspectWindowID(rawValue: 5), owner: owner, rootView: root
        )
        defer { controller.tearDown() }

        controller.show(
            highlight: InspectorHighlight(
                frameInWindowRoot: CGRect(x: 10, y: 20, width: 100, height: 40),
                label: "generalChat.thread #0",
                isLocked: false
            )
        )

        controller.show(highlight: nil)
        #expect(controller.overlayWindowForTesting.isVisible == false)
    }

    @Test func tearingDownDetachesTheOverlayFromItsOwner() {
        let (owner, root) = makeOwner(origin: .zero)
        let controller = InspectorOverlayController(
            windowID: InspectWindowID(rawValue: 6), owner: owner, rootView: root
        )
        let overlay = controller.overlayWindowForTesting

        controller.tearDown()

        #expect(owner.childWindows?.contains(overlay) != true)
        #expect(overlay.parent == nil)
        #expect(overlay.isVisible == false)
    }

    @Test func tearingDownTwiceIsHarmless() {
        let (owner, root) = makeOwner(origin: .zero)
        let controller = InspectorOverlayController(
            windowID: InspectWindowID(rawValue: 7), owner: owner, rootView: root
        )

        controller.tearDown()
        controller.tearDown()

        #expect(controller.overlayWindowForTesting.parent == nil)
    }
}
