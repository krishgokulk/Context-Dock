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

    // MARK: - The icon: collapsed, open, closed

    /// The icon is always there; at rest it is only the icon.
    @Test func theShelfRestsAsAPlainIcon() {
        #expect(shelf(holding: 0).phase == .collapsed)
        #expect(shelf(holding: 3).phase == .collapsed)
    }

    @Test func clickingTheIconOpensTheShelfAndClickingAgainClosesIt() {
        let presentation = shelf(holding: 2)

        presentation.toggle()
        #expect(presentation.phase == .expanded)
        #expect(presentation.phase.isCardShown)

        presentation.toggle()
        #expect(presentation.phase == .collapsed)
        #expect(!presentation.phase.isCardShown)
    }

    /// With no pins and nothing held the icon is still there and still opens: the shelf is
    /// not something that exists only once it has been used.
    @Test func anEmptyShelfStillOpens() {
        let presentation = shelf(holding: 0)

        presentation.toggle()

        #expect(presentation.phase == .expanded)
    }

    @Test func escapeClosesAnOpenShelf() {
        let presentation = shelf(holding: 1)
        presentation.toggle()

        presentation.collapse()

        #expect(presentation.phase == .collapsed)
    }

    @Test func collapsingAClosedShelfChangesNothing() {
        let presentation = shelf(holding: 1)
        var changes = 0
        presentation.onPhaseChange = { _ in changes += 1 }

        presentation.collapse()

        #expect(presentation.phase == .collapsed)
        #expect(changes == 0)
    }

    @Test func everyChangeOfPhaseIsReported() {
        let presentation = shelf(holding: 1)
        var seen: [DropShelfPhase] = []
        presentation.onPhaseChange = { seen.append($0) }

        presentation.toggle()
        presentation.toggle()

        #expect(seen == [.expanded, .collapsed])
    }

    @Test func theCountOnTheIconIsWhatTheShelfHolds() {
        let presentation = shelf(holding: 3)
        #expect(presentation.itemCount == 3)
        #expect(DropShelfIcon.spokenCount(0) == "empty")
        #expect(DropShelfIcon.spokenCount(1) == "1 item")
        #expect(DropShelfIcon.spokenCount(3) == "3 items")
    }

    // MARK: - A drag over the shell

    @Test func aDragSightedAnywhereInvitesADropOnTheIcon() {
        let presentation = shelf(holding: 0)

        presentation.dragEntered()

        #expect(presentation.phase == .inviting)
    }

    @Test func aDragThatLeavesWithoutDroppingPutsTheIconBackToRest() {
        let presentation = shelf(holding: 3)
        presentation.dragEntered()

        presentation.dragExited()

        #expect(presentation.phase == .collapsed)
    }

    @Test func aDragDoesNotCloseAShelfTheUserOpened() {
        let presentation = shelf(holding: 3)
        presentation.toggle()

        presentation.dragEntered()
        presentation.dragExited()

        #expect(presentation.phase == .expanded)
    }

    @Test func aDragRestingOnTheIconOpensTheShelfLikeAnyDragTarget() {
        let presentation = shelf(holding: 0)
        presentation.dragEntered()

        presentation.iconDragEntered()

        #expect(presentation.phase == .expanded)
        #expect(presentation.isDragOverIcon)
    }

    @Test func aShelfTheDragOpenedGoesWhenTheDragLeavesWithoutDropping() {
        let presentation = shelf(holding: 0)
        presentation.dragEntered()
        presentation.iconDragEntered()

        presentation.iconDragExited()
        presentation.dragExited()

        #expect(presentation.phase == .collapsed)
        #expect(!presentation.isDragOverIcon)
    }

    /// A drop on the icon leaves the shelf open, so the item is seen arriving.
    @Test func droppingOnTheIconLeavesTheShelfOpenAndItStaysOpen() {
        let presentation = shelf(holding: 0)
        presentation.dragEntered()
        presentation.iconDragEntered()

        presentation.itemCount = 1
        presentation.dropCompleted()
        presentation.dragExited()

        #expect(presentation.phase == .expanded)
        #expect(!presentation.isDragOverIcon)
        #expect(presentation.itemCount == 1)
    }

    @Test func droppingWhileOnlyInvitedReturnsTheIconToRest() {
        let presentation = shelf(holding: 0)
        presentation.dragEntered()

        presentation.dropCompleted()

        #expect(presentation.phase == .collapsed)
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

// MARK: - The drag-target rule

struct DropShelfDragRuleTests {
    typealias R = DropShelfDragRule

    @Test func theIconIsDrawnForTheDragItIsInvitingOrTargeted() {
        #expect(R.highlight(phase: .collapsed, dragOverIcon: false) == .none)
        #expect(R.highlight(phase: .inviting, dragOverIcon: false) == .invited)
        #expect(R.highlight(phase: .inviting, dragOverIcon: true) == .target)
        #expect(R.highlight(phase: .expanded, dragOverIcon: true) == .target)
        #expect(R.highlight(phase: .expanded, dragOverIcon: false) == .none)
    }

    @Test func aDragOnTheIconOpensItUnlessItIsOpenAlready() {
        #expect(R.expandsOnHover(dragOverIcon: true, expanded: false))
        #expect(!R.expandsOnHover(dragOverIcon: true, expanded: true))
        #expect(!R.expandsOnHover(dragOverIcon: false, expanded: false))
    }

    /// Only the icon, and the card once it is open, take a drop. A release anywhere else on
    /// the shell does what it did before the shelf existed.
    @Test func onlyTheIconAndTheOpenCardTakeADrop() {
        #expect(R.acceptsDrop(overIcon: true, overCard: false, expanded: false))
        #expect(R.acceptsDrop(overIcon: false, overCard: true, expanded: true))
        #expect(!R.acceptsDrop(overIcon: false, overCard: true, expanded: false))
        #expect(!R.acceptsDrop(overIcon: false, overCard: false, expanded: true))
    }

    @Test func aDraggedPinIsNotShelvedAsText() {
        #expect(DropShelfDropRule.shelvableText(["dockpin:1234"]) == nil)
        #expect(DropShelfDropRule.shelvableText(["note", "dockpin:1234"]) == "note")
        #expect(DropShelfDropRule.shelvableText(["a", "b"]) == "a\nb")
        #expect(DropShelfDropRule.shelvableText([]) == nil)
    }
}
