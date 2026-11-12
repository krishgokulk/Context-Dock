// AppChatComposerToolbarTests.swift
// Context-DockTests
//
// The App Pet composer's lower row (app chip, provider chip, "+"): only in the frontmost
// app's own conversation, never in a search field, the clipboard board or before a chat.

import Testing

@testable import Context_Dock

@Suite("App Pet composer toolbar")
struct AppChatComposerToolbarTests {

    @Test("an App Pet conversation draws the lower row")
    func appPetChatShowsRow() {
        #expect(
            AppChatComposerToolbar.shows(
                phase: .chat, isSearchField: false, isClipboardScope: false,
                appBundleID: "com.apple.MobileSMS"))
    }

    @Test("every phase before the chat keeps the single field row")
    func nonChatPhasesKeepOneRow() {
        for phase: AppChatPromptPhase in [.hidden, .mini, .dock, .prompt, .suggesting] {
            #expect(
                !AppChatComposerToolbar.shows(
                    phase: phase, isSearchField: false, isClipboardScope: false,
                    appBundleID: "com.apple.MobileSMS"))
        }
    }

    @Test("a search field — Global Context or a scope stepped into from it — has no lower row")
    func searchFieldHasNoRow() {
        #expect(
            !AppChatComposerToolbar.shows(
                phase: .chat, isSearchField: true, isClipboardScope: false,
                appBundleID: "com.apple.MobileSMS"))
    }

    @Test("the clipboard board and a field with no app have no lower row")
    func clipboardAndNoAppHaveNoRow() {
        #expect(
            !AppChatComposerToolbar.shows(
                phase: .chat, isSearchField: false, isClipboardScope: true,
                appBundleID: "com.apple.MobileSMS"))
        #expect(
            !AppChatComposerToolbar.shows(
                phase: .chat, isSearchField: false, isClipboardScope: false, appBundleID: ""))
    }
}
