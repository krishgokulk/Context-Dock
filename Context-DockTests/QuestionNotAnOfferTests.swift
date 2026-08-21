import Testing
import Foundation
@testable import Context_Dock

// MARK: - A question is answered, not offered as an action
//
// Step 0 of docs/architecture/FRONTMOST_AGENT.md.
//
// Asked "is this page related to our contextdock project in any ways you think?", a Safari
// thread replied "I found an enabled Safari tool for this task. Run it? → Run Open Social".
// offerScopedNativeAppAction's whole gate was "some capability's keywords overlap, or this
// looks executable" — nothing asked whether the sentence was a question.
//
// asksOnly existed and would not have caught it either: it needs a read *keyword* —
// "what", "show", "list" — and that sentence has none. It is a question by shape, which
// isQuestionShaped already knew and nothing consulted.
//
// The cases here are the sentences actually typed into DoraX, on both sides of the line.

@MainActor
struct QuestionNotAnOfferTests {

    private let resolver = GeneralAIActionResolver.shared

    // MARK: - Questions

    /// The sentence from the report.
    @Test func theQuestionThatWasOfferedAnAction() {
        #expect(resolver.asksOnly(
            "is this page related to our contextdock project in any ways you think?"))
    }

    @Test func questionsWithoutAnyReadKeyword() {
        #expect(resolver.asksOnly("is this page anything useful for our contextdock ?"))
        #expect(resolver.asksOnly("does this help us at all?"))
        #expect(resolver.asksOnly("are these two the same thing?"))
    }

    /// Read keywords still work — this is the older signal and it must not regress.
    @Test func readKeywordsStillRead() {
        #expect(resolver.asksOnly("what's in my downloads"))
        #expect(resolver.asksOnly("show me my recent files"))
    }

    // MARK: - Instructions

    /// An instruction phrased politely, with a question mark, is still an instruction.
    /// Blocking these would break asking DoraX to do anything in a civil tone.
    @Test func politeInstructionsAreNotQuestions() {
        #expect(!resolver.asksOnly("can you open safari?"))
        #expect(!resolver.asksOnly("could you please empty the trash?"))
        #expect(!resolver.asksOnly("would you close this window?"))
    }

    @Test func bareInstructionsAreNotQuestions() {
        #expect(!resolver.asksOnly("open safari"))
        #expect(!resolver.asksOnly("delete these files"))
        #expect(!resolver.asksOnly("new window"))
    }

    /// A change verb wins over a question mark: naming the change is what matters.
    @Test func aChangeVerbBeatsTheQuestionMark() {
        #expect(!resolver.asksOnly("turn on dark mode?"))
        #expect(!resolver.asksOnly("can you create a reminder for 5pm?"))
    }

    /// The pair that has to stay apart, from the interactive-command fix.
    @Test func theReadAndTheWriteOfTheSameSetting() {
        #expect(resolver.asksOnly("is dark mode on?"))
        #expect(!resolver.asksOnly("turn on dark mode"))
    }
}
