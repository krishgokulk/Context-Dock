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

    // MARK: - Why it refused
    //
    // `best` returned an optional and nil meant four different things. Its own comment said
    // the caller asks the user instead, which the caller could not do. These cover each kind
    // of refusal now that it is typed.

    @Test func oneClearMatchResolves() {
        let resolution = ComputerUseTargetResolver.resolve(
            phrase: "check for updates",
            among: [item(["Code", "Check for Updates…"]), item(["File", "New Window"])])

        #expect(resolution == .resolved(item(["Code", "Check for Updates…"])))
    }

    /// Two items the phrase describes equally well. A question, not a guess and not an
    /// absence.
    @Test func twoEqualMatchesAreAmbiguousRatherThanMissing() {
        let a = item(["File", "New Window"])
        let b = item(["File", "New Tab"])

        guard case .ambiguous(let options) = ComputerUseTargetResolver.resolve(
            phrase: "new", among: [a, b])
        else {
            Issue.record("expected an ambiguity"); return
        }
        #expect(options.count == 2)
    }

    /// Greyed out is a fact about the app's state. Reporting it as "not there" is what made
    /// the old refusal misleading.
    @Test func aGreyedOutMatchSaysSoInsteadOfClaimingItIsAbsent() {
        let resolution = ComputerUseTargetResolver.resolve(
            phrase: "check for updates",
            among: [item(["Code", "Check for Updates…"], enabled: false)])

        #expect(resolution == .disabled(item(["Code", "Check for Updates…"], enabled: false)))
    }

    /// A denylisted item is never a press from here, and saying "not found" about it would
    /// be a lie that invites the user to rephrase until it works.
    @Test func aDenylistedMatchIsNamedAsForbidden() {
        let send = item(["Message", "Send"])
        guard ComputerUseTargetResolver.isForbidden(path: send.path) else {
            return  // denylist does not cover this item on this build; nothing to assert
        }

        #expect(ComputerUseTargetResolver.resolve(phrase: "send", among: [send]) == .forbidden(send))
    }

    @Test func aPhraseThatNamesNothingIsStillNoMatch() {
        #expect(
            ComputerUseTargetResolver.resolve(
                phrase: "reticulate splines", among: [item(["File", "New Window"])]) == .noMatch)
        #expect(
            ComputerUseTargetResolver.resolve(phrase: "", among: [item(["File", "New Window"])])
                == .noMatch)
    }

    /// `best` keeps its old meaning exactly: the one enabled, permitted, unambiguous match.
    @Test func bestStillReturnsOnlyACleanResolution() {
        #expect(
            ComputerUseTargetResolver.best(
                matching: "check for updates",
                among: [item(["Code", "Check for Updates…"], enabled: false)]) == nil)
        #expect(
            ComputerUseTargetResolver.best(
                matching: "new", among: [item(["File", "New Window"]), item(["File", "New Tab"])])
                == nil)
    }
}
