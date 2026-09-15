// GeneralChatScopeResolver.swift
// Context-Dock
//
// Which apps a General Chat request touches, when it names none of them.
//
// Context Dock Chat knows its scope: the app is in front of the user. General Chat does not, and
// until now the answer was `chatFocusApps` — a list picked by hand before asking. That is
// "always ask first" wearing a different hat, and it fails the case the surface exists for:
// "where are my invoices?" does not know whether that is Mail, Files or Notes, so the person
// least able to answer is the one being asked.
//
// The rule here, from the decision "General Chat resolves scope per step and asks only on real
// ambiguity":
//
//   * Resolve from the capability inventory, not from a question.
//   * Per step. "find the invoice Sarah sent me and save it to the Client folder" is Mail then
//     Finder; there is no single answer to "which app?" and pretending otherwise asks the user
//     for two answers as if they were one.
//   * Ask only when two adapters are reached by the *same* word. Two adapters reached by
//     different words are not ambiguous — that is a two-step plan.
//
// This proposes; it does not authorise. `AppAccessPolicy` still gates every route, and a write
// still shows the approval sheet naming the app — which is where scope is confirmed, with a
// resolved plan in hand rather than before there is anything to show.

import Foundation

enum GeneralChatScopeResolver {

    /// One app the resolver may choose, and the words that reach it.
    ///
    /// The vocabulary is the app's own nouns — what its capabilities are *about* — rather than
    /// its capability ids. Nobody types "mail.search"; they type "email".
    struct Candidate: Equatable, Sendable {
        let bundleId: String
        let name: String
        let vocabulary: Set<String>

        init(bundleId: String, name: String, vocabulary: Set<String>) {
            self.bundleId = bundleId
            self.name = name
            self.vocabulary = Set(vocabulary.map { $0.lowercased() })
        }
    }

    enum Resolution: Equatable, Sendable {
        /// Bundle ids, in the order their steps appear in the sentence.
        case resolved([String])
        /// Two or more adapters answer to the same word. Named, so the question can be closed
        /// rather than open-ended.
        case ambiguous(candidates: [String])
        /// Nothing installed serves this. Not the same as ambiguous — it has its own answer,
        /// which is the capability-gap one.
        case unresolved
    }

    /// The scope for a turn: the user's explicit choice if they made one, otherwise resolved.
    ///
    /// The focus list wins outright. It is an explicit decision, and resolving past it would be
    /// the one place in the app where DoraX widens a scope the user narrowed on purpose.
    static func scope(
        request: String, focused: [String], inventory: [Candidate]
    ) -> Resolution {
        guard focused.isEmpty else { return .resolved(focused) }
        return resolve(request: request, inventory: inventory)
    }

    static func resolve(request: String, inventory: [Candidate]) -> Resolution {
        let words = tokens(in: request)
        guard !words.isEmpty, !inventory.isEmpty else { return .unresolved }

        // Which candidates each matched word reaches, in the order the words appear. Order is
        // the sentence's, because the steps run in that order.
        var order: [String] = []
        var reachedBy: [String: [Candidate]] = [:]
        for word in words {
            let matches = inventory.filter { $0.vocabulary.contains(word) }
            guard !matches.isEmpty else { continue }
            if reachedBy[word] == nil { order.append(word) }
            reachedBy[word] = matches
        }
        guard !order.isEmpty else { return .unresolved }

        // A word two adapters answer to is the real question, and it is asked before anything
        // runs — a contested step cannot be resolved by trying one and seeing.
        for word in order {
            guard let matches = reachedBy[word], matches.count > 1 else { continue }
            return .ambiguous(candidates: matches.map(\.name).sorted())
        }

        var resolved: [String] = []
        for word in order {
            guard let bundleId = reachedBy[word]?.first?.bundleId else { continue }
            if !resolved.contains(bundleId) { resolved.append(bundleId) }
        }
        return resolved.isEmpty ? .unresolved : .resolved(resolved)
    }

    /// Build the inventory from what DoraX already knows it can do.
    ///
    /// `CapabilityRecord` carries the app as a *name* and not a bundle id, so the mapping is
    /// injected rather than reached for — which is also what makes this testable without
    /// standing up InstalledApplicationsCatalog.
    ///
    /// An app whose name does not resolve to a bundle id is dropped rather than guessed at: a
    /// candidate with the wrong id would send a whole step to the wrong app.
    static func inventory(
        from records: [CapabilityRecord],
        bundleId resolveBundleId: (String) -> String?
    ) -> [Candidate] {
        var vocabularies: [String: Set<String>] = [:]
        var order: [String] = []

        for record in records {
            let app = record.app.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty else { continue }
            if vocabularies[app] == nil { order.append(app) }
            // The app's own name and its capabilities' keywords. Titles and descriptions are
            // deliberately excluded: they are prose, and prose words like "get" or "current"
            // belong to every adapter at once, which turns every request ambiguous.
            var words = vocabularies[app] ?? []
            words.formUnion(terms(in: app))
            for keyword in record.keywords { words.formUnion(terms(in: keyword)) }
            vocabularies[app] = words
        }

        return order.compactMap { app in
            guard let id = resolveBundleId(app) else { return nil }
            guard let words = vocabularies[app], !words.isEmpty else { return nil }
            return Candidate(bundleId: id, name: app, vocabulary: words)
        }
    }

    /// Words worth matching on, from a name or a keyword.
    ///
    /// Two-letter fragments and pure numbers are dropped — "to", "my" and "v2" reach every
    /// adapter and would make everything contested.
    private static func terms(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 && !$0.allSatisfy(\.isNumber) })
    }

    /// Whole words, singular and plural.
    ///
    /// Substring matching would find "note" in "noteworthy" and "reminder" in "remembered", and
    /// reaching into the wrong app is worse than reaching into none — a wrong answer about
    /// someone's mail looks exactly like a right one.
    private static func tokens(in request: String) -> [String] {
        let raw = request.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        var words: [String] = []
        for word in raw {
            words.append(word)
            // "emails" reaches the adapter that owns "email". Only the plain plural: anything
            // cleverer starts guessing at stems, and a wrong stem is a wrong app.
            if word.hasSuffix("es"), word.count > 3 { words.append(String(word.dropLast(2))) }
            if word.hasSuffix("s"), word.count > 2 { words.append(String(word.dropLast())) }
        }
        return words
    }
}
