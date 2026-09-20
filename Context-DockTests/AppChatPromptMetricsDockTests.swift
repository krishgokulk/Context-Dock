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

    /// The shell is drawn at `size(for:)` and the row at `dockLayout`. They were two
    /// computations of the same number with different budgets — the row grew to the screen
    /// while the shell stayed at a card and a half — so the row overflowed its own glass
    /// and the magnifier at the leading edge was the part that got clipped.
    @Test func theShellIsAsWideAsTheRowItDraws() {
        let budget: CGFloat = 1600
        let row = M.dockLayout(running: 9, pinned: 2, tools: 1, maximumWidth: budget)
        let shell = M.size(
            for: .dock, suggestions: 0, running: 9, pinned: 2, tools: 1, maximumWidth: budget)

        #expect(shell.width == row.width)
        // And the default budget really is narrower, so this is threading and not a tie.
        #expect(M.size(for: .dock, suggestions: 0, running: 9, pinned: 2, tools: 1).width
            < shell.width)
    }

    /// The field grows to hold its row of running apps rather than cutting it to "+1": a
    /// count is not somewhere you can click.
    @Test func theFieldGrowsToHoldItsPill() {
        #expect(M.promptWidth(icons: M.matchIconBaseCount) == M.width)
        #expect(M.promptWidth(icons: 2) == M.width)

        let roomy = M.promptWidth(icons: 9, maximumWidth: 1600)
        #expect(roomy > M.width)
        #expect(roomy == M.width + CGFloat(9 - M.matchIconBaseCount) * M.matchPillIconSpan)

        // Never past the screen it is on.
        #expect(M.promptWidth(icons: 100, maximumWidth: 900) == 900)
    }

    @Test func theFieldsIconCapacityGrowsWithItsBudget() {
        #expect(M.matchIconCapacity(maximumWidth: M.width) == M.matchIconBaseCount)
        #expect(M.matchIconCapacity(maximumWidth: 1600) > M.matchIconCapacity(maximumWidth: 700))
        // Whatever the budget, the field shows at least the four it always did.
        #expect(M.matchIconCapacity(maximumWidth: 100) == M.matchIconBaseCount)
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
