import Testing
import Foundation
@testable import Context_Dock

// MARK: - Scope-supplied grounding
//
// AgentSourceAuthority read the query and nothing else. In Context Dock Chat the frontmost
// app is half the sentence: "what do I need to finish today?" asked with Reminders in front
// is a question about reminder records, but the query names no object, so `isLiveStateQuestion`
// found a freshness word with nothing to attach it to and the decision came back
// `.conversation` — "answer conversationally", no reader forced, model answering from nothing.
//
// The app in front is the noun the user did not type. These cover it standing in, and the
// three ways it must not.

@MainActor
struct ScopedGroundingTests {

    @Test func theFrontmostDataAppSuppliesTheMissingObjectNoun() {
        let decision = AgentSourceAuthority.decide(
            query: "what do i need to finish today?",
            scopeBundleId: "com.apple.reminders")
        #expect(decision.primary == .liveState)
        #expect(decision.requiresFreshRead)
        #expect(!decision.allowsMemoryEvidence)
    }

    /// Unscoped there is no record set to read, and forcing a fresh read would only produce
    /// "it was not readable" for a question no reader owns.
    @Test func theSameQuestionWithoutAScopeStaysConversational() {
        let decision = AgentSourceAuthority.decide(query: "what do i need to finish today?")
        #expect(decision.primary != .liveState)
    }

    /// Safari is frontmost constantly and owns no records. Only apps whose whole content is
    /// a record set get to answer a question that never named one.
    @Test func anAppWithNoRecordSetSuppliesNothing() {
        let decision = AgentSourceAuthority.decide(
            query: "what do i need to finish today?",
            scopeBundleId: "com.apple.Safari")
        #expect(decision.primary != .liveState)
    }

    /// `create a reminder "call mum" today at 5pm` already answered "You have no open
    /// reminders" once, in ReadOnlyDataRouter. Scope must not reopen that hole from the
    /// other side: a change is never a read, whatever app is in front.
    @Test func scopeDoesNotTurnAWriteIntoARead() {
        let decision = AgentSourceAuthority.decide(
            query: #"create a reminder "call mum" today at 5pm"#,
            scopeBundleId: "com.apple.reminders")
        #expect(decision.primary != .liveState)
    }

    /// A question about the app's interface carries the same freshness words as a question
    /// about its contents. "how do I see what is due today?" wants documentation, not a read.
    @Test func scopeDoesNotHijackAProcedureQuestion() {
        let decision = AgentSourceAuthority.decide(
            query: "how do i see what is due today?",
            scopeBundleId: "com.apple.reminders")
        #expect(decision.primary != .liveState)
    }

    /// The mapping the whole rule rests on. Every app here owns a record set a reader can
    /// return; anything else must map to nothing rather than to a plausible-looking domain.
    @Test func everyPersonalDataAppMapsToItsRecordSet() {
        #expect(ReadOnlyDataDomain(scopeBundleId: "com.apple.reminders") == .reminders)
        #expect(ReadOnlyDataDomain(scopeBundleId: "com.apple.Notes") == .notes)
        #expect(ReadOnlyDataDomain(scopeBundleId: "com.apple.mail") == .mail)
        #expect(ReadOnlyDataDomain(scopeBundleId: "com.apple.iCal") == .calendar)
        #expect(ReadOnlyDataDomain(scopeBundleId: "com.apple.MobileSMS") == .messages)
        #expect(ReadOnlyDataDomain(scopeBundleId: "com.apple.AddressBook") == .contacts)
        #expect(ReadOnlyDataDomain(scopeBundleId: "com.apple.Photos") == .photos)

        #expect(ReadOnlyDataDomain(scopeBundleId: "com.apple.Safari") == nil)
        #expect(ReadOnlyDataDomain(scopeBundleId: "") == nil)
    }

    /// The other Apple record apps inherit the same fix — that is why it is worth making in
    /// the shared classifier rather than in a Reminders branch.
    @Test func theOtherRecordAppsInheritTheSameGrounding() {
        let cases: [(String, String)] = [
            ("com.apple.mail", "anything unread?"),
            ("com.apple.iCal", "what is on for tomorrow?"),
            ("com.apple.Notes", "what did i write recently?"),
        ]
        for (bundleId, query) in cases {
            let decision = AgentSourceAuthority.decide(query: query, scopeBundleId: bundleId)
            #expect(
                decision.primary == .liveState,
                "\(bundleId) should ground \"\(query)\" in a live read")
        }
    }
}

// MARK: - Absence is a finding
//
// "You have no reminders due today" and "I can't tell what's due today" are opposite
// statements, and `EvidenceSufficiency` is the only thing that tells them apart. Get it
// wrong in one direction and an empty list burns the turn's remaining rounds re-reading a
// list that is genuinely empty; wrong in the other and the model's shrug is served to the
// user as the answer.
//
// The Reminders capabilities each phrase their empty case in their own words, so the
// distinction rests on wording nobody is currently forced to keep. These pin it.

@MainActor
struct AbsenceReportingTests {

    /// Verbatim from AppleRemindersMCPCapabilities. A reader that ran, reached the store and
    /// found nothing has answered the question.
    @Test func anEmptyReadIsAnAnswerAndIsNotRetried() {
        for output in [
            "No reminders due today or overdue.",
            "No active reminders.",
            "Nothing overdue — you're caught up.",
            "No open reminder matching 'call mum' found.",
        ] {
            #expect(
                !EvidenceSufficiency.admitsDefeat(output),
                "\"\(output)\" is a finding; retrying it spends rounds to be told the same thing")
        }
    }

    /// The other direction, so the test above cannot be satisfied by a function that always
    /// returns false.
    @Test func anAdmissionOfNotKnowingIsStillCaught() {
        #expect(EvidenceSufficiency.admitsDefeat("I can't tell reliably from the data available."))
        #expect(EvidenceSufficiency.admitsDefeat("I don't have access to your reminders."))
        #expect(EvidenceSufficiency.admitsDefeat(""))
    }

    /// An empty read must not be retried even when rounds remain — that is the whole point of
    /// separating "found nothing" from "did not find out".
    @Test func roundsLeftDoNotJustifyRereadingAnEmptyList() {
        #expect(
            !EvidenceSufficiency.shouldRetry(
                answer: "No active reminders.", executed: [], roundsAllowed: 8))
    }
}
