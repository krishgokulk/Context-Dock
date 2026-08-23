import Foundation
import Testing

@testable import Context_Dock

/// One shell, two pills. The layout decides where each pill sits inside the shared
/// container so neither surface owns a floating window of its own.
struct CornerDockLayoutTests {
    private let pill = CGSize(width: 200, height: 56)
    private let card = CGSize(width: 372, height: 404)

    @Test func theClipboardAloneSitsInTheCorner() throws {
        let slots = CornerDockLayout.slots(shelf: nil, clipboard: pill)
        let clipboard = try #require(slots.clipboard)

        #expect(slots.shelf == nil)
        #expect(clipboard.minY == CornerDockLayout.pad)
        #expect(clipboard.maxX == CornerDockLayout.panelSize.width - CornerDockLayout.pad)
    }

    /// With no clipboard pill below it, the shelf drops into the corner rather than
    /// floating above a gap where nothing is.
    @Test func theShelfAloneTakesTheCornerItself() throws {
        let slots = CornerDockLayout.slots(shelf: pill, clipboard: nil)
        let shelf = try #require(slots.shelf)

        #expect(shelf.minY == CornerDockLayout.pad)
    }

    @Test func theShelfStacksDirectlyAboveTheClipboardWithOneGap() throws {
        let slots = CornerDockLayout.slots(shelf: pill, clipboard: pill)
        let shelf = try #require(slots.shelf)
        let clipboard = try #require(slots.clipboard)

        #expect(shelf.minY == clipboard.maxY + CornerDockLayout.gap)
    }

    @Test func stackedPillsNeverOverlap() throws {
        let slots = CornerDockLayout.slots(shelf: pill, clipboard: pill)
        let shelf = try #require(slots.shelf)
        let clipboard = try #require(slots.clipboard)

        #expect(!shelf.intersects(clipboard))
    }

    /// An expanded card grows upward from the same corner, so the pill above it has to
    /// move up with it rather than being overlapped.
    @Test func expandingTheClipboardPushesTheShelfAboveTheCard() throws {
        let slots = CornerDockLayout.slots(shelf: pill, clipboard: card)
        let shelf = try #require(slots.shelf)
        let clipboard = try #require(slots.clipboard)

        #expect(shelf.minY == clipboard.maxY + CornerDockLayout.gap)
        #expect(!shelf.intersects(clipboard))
    }

    @Test func bothPillsShareTheSameRightEdge() throws {
        let slots = CornerDockLayout.slots(shelf: pill, clipboard: card)
        let shelf = try #require(slots.shelf)
        let clipboard = try #require(slots.clipboard)

        #expect(shelf.maxX == clipboard.maxX)
    }

    /// The shell has to be tall enough for the worst case — a full card plus the other
    /// pill above it — or an expanded card would be clipped by its own window.
    @Test func theShellFitsACardAndAPillTogether() {
        let slots = CornerDockLayout.slots(shelf: pill, clipboard: card)

        #expect(slots.shelf!.maxY + CornerDockLayout.pad <= CornerDockLayout.panelSize.height)
    }

    @Test func nothingShowingMeansNoSlots() {
        let slots = CornerDockLayout.slots(shelf: nil, clipboard: nil)

        #expect(slots.shelf == nil)
        #expect(slots.clipboard == nil)
    }
}
