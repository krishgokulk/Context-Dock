// AdapterSearchSpelling.swift
// Context-Dock
//
// One word, two spellings, one action.
//
// The owner saved an action the model named "Minimize Code After Delay" and asked for it the
// way they write: "minimise code app after 2min". The adapter scorer normalises to lowercase
// alphanumerics, so those were two unrelated tokens: the name overlap fell from three words
// to two, the score from 102 to 80 — under the strong-match bar — and a cached menu item
// scoring 0.82 was offered instead. The chat proposed "Hide Others" for a request to
// minimise after two minutes, and the action that does exactly that was never offered.
//
// Folding is safe here because both sides of every comparison are folded the same way: a
// word this mangles ("promise" → "promize") still matches itself, in the query and in the
// action. What is lost is a distinction between two spellings of one word, which is the
// distinction that caused the bug.

import Foundation

enum AdapterSearchSpelling {

    /// One token, in the spelling the scorer compares.
    ///
    /// Deliberately only the -ise/-ize family. It is the difference that actually separated
    /// a user from their own action; a general synonym table would be a different feature
    /// with a much wider failure surface, and this one can be read in a sentence.
    static func fold(_ token: some StringProtocol) -> String {
        let word = String(token)
        // Short words are left alone: "wise", "rise" and "ise" have no -ize counterpart
        // anyone types, and folding them buys nothing.
        guard word.count > 5 else { return word }
        for (british, american) in endings where word.hasSuffix(british) {
            return String(word.dropLast(british.count)) + american
        }
        return word
    }

    /// Longest first, so "isation" is not matched as "ise" with letters left over.
    private static let endings: [(String, String)] = [
        ("isations", "izations"), ("isation", "ization"),
        ("ising", "izing"), ("ised", "ized"), ("ises", "izes"), ("ise", "ize"),
    ]
}
