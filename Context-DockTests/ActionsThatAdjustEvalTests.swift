import Foundation
import Testing

@testable import Context_Dock

// Evals for the owner's own sentences, in order (C2 of
// docs/superpowers/plans/2026-09-18-actions-that-adjust.md).
//
// The report: "next time if user ask to minimise after 5min, our ai can auto adjust this
// extension by choosing best top suted method using own extension without creating another
// one." What happened instead was a second action per number, because the runtime
// substituted only {{query}} — the whole sentence — and the number was baked into the script.
//
// This walks the five sentences through the pieces A and B built, with no model and no
// adapter store: what gets authored, what gets reused, what gets revised. If the sequence
// below ever changes, the thing the owner asked for has changed with it.

struct ActionsThatAdjustEvalTests {

    /// What the model is asked to write for "minimise after 5 min", as A4 teaches it.
    private var authoredReply: String {
        """
        {"name":"Minimise after a delay","summary":"Minimises the front window after a pause",
         "kind":"shell","script":"sleep {{value}}; osascript -e 'tell application \\"System Events\\" to keystroke \\"m\\" using command down'",
         "triggers":["minimise","delay"],"value":{"label":"seconds","default":"300"}}
        """
    }

    @MainActor
    private func savedAction() throws -> AdapterAction {
        let proposal = try #require(WorkflowAuthor.proposal(
            fromReply: authoredReply, request: "minimise after 5 min",
            bundleID: "com.apple.finder", appName: "Finder"))
        return WorkflowAuthor.action(for: proposal)
    }

    // MARK: - 1. The first time: nothing can do it, so one action is written

    @MainActor @Test func theFirstRequestAuthorsOneAdjustableAction() throws {
        // Nothing saved yet, so authoring is right — and exactly once.
        #expect(ActionReuse.decide(existing: nil, request: "minimise after 5 min") == .author)

        let action = try savedAction()
        #expect(action.script == "sleep {{value}}; osascript -e 'tell application \"System Events\" to keystroke \"m\" using command down'")
        #expect(action.takesValue)
        // The number the user said, in the unit the script needs — not baked into the script.
        #expect(action.valueDefault == "300")
    }

    // MARK: - 2. "minimise after 10 min" — the report

    @MainActor @Test func aDifferentNumberReusesTheSameAction() throws {
        let saved = try savedAction()
        let request = "minimise after 10 min"

        #expect(ActionReuse.best(among: [saved], request: request)?.id == saved.id)
        #expect(ActionReuse.decide(existing: saved, request: request) == .run(value: "600"))
        // What actually runs: ten minutes, from an action saved for five, with no model
        // in the loop and no second action.
        #expect(ActionValue.fill(saved.script ?? "", with: saved.value(for: request))
            .hasPrefix("sleep 600;"))
    }

    // MARK: - 3. "minimise after five minutes" — said the way people say it

    @MainActor @Test func wordsForNumbersReuseItToo() throws {
        let saved = try savedAction()
        #expect(ActionReuse.decide(existing: saved, request: "minimise after five minutes")
            == .run(value: "300"))
    }

    // MARK: - 4. "minimise after 10 min and then mute" — more than a number

    @MainActor @Test func doingMoreRevisesTheActionUnderTheSameID() throws {
        let saved = try savedAction()
        let request = "minimise after 10 min and then mute"
        #expect(ActionReuse.decide(existing: saved, request: request) == .revise)

        let reply = """
            {"summary":"Minimises the front window after a pause, then mutes","kind":"shell",
             "script":"sleep {{value}}; osascript -e 'minimise'; osascript -e 'set volume 0'",
             "triggers":["minimise","mute"],"value":{"label":"seconds","default":"300"}}
            """
        let revision = try #require(WorkflowAuthor.revision(
            fromReply: reply, existing: saved, request: request,
            bundleID: "com.apple.finder", appName: "Finder"))
        let card = AdapterActionProposalInstaller.proposalData(for: revision, replacing: saved)

        // The same action, changed — not a second one beside it.
        #expect(card.replacesActionId == saved.id)
        #expect(AdapterActionProposalInstaller.action(from: card).id == saved.id)
        // And it is still adjustable afterwards.
        #expect(AdapterActionProposalInstaller.action(from: card).value(for: request) == "600")
    }

    // MARK: - 5. "minimise now" — no number at all

    /// The owner's call, recorded: no number runs the action's own default rather than
    /// asking. The action was saved with one, and asking for a number the user already gave
    /// once is the friction this whole plan exists to remove.
    @MainActor @Test func noNumberRunsWhatItWasSavedWith() throws {
        let saved = try savedAction()
        #expect(ActionReuse.decide(existing: saved, request: "minimise now") == .run(value: "300"))
    }

    // MARK: - The other direction

    /// Reuse must not become "run whatever is closest". A different job authors, even with
    /// an action saved and a word in common.
    @MainActor @Test func adifferentRequestStillAuthors() throws {
        let saved = try savedAction()
        #expect(ActionReuse.decide(existing: ActionReuse.best(
            among: [saved], request: "export this page as a pdf"),
            request: "export this page as a pdf") == .author)
    }
}
