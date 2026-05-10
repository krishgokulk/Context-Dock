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

    // "web" / "browser" always resolve to the user's default browser
    private let webAliases: Set<String> = ["web", "browser", "browse"]

    // Verbs that signal "open this search query in the browser"
    private let browseVerbs: Set<String> = ["browse", "search", "google", "find", "look", "look up", "lookup"]

    /// Returns the bundle ID of the user's default web browser.
    static func defaultBrowserBundleId() -> String? {
        guard let httpURL = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: httpURL) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    /// Returns the display name of the user's default web browser.
    static func defaultBrowserName() -> String {
        guard let bid = defaultBrowserBundleId() else { return "Browser" }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return Bundle(url: appURL)?.infoDictionary?["CFBundleName"] as? String
                ?? appURL.deletingPathExtension().lastPathComponent
        }
        return "Browser"
    }

    /// Builds a Google-compatible search URL for the given query and opens it in the default browser.
    static func openWebSearch(_ searchQuery: String) {
        let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
        guard let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Parses "X on web" / "web X" / "browse X" patterns and returns the bare search term, or nil.
    func extractWebSearchQuery(from rawQuery: String) -> String? {
        let q = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()

        // "X on web" / "X in web" / "X on browser"
        for suffix in [" on web", " in web", " on browser", " in browser", " on the web", " in the browser"] {
            if lower.hasSuffix(suffix) {
                let term = String(q.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                if !term.isEmpty { return term }
            }
        }
        // "web X" / "browser X" / "browse X" / "search X" / "google X"
        for prefix in ["web ", "browser ", "browse ", "search web ", "search the web ", "google "] {
            if lower.hasPrefix(prefix) {
                let term = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !term.isEmpty { return term }
            }
        }
        return nil
    }

    private let fillerWords: Set<String> = [
        "app", "open", "go", "goto", "navigate", "launch", "show", "use",
        "please", "the", "a", "an", "to", "in", "on", "for", "with", "into"
    ]
    private let appLocatorWords: Set<String> = ["find"]

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
        return bestAppTarget(for: normalizedQuery, requireActionQuery: true)
    }

    func appScopeTarget(for query: String) -> L2ExplicitAppTarget? {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return nil }
        return bestAppTarget(for: normalizedQuery, requireActionQuery: false)
    }

    private func bestAppTarget(
        for normalizedQuery: String,
        requireActionQuery: Bool
    ) -> L2ExplicitAppTarget? {
        var best: (bundleId: String, appName: String, alias: String, actionQuery: String, score: Int)?

        // Pass 1 — known adapters (higher priority: base score 100/70)
        let adapters = AppAdapterManager.shared.adapters.filter(\.isEnabled)
        for adapter in adapters {
            for alias in aliases(for: adapter) {
                guard let candidate = candidateTarget(
                    normalizedQuery: normalizedQuery,
                    alias: alias,
                    appName: adapter.appName,
                    bundleId: adapter.bundleId,
                    requireActionQuery: requireActionQuery,
                    preferredStartScore: 100,
                    preferredNonStartScore: 70
                ) else { continue }
                let score = candidate.score
                if let current = best, current.score >= score { continue }
                best = candidate
            }
        }

        // Pass 2 — any running regular app not already covered by an adapter (base score 80/50)
        // This makes every installed app a valid cross-app target without needing a custom adapter.
        let knownBundleIds = Set(adapters.map(\.bundleId))
        let selfBundle = Bundle.main.bundleIdentifier ?? "ILauncher"
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let appName = app.localizedName, !appName.isEmpty,
                  let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
                  !knownBundleIds.contains(bundleId),
                  !bundleId.hasPrefix(selfBundle) else { continue }
            let alias = normalize(appName)
            guard !alias.isEmpty else { continue }
            guard let candidate = candidateTarget(
                normalizedQuery: normalizedQuery,
                alias: alias,
                appName: appName,
                bundleId: bundleId,
                requireActionQuery: requireActionQuery,
                preferredStartScore: 80,
                preferredNonStartScore: 50
            ) else { continue }
            let score = candidate.score
            if let current = best, current.score >= score { continue }
            best = candidate
        }

        guard let best else { return nil }
        if requireActionQuery, best.actionQuery.isEmpty {
            return nil
        }
        return L2ExplicitAppTarget(
            bundleId: best.bundleId,
            appName: best.appName,
            actionQuery: best.actionQuery,
            matchedAlias: best.alias
        )
    }

    private func candidateTarget(
        normalizedQuery: String,
        alias: String,
        appName: String,
        bundleId: String,
        requireActionQuery: Bool,
        preferredStartScore: Int,
        preferredNonStartScore: Int
    ) -> (bundleId: String, appName: String, alias: String, actionQuery: String, score: Int)? {
        if let extraction = extractActionQuery(from: normalizedQuery, alias: alias) {
            if requireActionQuery && extraction.actionQuery.isEmpty {
                return nil
            }
            let actionBonus = extraction.actionQuery.isEmpty ? 0 : min(extraction.actionQuery.count, 20)
            let score = (extraction.aliasAtStart ? preferredStartScore : preferredNonStartScore)
                + alias.count + actionBonus
            return (bundleId, appName, alias, extraction.actionQuery, score)
        }

        guard !requireActionQuery else { return nil }
        guard normalizedQuery.count >= 2 else { return nil }

        if normalizedQuery == alias {
            let score = preferredStartScore + 35 + alias.count
            return (bundleId, appName, alias, "", score)
        }

        return nil
    }

    // MARK: - Partial app name autocomplete

    /// Returns a partial match when the user has typed a prefix of an app name but not the full alias.
    /// Used for Spotlight-style ghost text + Tab completion in the L2 search field.
    /// - Returns: (appName, bundleId, ghostSuffix, actionQuery) or nil if no partial prefix match.
    func partialAppCompletion(for query: String) -> (appName: String, bundleId: String, ghost: String, actionQuery: String)? {
        let q = normalize(query)
        guard !q.isEmpty, q.count >= 2 else { return nil }
        // Don't trigger if query already fully matches (explicitAppTarget handles that)
        let tokens = tokenize(q)
        guard let firstToken = tokens.first, firstToken.count >= 2 else { return nil }
        let actionQuery = tokens.dropFirst().joined(separator: " ")
        guard !shouldSuppressPartialCompletion(
            fullQuery: q,
            firstToken: firstToken,
            actionQuery: actionQuery
        ) else {
            return nil
        }

        // Score = launch count * 1000 - alias length (shorter = better tie-break)
        struct Candidate {
            var appName: String; var bundleId: String; var ghost: String
            var actionQuery: String; var aliasLen: Int; var score: Int
        }
        var candidates: [Candidate] = []

        let adapters = AppAdapterManager.shared.adapters.filter {
            $0.isEnabled && !($0.actions.isEmpty == false && $0.actions.allSatisfy { $0.type == .cliTool })
        }
        for adapter in adapters {
            for alias in aliases(for: adapter) {
                let aliasTokens = tokenize(alias)
                guard let firstAliasToken = aliasTokens.first else { continue }
                guard shouldAllowShortPrefixMatch(prefix: firstToken, appName: adapter.appName, bundleId: adapter.bundleId) else { continue }

                if firstAliasToken == firstToken {
                    guard aliasTokens.count > 1 else { continue }
                    let ghost = " " + aliasTokens.dropFirst().joined(separator: " ")
                    let launches = AppLaunchTracker.shared.count(for: adapter.bundleId)
                    candidates.append(Candidate(appName: adapter.appName, bundleId: adapter.bundleId, ghost: ghost, actionQuery: actionQuery, aliasLen: alias.count, score: launches * 1000 - alias.count))
                    continue
                }

                guard firstAliasToken.hasPrefix(firstToken) else { continue }
                let ghost = String(alias.dropFirst(firstToken.count))
                let launches = AppLaunchTracker.shared.count(for: adapter.bundleId)
                candidates.append(Candidate(appName: adapter.appName, bundleId: adapter.bundleId, ghost: ghost, actionQuery: actionQuery, aliasLen: alias.count, score: launches * 1000 - alias.count))
            }
        }

        // Also check all installed apps (not just running) for better coverage
        let knownBundleIds = Set(adapters.map(\.bundleId))
        let selfBundle = Bundle.main.bundleIdentifier ?? ""

        // Running apps
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let appName = app.localizedName, !appName.isEmpty,
                  let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
                  !knownBundleIds.contains(bundleId), !bundleId.hasPrefix(selfBundle) else { continue }
            let alias = normalize(appName)
            let aliasTokens = tokenize(alias)
            guard let firstAliasToken = aliasTokens.first else { continue }
            guard firstAliasToken.hasPrefix(firstToken), firstAliasToken != firstToken else { continue }
            guard shouldAllowShortPrefixMatch(prefix: firstToken, appName: appName, bundleId: bundleId) else { continue }
            let ghost = String(alias.dropFirst(firstToken.count))
            let launches = AppLaunchTracker.shared.count(for: bundleId)
            candidates.append(Candidate(appName: appName, bundleId: bundleId, ghost: ghost, actionQuery: actionQuery, aliasLen: alias.count, score: launches * 1000 - alias.count))
        }

        guard !candidates.isEmpty else { return nil }
        // Pick highest score; for equal scores prefer shorter alias
        let best = candidates.max { $0.score < $1.score }!
        return (best.appName, best.bundleId, best.ghost, best.actionQuery)
    }

    private func shouldSuppressPartialCompletion(
        fullQuery: String,
        firstToken: String,
        actionQuery: String
    ) -> Bool {
        guard !actionQuery.isEmpty else { return false }
        if isQuestionLikeQuery(fullQuery) { return true }
        if isCommonLanguageStart(firstToken) && !looksLikeAppCommandRemainder(actionQuery) {
            return true
        }
        return false
    }

    private func isQuestionLikeQuery(_ query: String) -> Bool {
        let tokens = tokenize(query)
        guard let first = tokens.first else { return false }
        let questionStarts: Set<String> = [
            "what", "whats", "who", "when", "where", "why", "how",
            "is", "are", "do", "does", "did", "can", "could", "should",
            "tell", "explain", "describe", "summarize", "analyse", "analyze"
        ]
        if questionStarts.contains(first) { return true }
        if tokens.count >= 2 {
            let firstTwo = tokens.prefix(2).joined(separator: " ")
            if ["what is", "what are", "how do", "how can", "tell me"].contains(firstTwo) {
                return true
            }
        }
        return false
    }

    private func isCommonLanguageStart(_ token: String) -> Bool {
        let commonStarts: Set<String> = [
            "a", "an", "the", "this", "that", "these", "those",
            "what", "whats", "who", "when", "where", "why", "how",
            "is", "are", "do", "does", "did", "can", "could", "should",
            "i", "me", "my", "we", "you", "it", "its",
            "tell", "explain", "describe", "summarize", "analyse", "analyze"
        ]
        return commonStarts.contains(token)
    }

    private func looksLikeAppCommandRemainder(_ actionQuery: String) -> Bool {
        guard let first = tokenize(actionQuery).first else { return false }
        let commandStarts: Set<String> = [
            "open", "new", "close", "send", "message", "call", "search", "find",
            "show", "list", "compose", "create", "add", "play", "pause", "stop",
            "next", "previous", "download", "share", "copy", "paste", "reply"
        ]
        return commandStarts.contains(first)
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

        // Dynamically add "web" / "browser" / "browse" as aliases for the default browser
        if let defaultBid = L2AppActionRouter.defaultBrowserBundleId(),
           adapter.bundleId == defaultBid {
            webAliases.forEach { values.insert($0) }
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
        if !aliasAtStart {
            while let first = remaining.first, appLocatorWords.contains(first) {
                remaining.removeFirst()
            }
        }
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

    private func shouldAllowShortPrefixMatch(
        prefix: String,
        appName: String,
        bundleId: String
    ) -> Bool {
        let normalizedName = normalize(appName)
        if normalizedName == "news" || bundleId == "com.apple.news" {
            return prefix.count >= 4
        }
        return true
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
