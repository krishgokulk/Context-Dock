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

    @Test("Centred, a narrow pill sits under the middle of the card above it")
    func centreAlignsMidpoints() {
        let slots = CornerDockLayout.slots(clipboard: pill, prompt: card, anchor: .center)

        #expect(slots.prompt?.midX == slots.clipboard?.midX)
        #expect(slots.prompt?.midX == CornerDockLayout.panelSize.width / 2)
    }

    @Test("The stack order and heights do not depend on which edge it is against")
    func anchorMovesNothingVertically() {
        for anchor in CornerDockAnchor.allCases {
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

    @Test("Every anchor keeps the whole card inside the panel")
    func nothingHangsOutside() {
        for anchor in CornerDockAnchor.allCases {
            let slots = CornerDockLayout.slots(prompt: card, anchor: anchor)
            let rect = slots.prompt!
            #expect(rect.minX >= 0)
            #expect(rect.maxX <= CornerDockLayout.panelSize.width)
        }
    }
}
