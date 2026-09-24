import Testing
import Foundation
@testable import Context_Dock

// MARK: - Reuse the action, adjust it, or write a new one
//
// B2 of docs/superpowers/plans/2026-09-18-actions-that-adjust.md.
//
// A saved action and a new request. Three answers, and picking the wrong one is the whole
// bug the owner reported: "minimise after 10 min" authored a second action instead of
// reusing the first. The rule is about what the sentence changes, not what it says:
//
//   the same request, or only a number the action declares  → run it
//   the same action, doing something more or different      → revise it, same id
//   a different job                                         → author
//
// Pure, so the sentences can be checked without a provider.

struct ActionReuseTests {

    private func minimise(value: Bool = true) -> AdapterAction {
        AdapterAction(
            id: "ai.minimise-after-a-delay", name: "Minimise after a delay",
            icon: "sparkles", description: "Minimises the front window after a pause",
            triggers: ["minimise", "after", "delay"], type: .shell,
            script: value ? "sleep {{value}}; osascript -e 'minimise'" : "sleep 300; osascript -e 'minimise'",
            requiresApproval: true,
            valueLabel: value ? "seconds" : nil, valueDefault: value ? "300" : nil)
    }

    // MARK: - Run it

    /// The owner's sentence. A number the action declares is not a change to the action.
    @Test func aNewNumberRunsTheSameAction() {
        #expect(ActionReuse.decide(existing: minimise(), request: "minimise after 10 min")
            == .run(value: "600"))
        #expect(ActionReuse.decide(existing: minimise(), request: "minimise after five minutes")
            == .run(value: "300"))
    }

    /// The request that authored it, asked again. Nothing to decide — run it as saved.
    @Test func theSameRequestRunsItAsSaved() {
        #expect(ActionReuse.decide(existing: minimise(), request: "minimise after 5 min")
            == .run(value: "300"))
    }

    /// No number, and the action has a default: run at the default rather than refuse.
    @Test func noNumberRunsTheDefault() {
        #expect(ActionReuse.decide(existing: minimise(), request: "minimise")
            == .run(value: "300"))
    }

    /// An action with no value slot cannot take a number; the sentence matches it anyway.
    @Test func anActionWithoutAValueStillRuns() {
        #expect(ActionReuse.decide(existing: minimise(value: false), request: "minimise now")
            == .run(value: nil))
    }

    // MARK: - Revise it

    /// "and then mute" is not a number. The action is the right one; it has to do more.
    @Test func doingMoreRevisesTheSameAction() {
        #expect(ActionReuse.decide(existing: minimise(), request: "minimise after 10 min and then mute")
            == .revise)
    }

    /// A number an action cannot express is a revision, not a run: an action with no value
    /// slot given a new number would silently keep the old one — the bug this closes.
    @Test func aNumberAnActionCannotTakeIsARevision() {
        #expect(ActionReuse.decide(existing: minimise(value: false), request: "minimise after 10 min")
            == .revise)
    }

    // MARK: - Author

    /// A different job. Reusing by a shared word ("after") would run something the user did
    /// not ask for, which is worse than writing a new action.
    @Test func adifferentJobIsAuthored() {
        #expect(ActionReuse.decide(existing: minimise(), request: "export this page as a pdf")
            == .author)
        #expect(ActionReuse.decide(existing: minimise(), request: "email the selection to sam")
            == .author)
    }

    /// Nothing saved, nothing to reuse.
    @Test func noExistingActionIsAuthored() {
        #expect(ActionReuse.decide(existing: nil, request: "minimise after 10 min") == .author)
    }

    // MARK: - Which saved action the request is about (C1)

    private func action(_ name: String, triggers: [String]) -> AdapterAction {
        AdapterAction(
            id: "ai." + name.lowercased().replacingOccurrences(of: " ", with: "-"),
            name: name, icon: "sparkles", description: "", triggers: triggers,
            type: .shell, script: "true", requiresApproval: true)
    }

    /// The action that shares the most with the request wins. "minimise after 10 min" is
    /// about the minimise action, not the export one, though both are saved.
    @Test func theClosestSavedActionIsTheOneConsidered() {
        let saved = [
            action("Export as PDF", triggers: ["export", "pdf"]),
            minimise(),
            action("Empty the cache", triggers: ["cache", "empty"]),
        ]
        #expect(ActionReuse.best(among: saved, request: "minimise after 10 min")?.id
            == minimise().id)
    }

    /// Nothing shares a substantive word: nothing is considered, so the caller authors
    /// rather than bending an unrelated action to fit.
    @Test func nothingCloseMeansNothingIsConsidered() {
        let saved = [action("Export as PDF", triggers: ["export", "pdf"])]
        #expect(ActionReuse.best(among: saved, request: "email the selection to sam") == nil)
    }

    /// An empty adapter has nothing to offer.
    @Test func noSavedActionsMeansNothingIsConsidered() {
        #expect(ActionReuse.best(among: [], request: "minimise after 10 min") == nil)
    }

    /// The pick and the decision compose: this is the whole reuse path, end to end, with
    /// no model in it.
    @Test func theOwnersSentenceReusesTheOwnersAction() {
        let saved = [action("Export as PDF", triggers: ["export", "pdf"]), minimise()]
        let best = ActionReuse.best(among: saved, request: "minimise after 10 min")
        #expect(ActionReuse.decide(existing: best, request: "minimise after 10 min")
            == .run(value: "600"))
    }
}
