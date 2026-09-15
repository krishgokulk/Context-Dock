import Foundation
import Testing

@testable import Context_Dock

// Who asks before a note is read, and what "what's in this note?" grounds in.
//
// Issue #4 left two things open. Both are here.
//
// The first looked like two approval mechanisms: notes.read, notes.extract_tasks and
// notes.summarize are declared `.low`, so the registry gate waves them through, and then each
// executor asks for approval itself. It is not two mechanisms — it is the same
// AICapabilityApprovalCenter, called from a place that can see a setting the gate cannot.
// The gate takes a fixed riskLevel; this permission is conditional on a choice the user made.
//
// What was wrong is that the rule lived three times as an inline `if`, so deleting one by
// accident would have removed an approval with nothing to catch it.

@MainActor
struct NotesReadApprovalTests {

    // MARK: - The policy

    /// The whole rule, in one place, asserted rather than repeated in three executors.
    @Test func readingANoteAsksUnlessTheUserSaidNotTo() {
        #expect(
            AppleNotesMCPCapabilities.needsPerCallReadApproval(persistentFullReadEnabled: false),
            "with persistent read off, every full-body read must ask")
        #expect(
            !AppleNotesMCPCapabilities.needsPerCallReadApproval(persistentFullReadEnabled: true),
            "the user turned persistent read on; asking anyway discards their choice")
    }

    /// Declared `.low` is deliberate and load-bearing, so it is pinned with its reason. If a
    /// future change makes these `.medium`, the gate starts asking every time and the
    /// persistent-read setting silently stops working — which is a worse bug than it looks,
    /// because everything still functions and simply nags.
    @Test func theSelfGuardedReadsStayLowAtTheGate() {
        for id in ["notes.read", "notes.extract_tasks", "notes.summarize"] {
            guard let capability = CapabilityRegistry.shared.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(
                !capability.riskLevel.requiresApproval,
                """
                \(id) guards itself against a setting the gate cannot see; .medium here \
                would ask twice and ignore the setting
                """)
        }
    }

    /// The writes are the opposite arrangement: nothing conditional, so the gate does the whole
    /// job. Keeping both shapes visible in one test is the point — they are different on
    /// purpose.
    @Test func theWritesAreGatedNormally() {
        for id in ["notes.create", "notes.append", "notes.update"] {
            guard let capability = CapabilityRegistry.shared.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(capability.riskLevel.requiresApproval, "\(id) changes a note")
        }
    }

    // MARK: - Asking what is in the thing in front of you

    /// The second half of #4. "what's in this note?" names its subject, and the scope says which
    /// note — but it carries no freshness word and no possessive, so it grounded nowhere and
    /// the model answered from whatever it had.
    @Test func askingWhatIsInTheOpenRecordGroundsInARead() {
        for (bundleId, query) in [
            ("com.apple.Notes", "what's in this note?"),
            ("com.apple.Notes", "summarise this note"),
            ("com.apple.Notes", "what does this note say?"),
            ("com.apple.mail", "what's in this email?"),
            ("com.apple.reminders", "what's in this list?"),
        ] {
            let decision = AgentSourceAuthority.decide(query: query, scopeBundleId: bundleId)
            #expect(
                decision.primary == .liveState,
                "\"\(query)\" in \(bundleId) must read the record, got \(decision.primary)")
            #expect(!decision.allowsMemoryEvidence, "\"\(query)\" must not come from memory")
        }
    }

    /// Unscoped, the same sentence has no record to read, so forcing a live read would only
    /// produce "it was not readable" for a question no reader owns.
    @Test func theSameQuestionWithNoRecordAppStaysConversational() {
        for bundleId in ["com.apple.Safari", "com.apple.finder"] {
            let decision = AgentSourceAuthority.decide(
                query: "what's in this note?", scopeBundleId: bundleId)
            #expect(decision.primary != .liveState, "\(bundleId) owns no record set")
        }
    }

    /// The counterweight for the widened signals. These say "this" too and are not reads of the
    /// open record — widening far enough to catch them would ground questions that have no
    /// reader and answer them with "not readable".
    @Test func widerSignalsDoNotSwallowOrdinaryTalk() {
        for query in ["what's in it for me?", "how do i read this?", "what is this app?"] {
            let decision = AgentSourceAuthority.decide(
                query: query, scopeBundleId: "com.apple.Notes")
            #expect(
                decision.primary != .liveState,
                "\"\(query)\" is not a request to read the open note, got \(decision.primary)")
        }
    }
}
