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
