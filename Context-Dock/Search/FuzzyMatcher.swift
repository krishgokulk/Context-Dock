import Foundation

// MARK: - Fuzzy Matching

struct FuzzyMatcher {

    // Public API — accepts raw strings (lowercases internally).
    // Existing callers in ContentView / FileIndexManager use this.
    static func score(_ query: String, against target: String) -> Double? {
        score(query.lowercased(), againstLower: target.lowercased(), original: target)
    }

    // Optimized variant — call when both sides are already lowercased.
    // The search hot-path uses this to avoid repeated lowercased() allocations.
    static func score(_ queryLower: String, againstLower targetLower: String, original target: String) -> Double? {
        guard !queryLower.isEmpty, !targetLower.isEmpty else { return nil }

        // Fast path: exact match
        if targetLower == queryLower { return 1000.0 }

        // Fast path: prefix match
        if targetLower.hasPrefix(queryLower) {
            return 900.0 + Double(queryLower.count) / Double(targetLower.count) * 100
        }

        // Acronym match (e.g. "gc" → "Google Chrome")
        if let s = checkAcronymMatch(queryLower: queryLower, target: target) { return s }

        // Sequential character match using [Character] for O(1) index arithmetic
        let targetChars = Array(targetLower)
        let queryChars  = Array(queryLower)
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(queryChars.count)

        var ti = 0, qi = 0
        while qi < queryChars.count && ti < targetChars.count {
            if queryChars[qi] == targetChars[ti] {
                matchedIndices.append(ti)
                qi += 1
            }
            ti += 1
        }
        guard qi == queryChars.count else { return nil }

        let matchRatio = Double(queryChars.count) / Double(targetChars.count)
        var score = matchRatio * 100

        // Consecutive-match bonus — O(1) per pair (integer subtraction)
        var consecutiveBonus = 0.0
        var consecutiveCount = 0
        for i in 1..<matchedIndices.count {
            if matchedIndices[i] - matchedIndices[i - 1] == 1 {
                consecutiveCount += 1
                consecutiveBonus += 15.0 + Double(consecutiveCount) * 2.0
            } else {
                consecutiveCount = 0
            }
        }
        score += consecutiveBonus

        // Word-boundary bonus
        let words = targetLower.split(separator: " ")
        var wordBoundaryBonus = 0.0
        for word in words {
            let w = String(word)
            if w.hasPrefix(queryLower) {
                wordBoundaryBonus += 80.0; break
            } else if w.contains(queryLower) {
                wordBoundaryBonus += 40.0
            }
        }
        score += wordBoundaryBonus

        // Start-of-string bonus
        if matchedIndices.first == 0 { score += 40.0 }

        // CamelCase bonus (e.g. "gc" → "googleChrome")
        if let s = checkCamelCaseMatch(queryLower: queryLower, target: target) { score += s }

        return score
    }

    // MARK: - Private helpers

    private static func checkAcronymMatch(queryLower: String, target: String) -> Double? {
        let words = target.split(separator: " ")
        guard words.count >= 2 else { return nil }
        let acronym = words.map { String($0.prefix(1)) }.joined().lowercased()
        guard acronym.hasPrefix(queryLower) else { return nil }
        return 850.0 + Double(queryLower.count) * 10.0
    }

    private static func checkCamelCaseMatch(queryLower: String, target: String) -> Double? {
        let uppers = target.indices.filter { target[$0].isUppercase }
        guard !uppers.isEmpty else { return nil }
        let camelAcronym = uppers.map { String(target[$0]) }.joined().lowercased()
        return camelAcronym.hasPrefix(queryLower) ? 60.0 : nil
    }
}
