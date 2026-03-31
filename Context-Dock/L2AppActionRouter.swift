import Foundation
import AppKit

struct L2AppActionMatch {
    let adapter: AppAdapter
    let action: AdapterAction
    let score: Double
    let matchedAppPhrase: String
    let matchedActionPhrase: String
    let usedFrontmostFallback: Bool
}

struct L2AppActionResolution {
    let primary: L2AppActionMatch
    let alternatives: [L2AppActionMatch]
}

struct L2ExplicitAppTarget {
    let bundleId: String
    let appName: String
    let actionQuery: String
    let matchedAlias: String
}

@MainActor
final class L2AppActionRouter {
    static let shared = L2AppActionRouter()

    private init() {}

    private let manualAliases: [String: [String]] = [
        "com.apple.finder": ["finder"],
        "com.apple.Safari": ["safari"],
        "com.apple.MobileSMS": ["messages", "message", "imessage", "texts"],
        "com.apple.mail": ["mail", "email"],
        "com.apple.Notes": ["notes", "note"],
        "com.apple.iCal": ["calendar", "cal"],
        "com.apple.systempreferences": ["system settings", "settings", "preferences", "system preferences"],
        "com.microsoft.VSCode": ["vs code", "vscode", "visual studio code", "code"],
        "com.apple.dt.Xcode": ["xcode"]
    ]

    private let fillerWords: Set<String> = [
        "app", "open", "go", "goto", "navigate", "launch", "show", "use",
        "please", "the", "a", "an", "to", "in", "on", "for", "with", "into"
    ]

    func resolve(query: String) -> L2AppActionResolution? {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return nil }

        var matches = explicitAppMatches(for: normalizedQuery)
        if matches.isEmpty {
            matches = frontmostFallbackMatches(for: normalizedQuery)
        }

        let ranked = dedupeAndSort(matches)
        guard let primary = ranked.first else { return nil }

        let minimumScore = primary.usedFrontmostFallback ? 115.0 : 125.0
        guard primary.score >= minimumScore else { return nil }

