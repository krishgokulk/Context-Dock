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

    // MARK: - The list (C1, C3, C10)

    /// ↑/↓ over the results: the first press opens the list **and** lands on a row — the
    /// Dock's `expandGlobalContextTypingMatch(selectFirst: true)` — ↓ at the top, ↑ at the
    /// bottom; after that they move, wrapping. Nil when there is nothing to move through.
    static func listArrow(down: Bool, focused: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current = focused else { return down ? 0 : count - 1 }
        return (current + (down ? 1 : -1) + count) % count
    }

    /// The arrows in a list under an "Ask AI" row (Finder): nil is that row, and the walk
    /// wraps through it — ↓ from it to the first row, ↑ from the first row back to it.
    static func listArrowUnderAskRow(down: Bool, focused: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current = focused else { return down ? 0 : count - 1 }
        let next = current + (down ? 1 : -1)
        return (0..<count).contains(next) ? next : nil
    }

    /// Which row ↩ runs: the one the arrows landed on, else — where the field is a search —
    /// the top row, the one its leading icon previews. Nil means ↩ is not the list's: the
    /// field sends what is typed.
    static func returnRow(focused: Int?, count: Int, runsTopRow: Bool) -> Int? {
        if let focused, focused >= 0, focused < count { return focused }
        return runsTopRow && count > 0 ? 0 : nil
    }

    /// Space previews the highlighted row only while the user is arrowing through the list;
    /// with the caret in the field a space is a space. ⌘Space is Spotlight's.
    static func spacePreviews(hasFocusedRow: Bool, rowHasPreview: Bool, command: Bool) -> Bool {
        !command && hasFocusedRow && rowHasPreview
    }

    // MARK: - Walking the running apps with ←/→ on an empty field

    /// Where ←/→ go from the app at `current` (nil: Global Context) through `count` apps in
    /// pill order. → steps into the first app, then the next, wrapping; ← steps back one app
    /// at a time and, from the first, home to Global — the Dock's walk, in both directions.
    enum AppWalk: Equatable {
        case app(Int)
        case global
        case none
    }

    static func appWalk(forward: Bool, current: Int?, count: Int) -> AppWalk {
        guard count > 0 else { return .none }
        guard let current, current >= 0, current < count else {
            // From Global: → enters the first app; ← is not the walk's (the field folds).
            return forward ? .app(0) : .none
        }
        if forward { return .app((current + 1) % count) }
        return current == 0 ? .global : .app(current - 1)
    }

    // MARK: - Backspace on an empty field (B3, B4, E4)

    /// What Backspace on an empty field steps out of, innermost first.
    enum EmptyBackspace: Equatable {
        /// Up one folder — the mirror of → into it (B3).
        case leaveFolder
        /// Out of the Selection Scope, closing the surface: the scope *is* the surface, and
        /// an empty field under it is a dead end (B4).
        case leaveSelectionAndClose
        /// Out of the frontmost-app chat, kept, back to that app's menu search (E4).
        case leaveChat
        /// Out of a scope entered from Global Context, back to Global (B3).
        case leaveScope
        case pass
    }

    /// The Dock's ladder for Backspace on an empty field, in its order: a folder first, then
    /// the Selection Scope, then an app chat, then a scope entered from Global.
    static func emptyBackspace(
        browsingFolder: Bool, selectionScope: Bool, chatOpen: Bool, scopedFromGlobal: Bool
    ) -> EmptyBackspace {
        if browsingFolder { return .leaveFolder }
        if selectionScope { return .leaveSelectionAndClose }
        if chatOpen { return .leaveChat }
        if scopedFromGlobal { return .leaveScope }
        return .pass
    }

    // MARK: - ⌘R re-reads the app's menus (C12)

    /// ⌘R and nothing else held: the menu re-read's key in both shells.
    static func isMenuRereadKey(
        keyCode: UInt16, command: Bool, control: Bool, option: Bool, shift: Bool
    ) -> Bool {
        keyCode == 15 && command && !control && !option && !shift
    }

    /// Whether ⌘R re-reads the scoped app's live menus — for a menu that changed since the
    /// scope opened (a document opened, a tab moved). Only an app scope has menus to read:
    /// not Global Context, not a CLI tool, and not Finder (the Corner's file search, the Dock
    /// over Finder), whose lazy AX tree has nothing to show until its menus are opened.
    /// Declined, the key is spent on nothing and never reaches the frontmost app.
    static func rereadsMenus(
        appBundleID: String, isGlobalScope: Bool, isCLIScope: Bool, isFinder: Bool
    ) -> Bool {
        !appBundleID.isEmpty && !isGlobalScope && !isCLIScope && !isFinder
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
