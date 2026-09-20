// ActionReadiness.swift
// Context-Dock
//
// Whether a resolved action can actually be carried out, before it is offered.
//
// "rewrite, make it as next fix, current note" produced an offer to run **Create Apple Note**,
// which then failed with `Missing capability input: title`. Two separate things went wrong and
// both are decided here, deterministically, rather than left to whichever ranker sorted first:
//
//   1. The capability was offered with none of the inputs it requires. A candidate whose
//      required inputs are not filled cannot run — offering it spends the user's tap on a
//      guaranteed failure, and the failure reads as the app being broken rather than as the
//      route being wrong.
//   2. It was a *create* capability answering a request about a note that already exists.
//      "Rewrite this" and "write a new one" are opposite instructions, and the word the user
//      typed — current, this, it — is the whole difference.
//
// Both rules are cheap and refuse rather than guess, which is the right asymmetry: a refused
// offer costs a turn, a wrong one writes to somebody's notes.

import Foundation

enum ActionReadiness {

    /// Every input this capability demands is present and non-empty.
    ///
    /// The deterministic offer runs the capability with exactly the values the resolver
    /// filled in; nothing later supplies the missing ones. So an unfilled required input is
    /// not a risk of failure, it is a certainty of one.
    static func canRun(_ candidate: DoraXActionCandidate) -> Bool {
        candidate.requiredInputs.allSatisfy { key in
            guard let value = candidate.inputValues[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The request is about something that already exists, not about making a new one.
    ///
    /// Matched as whole words: "this", "current", "that", "it", "existing", "same", plus the
    /// verbs that only make sense against an existing thing — rewrite, update, edit, revise,
    /// replace, amend, fix, correct. "Create a new note about X" contains none of them, and
    /// must keep reaching the create capability it names.
    static func namesExistingItem(_ query: String) -> Bool {
        let words = Set(
            query.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init))
        // "new" is the counter-signal and it wins: "rewrite this as a new note" is a create,
        // and a person who typed the word new means it.
        guard !words.contains("new") else { return false }
        let pointers: Set<String> = [
            "this", "current", "currently", "that", "existing", "same", "above", "previous",
        ]
        let verbs: Set<String> = [
            "rewrite", "rewrote", "update", "updating", "edit", "editing", "revise", "revising",
            "replace", "amend", "correct", "fix", "change", "modify", "append", "adjust",
        ]
        return !words.isDisjoint(with: pointers) || !words.isDisjoint(with: verbs)
    }

    /// A capability that makes a new record rather than changing one.
    ///
    /// Read from the id's own verb, so every app's create capability is covered by the one
    /// rule and a newly registered `foo.create` needs nothing added here.
    static func createsSomethingNew(capabilityID: String?) -> Bool {
        guard let id = capabilityID?.lowercased(), !id.isEmpty else { return false }
        let verb = id.split(separator: ".").last.map(String.init) ?? id
        return ["create", "new", "add", "compose", "draft", "make"].contains(verb)
    }

    /// The filter the offer applies: can it run, and is it the kind of thing being asked for.
    static func isOfferable(_ candidate: DoraXActionCandidate, query: String) -> Bool {
        guard canRun(candidate) else { return false }
        if createsSomethingNew(capabilityID: candidate.capabilityID), namesExistingItem(query) {
            return false
        }
        return true
    }
}
