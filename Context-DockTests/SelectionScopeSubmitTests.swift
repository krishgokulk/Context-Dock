// SelectionScopeSubmitTests.swift
// Context-DockTests
//
// Typing a question into Selection Scope and pressing Return looked like it did nothing: the
// card vanished and no answer appeared anywhere. Two faults behind one symptom — the surface
// dismissed itself and handed the answer to a chat that was not on screen, and the selection
// it was opened on never travelled with the question.

import AppKit
import Foundation
import Testing

@testable import Context_Dock

@Suite("Selection scope submit")
@MainActor
struct SelectionScopeSubmitTests {

    private func summoned(text: String = "the paragraph the user highlighted")
        -> SelectionScopeModel
    {
        let model = SelectionScopeModel()
        let context = AXContext(
            appName: "Code", bundleId: "com.microsoft.VSCode", pid: 0, selectedText: text)
        #expect(model.summon(from: context))
        return model
    }

    @Test("The selection travels with the question")
    func theSelectedTextIsSent() async throws {
        let model = summoned()
        model.query = "summarise this"

        var received: [AnyHashable: Any]?
        let token = NotificationCenter.default.addObserver(
            forName: .appChatPromptSubmitted, object: nil, queue: .main
        ) { note in received = note.userInfo }
        defer { NotificationCenter.default.removeObserver(token) }

        #expect(model.submit())
        try await Task.sleep(nanoseconds: 100_000_000)

        // By the time the turn runs, the frontmost app is Context Dock and the live
        // selection is gone — so the text has to be carried, not re-read.
        #expect(received?["selectedText"] as? String == "the paragraph the user highlighted")
        #expect(received?["query"] as? String == "summarise this")
        #expect(received?["bundleId"] as? String == "com.microsoft.VSCode")
    }

    @Test("Asking opens somewhere for the answer to appear")
    func anAnswerSurfaceIsOpened() {
        let model = summoned()
        model.query = "explain this"
        #expect(model.submit())

        let presentation = CornerDockController.shared.chatPresentation
        #expect(presentation.isVisible)
        #expect(presentation.mode == .frontmostApp)
        // Waiting, not resting: the dock clears the session when it retargets, and a
        // transcript that treated that empty publish as "nothing here" would drop straight
        // back to a field before the answer arrived.
        #expect(presentation.appChat.phase == .chat)
    }
}
