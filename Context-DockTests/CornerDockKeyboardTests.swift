import Testing

@testable import Context_Dock

@MainActor
struct CornerDockKeyboardTests {
    @Test func composerInteractionArmsKeyboardAndRequestsFreshFocus() {
        let state = CornerDockKeyboardState()

        state.composerInteracted()
        let firstRequest = state.focusRequestToken
        state.composerInteracted()

        #expect(state.isArmed)
        #expect(firstRequest == 1)
        #expect(state.focusRequestToken == 2)
    }

    @Test func standDownRestoresAmbientPanelState() {
        let state = CornerDockKeyboardState()
        state.composerInteracted()

        state.stoodDown()

        #expect(!state.isArmed)
    }
}
