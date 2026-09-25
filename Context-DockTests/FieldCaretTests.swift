// Context-DockTests/FieldCaretTests.swift
import AppKit
import Testing

@testable import Context_Dock

/// The letter that brings a field back must survive the next one: focus selects the field's
/// text, and a selected "s" was replaced by "l" ("sleep" → "leep").
struct FieldCaretTests {
    @Test func aSelectionLeftByFocusBecomesACaretAtTheEnd() {
        #expect(FieldCaret.collapsedSelection(
            textLength: 1, selection: NSRange(location: 0, length: 1))
            == NSRange(location: 1, length: 0))
        #expect(FieldCaret.collapsedSelection(
            textLength: 5, selection: NSRange(location: 0, length: 5))
            == NSRange(location: 5, length: 0))
    }

    @Test func aCaretOrAnEmptyFieldIsLeftAlone() {
        #expect(FieldCaret.collapsedSelection(
            textLength: 3, selection: NSRange(location: 2, length: 0)) == nil)
        #expect(FieldCaret.collapsedSelection(
            textLength: 0, selection: NSRange(location: 0, length: 0)) == nil)
    }

    @Test func onlyPrintableTextIsCarriedIntoAFieldStillTakingFocus() {
        #expect(FieldCaret.carriesTextIntoUnfocusedField(
            characters: "l", hasCommandControlOrOption: false))
        #expect(FieldCaret.carriesTextIntoUnfocusedField(
            characters: "é", hasCommandControlOrOption: false))
        #expect(!FieldCaret.carriesTextIntoUnfocusedField(
            characters: "l", hasCommandControlOrOption: true))
        #expect(!FieldCaret.carriesTextIntoUnfocusedField(
            characters: "\r", hasCommandControlOrOption: false))
        #expect(!FieldCaret.carriesTextIntoUnfocusedField(
            characters: "\u{F700}", hasCommandControlOrOption: false))  // ↑
        #expect(!FieldCaret.carriesTextIntoUnfocusedField(
            characters: nil, hasCommandControlOrOption: false))
    }
}
