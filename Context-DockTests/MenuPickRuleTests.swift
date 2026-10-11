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

    // MARK: - Reading a cloud provider's reply

    /// The cloud fallback is reached whenever the on-device model is not available to ask, so
    /// these are the answers a real provider gives when it is the one deciding.
    @Test func readsTheTwoFieldsOutOfPlainJSON() throws {
        let pick = try #require(
            MenuPickRule.parse(reply: #"{"index": 3, "certainty": "certain"}"#))
        #expect(pick.index == 3)
        #expect(pick.certainty == "certain")
    }

    @Test func readsThemThroughACodeFenceOrAnExplanation() throws {
        let fenced = try #require(
            MenuPickRule.parse(
                reply: "```json\n{\"index\": 2, \"certainty\": \"likely\"}\n```"))
        #expect(fenced.index == 2)
        #expect(fenced.certainty == "likely")

        let explained = try #require(
            MenuPickRule.parse(
                reply: #"Looking at the list, {"index": 1, "certainty": "unsure"} is closest."#))
        #expect(explained.index == 1)
        #expect(explained.certainty == "unsure")
    }

    /// A model that ignores the format has still answered. The older picker threw these away.
    @Test func aBareNumberIsStillAnAnswer() throws {
        let bare = try #require(MenuPickRule.parse(reply: "3"))
        #expect(bare.index == 3)
        #expect(bare.certainty == "")
        #expect(try #require(MenuPickRule.parse(reply: "2.")).index == 2)
    }

    @Test func noneAndNonsenseBothMeanNoPick() {
        #expect(MenuPickRule.parse(reply: "none") == nil)
        #expect(MenuPickRule.parse(reply: "NONE") == nil)
        #expect(MenuPickRule.parse(reply: "") == nil)
        #expect(MenuPickRule.parse(reply: "   ") == nil)
        #expect(MenuPickRule.parse(reply: "I could not tell") == nil)
    }

    /// The point of the whole change: the cloud path and the on-device path are gated by the
    /// same rule, so a guess is dropped in both.
    @Test func aCloudGuessIsDroppedJustAsAnOnDeviceGuessIs() throws {
        let pick = try #require(
            MenuPickRule.parse(reply: #"{"index": 4, "certainty": "unsure"}"#))
        #expect(
            MenuPickRule.candidateIndex(
                index: pick.index, certainty: pick.certainty, candidateCount: 10) == nil)
    }

    @Test func aCloudIndexOutsideTheListIsRefusedNotClamped() throws {
        let pick = try #require(
            MenuPickRule.parse(reply: #"{"index": 11, "certainty": "certain"}"#))
        #expect(
            MenuPickRule.candidateIndex(
                index: pick.index, certainty: pick.certainty, candidateCount: 10) == nil)
    }
}
