import Foundation
import Testing

@testable import Context_Dock

// The Notes adapter's canonical question set. Same four groups as
// RemindersAdapterEvalTests, same bundle-id-only difference — see that file for why the
// groups are these four and no more.
//
// Notes differs from Reminders in one way worth knowing while reading group four: notes.read,
// notes.extract_tasks and notes.summarize are declared `.low` and do their own approval inside
// the executor, keyed on the persistent-read setting. So for those three the declared risk is
// not the whole promise, and the registry gate in AICapabilityRegistry.execute is not what
// stops them.

@MainActor
struct NotesAdapterEvalTests {

    private static let bundleId = "com.apple.Notes"

    private func decision(_ query: String) -> AgentSourceDecision {
        AgentSourceAuthority.decide(query: query, scopeBundleId: Self.bundleId)
    }

    // MARK: - Reads must reach a reader

    @Test func questionsAboutTheRecordSetGroundInALiveRead() {
        for query in [
            "what did i write recently?",
            "how many notes do i have?",
            "show me my notes",
            "find my note about the launch",
            "anything about the invoice?",
        ] {
            let d = decision(query)
            #expect(d.primary == .liveState, "\"\(query)\" must reach a reader, got \(d.primary)")
            #expect(!d.allowsMemoryEvidence, "\"\(query)\" must not come from saved memory")
        }
    }

    // MARK: - Writes must stay writes

    @Test func changesAreNeverClassifiedAsReads() {
        for query in [
            "create a note called groceries",
            "add a line to my meeting note",
            "delete this note",
        ] {
            let d = decision(query)
            #expect(d.primary != .liveState, "\"\(query)\" is a change, got \(d.primary)")
        }
    }

    // MARK: - Questions about the app, not its contents

    @Test func questionsAboutTheAppItselfDoNotForceARead() {
        for query in [
            "how do i pin a note?",
            "where is the folder list?",
        ] {
            let d = decision(query)
            #expect(d.primary != .liveState, "\"\(query)\" asks about the app, got \(d.primary)")
        }
    }

    // MARK: - Consequence is declared

    @Test func readsAreFreeAndWritesAreGated() {
        let registry = CapabilityRegistry.shared
        for id in ["notes.search", "notes.link_related", "notes.extract_tasks", "notes.summarize"]
        {
            guard let capability = registry.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(!capability.riskLevel.requiresApproval, "\(id) is a read but asks approval")
        }
        for id in ["notes.create", "notes.append", "notes.update"] {
            guard let capability = registry.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(
                capability.riskLevel.requiresApproval,
                "\(id) writes but would run with no approval")
        }
    }

    // MARK: - Absence stays a finding

    /// Verbatim from AppleNotesMCPCapabilities. A search that ran and matched nothing has
    /// answered the question; retrying it spends the turn's remaining rounds for nothing.
    @Test func anEmptySearchIsAnAnswer() {
        for output in [
            "No notes found matching 'invoice'.",
            "No related notes found for 'Launch plan'.",
        ] {
            #expect(!EvidenceSufficiency.admitsDefeat(output), "\"\(output)\" is a finding")
        }
    }
}
