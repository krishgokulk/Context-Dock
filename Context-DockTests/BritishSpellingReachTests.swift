import Testing
import Foundation
@testable import Context_Dock

// MARK: - The user's spelling is not a different request
//
// The owner saved an action the model named "Minimize Code After Delay" and then asked for
// it the way they write: "minimise code app after 2min". The scorer normalises to lowercase
// alphanumerics and nothing else, so `minimise` and `minimize` are two unrelated tokens.
//
// The arithmetic that produced the screenshot: name overlap {code, after} = 2 tokens →
// 36 + 2×22 = 80, under the 88 strong-match bar, so the action was offered at 0.62
// confidence and lost to a cached menu item at 0.82 — the chat proposed "Hide Others" for a
// request to minimise after two minutes. With the spelling folded, the overlap is
// {minimize, code, after} = 3 → 102, and the app's own action wins as it should.
//
// Both sides of every comparison are normalised the same way, which is what makes folding
// -ise/-ize safe: "promise" becomes "promize" in the query and in the action, so it still
// matches itself. The only thing lost is a distinction between two spellings of one word.

struct BritishSpellingReachTests {

    private let bundle = "com.example.spelling-reach"

    @MainActor
    private func adapterWithMinimiseAction() async {
        let manager = AppAdapterManager.shared
        if manager.adapter(for: bundle) == nil {
            await manager.createAdapter(appName: "Code", bundleId: bundle, icon: "app")
        }
        await manager.appendAction(
            AdapterAction(
                id: "ai.minimize-code-after-delay", name: "Minimize Code After Delay",
                icon: "sparkles",
                description: "Waits a set number of seconds, then minimizes the front window",
                triggers: ["minimize", "delay", "code"], type: .shell,
                script: "sleep {{value}}; osascript -e 'minimise'",
                requiresApproval: true, valueLabel: "seconds", valueDefault: "60"),
            to: bundle)
    }

    /// The reported sentence, scored against the action the owner saved.
    @MainActor @Test func theBritishSpellingReachesTheAmericanAction() async {
        await adapterWithMinimiseAction()
        let scored = AppAdapterManager.shared.scoredActions(
            for: bundle, query: "minimise code app after 2min")
        let top = scored.first
        #expect(top?.action.id == "ai.minimize-code-after-delay")
        // Strong, so the resolver offers it at full confidence instead of below a cached
        // menu item that merely shares a word.
        #expect((top?.score ?? 0) >= AppAdapterManager.adapterActionStrongMatchScore)
    }

    /// The American spelling was never broken and stays exactly as strong.
    @MainActor @Test func theAmericanSpellingStillReachesIt() async {
        await adapterWithMinimiseAction()
        let scored = AppAdapterManager.shared.scoredActions(
            for: bundle, query: "minimize code app after 2min")
        #expect((scored.first?.score ?? 0) >= AppAdapterManager.adapterActionStrongMatchScore)
    }

    /// Folding spellings must not make unrelated actions match.
    @MainActor @Test func anUnrelatedRequestStillMatchesNothing() async {
        await adapterWithMinimiseAction()
        let scored = AppAdapterManager.shared.scoredActions(
            for: bundle, query: "export the current file as pdf")
        #expect(scored.first?.action.id != "ai.minimize-code-after-delay")
    }

    // MARK: - The reuse decision reads the same spelling

    /// ActionReuse does its own tokenising, so it needs the same fold or it would author a
    /// second action for the British spelling of a request it already has an action for.
    @Test func reuseAgreesAcrossSpellings() {
        let action = AdapterAction(
            id: "ai.minimize-code-after-delay", name: "Minimize Code After Delay",
            icon: "sparkles", description: "", triggers: ["minimize", "delay"],
            type: .shell, script: "sleep {{value}}", requiresApproval: true,
            valueLabel: "seconds", valueDefault: "60")
        #expect(ActionReuse.best(among: [action], request: "minimise code app after 2min")?.id
            == action.id)
        #expect(ActionReuse.decide(existing: action, request: "minimise code app after 2min")
            == .run(value: "120"))
    }
}
