// AppChatKeyRules.swift
// Context-Dock
//
// The Corner field carrying out the Dock's keyboard rules (`DockKeyRules`). The rules say what
// a key means; this says what that is in the Corner's own state — its focused row, its list
// phase, its pills.

import Foundation

extension AppChatPromptModel {

    /// The field's pills as the pill rule sees them: on screen only while nothing is typed
    /// (the same test the field draws them by), and never inside a conversation.
    var pillRowIsAvailable: Bool {
        // The Drop Shelf, when it shows, is the row's last pill, so the row can exist with
        // no app running.
        phase.showsInput && phase != .chat && showsFieldPills
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The row's destinations as the key rule walks them: the field's app pills, then the
    /// Drop Shelf — one past the last pill.
    var pillRowCount: Int { globalMatchIcons.count + (showsShelf ? 1 : 0) }

    /// The pill index the Drop Shelf holds in the row.
    var shelfPillIndex: Int { globalMatchIcons.count }

    /// Tab and ←/→ have the highlight on the Drop Shelf's icon.
    var isShelfFocused: Bool { showsShelf && focusedPillIndex == shelfPillIndex }

    /// The pill Tab and ←/→ have highlighted — the id the strip and the field draw it by.
    var focusedPill: MatchDockIcon? {
        guard let index = focusedPillIndex, globalMatchIcons.indices.contains(index)
        else { return nil }
        return globalMatchIcons[index]
    }

    /// → means "the next app / scope" rather than anything in the field: nothing typed (no
    /// caret to move, no ghost to take), no row and no pill highlighted.
    var rightArrowWalksFromEmptyField: Bool {
        query.isEmpty && focusedRow == nil && focusedPillIndex == nil
    }

    /// ←, Esc and Backspace while a result row is highlighted (C4–C6). Returns whether the
    /// key was spent. Backspace here only lets go of the row: it deletes nothing, runs
    /// nothing and quits nothing.
    @discardableResult
    func applyResultFocusKey(_ key: DockKey) -> Bool {
        // The list the arrows opened — the Corner's rows open by the arrows alone, so a
        // highlighted row is what says so. A scope that rests on its list (a Finder
        // search) is not one Esc should close.
        let hasFocusedRow = focusedRow != nil
        switch DockKeyRules.resultFocus(
            key, hasFocusedRow: hasFocusedRow,
            listIsOpen: phase == .suggesting && hasFocusedRow)
        {
        case .pass:
            return false
        case .clearFocus:
            focusedMenuIndex = nil
            touch()
            return true
        case .collapseKeepingQuery:
            focusedMenuIndex = nil
            // Back to the field's resting shape for what is typed — the list closes in
            // Global, a Finder search keeps its results — and the query stays.
            syncListPhase()
            touch()
            return true
        }
    }

    /// Tab, ←/→, Esc, Backspace, Return and ↑/↓ on the field's pills (C7, C9). Returns
    /// whether the key was spent. Entering the row is Tab's alone; every other key is only
    /// the pills' while one of them is highlighted.
    @discardableResult
    func applyPillRowKey(
        _ key: DockKey, shelf: DropShelfPresentation? = nil
    ) -> Bool {
        // A highlighted result row outranks the pills: Tab takes that row first.
        if focusedPillIndex == nil, focusedRow != nil { return false }
        let pills = globalMatchIcons
        switch DockKeyRules.pillRow(
            key, focused: focusedPillIndex,
            // The app pills, then the Drop Shelf — a destination like the rest.
            separators: Array(repeating: false, count: pillRowCount),
            rowIsAvailable: pillRowIsAvailable)
        {
        case .pass:
            return false
        case .focus(let index):
            focusedPillIndex = index
            touch()
            return true
        case .leaveToField:
            focusedPillIndex = nil
            touch()
            return true
        case .stay:
            return true
        case .open(let index):
            focusedPillIndex = nil
            // What a click on the Drop Shelf's icon does.
            if index == shelfPillIndex {
                (shelf ?? DropShelfController.shared.presentation).toggle()
                return true
            }
            guard pills.indices.contains(index) else { return true }
            // What a click on the pill does, so the key and the pointer agree.
            openGlobalMatchIcon(pills[index])
            return true
        }
    }
}
