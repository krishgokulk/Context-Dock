// FieldCaret.swift
// Context-Dock
//
// One text field gaining focus from SwiftUI: what happens to what is already in it.
//
// `@FocusState` hands focus over asynchronously, and the NSTextField's becomeFirstResponder
// selects all of its text. A field that was seeded with the key that opened it — the Dock's
// search, the corner's field brought back by typing — therefore held its first letter
// *selected*, and the second letter replaced it: "sleep" arrived as "leep". The Dock fixed
// this long ago inline; this is that fix, shared, so both shells run the same code.

import AppKit

enum FieldCaret {
    /// Pure: the selection to put back — a caret at the end — when focus left the field's
    /// text selected. Nil when there is nothing to change (no selection, or no text).
    static func collapsedSelection(textLength: Int, selection: NSRange) -> NSRange? {
        guard selection.length > 0, textLength > 0 else { return nil }
        return NSRange(location: textLength, length: 0)
    }

    /// After SwiftUI's focus pass has run — two main-queue turns — collapse whatever the
    /// focused field selected to a caret at its end. `window` nil means the key window at
    /// that moment.
    static func collapseSelectionToEndAfterFocus(in window: NSWindow? = nil) {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard let target = window ?? NSApp.keyWindow,
                    let editor = target.fieldEditor(false, for: nil) as? NSTextView,
                    let range = collapsedSelection(
                        textLength: (editor.string as NSString).length,
                        selection: editor.selectedRange())
                else { return }
                editor.setSelectedRange(range)
            }
        }
    }

    // MARK: Typing into a field that is still taking focus

    /// Keys waiting for the field, in the order they were pressed.
    @MainActor private static var pending = ""
    @MainActor private static var flushScheduled = false

    /// Keys are queued for a field that has not taken focus yet. Keys arriving now belong
    /// with them, whoever the keyboard owner says it is for this one turn.
    @MainActor static var isWaitingForFocus: Bool { flushScheduled }

    /// Type `text` into the field once it holds focus — through the field itself, so the
    /// field and its binding agree. Setting the model instead did not reach an NSTextField
    /// that had not taken focus yet: the field kept its old "", and the next real key wrote
    /// that back over the model ("s" then "l" left "l"). Keys that arrive while one flush is
    /// waiting join it, in order.
    @MainActor static func typeWhenFocused(_ text: String, in window: NSWindow?) {
        pending += text
        guard !flushScheduled else { return }
        flushScheduled = true
        flush(in: window, attempt: 0)
    }

    @MainActor private static func flush(in window: NSWindow?, attempt: Int) {
        DispatchQueue.main.async {
            if let target = window ?? NSApp.keyWindow,
                let editor = target.firstResponder as? NSTextView
            {
                let end = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: end, length: 0))
                editor.insertText(pending, replacementRange: NSRange(location: end, length: 0))
                pending = ""
                flushScheduled = false
            } else if attempt < 25 {
                // Focus is handed over a few turns later; half a second is the most it has
                // ever needed. Past that the keys are dropped rather than typed somewhere
                // the user is no longer looking.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    flush(in: window, attempt: attempt + 1)
                }
            } else {
                pending = ""
                flushScheduled = false
            }
        }
    }

    /// Pure: whether a key should be typed into a field that is on screen but has not taken
    /// focus yet. Between the key that brings the corner's field back and SwiftUI giving it
    /// focus, the next keys have nowhere to go and are dropped — fast typing lost whole
    /// words. Only printable text, never a key with ⌘ ⌃ ⌥.
    static func carriesTextIntoUnfocusedField(
        characters: String?, hasCommandControlOrOption: Bool
    ) -> Bool {
        guard !hasCommandControlOrOption, let characters, !characters.isEmpty else {
            return false
        }
        return characters.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && !(0xF700...0xF8FF).contains($0.value)  // function keys, arrows
        }
    }
}
