// ActionReuse.swift
// Context-Dock
//
// Run the saved action, adjust it, or write a new one.
//
// B2 of docs/superpowers/plans/2026-09-18-actions-that-adjust.md. A1–A5 taught actions to
// carry a value; this is what decides, before any model is asked, whether the value is all
// that changed. The owner's report was a product that authored a second action for
// "minimise after 10 min" when it already had one for five — a decision this makes
// deterministically, from the sentence and the action, with nothing in between.
//
// The rule is about what the sentence *changes*, not what it says:
//
//   the same request, or only a number the action declares  → .run
//   the same action, doing something more or different      → .revise (same id, B1/B3)
//   a different job                                         → .author (the last resort)
//
// Pure and provider-free: the three sentences that motivated it are tests, not a live turn.

import Foundation

enum ActionReuse {

    enum Decision: Equatable {
        /// Run the saved action as it is. `value` fills its `{{value}}` slot — the number in
        /// the sentence, in the action's unit, or its default. Nil for an action that
        /// declares no value.
        case run(value: String?)
        /// The right action, asked to do something it does not do yet. Revised under the
        /// same id so it replaces rather than multiplies.
        case revise
        /// Nothing saved fits. Write one.
        case author
    }

    /// Words that carry no request of their own. A sentence whose only leftovers are these
    /// is asking for the action as it stands.
    private static let filler: Set<String> = [
        "a", "an", "the", "it", "this", "that", "me", "my", "please", "now", "again",
        "and", "then", "also", "to", "in", "at", "for", "of", "on", "with", "after",
        "before", "by", "just", "can", "you", "could", "would", "do", "make", "let",
        "us", "app", "window", "screen", "one", "more", "time", "times",
    ]

    /// What to do with `request`, given the best action already saved for it.
    ///
    /// `existing` is the action the ordinary matcher found — this does not search; it
    /// judges. Nil means nothing matched, which is the only honest reason to author.
    static func decide(existing: AdapterAction?, request: String) -> Decision {
        guard let existing else { return .author }
        let words = tokens(request)
        guard !words.isEmpty else { return .run(value: existing.value(for: request)) }

        // Does the sentence ask for *this* action? Matching on a shared filler word would
        // run something the user did not ask for, which is worse than authoring.
        let known = vocabulary(of: existing)
        guard !words.isDisjoint(with: known) else { return .author }

        // What the sentence says besides this action's own words and its value.
        let leftover = words
            .subtracting(known)
            .subtracting(filler)
            .filter { !ActionValue.isValueToken($0) }
        guard leftover.isEmpty else { return .revise }

        // Only the number changed — but an action with no `{{value}}` slot cannot take a
        // new one. Running it would silently use the old number: the bug this closes.
        if ActionValue.namesAQuantity(in: request), !existing.takesValue { return .revise }

        return .run(value: existing.value(for: request))
    }

    /// The saved action a request is about, or nil when none of them is.
    ///
    /// Deliberately not a search: it ranks what an adapter already holds by how much of its
    /// own vocabulary the request uses, so a request that shares nothing substantive with
    /// anything saved returns nil and the caller authors — rather than bending the least
    /// unrelated action to fit.
    static func best(among actions: [AdapterAction], request: String) -> AdapterAction? {
        let words = tokens(request).subtracting(filler)
        guard !words.isEmpty else { return nil }
        struct Scored {
            let action: AdapterAction
            let shared: Int
            let breadth: Int
        }
        var scored: [Scored] = []
        for action in actions {
            let known = vocabulary(of: action)
            let shared = known.intersection(words).count
            guard shared > 0 else { continue }
            scored.append(Scored(action: action, shared: shared, breadth: known.count))
        }
        // A tie goes to the action with the smaller vocabulary: matching two of an action's
        // three words says more than matching two of its twelve.
        let best = scored.max { a, b in
            if a.shared != b.shared { return a.shared < b.shared }
            return a.breadth > b.breadth
        }
        return best?.action
    }

    /// The words an action answers to: its triggers and every word of its name, minus the
    /// ones that carry no request. "Minimise after a delay" answers to "minimise" and
    /// "delay" — not to "a", which would make every sentence containing the word "a" a
    /// match for it. That is not a hypothetical: it made "export this page as a pdf" a
    /// revision of the minimise action.
    private static func vocabulary(of action: AdapterAction) -> Set<String> {
        var words = Set(action.triggers.flatMap { tokens($0) })
        words.formUnion(tokens(action.name))
        return words.subtracting(filler)
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber && $0 != "%" }
                .map(String.init)
                .filter { !$0.isEmpty })
    }
}
