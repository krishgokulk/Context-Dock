// DockTextMatch.swift
// Context-Dock
//
// The text rules the dock ranks with, taken off LauncherView so something other than that
// view can use them. Nothing here reads view state — it never did; the functions simply
// lived on a SwiftUI struct with 420+ @State vars, which is why no test could reach them
// and why the corner could not rank a menu item at all.
//
// Moved verbatim. If a rule looks odd, it is the shipped rule, and changing it changes what
// the dock returns.

import Foundation

enum DockTextMatch {

    /// Lowercased, punctuation flattened to spaces, runs of whitespace collapsed.
    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            {
                return Character(scalar)
            }
            return " "
        }
        return String(mapped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Words of `text`, with the favourite/favorite spellings folded together.
    static func tokens(_ text: String) -> [String] {
        normalized(text).split(separator: " ").flatMap { rawToken -> [String] in
            let token = String(rawToken)
            switch token {
            case "fav", "favs", "favourite", "favourites", "favorite", "favorites", "favourate",
                "favourates":
                return [token, "favorite"]
            default:
                return [token]
            }
        }
    }

    /// Levenshtein distance, abandoned at 4 — callers only ever ask "within 2?".
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        let m = a.count
        let n = b.count
        if abs(m - n) > 3 { return 4 }
        // The dock's callers gate on tokens of 4+, so this never saw an empty string.
        // Reachable from anywhere now, and `1...0` traps.
        guard m > 0, n > 0 else { return max(m, n) }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            var rowMin = i
            for j in 1...n {
                curr[j] =
                    a[i - 1] == b[j - 1] ? prev[j - 1] : 1 + min(prev[j - 1], prev[j], curr[j - 1])
                rowMin = min(rowMin, curr[j])
            }
            if rowMin > 3 { return 4 }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    /// How well `query` matches, highest first. nil when the query is empty.
    ///
    /// The bands are deliberate and ordered: exact title, exact alias, title prefix, word
    /// prefix, alias, context (the menu an item sits under), then a contained-substring
    /// rung that decays with how late the match starts.
    static func rankedScore(
        query: String,
        primary: String,
        aliases: [String] = [],
        contexts: [String] = []
    ) -> Double? {
        let q = normalized(query)
        guard !q.isEmpty else { return nil }

        let primaryText = normalized(primary)
        let aliasTexts = aliases.map(normalized).filter { !$0.isEmpty && $0 != primaryText }
        let contextTexts = contexts.map(normalized).filter { !$0.isEmpty }

        func wordPrefixScore(_ text: String, base: Double) -> Double? {
            let words = text.split(separator: " ").map(String.init)
            guard let idx = words.firstIndex(where: { $0.hasPrefix(q) }) else { return nil }
            return base - Double(idx * 34) - min(Double(text.count), 42)
        }

        var best: Double?
        func keep(_ score: Double?) {
            guard let score else { return }
            best = max(best ?? -Double.infinity, score)
        }

        if primaryText == q { keep(12_000) }
        if aliasTexts.contains(q) { keep(10_600) }
        if primaryText.hasPrefix(q) {
            keep(9_600 + Double(q.count * 20) - min(Double(primaryText.count), 48))
        }
        keep(wordPrefixScore(primaryText, base: 8_900 + Double(q.count * 12)))

        for alias in aliasTexts {
            if alias.hasPrefix(q) {
                keep(8_250 + Double(q.count * 14) - min(Double(alias.count), 48))
            }
            keep(wordPrefixScore(alias, base: 7_700 + Double(q.count * 10)))
        }

        for context in contextTexts {
            if context == q { keep(6_800) }
            if context.hasPrefix(q) { keep(6_100 - min(Double(context.count), 48)) }
            keep(wordPrefixScore(context, base: 5_700))
        }

        if q.count >= 2 {
            if let range = primaryText.range(of: q) {
                let offset = primaryText.distance(from: primaryText.startIndex, to: range.lowerBound)
                keep(4_900 - Double(offset * 72) - min(Double(primaryText.count), 48))
            }
            for alias in aliasTexts {
                if let range = alias.range(of: q) {
                    let offset = alias.distance(from: alias.startIndex, to: range.lowerBound)
                    keep(4_250 - Double(offset * 58) - min(Double(alias.count), 48))
                }
            }
            for context in contextTexts where context.contains(q) {
                keep(3_400 - min(Double(context.count), 48))
            }
        }

        // A multi-word query also scores on how many of its words land anywhere, which is
        // what lets "new window" beat a single-word near-miss.
        let queryTokens = q.split(separator: " ").map(String.init)
        if queryTokens.count > 1 {
            let primaryTokens = Set(tokens(primaryText))
            let aliasTokens = Set(aliasTexts.flatMap(tokens))
            let contextTokens = Set(contextTexts.flatMap(tokens))
            let qSet = Set(queryTokens)
            keep(Double(qSet.intersection(primaryTokens).count) * 820)
            keep(Double(qSet.intersection(aliasTokens).count) * 680)
            keep(Double(qSet.intersection(contextTokens).count) * 420)
        }

        return best
    }
}
