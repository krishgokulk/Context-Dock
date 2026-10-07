import Testing

@testable import Context_Dock

/// A running app's icon in Global Context is the window manager's handle on it (owner
/// 2026-10-07): the app in front has its front window minimised, any other comes forward with
/// its minimised windows, and the hover card shows only when there is a choice of windows.
struct DockAppClickTests {
    @Test func theAppInFrontHasItsFrontWindowMinimised() {
        #expect(DockAppClick.action(isRunning: true, isFrontmost: true, visibleWindows: 1)
            == .minimizeFrontWindow)
        #expect(DockAppClick.action(isRunning: true, isFrontmost: true, visibleWindows: 3)
            == .minimizeFrontWindow)
    }

    /// Everything minimised: the click brings them back rather than minimising nothing.
    @Test func anAppWithEveryWindowMinimisedComesBack() {
        #expect(DockAppClick.action(isRunning: true, isFrontmost: true, visibleWindows: 0)
            == .bringForward)
    }

    @Test func anAppBehindComesForward() {
        #expect(DockAppClick.action(isRunning: true, isFrontmost: false, visibleWindows: 2)
            == .bringForward)
        #expect(DockAppClick.action(isRunning: false, isFrontmost: false, visibleWindows: 0)
            == .bringForward)
    }

    @Test func theWindowsCardNeedsMoreThanOneWindow() {
        #expect(!DockAppClick.showsWindowPreview(windowCount: 0))
        #expect(!DockAppClick.showsWindowPreview(windowCount: 1))
        #expect(DockAppClick.showsWindowPreview(windowCount: 2))
        // Unreadable (no Accessibility permission): the card stays, as before.
        #expect(DockAppClick.showsWindowPreview(windowCount: nil))
    }
}
