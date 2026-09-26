// Context-DockTests/DockKeyRulesTests.swift
//
// The Dock's keyboard rules as one type both shells read (task 5; parity inventory C4–C7,
// C9). The pure rules first, then the Corner field carrying them out on its own state.

import AppKit
import Foundation
import Testing

@testable import Context_Dock

@Suite("Dock key rules")
struct DockKeyRulesTests {

    typealias R = DockKeyRules

    @Test("Only the bare keys the rules speak about are read")
    func keyCodes() {
        #expect(DockKey(keyCode: 123) == .left)
        #expect(DockKey(keyCode: 124) == .right)
        #expect(DockKey(keyCode: 48) == .tab)
        #expect(DockKey(keyCode: 53) == .escape)
        #expect(DockKey(keyCode: 51) == .backspace)
        #expect(DockKey(keyCode: 36) == .returnKey)
        #expect(DockKey(keyCode: 76) == .returnKey)
        #expect(DockKey(keyCode: 0) == nil)  // "a"
        #expect(DockKey(keyCode: 117) == nil)  // forward delete is not the Dock's backspace
    }

    // MARK: Result focus

    @Test("← with a row focused hands the caret back to the field (C4)")
    func leftLeavesResultFocus() {
        #expect(R.resultFocus(.left, hasFocusedRow: true, listIsOpen: true) == .clearFocus)
        #expect(R.resultFocus(.left, hasFocusedRow: false, listIsOpen: true) == .pass)
    }

    @Test("Esc with a row focused closes the list and keeps the query (C5)")
    func escapeCollapsesKeepingQuery() {
        #expect(
            R.resultFocus(.escape, hasFocusedRow: true, listIsOpen: true)
                == .collapseKeepingQuery)
        #expect(R.resultFocus(.escape, hasFocusedRow: true, listIsOpen: false) == .clearFocus)
        // The Dock's sheet open with nothing highlighted still closes, keeping the query.
        #expect(
            R.resultFocus(.escape, hasFocusedRow: false, listIsOpen: true)
                == .collapseKeepingQuery)
        // Nothing open, nothing highlighted: Esc keeps its field meaning.
        #expect(R.resultFocus(.escape, hasFocusedRow: false, listIsOpen: false) == .pass)
    }

    @Test("Backspace on a focused row lets go of it and does nothing else (C6)")
    func backspaceOnlyClearsFocus() {
        #expect(R.resultFocus(.backspace, hasFocusedRow: true, listIsOpen: true) == .clearFocus)
        #expect(R.resultFocus(.backspace, hasFocusedRow: false, listIsOpen: true) == .pass)
    }

    @Test("Keys the result rule does not own pass")
    func otherKeysPass() {
        for key: DockKey in [.right, .up, .down, .tab, .returnKey] {
            #expect(R.resultFocus(key, hasFocusedRow: true, listIsOpen: true) == .pass)
        }
    }

    // MARK: Pill row

    private let row = [false, false, false]

    @Test("Tab enters the pills, and Tab again leaves them (C7)")
    func tabEntersAndLeaves() {
        #expect(R.pillRow(.tab, focused: nil, separators: row, rowIsAvailable: true) == .focus(0))
        #expect(R.pillRow(.tab, focused: 1, separators: row, rowIsAvailable: true) == .leaveToField)
        // No row on screen: Tab is someone else's.
        #expect(R.pillRow(.tab, focused: nil, separators: row, rowIsAvailable: false) == .pass)
        #expect(R.pillRow(.tab, focused: nil, separators: [], rowIsAvailable: true) == .pass)
    }

    @Test("Only Tab enters the pills; other keys pass while none is highlighted")
    func onlyTabEnters() {
        for key: DockKey in [.left, .right, .up, .down, .escape, .backspace, .returnKey] {
            #expect(R.pillRow(key, focused: nil, separators: row, rowIsAvailable: true) == .pass)
        }
    }

    @Test("←/→ walk the pills and wrap to the field at either end (C9)")
    func arrowsWalkAndWrap() {
        #expect(R.pillRow(.right, focused: 0, separators: row, rowIsAvailable: true) == .focus(1))
        #expect(R.pillRow(.right, focused: 2, separators: row, rowIsAvailable: true) == .leaveToField)
        #expect(R.pillRow(.left, focused: 2, separators: row, rowIsAvailable: true) == .focus(1))
        #expect(R.pillRow(.left, focused: 0, separators: row, rowIsAvailable: true) == .leaveToField)
    }

    @Test("←/→ skip separators; Tab never lands on one (C9)")
    func separatorsAreSkipped() {
        let withDivider = [true, false, true, false]
        #expect(R.pillRow(.tab, focused: nil, separators: withDivider, rowIsAvailable: true) == .focus(1))
        #expect(R.pillRow(.right, focused: 1, separators: withDivider, rowIsAvailable: true) == .focus(3))
        #expect(R.pillRow(.left, focused: 3, separators: withDivider, rowIsAvailable: true) == .focus(1))
        #expect(
            R.pillRow(.left, focused: 1, separators: withDivider, rowIsAvailable: true)
                == .leaveToField)
    }

    @Test("Backspace and Esc on a pill let go of it — never quit the app it names")
    func backspaceAndEscapeLetGo() {
        #expect(R.pillRow(.backspace, focused: 1, separators: row, rowIsAvailable: true) == .leaveToField)
        #expect(R.pillRow(.escape, focused: 1, separators: row, rowIsAvailable: true) == .leaveToField)
    }

    @Test("Return opens the highlighted pill; ↑/↓ are spent and move nothing")
    func returnOpensAndVerticalStays() {
        #expect(R.pillRow(.returnKey, focused: 2, separators: row, rowIsAvailable: true) == .open(2))
        #expect(R.pillRow(.up, focused: 2, separators: row, rowIsAvailable: true) == .stay)
        #expect(R.pillRow(.down, focused: 2, separators: row, rowIsAvailable: true) == .stay)
    }

    @Test("A highlight left on a row that has gone is let go of by any key")
    func staleHighlightIsDropped() {
        #expect(R.pillRow(.right, focused: 1, separators: row, rowIsAvailable: false) == .leaveToField)
        #expect(R.pillRow(.returnKey, focused: 5, separators: row, rowIsAvailable: true) == .pass)
    }
}

