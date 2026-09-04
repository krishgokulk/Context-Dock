import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct DropShelfPresentationTests {
    private func shelf(holding count: Int) -> DropShelfPresentation {
        let presentation = DropShelfPresentation()
        presentation.itemCount = count
        return presentation
    }

    private func item(_ name: String) -> DropShelfItem {
        DropShelfItem(
            id: UUID(),
            relativePath: "Documents/\(name)",
            kind: .documents,
            originalName: name,
            sourceAppName: "Finder",
            sourceBundleId: "com.apple.finder",
            droppedAt: Date())
    }

    /// The shelf exists to be dragged out of, and dragging four files one at a time is the
    /// slow way to do the only thing it is for.
    @Test func theShelfSelectsTheSameWayTheClipboardDoes() {
        let presentation = shelf(holding: 3)
        let items = [item("a.pdf"), item("b.pdf"), item("c.pdf")]

        presentation.select(items[0], in: items, extend: false, toggle: false)
        #expect(presentation.selectedIDs == [items[0].id])

        presentation.select(items[2], in: items, extend: true, toggle: false)
        #expect(presentation.actionableItems(in: items, fallback: nil).count == 3)

        presentation.select(items[1], in: items, extend: false, toggle: true)
        #expect(presentation.actionableItems(in: items, fallback: nil).count == 2)
    }

    /// With nothing picked, an action applies to the row it was invoked on and no more.
    @Test func withNoSelectionAnActionAppliesToOneRow() {
        let presentation = shelf(holding: 2)
        let items = [item("a.pdf"), item("b.pdf")]

        let target = presentation.actionableItems(in: items, fallback: items[1])

        #expect(target.map(\.originalName) == ["b.pdf"])
    }

    @Test func clearingTheSelectionLeavesTheShelfItself() {
        let presentation = shelf(holding: 2)
        let items = [item("a.pdf"), item("b.pdf")]
        presentation.selectAll(items)

        presentation.clearSelection()

        #expect(presentation.selectedIDs.isEmpty)
        #expect(presentation.actionableItems(in: items, fallback: nil).isEmpty)
    }

    @Test func anEmptyShelfShowsNothingUntilSomethingIsDragged() {
        #expect(shelf(holding: 0).phase == .hidden)
    }

    @Test func aDragOverTheEdgeInvitesADrop() {
        let presentation = shelf(holding: 0)

        presentation.dragEntered()

        #expect(presentation.phase == .inviting)
    }

    @Test func aDragThatLeavesWithoutDroppingHidesAnEmptyShelfAgain() {
        let presentation = shelf(holding: 0)
        presentation.dragEntered()

        presentation.dragExited()

        #expect(presentation.phase == .hidden)
    }

    @Test func aDragThatLeavesWithoutDroppingLeavesAHoldingShelfHolding() {
        let presentation = shelf(holding: 3)
        presentation.dragEntered()

        presentation.dragExited()

        #expect(presentation.phase == .holding)
    }

    @Test func droppingSomethingLeavesTheShelfHolding() {
        let presentation = shelf(holding: 0)
        presentation.dragEntered()

        presentation.itemCount = 1
        presentation.dropCompleted()

        #expect(presentation.phase == .holding)
    }

    @Test func hoveringAHoldingShelfOpensTheCard() {
        let presentation = shelf(holding: 2)
        presentation.itemCountChanged()

        presentation.hoverBegan()

        #expect(presentation.phase == .expanded)
    }

    @Test func leavingTheCardCollapsesItBackToThePill() {
        let presentation = shelf(holding: 2)
        presentation.itemCountChanged()
        presentation.hoverBegan()

        presentation.hoverEnded()

        #expect(presentation.phase == .holding)
    }

    /// Hovering where the shelf would be, when it holds nothing, must not open an empty
    /// card over the user's work.
    @Test func hoveringAnEmptyShelfOpensNothing() {
        let presentation = shelf(holding: 0)

        presentation.hoverBegan()

        #expect(presentation.phase == .hidden)
    }

    @Test func removingTheLastItemHidesTheShelf() {
        let presentation = shelf(holding: 1)
        presentation.itemCountChanged()
        presentation.hoverBegan()

        presentation.itemCount = 0
        presentation.itemCountChanged()

        #expect(presentation.phase == .hidden)
    }

    /// A drag is not a copy. While one is in flight the clipboard pill stands down so the
    /// two never fight for the same corner or the same pointer.
    @Test func theClipboardStandsDownForTheDurationOfADrag() {
        let presentation = shelf(holding: 0)

        presentation.dragEntered()
        #expect(presentation.wantsClipboardSuppressed)

        presentation.dropCompleted()
        #expect(!presentation.wantsClipboardSuppressed)
    }

    @Test func aDragThatLeavesAlsoReleasesTheClipboard() {
        let presentation = shelf(holding: 0)
        presentation.dragEntered()

        presentation.dragExited()

        #expect(!presentation.wantsClipboardSuppressed)
    }
}

// MARK: - Standing down

@MainActor
struct DropShelfAutoHideTests {
    private func holdingShelf(_ count: Int = 2) -> DropShelfPresentation {
        let presentation = DropShelfPresentation()
        presentation.itemCount = count
        presentation.itemCountChanged()
        return presentation
    }

    /// The shelf keeps what it holds, but it does not squat in the corner forever.
    @Test func settlingIntoHoldingArmsTheAutoHide() {
        let presentation = holdingShelf()

        #expect(presentation.phase == .holding)
        #expect(presentation.isHideArmed)
    }

    @Test func reachingForTheShelfCancelsTheAutoHide() {
        let presentation = holdingShelf()

        presentation.hoverBegan()

        #expect(presentation.phase == .expanded)
        #expect(!presentation.isHideArmed)
    }

    @Test func leavingTheCardRearmsTheAutoHide() {
        let presentation = holdingShelf()
        presentation.hoverBegan()

        presentation.hoverEnded()

        #expect(presentation.phase == .holding)
        #expect(presentation.isHideArmed)
    }

    /// Hiding is only the pill going away. Nothing is dropped from the shelf.
    @Test func hidingItselfDoesNotDiscardWhatItHolds() {
        let presentation = holdingShelf(3)

        presentation.autoHide()

        #expect(presentation.phase == .hidden)
        #expect(presentation.itemCount == 3)
    }

    /// Once hidden the items would be stranded, so the corner still answers the pointer.
    @Test func movingIntoTheCornerBringsAHiddenShelfBack() {
        let presentation = holdingShelf()
        presentation.autoHide()

        presentation.hoverBegan()

        #expect(presentation.phase == .expanded)
    }

    @Test func aDragRevealsAHiddenShelfToCatchTheDrop() {
        let presentation = holdingShelf()
        presentation.autoHide()

        presentation.dragEntered()

        #expect(presentation.phase == .inviting)
    }

    @Test func aNewDropBringsTheHiddenPillBack() {
        let presentation = holdingShelf()
        presentation.autoHide()

        presentation.itemCount += 1
        presentation.itemCountChanged()

        #expect(presentation.phase == .holding)
    }

    @Test func anEmptyShelfStaysHiddenAndArmsNothing() {
        let presentation = DropShelfPresentation()
        presentation.itemCount = 0

        presentation.itemCountChanged()

        #expect(presentation.phase == .hidden)
        #expect(!presentation.isHideArmed)
    }
}
