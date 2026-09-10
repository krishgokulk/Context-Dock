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

/// Somewhere for a main-queue observer to put what it saw.
@MainActor
private final class Received {
    private(set) var all: [[AnyHashable: Any]] = []
    nonisolated func append(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        MainActor.assumeIsolated { all.append(info) }
    }
}

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

        // Every test in the process shares one NotificationCenter, and these run in
        // parallel — watching for "the next notification" caught another test's question
        // and compared it to this one's. Collect, then find our own.
        let question = "summarise this \(UUID().uuidString)"
        model.query = question

        let received = Received()
        let token = NotificationCenter.default.addObserver(
            forName: .appChatPromptSubmitted, object: nil, queue: .main
        ) { note in received.append(note.userInfo) }
        defer { NotificationCenter.default.removeObserver(token) }

        #expect(model.submit())
        try await Task.sleep(nanoseconds: 100_000_000)

        let ours = received.all.first { $0["query"] as? String == question }
        // By the time the turn runs, the frontmost app is Context Dock and the live
        // selection is gone — so the text has to be carried, not re-read.
        #expect(ours?["selectedText"] as? String == "the paragraph the user highlighted")
        #expect(ours?["bundleId"] as? String == "com.microsoft.VSCode")
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
