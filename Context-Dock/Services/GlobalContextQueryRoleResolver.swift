import AppKit
import Foundation

enum GlobalContextAppRole: String {
    case scope
    case target
    case filter
    case ignored
}

struct GlobalContextResolvedAppRole: Identifiable {
    let role: GlobalContextAppRole
    let bundleId: String
    let appName: String
    let appPath: String?
    let matchedAlias: String
    let aliasStartIndex: Int
    let aliasTokenCount: Int
    let actionQuery: String
    let confidence: Double

    var id: String { "\(role.rawValue):\(bundleId):\(aliasStartIndex)" }
}

struct GlobalContextQueryRoleResolution {
    let normalizedQuery: String
    let scope: GlobalContextResolvedAppRole?
    let targets: [GlobalContextResolvedAppRole]
    let filters: [GlobalContextResolvedAppRole]

    var hasRoles: Bool {
        scope != nil || !targets.isEmpty || !filters.isEmpty
    }
}

final class GlobalContextQueryRoleResolver {
    static let shared = GlobalContextQueryRoleResolver()
    private init() {}

    private struct AppCandidate {
        let bundleId: String
        let name: String
        let path: String?
        let aliases: [String]
        let priority: Double
    }

    private struct AliasMatch {
        let app: AppCandidate
        let alias: String
        let start: Int
        let count: Int
        let score: Double
    }

    func resolve(_ rawQuery: String) -> GlobalContextQueryRoleResolution {
        let normalized = AppMenuCapabilityCache.normalize(rawQuery)
        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else {
            return GlobalContextQueryRoleResolution(
                normalizedQuery: normalized, scope: nil, targets: [], filters: [])
        }

        let apps = appCandidates()
        let matches = findAliasMatches(tokens: tokens, apps: apps)
        guard !matches.isEmpty else {
            return GlobalContextQueryRoleResolution(
                normalizedQuery: normalized, scope: nil, targets: [], filters: [])
        }

        if let explicit = explicitScopeResolution(tokens: tokens, matches: matches) {
            return explicit
        }

        let sorted = matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
        }
        guard let best = sorted.first else {
            return GlobalContextQueryRoleResolution(
                normalizedQuery: normalized, scope: nil, targets: [], filters: [])
        }

