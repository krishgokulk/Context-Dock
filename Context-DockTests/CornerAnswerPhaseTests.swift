// CornerAnswerPhaseTests.swift
// Context-DockTests
//
// Asking inside a scope with no history of its own — a CLI tool, an app never chatted with
// — showed the scope's list again instead of the answer. The dock starts a fresh session
// for such a scope, and a fresh session publishes an empty transcript one hop after the
// question is handed over; the corner read that empty publish as "there is nothing here"
// and stepped back to the field. Nothing put it back when the answer arrived.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Corner answer phase")
@MainActor
struct CornerAnswerPhaseTests {

    private func scopedModel() -> (AppChatPromptModel, AppChatConversation) {
        let conversation = AppChatConversation()
        let model = AppChatPromptModel(conversation: conversation)
        model.summon(app: "brew", bundleID: "cli://brew")
        return (model, conversation)
    }

    @Test("The question's own session clear does not take the card away")
    func aFreshSessionDoesNotDropTheAnswer() {
        let (model, conversation) = scopedModel()
        model.query = "what can you do for me here?"

        #expect(model.submit())
        #expect(model.phase == .chat)

        // The dock retargets to this scope and starts a session for it: empty transcript,
        // no turn running yet.
        conversation.messages = []
        #expect(model.phase == .chat)

        conversation.messages = [AIChatMessage(role: .assistant, content: "brew can…")]
        #expect(model.phase == .chat)
    }

    @Test("An empty conversation nobody asked into is still a field")
    func anEmptyConversationWithoutAQuestionDrops() {
        let (model, conversation) = scopedModel()
        conversation.messages = [AIChatMessage(role: .assistant, content: "older")]
        // Arriving in a scope that already has a conversation shows it…
        model.frontmostAppDidChange(
            app: "Safari", bundleID: "com.apple.Safari", suggestions: [], summary: "")
        #expect(model.phase == .chat)

        // …and losing it, with nothing asked and no turn running, is a field again.
        conversation.messages = []
        #expect(model.phase != .chat)
    }

    @Test("Leaving the scope stops the surface waiting for that answer")
    func leavingStopsTheWait() {
        let (model, conversation) = scopedModel()
        model.query = "anything"
        #expect(model.submit())

        model.adoptScope(name: "Safari", bundleID: "com.apple.Safari")
        conversation.messages = []
        #expect(model.phase != .chat)
    }
}
