import Testing
import Foundation
@testable import Context_Dock

// MARK: - A question is not a licence to write
//
// The tool loop checked authority and risk and never intent, so "what's in my trash bin"
// reached the Empty Trash capability: permitted, high risk, approved on a card, and the
// wrong action. Emptying the trash does answer "is it empty" — afterwards, and permanently.
//
// The guard has to be wrong in only one direction. Letting a write through that should have
// been refused costs the user data; refusing one they clearly asked for costs them a retry,
// and is still a bug. These cover both sides.

@MainActor
struct WriteIntentGuardTests {

    private var resolver: GeneralAIActionResolver { .shared }

    // MARK: Refuses

    @Test func questionsAboutAThingNeverAuthoriseChangingIt() {
        #expect(resolver.asksOnly("what's in my trash bin"))
        #expect(resolver.asksOnly("how many items are in the bin"))
        #expect(resolver.asksOnly("show me my reminders"))
        #expect(resolver.asksOnly("what is my current volume"))
    }

    // MARK: Permits

    /// Read-shaped by its opening and plainly also an instruction. Blocking the delete here
    /// would be the guard misreading the user rather than protecting them.
    @Test func aQuestionFollowedByAnInstructionIsStillAnInstruction() {
        #expect(!resolver.asksOnly("show me my reminders then delete the completed ones"))
        #expect(!resolver.asksOnly("what's in my trash bin — empty it"))
        #expect(!resolver.asksOnly("list my notes and remove the empty ones"))
    }

    @Test func plainImperativesAreNeverRefused() {
        #expect(!resolver.asksOnly("empty the trash"))
        #expect(!resolver.asksOnly("turn on dark mode"))
        #expect(!resolver.asksOnly("create a reminder to call sujith at 5pm"))
        #expect(!resolver.asksOnly("restart my mac"))
    }

    /// The guard only ever fires on read-shaped phrasing, so anything without a read signal
    /// passes regardless of what else it says.
    @Test func phrasingWithNoQuestionSignalIsNeverRefused() {
        #expect(!resolver.asksOnly("trash bin"))
        #expect(!resolver.asksOnly("dark mode"))
    }

    /// Nouns are not verbs. "trash" and "bin" are what the user is asking *about* in the
    /// sentence this guard exists to catch — treating them as mutating words would make the
    /// guard permit the exact call it was written to stop.
    @Test func theSubjectOfTheQuestionIsNotReadAsAnInstruction() {
        #expect(resolver.asksOnly("what's in my trash bin"))
        #expect(resolver.asksOnly("what's in the bin"))
    }

    /// Stricter than looksReadOnly on purpose: one refuses, the other only declines to
    /// offer. A sentence carrying an instruction must clear the stricter gate and not the
    /// looser one.
    @Test func refusingIsStricterThanDecliningToOffer() {
        let mixed = "show me my reminders then delete the completed ones"
        #expect(resolver.looksReadOnly(mixed))
        #expect(!resolver.asksOnly(mixed))
    }
}
