// AppChatRowRanker.swift
// Context-Dock
//
// One ranked list for everything the frontmost app can do: the actions its adapter declares
// and the commands in its own menus, ordered together.
//
// The corner used to show whichever three menu rows the cache happened to hold first, in
// alphabetical order — so "About Visual Studio Code" and "Add Configuration…" were what an
// editor offered, and nothing an adapter author had actually curated ever surfaced. That is
// issue #13, and ordering by what the user typed is what fixes it.
//
// Scoring is `DockTextMatch` — the same rule the dock ranks with, so a query means the same
// thing wherever it is typed.
//
// The unified ranking formula (Unified Spotlight-Pet Surface spec §4):
//   TotalScore = MatchScore + FrecencyBoost + FrontmostBoost + SourceWeight - IncidentalPenalty

import Foundation

/// One row: something the app can do, whichever kind it is.
enum AppChatRow: Identifiable {
    case command(AXMenuItem)
    case action(AdapterAction)
    /// A Global Context result: an app, a CLI tool, a system command, a tab, a menu — the
    /// dock's own index, ranked by the dock's own coordinator.
    case global(GlobalSearchService.SearchDocument)
    case dock(DockPill)
    /// A file or folder, from the Finder scope's Spotlight search.
    case file(URL)
    /// A subcommand this CLI tool takes, offered inside its scope.
    case cliSuggestion(String)
    /// An app to jump to, from a "/" in Global or a Context Dock — running or not.
    case app(ChatAppEntry)

    var id: String {
        switch self {
        case .command(let item): return "menu:" + item.path.joined(separator: ">")
        case .action(let action): return "action:" + action.id
        case .global(let doc): return "global:" + doc.id
        case .dock(let pill): return "dock:" + pill.id
        case .file(let url): return "file:" + url.path
        case .cliSuggestion(let word): return "cli:" + word
        case .app(let entry): return "app:" + entry.id
        }
    }

    var title: String {
        switch self {
        case .command(let item): return item.title
        case .action(let action): return action.name
        case .global(let doc): return doc.title
        case .dock(let pill): return pill.name
        case .file(let url): return url.lastPathComponent
        case .cliSuggestion(let word): return word
        case .app(let entry): return entry.name
        }
    }

    var isAction: Bool {
        if case .action = self { return true }
        return false
    }

    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

enum AppChatRowRanker {

    /// Ties go to the adapter action. Someone wrote it deliberately for this app, while a
    /// menu command is simply everything the app happens to expose — so when the query fits
    /// both equally, the curated one is the better answer.
    private static let curatedActionEdge: Double = 1

    /// What the app offers, best match first.
    ///
    /// With nothing typed this is the opening offer: curated actions, then a spread of menu
    /// commands. With a query it is one ranked list — a command that matches well outranks
    /// an action that matches poorly, because relevance beats provenance.
    static func rank(
        commands: [AXMenuItem],
        actions: [AdapterAction],
        query: String,
        limit: Int,
        policy: FrontmostMenuMatcher.Policy = .cornerAppChat,
        frontmostBundleID: String? = nil,
        intent: QueryIntentArchetype = .navigational
    ) -> [AppChatRow] {
        let typed = DockTextMatch.normalized(query)
        let isFrontmost = frontmostBundleID != nil

        guard !typed.isEmpty else {
            let leading = actions.prefix(limit).map(AppChatRow.action)
            let remaining = limit - leading.count
            guard remaining > 0 else { return Array(leading) }
            let filled = FrontmostMenuMatcher.ranked(
                commands, query: "", limit: remaining, policy: policy)
            return leading + filled.map(AppChatRow.command)
        }

        var scored: [(row: AppChatRow, score: Double)] = []

        for item in FrontmostMenuMatcher.ranked(
            commands, query: typed, limit: limit * 2, policy: policy)
        {
            var score = DockTextMatch.rankedScore(
                query: typed,
                primary: item.title,
                contexts: [
                    item.path.dropLast().last ?? "",
                    item.path.joined(separator: " "),
                ]) ?? 0
            if isFrontmost {
                score += UnifiedIntentClassifier.frontmostAppBoost
            }
            scored.append((.command(item), score))
        }

        for action in actions {
            guard let score = DockTextMatch.rankedScore(
                query: typed,
                primary: action.name,
                aliases: action.triggers,
                contexts: [action.category ?? "", action.description]),
                score > 0
            else { continue }
            var adjusted = score + curatedActionEdge
            if isFrontmost {
                adjusted += UnifiedIntentClassifier.frontmostAppBoost
            }
            scored.append((.action(action), adjusted))
        }

        return Array(
            scored
                .filter { $0.score > 0 }
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.row.title.localizedCaseInsensitiveCompare($1.row.title)
                        == .orderedAscending
                }
                .prefix(limit)
                .map(\.row))
    }

    // MARK: - Unified Ranking

    /// Applies the unified ranking adjustments to an already-ordered list of rows:
    /// conversational file penalty, explicit file boost, and frecency reordering.
    static func applyUnifiedAdjustments(
        to rows: [AppChatRow],
        query: String,
        intent: QueryIntentArchetype,
        frontmostBundleID: String? = nil
    ) -> [AppChatRow] {
        guard !rows.isEmpty else { return rows }

        var scored: [(row: AppChatRow, score: Double)] = []
        let baseScore: Double = 10_000

        for (index, row) in rows.enumerated() {
            var score = baseScore - Double(index) * 100

            // Conversational penalty on incidental file matches
            if intent == .conversational, row.isFile {
                score += UnifiedIntentClassifier.conversationalFilePenalty
            }

            // Explicit file boost
            if intent == .explicitFile, row.isFile {
                score += UnifiedIntentClassifier.explicitFileBoost
            }

            // Frecency boost from UsageTracker
            let frecency = UsageTracker.shared.getScore(for: row.id)
            if frecency > 0 {
                score += min(frecency, 200)
            }

            // Frontmost boost for commands/actions of the frontmost app
            if let bid = frontmostBundleID {
                if case .global(let doc) = row, doc.bundleId == bid {
                    score += UnifiedIntentClassifier.frontmostAppBoost
                }
            }

            scored.append((row, score))
        }

        return scored
            .sorted { $0.score > $1.score }
            .map(\.row)
    }

    // MARK: - Ghost Text Derivation

    /// Returns the ghost completion suffix for the top-ranked row, or nil if no prefix match.
    /// The query "exp" with top result "Export as PDF…" yields "ort as PDF…".
    static func ghostText(for query: String, topRow: AppChatRow?) -> String? {
        guard let topRow, !query.isEmpty else { return nil }
        let title = topRow.title
        let normalizedQuery = query.lowercased()
        let normalizedTitle = title.lowercased()
        guard normalizedTitle.hasPrefix(normalizedQuery) else { return nil }
        let suffixStart = title.index(title.startIndex, offsetBy: query.count)
        let suffix = String(title[suffixStart...])
        guard !suffix.isEmpty else { return nil }
        return suffix
    }

    /// For conversational queries with no high-confidence local match, returns the
    /// "Ask Dora" ghost suffix to display after the query text.
    static func conversationalGhostText(
        for query: String,
        intent: QueryIntentArchetype,
        hasHighConfidenceMatch: Bool
    ) -> String? {
        guard intent == .conversational || intent == .webResearch,
              !hasHighConfidenceMatch, !query.isEmpty
        else { return nil }
        return " — Ask Dora (↵)"
    }
}
