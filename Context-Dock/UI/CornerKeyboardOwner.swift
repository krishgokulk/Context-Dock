// CornerKeyboardOwner.swift
// Context-Dock
//
// Which corner surface owns the keyboard.
//
// The corner stacks several surfaces in one shell, and each of them used to answer that
// question for itself: the clipboard card takes SwiftUI focus when it is armed, the App Chat
// field takes it whenever its phase changes or a focus token is bumped, and the selection
// card takes it on appear. Whoever wrote last won — so opening the clipboard while the chat
// was up left the caret in the chat, and the down arrow moved the text cursor instead of
// walking the clips.
//
// One rule, in one place, read by every surface that wants focus.

import Foundation

enum CornerKeyboardClaimant: Equatable {
    case clipboard
    case selection
    case chat
    case none
}

enum CornerKeyboardOwner {

    /// Who should hold the keyboard, given what is on screen.
    ///
    /// A card that has already asked its question no longer wants the keyboard — the
    /// conversation moved to the chat, and a follow-up must be typeable there without
    /// dismissing the thing the question was about.
    ///
    /// Precedence is by how explicitly the user asked for it. Arming the clipboard is a
    /// deliberate "I am working in the clips now" — a hotkey, or a click on the card — so it
    /// outranks a chat field that is merely present. The selection card is summoned the same
    /// way and outranks the chat for the same reason. The chat field is the resting owner:
    /// it holds the keyboard whenever nothing louder is up, which is most of the time.
    static func owner(
        clipboardArmed: Bool,
        selectionWantsKeyboard: Bool,
        chatShowsInput: Bool
    ) -> CornerKeyboardClaimant {
        if clipboardArmed { return .clipboard }
        if selectionWantsKeyboard { return .selection }
        if chatShowsInput { return .chat }
        return .none
    }

    /// Should the panel be able to take the keyboard at all?
    ///
    /// Separate from *which* surface owns it, and the half that was missing: the corner is
    /// a `.nonactivatingPanel`, which is what keeps its ambient pills harmless and is also
    /// exactly what stops it becoming key. Only the chat field ever dropped that style, so
    /// a selection card summoned by hotkey named itself the keyboard's owner, focused its
    /// field, and could not receive a single keystroke.
    static func panelHoldsKeyboard(
        clipboardArmed: Bool,
        selectionWantsKeyboard: Bool,
        chatShowsInput: Bool
    ) -> Bool {
        owner(
            clipboardArmed: clipboardArmed,
            selectionWantsKeyboard: selectionWantsKeyboard,
            chatShowsInput: chatShowsInput) != .none
    }

    /// Should the App Chat field hold the caret right now?
    static func chatFieldHoldsFocus(
        clipboardArmed: Bool,
        selectionWantsKeyboard: Bool,
        chatShowsInput: Bool
    ) -> Bool {
        owner(
            clipboardArmed: clipboardArmed,
            selectionWantsKeyboard: selectionWantsKeyboard,
            chatShowsInput: chatShowsInput) == .chat
    }
}