        let alternatives = Array(ranked.dropFirst().prefix(3)).filter { $0.score >= primary.score - 18 }
        return L2AppActionResolution(primary: primary, alternatives: alternatives)
    }

    func explicitAppTarget(for query: String) -> L2ExplicitAppTarget? {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return nil }

        let adapters = AppAdapterManager.shared.adapters.filter(\.isEnabled)
        var best: (adapter: AppAdapter, alias: String, actionQuery: String, score: Int)?

        for adapter in adapters {
            for alias in aliases(for: adapter) {
                guard let extraction = extractActionQuery(from: normalizedQuery, alias: alias) else { continue }
                let score = (extraction.aliasAtStart ? 100 : 70) + alias.count
                if let current = best, current.score >= score { continue }
                best = (adapter, alias, extraction.actionQuery, score)
            }
        }

        guard let best, !best.actionQuery.isEmpty else { return nil }
        return L2ExplicitAppTarget(
            bundleId: best.adapter.bundleId,
            appName: best.adapter.appName,
            actionQuery: best.actionQuery,
            matchedAlias: best.alias
        )
    }

    private func explicitAppMatches(for normalizedQuery: String) -> [L2AppActionMatch] {
        let adapters = AppAdapterManager.shared.adapters.filter(\.isEnabled)
        var matches: [L2AppActionMatch] = []

        for adapter in adapters {
            for alias in aliases(for: adapter) {
                guard let extraction = extractActionQuery(from: normalizedQuery, alias: alias) else { continue }
                guard !extraction.actionQuery.isEmpty else { continue }

                let appScore = scoreAppMatch(
                    adapter: adapter,
                    alias: alias,
                    aliasAtStart: extraction.aliasAtStart
                )

                matches.append(contentsOf: scoreActions(
                    in: adapter,
                    actionQuery: extraction.actionQuery,
                    fullQuery: normalizedQuery,
                    appScore: appScore,
                    matchedAppPhrase: alias,
                    usedFrontmostFallback: false
                ))
            }
        }

        return matches
    }

    private func frontmostFallbackMatches(for normalizedQuery: String) -> [L2AppActionMatch] {
        guard normalizedQuery.split(separator: " ").count <= 4,
              let frontmost = AppDelegate.shared?.previousFrontmostApp,
              let bundleId = frontmost.bundleIdentifier,
              let adapter = AppAdapterManager.shared.adapter(for: bundleId) else {
            return []
        }

        let trimmedQuery = trimFillerWords(from: normalizedQuery)
        guard !trimmedQuery.isEmpty else { return [] }

        return scoreActions(
            in: adapter,
            actionQuery: trimmedQuery,
            fullQuery: normalizedQuery,
            appScore: 42,
            matchedAppPhrase: adapter.appName.lowercased(),
            usedFrontmostFallback: true
        )
    }

    private func scoreActions(
        in adapter: AppAdapter,
        actionQuery: String,
        fullQuery: String,
        appScore: Double,
        matchedAppPhrase: String,
        usedFrontmostFallback: Bool
    ) -> [L2AppActionMatch] {
        var matches: [L2AppActionMatch] = []

        for action in adapter.actions {
            let actionScore = score(action: action, against: actionQuery, fullQuery: fullQuery)
            guard actionScore > 0 else { continue }

            matches.append(L2AppActionMatch(
                adapter: adapter,
                action: action,
                score: appScore + actionScore,
                matchedAppPhrase: matchedAppPhrase,
                matchedActionPhrase: actionQuery,
                usedFrontmostFallback: usedFrontmostFallback
            ))
        }

        return matches
    }

    private func scoreAppMatch(adapter: AppAdapter, alias: String, aliasAtStart: Bool) -> Double {
        var score = aliasAtStart ? 58.0 : 42.0

        if adapter.appName.lowercased() == alias {
            score += 8
        }

        if let frontmostBundleId = AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier,
           frontmostBundleId == adapter.bundleId {
            score += 14
        } else if NSRunningApplication.runningApplications(withBundleIdentifier: adapter.bundleId).isEmpty == false {
            score += 8
        }

        return score
    }

    private func score(action: AdapterAction, against actionQuery: String, fullQuery: String) -> Double {
        let normalizedName = normalize(action.name)
        let normalizedDescription = normalize(action.description)
        let normalizedTriggers = action.triggers.map(normalize)

        var score = 0.0

        if normalizedName == actionQuery {
            score = max(score, 120)
        }

        for trigger in normalizedTriggers {
            if trigger == actionQuery {
                score = max(score, 130)
            }
            if trigger.hasPrefix(actionQuery) || actionQuery.hasPrefix(trigger) {
                score = max(score, 88)
            }
            if trigger.contains(actionQuery) || actionQuery.contains(trigger) {
                score = max(score, 78)
            }
            let overlap = tokenOverlap(trigger, actionQuery)
            if overlap > 0 {
                score = max(score, 34 + Double(overlap * 18))
            }
        }

        let nameOverlap = tokenOverlap(normalizedName, actionQuery)
        if nameOverlap > 0 {
            score = max(score, 28 + Double(nameOverlap * 20))
        }

        if !normalizedDescription.isEmpty,
           normalizedDescription.contains(actionQuery),
           actionQuery.count >= 4 {
            score = max(score, 44)
        }

        if normalize(fullQuery).contains(normalizedName), normalizedName.count >= 4 {
            score += 6
        }

        return score
    }

    private func aliases(for adapter: AppAdapter) -> [String] {
        var values = Set<String>()
        values.insert(normalize(adapter.appName))

        if let bundleTail = adapter.bundleId.split(separator: ".").last {
            let tail = normalize(String(bundleTail))
            if !tail.isEmpty && tail != "app" {
                values.insert(tail)
            }
        }

        for alias in manualAliases[adapter.bundleId] ?? [] {
            let normalized = normalize(alias)
            if !normalized.isEmpty {
                values.insert(normalized)
            }
        }

        return values.sorted { lhs, rhs in
            lhs.split(separator: " ").count > rhs.split(separator: " ").count
        }
    }

    private func extractActionQuery(from normalizedQuery: String, alias: String) -> (actionQuery: String, aliasAtStart: Bool)? {
        let queryTokens = tokenize(normalizedQuery)
        let aliasTokens = tokenize(alias)

        guard let range = firstSubsequence(of: aliasTokens, in: queryTokens) else { return nil }

        var remaining = queryTokens
        remaining.removeSubrange(range)
        let aliasAtStart = range.lowerBound == 0
        let actionQuery = trimFillerWords(from: remaining.joined(separator: " "))
        return (actionQuery, aliasAtStart)
    }

    private func trimFillerWords(from value: String) -> String {
        var words = tokenize(value)

        while let first = words.first, fillerWords.contains(first) {
            words.removeFirst()
        }

        while let last = words.last, fillerWords.contains(last) {
            words.removeLast()
        }

        return words.joined(separator: " ")
    }

    private func dedupeAndSort(_ matches: [L2AppActionMatch]) -> [L2AppActionMatch] {
        var bestByActionId: [String: L2AppActionMatch] = [:]

        for match in matches {
            let key = "\(match.adapter.bundleId)::\(match.action.id)"
            if let current = bestByActionId[key], current.score >= match.score {
                continue
            }
            bestByActionId[key] = match
        }

        return bestByActionId.values.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.action.name < rhs.action.name
            }
            return lhs.score > rhs.score
        }
    }

    private func normalize(_ value: String) -> String {
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let collapsed = String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    private func tokenize(_ value: String) -> [String] {
        value.split(separator: " ").map(String.init)
    }

    private func tokenOverlap(_ lhs: String, _ rhs: String) -> Int {
        let left = Set(tokenize(lhs))
        let right = Set(tokenize(rhs))
        return left.intersection(right).count
    }

    private func firstSubsequence(of needle: [String], in haystack: [String]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }

        for start in 0...(haystack.count - needle.count) {
            let end = start + needle.count
            if Array(haystack[start..<end]) == needle {
                return start..<end
            }
        }

        return nil
    }
}
