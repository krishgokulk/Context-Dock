import Foundation
import Testing
@testable import Context_Dock

/// The strip's size is arithmetic on two counts: the corner draws this and hit-tests the
/// same number, so nothing here may come from a measured view.
struct AppChatPromptMetricsDockTests {
    typealias M = AppChatPromptMetrics

    @Test func oneRunningNoPins() {
        let layout = M.dockLayout(running: 1, pinned: 0)
        let one: CGFloat = M.dockSearchStubSpan + 20 + 48
        #expect(layout.width == one)
        #expect(layout.shownRunning == 1)
        #expect(layout.overflow == 0)
    }

    @Test func fourRunningNoPins() {
        let expected: CGFloat = M.dockSearchStubSpan + 20 + 4 * 48 + 3 * 8
        #expect(M.dockLayout(running: 4, pinned: 0).width == expected)
    }

    @Test func pinsAddADividerAndTheirOwnRun() {
        let layout = M.dockLayout(running: 4, pinned: 3)
        let runningWidth: CGFloat = 4 * 48 + 3 * 8
        let pinsWidth: CGFloat = 3 * 48 + 2 * 8
        let expected: CGFloat = M.dockSearchStubSpan + 20 + runningWidth + 17 + pinsWidth
        #expect(layout.width == expected)
    }

    @Test func zeroOfBothStillDrawsOneSlot() {
        // Finder is always running, but the arithmetic must not go negative either way.
        let one: CGFloat = M.dockSearchStubSpan + 20 + 48
        #expect(M.dockLayout(running: 0, pinned: 0).width == one)
    }

    @Test func runningOverflowsIntoAPlusPill() {
        let layout = M.dockLayout(running: 12, pinned: 0)
        #expect(layout.width <= M.dockMaximumWidth)
        #expect(layout.overflow > 0)
        #expect(layout.shownRunning + 1 <= 12)  // the +N pill takes one slot
        #expect(layout.shownRunning + layout.overflow == 12)
    }

    @Test func pinsAreNeverOverflowed() {
        let layout = M.dockLayout(running: 12, pinned: 5)
        #expect(layout.width <= M.dockMaximumWidth)
        // Pins keep every slot; running gives way.
        let pinsWidth: CGFloat = 17 + 5 * 48 + 4 * 8
        let floor: CGFloat = M.dockSearchStubSpan + 20 + 48 + pinsWidth
        #expect(layout.width >= floor)
    }

    /// The Dock grows with what is in it. This one stopped at 1.6 card widths — a number
    /// from when the corner's window was one card wide — so four apps beside a plugin tile
    /// already spilled into `+1` with most of the screen empty beside it.
    @Test func theRowGrowsToTheWidthItIsGiven() {
        let cramped = M.dockLayout(running: 12, pinned: 0)
        let roomy = M.dockLayout(running: 12, pinned: 0, maximumWidth: 1600)

        #expect(cramped.overflow > 0)
        #expect(roomy.overflow == 0)
        #expect(roomy.shownRunning == 12)
        #expect(roomy.width > cramped.width)
        #expect(roomy.width <= 1600)
    }

    /// And it still stops somewhere: a screen that cannot hold them all keeps the `+N`.
    @Test func aRowTooLongForItsScreenStillOverflows() {
        let layout = M.dockLayout(running: 40, pinned: 0, maximumWidth: 1200)
        #expect(layout.overflow > 0)
        #expect(layout.width <= 1200)
        #expect(layout.shownRunning + layout.overflow == 40)
    }

    @Test func sizeForDockUsesTheLayout() {
        let size = M.size(for: .dock, suggestions: 0, running: 4, pinned: 3)
        #expect(size.height == 68)
        #expect(size.width == M.dockLayout(running: 4, pinned: 3).width)
    }

    @Test func toolsAddADividerAndTheirOwnRun() {
        let plain = M.dockLayout(running: 3, pinned: 0)
        let withTools = M.dockLayout(running: 3, pinned: 0, tools: 2)
        let toolsWidth: CGFloat = 17 + 2 * 48 + 8
        #expect(withTools.width == plain.width + toolsWidth)
        #expect(withTools.tools == 2)
    }

    @Test func otherPhasesIgnoreTheStripCounts() {
        let a = M.size(for: .prompt, suggestions: 0)
        let b = M.size(for: .prompt, suggestions: 0, running: 9, pinned: 9)
        #expect(a == b)
    }
}
