import Foundation
import Testing

@testable import Context_Dock

// What Computer Use is allowed to press, and how a phrase becomes a target.
//
// The clicking itself needs a real app and a real screen, so it is verified by hand. What can
// be tested is everything that decides *whether* and *what* — and that is where the damage
// lives: a denylisted item pressed because the phrase matched loosely, or a target resolved to
// the nearest thing rather than refused.

@MainActor
struct ComputerUseTargetTests {

    private func item(_ path: [String], enabled: Bool = true) -> ComputerUseTarget {
        ComputerUseTarget(path: path, isEnabled: enabled)
    }

    @Test func theMissingMenuItemIsFoundByItsWords() {
        // The reported case: "update this app" in a Code scope. The item exists in the live
        // menu bar and was absent from the cache, so the phrase has to reach it by matching,
        // not by an exact path the model would have had to already know.
        let candidates = [
            item(["Code", "Hide Visual Studio Code"]),
            item(["Code", "Check for Updates…"]),
            item(["Code", "Quit Visual Studio Code"]),
        ]
        let chosen = ComputerUseTargetResolver.best(
            matching: "Check for Updates", among: candidates)
        #expect(chosen?.path.last == "Check for Updates…")
    }

    @Test func anEllipsisNeverCostsAMatch() {
        // A model writes "Check for Updates"; the menu says "Check for Updates…". The three
        // dots are the app's punctuation, not part of what the user asked for.
        let chosen = ComputerUseTargetResolver.best(
            matching: "check for updates...", among: [item(["Code", "Check for Updates…"])])
        #expect(chosen != nil)
    }

    @Test func aDisabledItemIsNotPressed() {
        // Greyed out means the app will not accept it in this state. Pressing anyway produces
        // a click that does nothing and a report that says it worked.
        let chosen = ComputerUseTargetResolver.best(
            matching: "Check for Updates",
            among: [item(["Code", "Check for Updates…"], enabled: false)])
        #expect(chosen == nil)
    }

    @Test func aWeakOverlapIsRefusedRatherThanApproximated() {
        // "update this app" must not press "Hide Visual Studio Code" because both are in the
        // same menu. Refusing is the behaviour the owner called perfect; this keeps it while
        // the rung below gets built.
        let chosen = ComputerUseTargetResolver.best(
            matching: "update this app",
            among: [item(["Code", "Hide Visual Studio Code"]), item(["Code", "Quit"])])
        #expect(chosen == nil)
    }

    @Test func destructiveItemsAreNeverPressedByComputerUse() {
        // The same denylist verified menus use (decision `647c9c56`), applied to the tier that
        // has no app's blessing at all. Send is the canonical one: a half-written mail sent by
        // a click nobody asked for cannot be recalled.
        for title in ["Send", "Send Message", "Delete", "Move to Trash", "Empty Trash"] {
            #expect(
                ComputerUseTargetResolver.isForbidden(path: ["Anything", title]),
                "\(title) must never be pressed by Computer Use")
        }
    }

    @Test func ordinaryItemsAreNotForbidden() {
        for title in ["Check for Updates…", "New Window", "Show Sidebar", "Zoom"] {
            #expect(!ComputerUseTargetResolver.isForbidden(path: ["App", title]))
        }
    }

    @Test func aForbiddenItemIsRefusedEvenWhenTheWordsMatchExactly() {
        // The denylist outranks the match. Otherwise the clearest possible instruction is the
        // one that gets through.
        let chosen = ComputerUseTargetResolver.best(
            matching: "Send", among: [item(["Message", "Send"])])
        #expect(chosen == nil)
    }
}
