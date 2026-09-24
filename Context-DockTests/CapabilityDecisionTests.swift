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
        _ id: String, _ score: Double, write: Bool, coverage: Double = 1.0,
        surface: CapabilityRecord.Surface = .headless
    ) -> CapabilityIndex.Hit {
        .init(
            record: CapabilityRecord(
                id: id, app: "App", kind: .capability, title: id, isWrite: write,
                surface: surface),
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

    // MARK: - Cost, before score
    //
    // The index ranks what DoraX can do. These cover what doing it costs, which is the axis
    // it was missing — and the report it came from: "new chat" in the Claude scope, where a
    // linked CLI and a menu item could both have done it and neither was offered.

    /// The report. Two paths in the band, different surfaces, so the user chooses.
    @Test func ablePathsThatDifferInCostAreAChoiceForTheUser() {
        let cli = hit("claude.cli.newChat", 11.0, write: true, surface: .headless)
        let menu = hit("claude.menu.newChat", 10.2, write: true, surface: .opensApp)

        #expect(CapabilityDecision.make(from: [cli, menu]) == .ask([cli, menu]))
    }

    /// And the cheapest is named first, so the default reading is the cheap one.
    @Test func theCheapestIsOfferedFirst() throws {
        let menu = hit("claude.menu.newChat", 11.0, write: true, surface: .opensApp)
        let cli = hit("claude.cli.newChat", 10.2, write: true, surface: .headless)

        guard case .ask(let offered) = CapabilityDecision.make(from: [menu, cli]) else {
            Issue.record("expected a choice"); return
        }
        #expect(offered.map(\.record.id) == ["claude.cli.newChat", "claude.menu.newChat"])
    }

    /// Finder, "empty the trash": `finder.emptyTrash` names the request outright and the
    /// menu item is far behind it. Three able paths, one obvious winner, and it must not
    /// become a question — this is the test that stops the rule turning into a prompt on
    /// every request.
    @Test func aClearWinnerStillRunsEvenWhenCheaperNeighboursExist() {
        let action = hit("finder.emptyTrash", 14.0, write: true, surface: .headless)
        let menu = hit("finder.menu.emptyTrash", 6.0, write: true, surface: .opensApp)
        let screen = hit("finder.computerUse", 4.0, write: true, surface: .takesScreen)

        #expect(CapabilityDecision.make(from: [action, menu, screen]) == .act(action))
    }

    /// Two headless paths are not a cost question. VS Code's `code --list-extensions` and
    /// its registered capability do the same thing at the same cost, so the cost rule stays
    /// out of it and the existing ranking picks — even though both are well inside the band
    /// that would have triggered a choice had their surfaces differed.
    ///
    /// Written expecting `.ask` at first, which was wrong: 0.4 apart is outside the read
    /// tie-margin, so acting is right and the assertion was the thing at fault.
    @Test func sameSurfaceNeighboursAreRankedNotAsked() {
        let capability = hit("vscode.extensions.list", 11.0, write: false, surface: .headless)
        let cli = hit("vscode.cli.listExtensions", 10.6, write: false, surface: .headless)

        #expect(CapabilityDecision.make(from: [capability, cli]) == .act(capability))
    }

    /// The same two, moved close enough to tie. Now it asks — but as peers of equal cost,
    /// which is the pre-existing tie rule and not the cost rule. Both questions exist; they
    /// are asked for different reasons.
    @Test func sameSurfacePeersThatGenuinelyTieStillAsk() {
        let capability = hit("vscode.extensions.list", 11.0, write: false, surface: .headless)
        // 0.02 apart. Picked 10.95 first, which is exactly tieMargin away and came out at
        // 0.05000000000000071 in floating point — just outside, so it acted.
        let cli = hit("vscode.cli.listExtensions", 10.98, write: false, surface: .headless)

        #expect(CapabilityDecision.make(from: [capability, cli]) == .ask([capability, cli]))
    }

    /// The rule that matters most: the screen is never taken while something cheaper is in
    /// contention. Even with Computer Use scoring highest, it is not acted on alone.
    @Test func theScreenIsNeverTakenSilentlyWhileSomethingCheaperIsInContention() throws {
        let screen = hit("appstore.computerUse", 11.0, write: true, surface: .takesScreen)
        let cli = hit("appstore.cli.update", 9.5, write: true, surface: .headless)

        guard case .ask(let offered) = CapabilityDecision.make(from: [screen, cli]) else {
            Issue.record("expected a choice, not a silent screen-take"); return
        }
        #expect(offered.first?.record.surface == .headless)
    }

    /// When the only able path takes the screen, that is not a tie and not a failure — it
    /// is the answer. App Store "update all": nothing headless can do it, the button is
    /// right there.
    @Test func theScreenIsTheAnswerWhenNothingCheaperCanDoIt() {
        let screen = hit("appstore.updateAll", 12.0, write: true, surface: .takesScreen)

        #expect(CapabilityDecision.make(from: [screen]) == .act(screen))
    }

    @Test func theSummaryNamesTheCostBecauseThatIsWhatTheChoiceIsAbout() {
        let cli = hit("claude.cli.newChat", 11.0, write: true, surface: .headless)
        let menu = hit("claude.menu.newChat", 10.2, write: true, surface: .opensApp)

        let summary = CapabilityDecision.make(from: [cli, menu]).summary
        #expect(summary.contains("no window opens"))
        #expect(summary.contains("opens the app"))
    }
}
