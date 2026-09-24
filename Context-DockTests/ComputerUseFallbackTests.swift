import Foundation
import Testing

@testable import Context_Dock

// When DoraX offers to press something itself.
//
// The offer used to depend on the model asking for it, and three turns in a row proved that
// does not happen: each one named `operate_app` as the thing it lacked while the item sat in
// the live menu bar. Noticing that a turn has run out of routes is the deterministic layer's
// job, so these are the conditions under which it decides.

struct ComputerUseFallbackTests {

    @Test func aFailedActionTurnIsOffered() {
        // The reported case exactly: "update this app" in Code, nothing linked ran.
        #expect(
            ComputerUseFallback.shouldOffer(
                intent: .act, ranAnything: false, bundleID: "com.microsoft.VSCode"))
    }

    @Test func aQuestionIsNeverOfferedAClick() {
        // Asking what version is installed is not a request to press anything, and a card
        // that appears for questions is a card people learn to dismiss.
        for intent in [FrontmostAppTaskPlan.Intent.answer, .read] {
            #expect(
                !ComputerUseFallback.shouldOffer(
                    intent: intent, ranAnything: false, bundleID: "com.microsoft.VSCode"))
        }
    }

    @Test func aTurnThatRanSomethingIsNotOffered() {
        // The owner's rule: Computer Use is offered only when the CLI, the adapter actions,
        // MCP and the workers could not do it. Something having run means one of them could.
        #expect(
            !ComputerUseFallback.shouldOffer(
                intent: .act, ranAnything: true, bundleID: "com.microsoft.VSCode"))
    }

    @Test func aWorkflowTurnCountsAsAnAction() {
        #expect(
            ComputerUseFallback.shouldOffer(
                intent: .workflow, ranAnything: false, bundleID: "com.microsoft.VSCode"))
    }

    @Test func aScopeWithNoAppHasNothingToOperate() {
        // A CLI thread and a bare scope have no menu bar. Offering there would read the
        // frontmost app's menus, which is a different app from the one the chat is about.
        for bundleID in ["", "cli://tailscale", "scope://clipboard"] {
            #expect(
                !ComputerUseFallback.shouldOffer(
                    intent: .act, ranAnything: false, bundleID: bundleID))
        }
    }

    @MainActor
    @Test func theRequestsOwnWordsReachTheMenuItem() {
        // The match this whole rung exists for, and the reason it failed anyway: the menu is
        // written in the app's voice ("Check for Updates…") and the request in the user's
        // ("update this app"). Compared word for word those share nothing.
        let chosen = ComputerUseTargetResolver.best(
            matching: "update this app",
            among: [
                ComputerUseTarget(path: ["Code", "Check for Updates…"], isEnabled: true),
                ComputerUseTarget(path: ["Code", "Hide Visual Studio Code"], isEnabled: true),
                ComputerUseTarget(path: ["Code", "Quit Visual Studio Code"], isEnabled: true),
            ])
        #expect(chosen?.path.last == "Check for Updates…")
    }

    @MainActor
    @Test func pluralityIsNotTheOnlyThingHoldingAMatchTogether() {
        // Singularising must not turn unrelated words into each other. "Copy Line Up" is the
        // action a wrong match actually pressed on the owner's machine.
        let chosen = ComputerUseTargetResolver.best(
            matching: "update this app",
            among: [
                ComputerUseTarget(path: ["Selection", "Copy Line Up"], isEnabled: true),
                ComputerUseTarget(path: ["Edit", "Paste"], isEnabled: true),
            ])
        #expect(chosen == nil)
    }
}
