// CornerKeyboardOwnerTests.swift
// Context-DockTests
//
// The corner stacks several surfaces in one shell and they all want the keyboard. This is
// the rule that stops them arguing — the bug it fixes was the clipboard arming while the
// chat field held the caret, so the down arrow moved the text cursor instead of walking
// the clips.

import Testing

@testable import Context_Dock

@Suite("Corner keyboard owner")
struct CornerKeyboardOwnerTests {

    @Test("With only the chat up, the chat holds the keyboard")
    func chatIsTheRestingOwner() {
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: false, selectionWantsKeyboard: false, chatShowsInput: true) == .chat)
    }

    @Test("An armed clipboard takes it, even with the chat field on screen")
    func armedClipboardOutranksTheChat() {
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: true, selectionWantsKeyboard: false, chatShowsInput: true)
                == .clipboard)
        #expect(
            CornerKeyboardOwner.chatFieldHoldsFocus(
                clipboardArmed: true, selectionWantsKeyboard: false, chatShowsInput: true) == false)
    }

    @Test("The selection card outranks the chat, and yields to an armed clipboard")
    func selectionSitsBetween() {
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: false, selectionWantsKeyboard: true, chatShowsInput: true)
                == .selection)
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: true, selectionWantsKeyboard: true, chatShowsInput: true)
                == .clipboard)
    }

    @Test("A clipboard that is merely visible does not take the keyboard — only an armed one")
    func unarmedClipboardLeavesTheChatAlone() {
        // The pill appears on copy without the user asking for it. Taking the caret then
        // would steal keys mid-sentence.
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: false, selectionWantsKeyboard: false, chatShowsInput: true) == .chat)
    }

    @Test("With nothing up, nobody holds it")
    func nothingUpNoOwner() {
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: false, selectionWantsKeyboard: false, chatShowsInput: false) == .none)
    }

    @Test("The chat gets it back the moment the clipboard disarms")
    func chatRecoversOnDisarm() {
        #expect(
            CornerKeyboardOwner.chatFieldHoldsFocus(
                clipboardArmed: true, selectionWantsKeyboard: false, chatShowsInput: true) == false)
        #expect(
            CornerKeyboardOwner.chatFieldHoldsFocus(
                clipboardArmed: false, selectionWantsKeyboard: false, chatShowsInput: true))
    }

    /// Naming an owner is only half of it. The corner is a `.nonactivatingPanel` — the very
    /// thing that keeps its ambient pills harmless also stops it becoming key — and only
    /// the chat field ever dropped that style. So a selection card summoned by hotkey was
    /// named the owner, focused its field, and could not receive a keystroke: a caret sat
    /// in a window the keyboard could not reach.
    @Test("Any surface that owns the keyboard needs the panel to take it")
    func thePanelTakesTheKeyboardForEveryClaimant() {
        #expect(
            CornerKeyboardOwner.panelHoldsKeyboard(
                clipboardArmed: false, selectionWantsKeyboard: true, chatShowsInput: false))
        #expect(
            CornerKeyboardOwner.panelHoldsKeyboard(
                clipboardArmed: true, selectionWantsKeyboard: false, chatShowsInput: false))
        #expect(
            CornerKeyboardOwner.panelHoldsKeyboard(
                clipboardArmed: false, selectionWantsKeyboard: false, chatShowsInput: true))
    }

    @Test("It gives the keyboard back when every surface is gone")
    func thePanelReleasesWhenNobodyWantsIt() {
        #expect(
            CornerKeyboardOwner.panelHoldsKeyboard(
                clipboardArmed: false, selectionWantsKeyboard: false, chatShowsInput: false) == false)
    }

    @Test("The chat closing does not take the keys from a card still up")
    func closingOneSurfaceDoesNotDisarmAnother() {
        // The chat used to disarm on its own phase change, which would pull the keyboard
        // out from under a selection card that was still on screen.
        #expect(
            CornerKeyboardOwner.panelHoldsKeyboard(
                clipboardArmed: false, selectionWantsKeyboard: true, chatShowsInput: false))
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: false, selectionWantsKeyboard: true, chatShowsInput: false)
                == .selection)
    }
}
