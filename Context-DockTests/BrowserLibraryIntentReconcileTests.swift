import Foundation
import Testing

@testable import Context_Dock

/// One model answer about browser data carries five separate judgements, and they are not
/// equally hard. `source` is nearly always readable from the question; `subject` is the one
/// that goes wrong, which is why the prompt carries three prohibitions about it.
///
/// These cover the rule each field is admitted by. No model runs here.
@MainActor
@Suite("Browser library intent reconcile")
struct BrowserLibraryIntentReconcileTests {
    private func heuristic(
        source: BrowserLibraryIntent.Source = .history,
        subject: String = "",
        range: BrowserLibraryIntent.Range? = nil,
        latest: Bool = false,
        copy: Bool = false
    ) -> BrowserLibraryIntent {
        var intent = BrowserLibraryIntent()
        intent.source = source
        intent.subject = subject
        intent.range = range
        intent.wantsLatest = latest
        intent.copyToClipboard = copy
        return intent
    }

    // MARK: - The subject guard, which is what this change is for

    /// The case the old 40-character guard let through: "what did I visit yesterday on
    /// github" comes back as `visit github`, and the library was searched for `visit`.
    @Test func aSubjectKeepsOnlyTheWordsThatCouldBeASubject() {
        #expect(
            BrowserLibraryIntentParser.cleanedSubject("visit github", heuristic: "") == "github")
        #expect(
            BrowserLibraryIntentParser.cleanedSubject("visited safari pages about swift", heuristic: "")
                == "swift")
        #expect(BrowserLibraryIntentParser.cleanedSubject("the verge", heuristic: "") == "verge")
    }

    @Test func anEmptySubjectIsARealAnswerAndIsKept() {
        // The instructions ask for "" when the question names no subject, so replacing it
        // with the heuristic's guess would override a correct answer.
        #expect(BrowserLibraryIntentParser.cleanedSubject("", heuristic: "github") == "")
        #expect(BrowserLibraryIntentParser.cleanedSubject("   ", heuristic: "github") == "")
        #expect(BrowserLibraryIntentParser.cleanedSubject(nil, heuristic: "github") == "")
    }

    @Test func aSubjectOfNothingButNoiseFallsBackToTheHeuristic() {
        #expect(
            BrowserLibraryIntentParser.cleanedSubject("what did i visit", heuristic: "swift")
                == "swift")
    }

    @Test func aSubjectThatEchoesTheWholeQuestionFallsBackToTheHeuristic() {
        let echoed = String(repeating: "a", count: 41)
        #expect(BrowserLibraryIntentParser.cleanedSubject(echoed, heuristic: "swift") == "swift")
    }

    // MARK: - Every other field is admitted on its own merits

    @Test func anUnreadableFieldTakesTheHeuristicAndLeavesTheRestStanding() {
        let intent = BrowserLibraryIntentParser.reconcile(
            source: "not-a-source", subject: "github", range: "not-a-range", latest: nil,
            heuristic: heuristic(source: .bookmarks, subject: "swift", range: .yesterday, latest: true))
        #expect(intent.source == .bookmarks)
        #expect(intent.range == .yesterday)
        #expect(intent.wantsLatest == true)
        // The good field survives its neighbours being wrong.
        #expect(intent.subject == "github")
    }

    @Test func theModelOverridesTheHeuristicWhenItIsReadable() {
        let intent = BrowserLibraryIntentParser.reconcile(
            source: "tabs", subject: "github", range: "last7", latest: true,
            heuristic: heuristic(source: .history, subject: "swift", range: .today, latest: false))
        #expect(intent.source == .tabs)
        #expect(intent.subject == "github")
        #expect(intent.range == .last7)
        #expect(intent.wantsLatest == true)
    }

    /// The clipboard is a side effect, so it is read from the user's literal wording and
    /// never from the model — true before this change and worth holding.
    @Test func theClipboardIsNeverTheModelsToDecide() {
        let asked = BrowserLibraryIntentParser.reconcile(
            source: "history", subject: "github", range: nil, latest: nil,
            heuristic: heuristic(copy: true))
        #expect(asked.copyToClipboard == true)

        let notAsked = BrowserLibraryIntentParser.reconcile(
            source: "history", subject: "github", range: nil, latest: nil,
            heuristic: heuristic(copy: false))
        #expect(notAsked.copyToClipboard == false)
    }

    /// The question from the audit, end to end through the heuristic the app really uses.
    @Test func theAuditsQuestionResolvesToTheSubjectItNames() {
        let normalized = "what did i visit yesterday on github"
        let seed = BrowserLibraryIntentParser.heuristicIntent(for: normalized)
        let intent = BrowserLibraryIntentParser.reconcile(
            source: "history", subject: "visit github", range: "yesterday", latest: false,
            heuristic: seed)
        #expect(intent.source == .history)
        #expect(intent.range == .yesterday)
        #expect(intent.subject == "github")
    }
}
