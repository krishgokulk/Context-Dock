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
                clipboardArmed: false, selectionVisible: false, chatShowsInput: true) == .chat)
    }

    @Test("An armed clipboard takes it, even with the chat field on screen")
    func armedClipboardOutranksTheChat() {
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: true, selectionVisible: false, chatShowsInput: true)
                == .clipboard)
        #expect(
            CornerKeyboardOwner.chatFieldHoldsFocus(
                clipboardArmed: true, selectionVisible: false, chatShowsInput: true) == false)
    }

    @Test("The selection card outranks the chat, and yields to an armed clipboard")
    func selectionSitsBetween() {
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: false, selectionVisible: true, chatShowsInput: true)
                == .selection)
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: true, selectionVisible: true, chatShowsInput: true)
                == .clipboard)
    }

    @Test("A clipboard that is merely visible does not take the keyboard — only an armed one")
    func unarmedClipboardLeavesTheChatAlone() {
        // The pill appears on copy without the user asking for it. Taking the caret then
        // would steal keys mid-sentence.
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: false, selectionVisible: false, chatShowsInput: true) == .chat)
    }

    @Test("With nothing up, nobody holds it")
    func nothingUpNoOwner() {
        #expect(
            CornerKeyboardOwner.owner(
                clipboardArmed: false, selectionVisible: false, chatShowsInput: false) == .none)
    }

    @Test("The chat gets it back the moment the clipboard disarms")
    func chatRecoversOnDisarm() {
        #expect(
            CornerKeyboardOwner.chatFieldHoldsFocus(
                clipboardArmed: true, selectionVisible: false, chatShowsInput: true) == false)
        #expect(
            CornerKeyboardOwner.chatFieldHoldsFocus(
                clipboardArmed: false, selectionVisible: false, chatShowsInput: true))
    }
}
