import Foundation

// MARK: - Fuzzy Matching

struct FuzzyMatcher {
    /// Performs fuzzy matching and returns a score (0.0 = no match, higher = better match)
    static func score(_ query: String, against target: String) -> Double? {
        let query = query.lowercased()
        let targetLower = target.lowercased()

        guard !query.isEmpty else { return nil }
        guard !targetLower.isEmpty else { return nil }

        // Fast path: exact match (case-insensitive)
        if targetLower == query {
            return 1000.0
        }

        // Fast path: starts with query
        if targetLower.hasPrefix(query) {
            // Strong bonus for prefix matches, scaled by coverage
            return 900.0 + Double(query.count) / Double(targetLower.count) * 100
        }

        // Check for acronym match (e.g., "gc" matches "Google Chrome")
        if let acronymScore = checkAcronymMatch(query: query, target: target) {
            return acronymScore
        }

        // Check if all characters in query appear in order in target
        var targetIndex = targetLower.startIndex
        var queryIndex = query.startIndex
        var matchedIndices: [String.Index] = []

        while queryIndex < query.endIndex && targetIndex < targetLower.endIndex {
            if query[queryIndex] == targetLower[targetIndex] {
                matchedIndices.append(targetIndex)
                queryIndex = query.index(after: queryIndex)
            }
            targetIndex = targetLower.index(after: targetIndex)
        }

        // If we didn't match all query characters, no match
        guard queryIndex == query.endIndex else {
            return nil
        }

        // Calculate base score from match ratio
        let matchRatio = Double(query.count) / Double(targetLower.count)
        var score = matchRatio * 100

        // Bonus for consecutive matches (rewards continuous substrings)
        var consecutiveBonus = 0.0
        var consecutiveCount = 0
        for i in 1..<matchedIndices.count {
            let prev = matchedIndices[i - 1]
            let curr = matchedIndices[i]
            if targetLower.distance(from: prev, to: curr) == 1 {
                consecutiveCount += 1
                consecutiveBonus += 15.0 + Double(consecutiveCount) * 2.0  // Escalating bonus
            } else {
                consecutiveCount = 0
            }
        }
        score += consecutiveBonus

        // Bonus for matching at word boundaries
        let words = targetLower.split(separator: " ")
        var wordBoundaryBonus = 0.0
        for word in words {
            let wordStr = String(word)
            if wordStr.hasPrefix(query) {
                wordBoundaryBonus += 80.0
                break
            } else if wordStr.contains(query) {
                wordBoundaryBonus += 40.0
            }
        }
        score += wordBoundaryBonus

        // Bonus for matching at the very start
        if let firstMatch = matchedIndices.first, firstMatch == targetLower.startIndex {
            score += 40.0
        }

        // Bonus for CamelCase matching (e.g., "gc" matches "googleChrome")
        if let camelScore = checkCamelCaseMatch(query: query, target: target) {
            score += camelScore
        }

        return score
    }

    /// Check if query matches the acronym of target words (e.g., "gc" -> "Google Chrome")
    private static func checkAcronymMatch(query: String, target: String) -> Double? {
        let words = target.split(separator: " ")
        guard words.count >= 2 else { return nil }

        let acronym = words.map { String($0.prefix(1)) }.joined().lowercased()
        if acronym.hasPrefix(query.lowercased()) {
            return 850.0 + Double(query.count) * 10.0
        }
        return nil
    }

    /// Check if query matches CamelCase initials (e.g., "gc" -> "googleChrome")
    private static func checkCamelCaseMatch(query: String, target: String) -> Double? {
        let uppercaseIndices = target.indices.filter { target[$0].isUppercase }
        guard !uppercaseIndices.isEmpty else { return nil }

        let camelAcronym = uppercaseIndices.map { String(target[$0]) }.joined().lowercased()
        if camelAcronym.hasPrefix(query.lowercased()) {
            return 60.0
        }
        return nil
    }
}
