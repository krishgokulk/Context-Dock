import Foundation
import Testing

@testable import Context_Dock

/// The corner is a non-activating panel, which is what keeps the ambient pills harmless and
/// is also exactly what stops it becoming key. Something has to decide when it may hold the
/// keyboard, and it used to be the phase change alone — so it happened once, on the way in.
@MainActor
struct CornerDockKeyboardTests {
    @Test func aFreshCornerHoldsNoKeyboard() {
        let state = CornerDockKeyboardState()

        #expect(!state.isArmed)
        #expect(state.focusRequestToken == 0)
    }

    @Test func clickingTheComposerArmsTheKeyboardAndAsksForFocus() {
        let state = CornerDockKeyboardState()

        state.composerInteracted()

        #expect(state.isArmed)
        #expect(state.focusRequestToken == 1)
    }

    /// The bug this exists for: click the pill, click another app, click the pill again.
    /// Nothing about the phase changed, so a boolean would already read true and the field
    /// would never be told to take focus back. The token moves every time.
    @Test func clickingAgainAfterFocusWentElsewhereIsANewRequest() {
        let state = CornerDockKeyboardState()

        state.composerInteracted()
        state.composerInteracted()
        state.composerInteracted()

        #expect(state.focusRequestToken == 3)
    }

    /// Shrinking to the badge is leaving. The corner must give the keyboard back, or it
    /// keeps it from the app the user just returned to.
    @Test func standingDownGivesTheKeyboardBack() {
        let state = CornerDockKeyboardState()
        state.composerInteracted()

        state.stoodDown()

        #expect(!state.isArmed)
    }

    /// Standing down ends the arming, not the conversation about focus: coming back is a
    /// fresh request, counted from where the last one left off.
    @Test func comingBackAfterAStandDownArmsItAgain() {
        let state = CornerDockKeyboardState()
        state.composerInteracted()
        state.stoodDown()

        state.composerInteracted()

        #expect(state.isArmed)
        #expect(state.focusRequestToken == 2)
    }
}
