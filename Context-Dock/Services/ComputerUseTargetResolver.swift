// ComputerUseTargetResolver.swift
// Context-Dock
//
// Turning "check for updates" into the exact thing to press, or into nothing at all.
//
// The reported failure: asked to update VS Code, the turn found no linked route and no
// `Code ▸ Check for Updates…` in the cached menu map, so it refused. The refusal was right —
// guessing a menu path is how "open it" once closed a window. But the item *exists*: Electron
// builds its menus lazily, and the cache was written before the app filled them in. So the rung
// below a verified menu is not "click anything"; it is "look at the live menu bar, and press
// only what the words actually name".
//
// Refusing stays the default. This resolver returns nil far more readily than it returns a
// target, because the cost of the two outcomes is not symmetric: a refusal wastes a turn, and a
// wrong press happens on someone's screen, in their app, with their data.

import Foundation

/// One thing that could be pressed, with the state the app reported for it.
struct ComputerUseTarget: Equatable, Sendable {
    /// Menu path, outermost first: `["Code", "Check for Updates…"]`.
    let path: [String]
    /// Greyed-out items are excluded before matching — see `best(matching:among:)`.
    let isEnabled: Bool

    var title: String { path.last ?? "" }
    var display: String { path.joined(separator: " ▸ ") }
}

enum ComputerUseTargetResolver {

    /// Never pressed by Computer Use, whatever the phrase says.
    ///
    /// Reuses `AppMenuConsentStore.isDestructive` rather than restating it: that list already
    /// distinguishes local destruction ("delete", "empty") from putting something in front of
    /// another person ("send", "reply", "forward"), and it already matches outbound words as
    /// whole words so "Shared Links" is not mistaken for sharing. A second copy here would be a
    /// second thing to keep in step, and the copy that drifts is always the one guarding the
    /// newer, less-watched path.
    ///
    /// Verified menus *gate* these behind approval. Computer Use refuses them outright: an
    /// approval card for a click the app never offered, resolved from a phrase, on a tier whose
    /// whole purpose is acting where no route exists, is more trust than this rung has earned.
    @MainActor
    static func isForbidden(path: [String]) -> Bool {
        AppMenuConsentStore.shared.isDestructive(path: path)
    }

    /// The one item a phrase names, or nil.
    ///
    /// Nil whenever the answer is not obvious: nothing enabled matches, several match equally,
    /// or the best match is only loosely related. "Update this app" against a menu holding
    /// "Hide Visual Studio Code" and "Quit" has no answer, and inventing one is the failure
    /// this whole rung exists beneath.
    @MainActor
    /// Why a phrase did not become a press.
    ///
    /// `best` used to return an optional, and nil meant four different things: the phrase was
    /// empty, nothing in the live UI matched it, everything that matched was greyed out or on
    /// the denylist, or two items described it equally well. Its own comment said "the caller
    /// asks the user instead" — which the caller could not do, because nil does not say which.
    ///
    /// An ambiguity is a question. A greyed-out item is a fact about the app's state worth
    /// telling the user. Neither is "not found", and reporting them as such is how an
    /// assistant looks like it has understood nothing.
    enum Resolution: Equatable {
        case resolved(ComputerUseTarget)
        /// Several items the phrase describes equally well. Picking one is guessing with
        /// extra steps.
        case ambiguous([ComputerUseTarget])
        /// The best match exists but the app will not accept it in this state.
        case disabled(ComputerUseTarget)
        /// The best match is on the destructive/outbound denylist. Never pressed from here,
        /// whatever the user asked — it goes through the consent path or not at all.
        case forbidden(ComputerUseTarget)
        /// The phrase named nothing in the live UI.
        case noMatch
    }

    /// The typed resolution. `best` is kept as the thin wrapper below.
    static func resolve(phrase: String, among candidates: [ComputerUseTarget]) -> Resolution {
        let wanted = tokens(phrase)
        guard !wanted.isEmpty else { return .noMatch }

        // Everything is scored, including items that cannot be pressed, so the answer can say
        // *why* rather than reporting a greyed-out match as an absent one.
        var scored: [(score: Double, target: ComputerUseTarget)] = []
        for candidate in candidates {
            let itemTokens = tokens(candidate.title)
            guard !itemTokens.isEmpty else { continue }
            let shared = wanted.intersection(itemTokens)
            guard !shared.isEmpty else { continue }

            // Both directions matter. Coverage of the item's own words stops "update" matching
            // "Check for Updates and Restart Now" as readily as "Check for Updates"; coverage
            // of the phrase stops a one-word overlap from carrying a long request.
            let itemCoverage = Double(shared.count) / Double(itemTokens.count)
            let phraseCoverage = Double(shared.count) / Double(wanted.count)
            guard itemCoverage >= 0.6 || phraseCoverage >= 0.6 else { continue }
            scored.append((itemCoverage + phraseCoverage, candidate))
        }

        let ranked = scored.sorted { $0.score > $1.score }
        guard let first = ranked.first else { return .noMatch }

        // Denylist first: a forbidden item is forbidden whether or not anything ties with it.
        if isForbidden(path: first.target.path) { return .forbidden(first.target) }

        let tied = ranked.filter { abs($0.score - first.score) < 0.01 }
        if tied.count > 1 { return .ambiguous(tied.map(\.target)) }

        // Greyed out means the app will not accept it in this state. Pressing anyway is a
        // click that does nothing followed by a report that it worked.
        guard first.target.isEnabled else { return .disabled(first.target) }
        return .resolved(first.target)
    }

    /// The one enabled, permitted, unambiguous match — or nil. Unchanged behaviour for
    /// callers that only need a target; `resolve` is what a caller uses when it can act on
    /// the difference between "not there" and "greyed out".
    static func best(matching phrase: String, among candidates: [ComputerUseTarget])
        -> ComputerUseTarget?
    {
        if case .resolved(let target) = resolve(phrase: phrase, among: candidates) {
            return target
        }
        return nil
    }

    /// Words that carry intent. Menu punctuation is the app's, not the user's: a model writes
    /// "Check for Updates" and the menu says "Check for Updates…", and three dots must never
    /// cost a match.
    private static func tokens(_ text: String) -> Set<String> {
        let stripped = text.replacingOccurrences(of: "…", with: " ")
        let words = stripped.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
        // "this app" is how a person refers to the scope, not to a menu item, and left in it
        // matches every item containing the app's own name.
        let noise: Set<String> = ["the", "this", "that", "app", "please", "now", "for", "and"]
        return Set(words.filter { !noise.contains($0) }.map(singular))
    }

    /// "updates" and "update" are the same word here.
    ///
    /// Menus are written in the app's voice and requests in the user's: the menu says "Check
    /// for Updates…" and the person says "update this app". Compared exactly, those two share
    /// no word at all — which is why the rung built for precisely this case still found
    /// nothing, and the answer went back to "click it yourself".
    private static func singular(_ word: String) -> String {
        // "ss" is not a plural: "address", "class", "pass".
        guard !word.hasSuffix("ss") else { return word }
        if word.count > 4, word.hasSuffix("es") {
            // Only a stem that hisses takes "es" — boxes, dishes, searches. Everything else
            // is an ordinary "s" on a word that happens to end in "e", and dropping both
            // letters turns "updates" into "updat", which matches nothing. That is exactly
            // how this rung stayed silent on the case it was written for.
            let stem = String(word.dropLast(2))
            for ending in ["s", "x", "z", "ch", "sh"] where stem.hasSuffix(ending) {
                return stem
            }
            return String(word.dropLast())
        }
        if word.count > 3, word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }
}
