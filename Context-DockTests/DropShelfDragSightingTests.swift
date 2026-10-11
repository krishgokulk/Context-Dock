import AppKit
import Testing

@testable import Context_Dock

/// A file picked up anywhere wakes the dock with the shelf's icon (owner 2026-10-08). A drag
/// is a button-held move after which the drag pasteboard was written with a file.
@MainActor
struct DropShelfDragSightingTests {
    @Test func aFileBeingDraggedIsSighted() {
        #expect(DropShelfDragSighting.isFileDrag(
            countNow: 8, countAtMouseDown: 7, types: [.fileURL, .string]))
    }

    /// Selecting text or moving a window holds the button down too: no new drag, no wake.
    @Test func aButtonHeldMoveWithoutANewDragIsNot() {
        #expect(!DropShelfDragSighting.isFileDrag(
            countNow: 7, countAtMouseDown: 7, types: [.fileURL]))
    }

    /// Dragged text is not something the dock pins or shelves as a file.
    @Test func aDragWithoutAFileIsNot() {
        #expect(!DropShelfDragSighting.isFileDrag(
            countNow: 8, countAtMouseDown: 7, types: [.string]))
    }
}
