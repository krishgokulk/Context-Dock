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

    @Test("Centred, the clipboard keeps the right-hand corner; the field stays in the middle")
    func centreKeepsTheClipboardInTheCorner() {
        let width: CGFloat = 1800
        let slots = CornerDockLayout.slots(
            clipboard: pill, prompt: card, anchor: .center, panelWidth: width)

        // Same baseline; clipboard flush to the panel's right pad, where the right anchor
        // puts it; field centred on the panel.
        #expect(slots.clipboard?.minY == slots.prompt?.minY)
        #expect(slots.clipboard?.maxX == width - CornerDockLayout.pad)
        #expect(abs((slots.prompt?.midX ?? 0) - width / 2) < 0.5)
    }

    @Test("Centred, the shelf and the field are centred as one row")
    func centreCentresTheRow() {
        let width: CGFloat = 1800
        let slots = CornerDockLayout.slots(
            shelf: pill, clipboard: pill, prompt: card, anchor: .center, panelWidth: width)
        let left = slots.shelf!.minX
        let right = slots.prompt!.maxX

        #expect(abs((left + right) / 2 - width / 2) < 0.5)
        #expect(slots.shelf!.maxX + CornerDockLayout.gap == slots.prompt!.minX)
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

    /// The Global dock is as wide as its apps, its pins and its plugin tiles — near a
    /// thousand points — and the edge-anchored window was one card wide, 428. The right
    /// anchor then placed it at x = -570: half the dock outside the window, and a window
    /// clips. Every anchor gets a window as wide as the screen it is told about.
    @Test("A dock strip wider than one card still fits an edge-anchored window")
    func theStripFitsTheEdgeAnchoredWindow() {
        let strip = CGSize(width: 970, height: 56)
        let screen: CGFloat = 1512
        for anchor in [CornerDockAnchor.left, .right] {
            let panel = CornerDockLayout.panelSize(for: anchor, panelWidth: screen)
            #expect(panel.width == screen)

            let slots = CornerDockLayout.slots(prompt: strip, anchor: anchor, panelWidth: screen)
            let rect = slots.prompt!
            #expect(rect.minX >= 0)
            #expect(rect.maxX <= panel.width)
            // And it still hugs the edge it is anchored to.
            if anchor == .right {
                #expect(rect.maxX == screen - CornerDockLayout.pad)
            } else {
                #expect(rect.minX == CornerDockLayout.pad)
            }
        }
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
