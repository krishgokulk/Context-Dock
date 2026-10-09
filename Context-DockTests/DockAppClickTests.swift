import CoreGraphics
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

    /// The card opens only on something to show (owner 2026-10-08: "No windows" over a
    /// pinned web app): windows, a capture still running, or the Screen Recording ask.
    @Test func theWindowsCardIsNeverEmpty() {
        #expect(!AppChatPromptModel.windowCardHasContent(windows: 0, capturing: false, denied: false))
        #expect(AppChatPromptModel.windowCardHasContent(windows: 2, capturing: false, denied: false))
        #expect(AppChatPromptModel.windowCardHasContent(windows: 0, capturing: true, denied: false))
        #expect(AppChatPromptModel.windowCardHasContent(windows: 0, capturing: false, denied: true))
    }

    @Test func theWindowsCardNeedsMoreThanOneWindow() {
        #expect(!DockAppClick.showsWindowPreview(windowCount: 0))
        #expect(!DockAppClick.showsWindowPreview(windowCount: 1))
        #expect(DockAppClick.showsWindowPreview(windowCount: 2))
        // Unreadable (no Accessibility permission): the card stays, as before.
        #expect(DockAppClick.showsWindowPreview(windowCount: nil))
    }

    /// Windows are counted from the window server, never by asking the app: a busy Terminal
    /// froze the corner when every hover asked it over Accessibility.
    @Test func onlyTheAppsOwnDocumentWindowsCount() {
        let big = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(WindowServerWindows.isDocumentWindow(ownerPID: 42, layer: 0, bounds: big, pid: 42))
        // Another app's window, a menu or palette layer, a tiny helper window: not counted.
        #expect(!WindowServerWindows.isDocumentWindow(ownerPID: 7, layer: 0, bounds: big, pid: 42))
        #expect(!WindowServerWindows.isDocumentWindow(ownerPID: 42, layer: 25, bounds: big, pid: 42))
        #expect(!WindowServerWindows.isDocumentWindow(
            ownerPID: 42, layer: 0, bounds: CGRect(x: 0, y: 0, width: 40, height: 20), pid: 42))
        #expect(!WindowServerWindows.isDocumentWindow(ownerPID: 42, layer: 0, bounds: nil, pid: 42))
        // A transparent helper window (Electron keeps them) is not a window to choose.
        #expect(!WindowServerWindows.isDocumentWindow(
            ownerPID: 42, layer: 0, bounds: big, alpha: 0, pid: 42))
    }
}
