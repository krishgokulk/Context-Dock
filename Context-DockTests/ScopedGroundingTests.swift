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

// MARK: - Every write capability's own verb counts as a change
//
// `requestsChange` is the gate that keeps a change out of the read paths: ReadOnlyDataRouter
// refuses a domain when it fires, and `asksAboutScopedRecords` refuses to ground. A write
// capability whose natural verb is missing from its list is therefore routed as a question —
// answered from a reader, never executed, and never shown an approval sheet.
//
// The list was written from the verbs that existed then. Capabilities have been added since,
// and their verbs were not added with them, so this ties the two together: if you register a
// capability that changes something, the way a person would ask for it has to be recognised.

@MainActor
struct WriteVerbCoverageTests {

    @Test func theNaturalPhrasingOfEveryWriteCapabilityIsSeenAsAChange() {
        let cases: [(capability: String, asked: String)] = [
            ("notes.create", "create a note called groceries"),
            ("notes.append", "append the invoice number to my launch note"),
            ("notes.update", "update my meeting note with the new date"),
            ("reminders.create", "add a reminder to pay the bank tomorrow"),
            ("reminders.complete", "mark the bank reminder as done"),
            ("reminders.delete", "delete my grocery reminder"),
        ]
        for (capability, asked) in cases {
            #expect(
                GeneralAIActionResolver.shared.requestsChange(asked),
                """
                    \(capability) exists, but "\(asked)" is not recognised as a change, \
                    so it would be answered from a reader instead of run
                    """)
        }
    }

    /// The counterweight. These name the same records and change nothing, so widening the verb
    /// list must not swallow them — a read misread as a write loses its grounding and its
    /// answer.
    @Test func questionsAboutTheSameRecordsAreNotChanges() {
        for asked in [
            "what did i write recently?",
            "show me my completed reminders",
            "any updates on the launch note?",
            "find my note about the meeting",
            "what do i need to finish today?",
        ] {
            #expect(
                !GeneralAIActionResolver.shared.requestsChange(asked),
                "\"\(asked)\" is a question, not a change")
        }
    }
}