@Suite("Corner keys follow the Dock's rules")
@MainActor
struct CornerDockKeyRulesTests {

    private static func icon(_ id: String) -> MatchDockIcon {
        MatchDockIcon(
            id: id, bundleID: id, title: id, icon: NSImage(), isRunning: true,
            isExpandable: false, score: 0, isExactAppPrefix: false)
    }

    private static func command(_ title: String) -> AppChatRow {
        .command(AXMenuItem(
            title: title, path: ["Safari", title], isEnabled: true,
            element: AXUIElementCreateSystemWide(), children: []))
    }

    /// Global Context with something typed and the list arrowed open on its first row.
    private func typedWithFocusedRow() -> AppChatPromptModel {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.query = "quit"
        model.rows = [Self.command("Quit Safari"), Self.command("Quit and Keep Windows")]
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.phase == .suggesting)
        return model
    }

    /// Global Context with an empty field and three running-app pills beside it.
    private func emptyWithPills() -> AppChatPromptModel {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.setGlobalTyping(top: nil, running: ["a", "b", "c"].map(Self.icon))
        #expect(model.pillRowIsAvailable)
        return model
    }

    @Test("← on a focused row lets go of it and keeps the query (C4)")
    func leftLeavesTheRow() {
        let model = typedWithFocusedRow()
        #expect(model.applyResultFocusKey(.left))
        #expect(model.focusedRow == nil)
        #expect(model.query == "quit")
    }

    @Test("Esc on a focused row closes the list and keeps the query (C5)")
    func escapeKeepsTheQuery() {
        let model = typedWithFocusedRow()
        #expect(model.applyResultFocusKey(.escape))
        #expect(model.focusedRow == nil)
        #expect(model.query == "quit")
        #expect(model.phase == .prompt)
    }

    @Test("Backspace on a focused \"Quit\" row lets go of it: nothing deleted, nothing run (C6)")
    func backspaceNeverQuits() {
        let model = typedWithFocusedRow()
        #expect(model.applyResultFocusKey(.backspace))
        #expect(model.focusedRow == nil)
        // The row did not run — running clears the field — and no character was taken.
        #expect(model.query == "quit")
        #expect(model.phase == .suggesting)
    }

    @Test("With no row focused the result keys are the field's")
    func noRowNoRule() {
        let model = emptyWithPills()
        for key: DockKey in [.left, .escape, .backspace] {
            #expect(!model.applyResultFocusKey(key))
        }
    }

    @Test("Tab walks into the pills and out again (C7)")
    func tabEntersPills() {
        let model = emptyWithPills()
        #expect(model.applyPillRowKey(.tab))
        #expect(model.focusedPill?.id == "a")
        #expect(model.applyPillRowKey(.tab))
        #expect(model.focusedPillIndex == nil)
    }

    @Test("←/→ walk the pills and wrap back to the field (C9)")
    func arrowsWalkThePills() {
        let model = emptyWithPills()
        #expect(model.applyPillRowKey(.tab))
        #expect(model.applyPillRowKey(.right))
        #expect(model.focusedPill?.id == "b")
        #expect(model.applyPillRowKey(.right))
        #expect(model.applyPillRowKey(.right))
        #expect(model.focusedPillIndex == nil)
        #expect(model.applyPillRowKey(.tab))
        #expect(model.applyPillRowKey(.left))
        #expect(model.focusedPillIndex == nil)
    }

    @Test("Backspace on a pill lets go of it and stays in the scope (C6)")
    func backspaceOnAPillStays() {
        let model = emptyWithPills()
        #expect(model.applyPillRowKey(.tab))
        #expect(model.applyPillRowKey(.backspace))
        #expect(model.focusedPillIndex == nil)
        #expect(model.isGlobalScope)
    }

    @Test("A highlighted row takes Tab before the pills do")
    func aFocusedRowOutranksThePills() {
        let model = typedWithFocusedRow()
        #expect(!model.applyPillRowKey(.tab))
        #expect(model.focusedPillIndex == nil)
    }

    @Test("Typing takes the highlight off the pills")
    func typingLeavesThePills() {
        let model = emptyWithPills()
        #expect(model.applyPillRowKey(.tab))
        model.query = "s"
        model.queryChanged()
        #expect(model.focusedPillIndex == nil)
        #expect(!model.pillRowIsAvailable)
    }
}
