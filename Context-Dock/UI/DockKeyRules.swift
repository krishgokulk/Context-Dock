// DockKeyRules.swift
// Context-Dock
//
// The Dock's keyboard rules, as one pure type both shells read.
//
// The ⌥⌥ Dock's key monitor (`LauncherView+KeyboardNavigation`) has always been the reference
// for what a key does, and the Corner was meant to do the same — but each shell answered the
// question in its own code, so the Corner drifted: ← left the highlight on the row, Esc threw
// the query away, Backspace deleted a character out from under a highlighted row, and Tab
// never reached the running-app pills at all (parity inventory C4–C7, C9).
//
// A rule here takes only the facts a key depends on and answers with what should happen. The
// shells keep doing it — reclaiming the caret, resizing a window — because that part really
// is theirs. What a key *means* lives here once, with its tests.

import Foundation

/// The keys the rules speak about. Anything else is none of theirs.
enum DockKey: Equatable {
    case left, right, up, down, tab, escape, backspace, returnKey

    /// Only a bare key: with ⌘, ⌃ or ⌥ down it is a shortcut, and a shortcut belongs to
    /// whoever defined it.
    init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 126: self = .up
        case 125: self = .down
        case 48: self = .tab
        case 53: self = .escape
        case 51: self = .backspace
        case 36, 76: self = .returnKey
        default: return nil
        }
    }
}

enum DockKeyRules {

    // MARK: - A result row is focused (C4, C5, C6)

    /// What a key does to the result list while the user has arrowed onto a row.
    enum ResultFocus: Equatable {
        /// Let go of the row; the caret is back in the field, the query untouched.
        case clearFocus
        /// Let go of the row and close the list back to the field, the query untouched.
        case collapseKeepingQuery
        /// Not this rule's key: the shell's other handlers decide.
        case pass
    }

    /// The Dock's result-focus keys (`LauncherView+KeyboardNavigation`, the grouped-list
    /// switch): ← hands the caret back (C4), Esc closes the list but keeps what was typed
    /// (C5), Backspace lets go of the row and deletes nothing (C6).
    ///
    /// `listIsOpen` is a list the user *opened* — the Dock's expanded sheet, the Corner's
    /// arrowed-open list. A list that is simply how a scope rests (a Finder search's
    /// results) is not one: Esc there keeps its field meaning.
    ///
    /// Backspace on a row **only** lets go of it. It never runs the row, never quits the app
    /// the row names, and never reaches the field as a deletion — a highlighted app row and a
    /// key that means "remove" are one slip away from quitting that app.
    static func resultFocus(
        _ key: DockKey, hasFocusedRow: Bool, listIsOpen: Bool
    ) -> ResultFocus {
        switch key {
        case .left, .backspace:
            return hasFocusedRow ? .clearFocus : .pass
        case .escape:
            // An open list is what Esc closes; a row alone is what it lets go of. With
            // neither, Esc keeps its field meaning (clear, then close).
            if listIsOpen { return .collapseKeepingQuery }
            return hasFocusedRow ? .clearFocus : .pass
        default:
            return .pass
        }
    }

    // MARK: - The pill row (C7, C9)

    /// What a key does to the row of app pills beside the field.
    enum PillRow: Equatable {
        /// Put the highlight on the pill at this index.
        case focus(Int)
        /// Take the highlight off the pills; the caret is the field's again.
        case leaveToField
        /// Open the highlighted pill, as a click on it would.
        case open(Int)
        /// The key is spent and nothing moves: ↑/↓ while a pill is highlighted, as in the
        /// Dock, where they neither walk the pills nor change layer.
        case stay
        /// Not this rule's key.
        case pass
    }

    /// The Dock's app-pill keys (horizontal row): Tab enters and leaves pill navigation —
    /// and is always spent while the row is up, so macOS Full Keyboard Navigation never takes
    /// the focus ring away (C7); ←/→ walk the pills, skip separators, and wrap to the field at
    /// either end (C9); Backspace and Esc let go (never quit an app); Return opens the pill.
    ///
    /// `separators` marks the pills that are dividers, not destinations. `rowIsAvailable` is
    /// whether the row is on screen at all: nothing typed and something to show.
    static func pillRow(
        _ key: DockKey, focused: Int?, separators: [Bool], rowIsAvailable: Bool
    ) -> PillRow {
        let count = separators.count
        guard rowIsAvailable, count > 0 else {
            // A highlight left on a row that has gone is let go of by any key.
            return focused == nil ? .pass : .leaveToField
        }
        guard let current = focused, separators.indices.contains(current) else {
            guard key == .tab else { return .pass }
            return firstPill(from: 0, step: 1, separators).map(PillRow.focus) ?? .pass
        }
        switch key {
        case .tab, .escape, .backspace:
            return .leaveToField
        case .left:
            return firstPill(from: current - 1, step: -1, separators).map(PillRow.focus)
                ?? .leaveToField
        case .right:
            return firstPill(from: current + 1, step: 1, separators).map(PillRow.focus)
                ?? .leaveToField
        case .returnKey:
            return .open(current)
        case .up, .down:
            return .stay
        }
    }

    /// The nearest pill that is not a separator, walking from `start` by `step`; nil past
    /// either end.
    private static func firstPill(from start: Int, step: Int, _ separators: [Bool]) -> Int? {
        var index = start
        while separators.indices.contains(index) {
            if !separators[index] { return index }
            index += step
        }
        return nil
    }
}