        let scope = resolvedRole(
            from: best,
            role: .scope,
            tokens: tokens,
            actionRange: actionRangeExcluding(match: best, tokens: tokens)
        )
        let targetMatches = sorted.dropFirst().filter { other in
            other.app.bundleId != best.app.bundleId
        }
        let targets = targetMatches.prefix(2).map {
            resolvedRole(
                from: $0,
                role: .target,
                tokens: tokens,
                actionRange: actionRangeExcluding(match: $0, tokens: tokens)
            )
        }
        return GlobalContextQueryRoleResolution(
            normalizedQuery: normalized,
            scope: scope,
            targets: targets,
            filters: []
        )
    }

    private func explicitScopeResolution(
        tokens: [String],
        matches: [AliasMatch]
    ) -> GlobalContextQueryRoleResolution? {
        guard let inIndex = tokens.lastIndex(of: "in"), inIndex + 1 < tokens.count else {
            return nil
        }
        let suffixRange = (inIndex + 1)..<tokens.count
        guard let scopeMatch = matches
            .filter({ suffixRange.contains($0.start) })
            .sorted(by: { $0.score > $1.score })
            .first
        else { return nil }

        let actionTokens = Array(tokens[..<inIndex])
        let targetMatches = matches
            .filter { $0.app.bundleId != scopeMatch.app.bundleId && $0.start < inIndex }
            .sorted { $0.score > $1.score }

        let scope = resolvedRole(
            from: scopeMatch,
            role: .scope,
            tokens: actionTokens.isEmpty ? tokens : actionTokens,
            actionRange: actionTokens.indices
        )
        let targets = targetMatches.prefix(3).map {
            resolvedRole(
                from: $0,
                role: .target,
                tokens: tokens,
                actionRange: actionRangeExcluding(match: $0, tokens: tokens)
            )
        }
        return GlobalContextQueryRoleResolution(
            normalizedQuery: tokens.joined(separator: " "),
            scope: scope,
            targets: targets,
            filters: []
        )
    }

    private func resolvedRole(
        from match: AliasMatch,
        role: GlobalContextAppRole,
        tokens: [String],
        actionRange: Range<Int>
    ) -> GlobalContextResolvedAppRole {
        let action = actionRange
            .filter { tokens.indices.contains($0) }
            .map { tokens[$0] }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GlobalContextResolvedAppRole(
            role: role,
            bundleId: match.app.bundleId,
            appName: match.app.name,
            appPath: match.app.path,
            matchedAlias: match.alias,
            aliasStartIndex: match.start,
            aliasTokenCount: match.count,
            actionQuery: action,
            confidence: match.score
        )
    }

    private func actionRangeExcluding(match: AliasMatch, tokens: [String]) -> Range<Int> {
        if match.start == 0 {
            return min(match.count, tokens.count)..<tokens.count
        }
        if match.start + match.count >= tokens.count {
            return 0..<match.start
        }
        return 0..<tokens.count
    }

    private func findAliasMatches(tokens: [String], apps: [AppCandidate]) -> [AliasMatch] {
        var output: [AliasMatch] = []
        for app in apps {
            for alias in app.aliases {
                let aliasTokens = alias.split(separator: " ").map(String.init)
                guard !aliasTokens.isEmpty, aliasTokens.count <= tokens.count else { continue }
                for start in 0...(tokens.count - aliasTokens.count) {
                    guard aliasMatches(aliasTokens, tokens: tokens, start: start) else { continue }
                    let exact = aliasTokens.enumerated().allSatisfy { offset, token in
                        tokens[start + offset] == token
                    }
                    let trailingBoost = start + aliasTokens.count == tokens.count ? 900.0 : 0.0
                    let leadingBoost = start == 0 ? 650.0 : 0.0
                    let score = app.priority
                        + (exact ? 4_000 : 2_800)
                        + Double(alias.count * 12)
                        + trailingBoost
                        + leadingBoost
                        - Double(start * 80)
                    output.append(AliasMatch(
                        app: app,
                        alias: alias,
                        start: start,
                        count: aliasTokens.count,
                        score: score
                    ))
                }
            }
        }
        return output
    }

    private func aliasMatches(_ aliasTokens: [String], tokens: [String], start: Int) -> Bool {
        for (offset, aliasToken) in aliasTokens.enumerated() {
            let queryToken = tokens[start + offset]
            if queryToken == aliasToken { continue }
            let isLast = offset == aliasTokens.count - 1
            if isLast, queryToken.count >= 3, aliasToken.hasPrefix(queryToken) { continue }
            return false
        }
        return true
    }

    private func appCandidates() -> [AppCandidate] {
        var byBundle: [String: AppCandidate] = [:]

        func insert(bundleId: String, name: String, path: String?, aliases: [String], priority: Double) {
            let normalizedAliases = ([name] + aliases)
                .map(AppMenuCapabilityCache.normalize)
                .filter { $0.count >= 2 }
            guard !bundleId.isEmpty, !normalizedAliases.isEmpty else { return }
            let candidate = AppCandidate(
                bundleId: bundleId,
                name: name,
                path: path,
                aliases: Array(Set(normalizedAliases)),
                priority: priority
            )
            if let existing = byBundle[bundleId], existing.priority >= priority { return }
            byBundle[bundleId] = candidate
        }

        for app in InstalledApplicationsCatalog.cachedInstalledApps() {
            insert(
                bundleId: app.bundleId,
                name: app.name,
                path: app.url.path,
                aliases: aliases(for: app.bundleId, name: app.name),
                priority: 500
            )
        }

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            guard let bundleId = app.bundleIdentifier else { continue }
            insert(
                bundleId: bundleId,
                name: app.localizedName ?? bundleId,
                path: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path,
                aliases: aliases(for: bundleId, name: app.localizedName ?? bundleId),
                priority: 1_600
            )
        }

        insert(bundleId: "com.apple.MobileSMS", name: "Messages", path: nil,
               aliases: ["message", "messages", "imessage", "sms", "texts"], priority: 1_300)
        insert(bundleId: "com.apple.mail", name: "Mail", path: nil,
               aliases: ["mail", "email", "emails"], priority: 1_300)
        insert(bundleId: "com.apple.Safari", name: "Safari", path: nil,
               aliases: ["safari", "browser", "web"], priority: 1_300)

        return Array(byBundle.values)
    }

    private func aliases(for bundleId: String, name: String) -> [String] {
        var output = [name]
        let normalized = AppMenuCapabilityCache.normalize(name)
        output.append(contentsOf: normalized.split(separator: " ").map(String.init))
        switch bundleId {
        case "com.apple.MobileSMS":
            output += ["messages", "message", "imessage", "sms", "texts"]
        case "com.apple.mail":
            output += ["mail", "email", "emails"]
        case "com.apple.Safari":
            output += ["safari", "browser", "web"]
        case "com.spotify.client":
            output += ["spotify", "music"]
        default:
            break
        }
        return output
    }
}
