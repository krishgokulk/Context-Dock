import Testing
import Foundation
@testable import Context_Dock

// MARK: - Act, ask, or answer
//
// Steps 0.5 and 1 of docs/architecture/FRONTMOST_AGENT.md meet here.
//
// The bar is not confidence. Confidence alone produces a prompt on every request, which is
// worse than guessing. It is what a wrong choice costs: a read that picks the wrong list
// wastes a sentence, and a write that picks the wrong target does not.

struct CapabilityDecisionTests {

    private func hit(
        _ id: String, _ score: Double, write: Bool, coverage: Double = 1.0
    ) -> CapabilityIndex.Hit {
        .init(
            record: CapabilityRecord(
                id: id, app: "App", kind: .capability, title: id, isWrite: write),
            score: score,
            matched: ["x"],
            coverage: coverage)
    }

    // MARK: - Nothing named

    /// "is this page related to our contextdock project?" ranks nothing. Prose is the
    /// honest answer, and offering an action instead is the bug that started this.
    @Test func nothingRankedMeansAnswerInProse() {
        #expect(CapabilityDecision.make(from: []) == .answer)
    }

    // MARK: - A clear leader

    @Test func aLoneCandidateIsActedOn() {
        let only = hit("finder.trash", 4.0, write: true)
        #expect(CapabilityDecision.make(from: [only]) == .act(only))
    }

    @Test func aClearLeadOnAReadIsActedOn() {
        let hits = [hit("notes.search", 4.0, write: false), hit("mail.search", 3.0, write: false)]
        #expect(CapabilityDecision.make(from: hits) == .act(hits[0]))
    }

    // MARK: - A write has to be clearly right

    /// The asymmetry, stated. The same gap that lets a read proceed makes a write ask,
    /// because being nearly right about which thing to delete is not a licence to delete
    /// it.
    @Test func theSameGapActsOnAReadAndAsksOnAWrite() {
        let read = [hit("a.read", 4.0, write: false), hit("b.read", 3.5, write: false)]
        let write = [hit("a.write", 4.0, write: true), hit("b.write", 3.5, write: true)]

        #expect(CapabilityDecision.make(from: read) == .act(read[0]))
        if case .ask = CapabilityDecision.make(from: write) {} else {
            Issue.record("a write with a 0.5 lead must ask")
        }
    }

    @Test func aWriteWithARealGapProceeds() {
        let hits = [hit("a.write", 6.0, write: true), hit("b.write", 3.0, write: true)]
        #expect(CapabilityDecision.make(from: hits) == .act(hits[0]))
    }

    // MARK: - What gets offered

    /// Only real alternatives. Putting six options in front of someone who asked one
    /// question is its own kind of unhelpful.
    @Test func onlyGenuineContendersAreOffered() {
        let hits = [
            hit("a", 4.00, write: false),
            hit("b", 3.99, write: false),
            hit("c", 1.00, write: false),
        ]
        guard case .ask(let offered) = CapabilityDecision.make(from: hits) else {
            Issue.record("expected a tie to be asked about")
            return
        }
        #expect(offered.map(\.record.id) == ["a", "b"])
    }

    /// The leader is always among the options — the user should be able to pick what
    /// DoraX would have chosen.
    @Test func theLeaderIsOneOfTheOptions() {
        let hits = [hit("a", 4.0, write: true), hit("b", 3.9, write: true)]
        guard case .ask(let offered) = CapabilityDecision.make(from: hits) else {
            Issue.record("expected ask")
            return
        }
        #expect(offered.first?.record.id == "a")
    }

    // MARK: - A tie that means nothing

    /// From the first shadow log: "new chat" tied five ways at 10.39 — New Board, New
    /// Automator Document, New Event, New Card, Check Mail — because "new" is in all of
    /// them and nothing in the capability set is about chat. Asking between five unrelated
    /// things is the ranking passing its own failure to the user.
    /// The real shape of it: a high score, and half the sentence unaccounted for. A
    /// threshold on score alone does not catch this, and the first attempt at this fix did
    /// not — 10.39 clears any floor worth having.
    ///
    /// These are not answers and must not be offered as a menu; none of the five
    /// New-something commands is a chat. They are near misses, and saying so is what
    /// separates "I could not find that, here is what I have" from both a wrong choice and
    /// an unhelpful silence.
    @Test func aHalfMatchedSentenceOffersNearMissesNotAnswers() {
        let hits = [
            hit("a", 10.39, write: false, coverage: 0.5),
            hit("b", 10.39, write: false, coverage: 0.5),
            hit("c", 10.39, write: false, coverage: 0.5),
        ]
        guard case .suggest(let near) = CapabilityDecision.make(from: hits) else {
            Issue.record("half a sentence matched should suggest, not answer or ask")
            return
        }
        #expect(near.count == 3)
    }

    /// A single strong candidate that only explains half the sentence is the same problem
    /// without the tie, and must not be acted on either.
    @Test func aLoneCandidateMustAlsoExplainTheSentence() {
        guard case .suggest = CapabilityDecision.make(
            from: [hit("a", 12.0, write: true, coverage: 0.5)])
        else {
            Issue.record("a half-matched leader must not be acted on")
            return
        }
    }

    /// Nothing at all is still nothing: with no hits there is no near miss to name, and
    /// inventing one would be worse than silence.
    @Test func withNoHitsThereIsNothingToSuggest() {
        #expect(CapabilityDecision.make(from: []) == .answer)
    }

    /// A real tie between things that scored well is still a question.
    @Test func aTieAmongStrongCandidatesIsStillAsked() {
        let hits = [hit("a", 9.0, write: false), hit("b", 9.0, write: false)]
        if case .ask = CapabilityDecision.make(from: hits) {} else {
            Issue.record("a strong tie must still ask")
        }
    }

    /// Past three, a question stops being a choice.
    @Test func neverMoreThanThreeOptions() {
        let hits = (0..<6).map { hit("c\($0)", 9.0, write: false) }
        guard case .ask(let offered) = CapabilityDecision.make(from: hits) else {
            Issue.record("expected ask")
            return
        }
        #expect(offered.count == 3)
    }

    // MARK: - Explaining itself

    /// Every decision has to be able to say what it did and on which words, or the shadow
    /// log is unreadable and so is the receipt.
    @Test func everyDecisionExplainsItself() {
        #expect(CapabilityDecision.make(from: []).summary.contains("nothing"))
        #expect(CapabilityDecision.make(from: [hit("a", 9.0, write: false, coverage: 0.4)])
            .summary.contains("near"))
        #expect(CapabilityDecision.make(from: [hit("finder.trash", 9.0, write: true)])
            .summary.contains("finder.trash"))
        #expect(CapabilityDecision.make(from: [hit("a", 4.0, write: true), hit("b", 3.9, write: true)])
            .summary.contains("ask"))
    }
}
