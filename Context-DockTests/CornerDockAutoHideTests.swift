import Foundation
import Testing

@testable import Context_Dock

/// Auto-hide, the macOS Dock's way: gone at rest, back when the pointer reaches the bottom
/// edge under it, and never hidden while the user has something open.
@Suite("Corner dock auto-hide")
struct CornerDockAutoHideTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// The strip, centred, 20pt above the bottom edge.
    private let strip = CGRect(x: 556, y: 20, width: 400, height: 56)

    private func canHide(
        enabled: Bool = true, strip: Bool = true, hoverCard: Bool = false,
        selection: Bool = false, clipboardExpanded: Bool = false, shelf: Bool = false,
        plugin: Bool = false, menu: Bool = false
    ) -> Bool {
        CornerDockAutoHide.canHide(
            enabled: enabled, stripShowing: strip, hoverCardShowing: hoverCard,
            selectionShowing: selection, clipboardExpanded: clipboardExpanded,
            shelfNeedsAttention: shelf, pluginEditing: plugin, menuOpen: menu)
    }

    @Test func theRestingStripHides() {
        #expect(canHide())
    }

    @Test func offInSettingsItNeverHides() {
        #expect(!canHide(enabled: false))
    }

    /// The field, a conversation, General chat — anything but the strip — is the user
    /// working, and a dock that slid away under them would take what they were doing.
    @Test func anythingOpenKeepsItUp() {
        #expect(!canHide(strip: false))
        #expect(!canHide(hoverCard: true))
        #expect(!canHide(selection: true))
        #expect(!canHide(clipboardExpanded: true))
        #expect(!canHide(shelf: true))
        #expect(!canHide(plugin: true))
    }

    /// Right-click → Unpin: the pointer goes to the menu, off the dock, and the dock has to
    /// wait for the choice rather than slide away under it.
    @Test func anOpenMenuKeepsItUp() {
        #expect(!canHide(menu: true))
    }

    /// The field folding into the strip is a 0.9s morph; the dock waits for it to land.
    @Test func aFreshFoldIsWaitedOut() {
        let d = CornerDockAutoHide.delay(base: 0.45, sinceFold: 0, foldDuration: 0.9)
        #expect(d == 0.9 + CornerDockAutoHide.settleBeat)
    }

    @Test func aFoldLongAgoIsNoReasonToWait() {
        #expect(CornerDockAutoHide.delay(base: 0.45, sinceFold: 10, foldDuration: 0.9) == 0.45)
        #expect(CornerDockAutoHide.delay(base: 3, sinceFold: nil, foldDuration: 0.9) == 3)
    }

    @Test func theBottomEdgeUnderTheDockRevealsIt() {
        #expect(
            CornerDockAutoHide.pointerReveals(
                mouse: CGPoint(x: 700, y: 0), screenFrame: screen, content: strip))
        #expect(
            CornerDockAutoHide.pointerReveals(
                mouse: CGPoint(x: 700, y: 1.5), screenFrame: screen, content: strip))
    }

    /// Only the edge: the pointer passing low across the screen is not a request.
    @Test func aboveTheEdgeDoesNotReveal() {
        #expect(
            !CornerDockAutoHide.pointerReveals(
                mouse: CGPoint(x: 700, y: 10), screenFrame: screen, content: strip))
    }

    /// The edge away from the dock is another app's corner — a hot corner, a window.
    @Test func theEdgeFarFromTheDockDoesNotReveal() {
        #expect(
            !CornerDockAutoHide.pointerReveals(
                mouse: CGPoint(x: 100, y: 0), screenFrame: screen, content: strip))
        // A little past either end still counts.
        #expect(
            CornerDockAutoHide.pointerReveals(
                mouse: CGPoint(x: strip.maxX + 10, y: 0), screenFrame: screen, content: strip))
    }

    /// Coming up from the edge through the gap under the strip is on the way in.
    @Test func theGapUnderTheStripCountsAsOverIt() {
        #expect(
            CornerDockAutoHide.pointerIsOver(
                mouse: CGPoint(x: 700, y: 8), screenFrame: screen, content: strip, slack: 6))
        #expect(
            !CornerDockAutoHide.pointerIsOver(
                mouse: CGPoint(x: 700, y: 200), screenFrame: screen, content: strip, slack: 6))
    }

    @Test func itMovesDownFarEnoughToTakeItsShadowOffScreen() {
        // Content top 76pt in a window sitting at the screen's bottom.
        let d = CornerDockAutoHide.hideDistance(contentTop: 76, screenMinY: 0, shadow: 16)
        #expect(d == CGFloat(92))
    }

    /// A screen above the main one starts at a positive y; distances are from its edge.
    @Test func hideDistanceIsMeasuredFromTheDocksOwnScreen() {
        let d = CornerDockAutoHide.hideDistance(contentTop: 1058, screenMinY: 982, shadow: 16)
        #expect(d == CGFloat(92))
    }
}
