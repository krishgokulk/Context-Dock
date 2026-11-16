// CapabilityWriteRetentionTests.swift
// Context-Dock
//
// Cross-turn capability write retention — Issue #233.
//
// A notes.create (or reminders.create, calendar.create) write in turn N must be
// visible to the model in turn N+1 so it can answer "what did you just create?"
// without retracting the write. Two mechanisms keep it visible:
//
//   A. DockCore+AIChat appends "[Capability writes this turn: …]" to the assistant
//      message when building the history array for the next turn's provider call.
//
//   B. ScopedTurnRunner skips the unperformed-work correction pass when no tools
//      ran this turn AND history already carries that marker — the model is answering
//      a history question, not asserting new unperformed work.
//
// These tests cover (B) via AgentAnswerVerifier.historyContainsPriorCapabilityWrites
// and the interaction between the marker and claimsUnperformedWork.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Capability write retention across turns (#233)")
struct CapabilityWriteRetentionTests {

    // MARK: - historyContainsPriorCapabilityWrites

    @Test func emptyHistoryHasNoWrites() {
        #expect(!AgentAnswerVerifier.historyContainsPriorCapabilityWrites([]))
    }

    @Test func userOnlyHistoryHasNoWrites() {
        let history = [ChatMessage(role: .user, content: "Create a note titled Meeting")]
        #expect(!AgentAnswerVerifier.historyContainsPriorCapabilityWrites(history))
    }

    @Test func assistantMessageWithoutMarkerHasNoWrites() {
        let history = [
            ChatMessage(role: .user, content: "Create a note titled Meeting"),
            ChatMessage(role: .assistant, content: "Done — note 'Meeting' has been created."),
        ]
        #expect(!AgentAnswerVerifier.historyContainsPriorCapabilityWrites(history))
    }

    @Test func assistantMessageWithMarkerDetectedAsWrite() {
        let content = "Done — note 'Meeting' has been created."
            + "\n\n[Capability writes this turn: notes.create(title: \"Meeting\")]"
        let history = [
            ChatMessage(role: .user, content: "Create a note titled Meeting"),
            ChatMessage(role: .assistant, content: content),
        ]
        #expect(AgentAnswerVerifier.historyContainsPriorCapabilityWrites(history))
    }

    @Test func markerOnUserMessageIsIgnored() {
        // A user message that happens to contain the marker text must not count.
        let userContent = "My draft: [Capability writes this turn: notes.create] — ignore this"
        let history = [
            ChatMessage(role: .user, content: userContent),
            ChatMessage(role: .assistant, content: "Here is your note."),
        ]
        #expect(!AgentAnswerVerifier.historyContainsPriorCapabilityWrites(history))
    }

    @Test func multipleCapabilityWritesAllDetected() {
        let content = "Created a note and a reminder."
            + "\n\n[Capability writes this turn: notes.create(title: \"Meeting\"), reminders.create(title: \"Follow up\")]"
        let history = [ChatMessage(role: .assistant, content: content)]
        #expect(AgentAnswerVerifier.historyContainsPriorCapabilityWrites(history))
    }

    // MARK: - suppressUnperformedWorkCheck semantics

    /// The model answers "what note did you create?" with no tools this turn, but history
    /// shows a prior write. The suppression condition should be true — no correction fired.
    @Test func suppressWhenHistoryHasPriorWriteAndNoToolsRan() {
        let content = "Done — note 'Meeting' has been created."
            + "\n\n[Capability writes this turn: notes.create(title: \"Meeting\")]"
        let history = [
            ChatMessage(role: .user, content: "Create a note titled Meeting"),
            ChatMessage(role: .assistant, content: content),
        ]
        let executed: [AIProviderService.ExecutedCommand] = []
        let suppress = executed.isEmpty
            && AgentAnswerVerifier.historyContainsPriorCapabilityWrites(history)
        #expect(suppress)
    }

    /// Turn 2: user asks "Create another note", model correctly calls notes.create.
    /// executed is non-empty → suppression is false → claimsUnperformedWork can fire normally.
    @Test func noSuppressWhenToolsRanThisTurn() {
        let content = "Done — note 'Meeting' has been created."
            + "\n\n[Capability writes this turn: notes.create(title: \"Meeting\")]"
        let history = [
            ChatMessage(role: .user, content: "Create a note titled Meeting"),
            ChatMessage(role: .assistant, content: content),
        ]
        let executed = [AIProviderService.ExecutedCommand(
            command: "run_capability(notes.create, ...)",
            output: "Created note 'Agenda' with ID: xyz",
            success: true)]
        let suppress = executed.isEmpty
            && AgentAnswerVerifier.historyContainsPriorCapabilityWrites(history)
        #expect(!suppress)
    }

    /// No prior writes in history → suppression is false → original verifier logic applies.
    @Test func noSuppressWhenHistoryHasNoPriorWrites() {
        let history = [
            ChatMessage(role: .user, content: "Create a note titled Meeting"),
            ChatMessage(role: .assistant, content: "Done — note 'Meeting' has been created."),
        ]
        let executed: [AIProviderService.ExecutedCommand] = []
        let suppress = executed.isEmpty
            && AgentAnswerVerifier.historyContainsPriorCapabilityWrites(history)
        #expect(!suppress)
    }

    // MARK: - claimsUnperformedWork baseline (must not regress)

    @Test func claimsUnperformedWorkFiringUnchangedWithNoHistory() {
        // Turn 1 hallucination: no tools ran, model claims work. Verifier must still fire.
        #expect(AgentAnswerVerifier.claimsUnperformedWork(
            answer: "Done — the note has been created.",
            executed: []))
    }

    @Test func claimsUnperformedWorkSilentWhenToolRan() {
        let executed = [AIProviderService.ExecutedCommand(
            command: "run_capability(notes.create, ...)",
            output: "Created note 'Meeting'",
            success: true)]
        #expect(!AgentAnswerVerifier.claimsUnperformedWork(
            answer: "Done — the note has been created.",
            executed: executed))
    }
}
