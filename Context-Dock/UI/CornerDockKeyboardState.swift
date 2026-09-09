import Combine

/// Who holds the keyboard in the corner, published so each board can claim its own field.
///
/// Clearing one surface's focus does not hand it to another — SwiftUI focus is per-view, and
/// a board that arms *before* its card is mounted never sees a change to react to. That was
/// the clipboard: armed, on screen, and receiving no keys, because the only thing that had
/// happened was the chat field letting go.
///
/// So the owner is stated here, and every board watches it — on appear as well as on change —
/// and focuses itself when it is named. One fact, several listeners, no races between views
/// each asserting their own focus.
@MainActor
final class CornerDockKeyboardState: ObservableObject {
    @Published private(set) var isArmed = false
    @Published private(set) var focusRequestToken = 0
    /// The board that should have the caret right now.
    @Published private(set) var owner: CornerKeyboardClaimant = .none

    func composerInteracted() {
        isArmed = true
        focusRequestToken &+= 1
    }

    /// Recomputed whenever a board opens, arms or closes. The token is bumped even when the
    /// owner is unchanged, so a board that has just mounted still gets told to take focus.
    func ownerChanged(
        clipboardArmed: Bool,
        selectionVisible: Bool,
        chatShowsInput: Bool
    ) {
        owner = CornerKeyboardOwner.owner(
            clipboardArmed: clipboardArmed,
            selectionVisible: selectionVisible,
            chatShowsInput: chatShowsInput)
        focusRequestToken &+= 1
    }

    func stoodDown() {
        isArmed = false
        owner = .none
    }
}
