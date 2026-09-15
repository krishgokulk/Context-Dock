// CornerDockAnchorTests.swift
// Context-DockTests
//
// Where the shell sits. The cards are drawn from these rects and hit-tested against them,
// so an anchor that lines them up differently in the two places is a surface the pointer
// misses.

import CoreGraphics
import Testing

@testable import Context_Dock

@Suite("Corner dock anchor")
struct CornerDockAnchorTests {

    private let card = CGSize(width: 372, height: 200)
    private let pill = CGSize(width: 52, height: 44)

    @Test("Anchored right, cards line up on their right edges")
    func rightAlignsTrailingEdges() {
        let slots = CornerDockLayout.slots(clipboard: pill, prompt: card, anchor: .right)

        #expect(slots.prompt?.maxX == slots.clipboard?.maxX)
        #expect(slots.prompt?.maxX == CornerDockLayout.panelSize.width - CornerDockLayout.pad)
    }

    @Test("Anchored left, they line up on their left edges")
    func leftAlignsLeadingEdges() {
        let slots = CornerDockLayout.slots(clipboard: pill, prompt: card, anchor: .left)

        #expect(slots.prompt?.minX == CornerDockLayout.pad)
        #expect(slots.clipboard?.minX == CornerDockLayout.pad)
    }

    @Test("Centred, the shell is a row: the clipboard stands beside the field, not over it")
    func centreLaysOutSideways() {
        let slots = CornerDockLayout.slots(clipboard: pill, prompt: card, anchor: .center)

        // Same baseline, clipboard to the right of the field, one gap between them.
        #expect(slots.clipboard?.minY == slots.prompt?.minY)
        #expect(slots.clipboard?.minX == (slots.prompt?.maxX ?? 0) + CornerDockLayout.gap)
    }

    @Test("Centred, the whole row is centred — not the field with things hanging off it")
    func centreCentresTheRow() {
        let slots = CornerDockLayout.slots(
            shelf: pill, clipboard: pill, prompt: card, anchor: .center)
        let left = slots.shelf!.minX
        let right = slots.clipboard!.maxX

        #expect(
            abs((left + right) / 2 - CornerDockLayout.panelSize(for: .center).width / 2) < 0.5)
    }

    @Test("Centred, what answers the field still sits above the field")
    func centreKeepsBoardsAboveTheField() {
        let board = CGSize(width: 372, height: 160)
        let slots = CornerDockLayout.slots(
            clipboard: pill, list: board, prompt: card, anchor: .center)

        #expect(slots.list?.midX == slots.prompt?.midX)
        #expect(slots.list?.minY == (slots.prompt?.maxY ?? 0) + CornerDockLayout.gap)
    }

    @Test("Anchored to an edge, the surfaces stack in one order")
    func anchorMovesNothingVertically() {
        // Centred is deliberately not a column — it is a row, covered above.
        for anchor in [CornerDockAnchor.left, .right] {
            let slots = CornerDockLayout.slots(clipboard: pill, prompt: card, anchor: anchor)
            // The prompt takes the bottom; the clipboard sits a gap above it.
            #expect(slots.prompt?.minY == CornerDockLayout.pad)
            #expect(
                slots.clipboard?.minY
                    == (slots.prompt?.maxY ?? 0) + CornerDockLayout.gap)
        }
    }

    @Test("A surface showing nothing still takes no space, whichever edge it is on")
    func absentSurfacesTakeNoRoom() {
        for anchor in CornerDockAnchor.allCases {
            let slots = CornerDockLayout.slots(prompt: card, anchor: anchor)
            #expect(slots.clipboard == nil)
            #expect(slots.prompt?.minY == CornerDockLayout.pad)
        }
    }

    @Test("The centred row fits the window it is drawn into")
    func centredRowFitsItsPanel() {
        // The row was being drawn into a column's window — 428 points for three cards —
        // so the surfaces landed on top of each other.
        let slots = CornerDockLayout.slots(
            shelf: card, clipboard: card, prompt: card, anchor: .center)
        let panel = CornerDockLayout.panelSize(for: .center)

        #expect(slots.shelf!.minX >= 0)
        #expect(slots.clipboard!.maxX <= panel.width)
        #expect(panel.width > CornerDockLayout.panelSize(for: .right).width)
    }

    @Test("Every anchor keeps the whole card inside the panel")
    func nothingHangsOutside() {
        for anchor in CornerDockAnchor.allCases {
            let slots = CornerDockLayout.slots(prompt: card, anchor: anchor)
            let rect = slots.prompt!
            // Measured against the window that anchor actually draws into: centred is a
            // row and gets a wider one.
            #expect(rect.minX >= 0)
            #expect(rect.maxX <= CornerDockLayout.panelSize(for: anchor).width)
        }
    }
}
