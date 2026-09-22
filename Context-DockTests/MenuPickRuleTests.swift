import Foundation
import Testing

@testable import Context_Dock

/// Tier 2 of the menu router asks the on-device model which menu item the user meant, and
/// the answer comes back as fields rather than a sentence. These cover the rule applied to
/// that answer, which is the part that decides whether the user is shown a menu proposal at
/// all.
///
/// The rule lives apart from the model call on purpose: no model runs in this suite, and the
/// decision worth pinning down is not "can the model pick" but "what does the app do with a
/// pick it should not trust".
@Suite("Menu pick rule")
struct MenuPickRuleTests {
    @Test func aConfidentPickBecomesAZeroBasedIndex() {
        #expect(
            MenuPickRule.candidateIndex(index: 1, certainty: "certain", candidateCount: 5) == 0)
        #expect(
            MenuPickRule.candidateIndex(index: 5, certainty: "certain", candidateCount: 5) == 4)
    }

    @Test func likelyIsStillWorthOffering() {
        #expect(
            MenuPickRule.candidateIndex(index: 3, certainty: "likely", candidateCount: 5) == 2)
    }

    /// Tier 2 runs only because the keyword score already failed to find a confident match.
    /// A guess on top of that is worse than no proposal, because the pill it would build
    /// reads "Best path: …" with nothing marking it as a guess.
    @Test func aGuessIsNotOffered() {
        #expect(
            MenuPickRule.candidateIndex(index: 2, certainty: "unsure", candidateCount: 5) == nil)
        for word in MenuPickRule.lowConfidenceWords {
            #expect(
                MenuPickRule.candidateIndex(index: 1, certainty: word, candidateCount: 5) == nil,
                "\(word) should not produce a proposal")
        }
    }

    @Test func certaintyIsReadLooselyEnoughToSurviveTheModelsWording() {
        #expect(
            MenuPickRule.candidateIndex(index: 1, certainty: "  UNSURE ", candidateCount: 3)
                == nil)
        // Not on the reject list, so it counts. Requiring an approved word instead would
        // throw away a real pick for describing itself in the wrong register.
        #expect(
            MenuPickRule.candidateIndex(index: 1, certainty: "very sure", candidateCount: 3) == 0)
        #expect(MenuPickRule.candidateIndex(index: 1, certainty: "", candidateCount: 3) == 0)
    }

    /// Zero is how the model says none of these, and it is the same answer as an index that
    /// does not exist: propose nothing.
    @Test func zeroAndOutOfRangeBothMeanNoProposal() {
        #expect(MenuPickRule.candidateIndex(index: 0, certainty: "certain", candidateCount: 5) == nil)
        #expect(MenuPickRule.candidateIndex(index: 6, certainty: "certain", candidateCount: 5) == nil)
        #expect(MenuPickRule.candidateIndex(index: -1, certainty: "certain", candidateCount: 5) == nil)
        #expect(MenuPickRule.candidateIndex(index: 1, certainty: "certain", candidateCount: 0) == nil)
    }
}
