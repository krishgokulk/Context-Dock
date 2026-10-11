// Context-DockTests/CornerAppActivationTests.swift
import Testing

@testable import Context_Dock

/// Clicking an app in the corner must do what the Dock does: an app whose only window is
/// minimised comes back with that window on screen, not merely "active" with nothing shown.
struct CornerAppActivationTests {
    @Test func aClickedRunningAppHasItsMinimisedWindowsRestored() {
        #expect(AppActivation.raiseSteps(isHidden: false, restoringWindows: true)
            == [.activate, .restoreMinimisedWindows])
    }

    @Test func aHiddenAppIsUnhiddenBeforeItIsActivated() {
        #expect(AppActivation.raiseSteps(isHidden: true, restoringWindows: true)
            == [.unhide, .activate, .restoreMinimisedWindows])
    }

    @Test func theRetryOnlyActivatesAndDoesNotStartASecondRestore() {
        #expect(AppActivation.raiseSteps(isHidden: false, restoringWindows: false) == [.activate])
    }
}
