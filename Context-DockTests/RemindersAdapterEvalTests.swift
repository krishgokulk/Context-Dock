import Foundation
import Testing

@testable import Context_Dock

// The Reminders adapter's canonical question set.
//
// Every app adapter is meant to pass the same contract, and the row that decides whether the
// rest of it matters is grounding: does a question about the user's records reach a reader
// before the model is allowed to answer? Asked with Reminders in front, "what do I need to
// finish today?" used to classify `.conversation` — answer from the prompt, no reader — and
// the model invented reminders that did not exist.
//
// These are evals in the same sense as RoutePreferenceEvalTests: offline, deterministic, and
// about which decision a request gets rather than what a model says about it. Nothing here
// calls a provider, so the set can grow without the suite costing money or needing a network.
//
// Adding an app: copy this file, change the bundle id, keep the four groups.

@MainActor
struct RemindersAdapterEvalTests {

    private static let bundleId = "com.apple.reminders"

    private func decision(_ query: String) -> AgentSourceDecision {
        AgentSourceAuthority.decide(query: query, scopeBundleId: Self.bundleId)
    }

    // MARK: - Reads must reach a reader

    /// The questions someone actually opens this chat to ask. None of them names a reminder,
    /// a task or a to-do; the app in front is the noun. Every one must force a fresh read.
    @Test func questionsAboutTheRecordSetGroundInALiveRead() {
        for query in [
            "what do i need to finish today?",
            "what's due today?",
            "anything overdue?",
            "what's left to do today?",
            "how many reminders do i have?",
            "do i have anything due tomorrow?",
            "show me my list",
            "what's on for this week?",
        ] {
            let d = decision(query)
            #expect(d.primary == .liveState, "\"\(query)\" must reach a reader, got \(d.primary)")
            #expect(d.requiresFreshRead, "\"\(query)\" must require a fresh read")
            #expect(
                !d.allowsMemoryEvidence,
                "\"\(query)\" must not be answerable from saved memory")
        }
    }

    // MARK: - Writes must stay writes

    /// `.liveState` says "answer only from a live reader". A change routed there never reaches
    /// `.action`, which is the branch carrying execution authority and the approval gate — so
    /// a misclassified write is both an action that does not happen and an answer about the
    /// wrong thing. `create a reminder "call mum" today at 5pm` was answered "You have no open
    /// reminders" exactly this way.
    @Test func changesAreNeverClassifiedAsReads() {
        for query in [
            #"create a reminder "call mum" today at 5pm"#,
            "add a reminder to pay the bank tomorrow",
            "delete my grocery reminder",
            "remind me today to send the invoice",
        ] {
            let d = decision(query)
            #expect(d.primary != .liveState, "\"\(query)\" is a change, got \(d.primary)")
        }
    }

    // MARK: - Questions about the app, not its contents

    /// A question about the interface carries the same words as a question about the records.
    /// Forcing a read here answers "your reminders were not readable" to someone who asked how
    /// a feature works.
    @Test func questionsAboutTheAppItselfDoNotForceARead() {
        for query in [
            "how do i see what is due today?",
            "how can i share my list?",
            "where do i change the default list?",
        ] {
            let d = decision(query)
            #expect(d.primary != .liveState, "\"\(query)\" asks about the app, got \(d.primary)")
        }
    }

    // MARK: - Consequence is declared

    /// The reads this adapter answers with must not put an approval sheet in front of an
    /// ordinary question, and the writes must not skip one. Declared risk is what the gate in
    /// `AICapabilityRegistry.execute` reads, so this is the whole of the promise.
    @Test func readsAreFreeAndWritesAreGated() {
        let registry = CapabilityRegistry.shared
        for id in ["reminders.today", "reminders.list", "reminders.overdue"] {
            guard let capability = registry.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(!capability.riskLevel.requiresApproval, "\(id) is a read but asks approval")
        }
        for id in ["reminders.create", "reminders.complete", "reminders.delete"] {
            guard let capability = registry.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(
                capability.riskLevel.requiresApproval,
                "\(id) writes but would run with no approval")
        }
    }
}
