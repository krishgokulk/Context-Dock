import AppKit
import Testing

@testable import Context_Dock

/// #143: a clipboard notice in the corner must not take clicks meant for the app in front.
/// The shell spans the screen; only its cards may answer the pointer.
@Suite("Corner dock mouse rule")
struct CornerDockMouseRuleTests {
    private let clipboardPill = CGRect(x: 1200, y: 20, width: 250, height: 56)

    private func ignores(_ pointer: CGPoint, cards: [CGRect]? = nil, hidden: Bool = false)
        -> Bool
    {
        CornerDockMouseRule.shouldIgnoreMouse(
            pointer: pointer, cards: cards ?? [clipboardPill],
            slack: ClipboardPillMetrics.hoverTolerance, autoHidden: hidden)
    }

    @Test func emptyShellLetsTheClickThroughToTheAppBeneath() {
        #expect(ignores(CGPoint(x: 400, y: 500)))
        // Above the pill, inside the shell's transparent shadow pad.
        #expect(ignores(CGPoint(x: 1300, y: 120)))
    }

    @Test func theNoticeItselfStillTakesTheClick() {
        #expect(!ignores(CGPoint(x: 1300, y: 40)))
    }

    @Test func aPointerOnTheCardsEdgeStillCounts() {
        #expect(!ignores(CGPoint(x: 1200 - 4, y: 40)))
        #expect(ignores(CGPoint(x: 1200 - 20, y: 40)))
    }

    @Test func noCardsMeansEverythingPassesThrough() {
        #expect(ignores(CGPoint(x: 1300, y: 40), cards: []))
    }

    @Test func anySeparateCardAnswers() {
        let other = CGRect(x: 600, y: 100, width: 300, height: 200)
        #expect(!ignores(CGPoint(x: 700, y: 150), cards: [clipboardPill, other]))
    }

    @Test func aHiddenShellTakesNothing() {
        #expect(ignores(CGPoint(x: 1300, y: 40), hidden: true))
    }

    /// An ambient copy announces itself without arming the keyboard, which is what would
    /// make the shell drop `.nonactivatingPanel` and activate DoraX.
    @Test @MainActor func aCopyNoticeDoesNotArmTheKeyboard() {
        let model = ClipboardPanelModel()
        model.didCopy()
        #expect(model.phase == .collapsed)
        #expect(!model.isKeyboardArmed)
    }

    @Test @MainActor func theShellPanelStaysUnkeyedUntilAskedTo() {
        let panel = CornerDockPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.becomesKeyOnlyIfNeeded = true
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.isKeyWindow)
    }
}
