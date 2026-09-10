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

import Foundation

/// One row: something the app can do, whichever kind it is.
enum AppChatRow: Identifiable {
    case command(AXMenuItem)
    case action(AdapterAction)
    /// A Global Context result: an app, a CLI tool, a system command, a tab, a menu — the
    /// dock's own index, ranked by the dock's own coordinator.
    case global(GlobalSearchService.SearchDocument)
    /// A file or folder, from the Finder scope's Spotlight search.
    case file(URL)
    /// A subcommand this CLI tool takes, offered inside its scope.
    case cliSuggestion(String)

    var id: String {
        switch self {
        case .command(let item): return "menu:" + item.path.joined(separator: ">")
        case .action(let action): return "action:" + action.id
        case .global(let doc): return "global:" + doc.id
        case .file(let url): return "file:" + url.path
        case .cliSuggestion(let word): return "cli:" + word
        }
    }

    var title: String {
        switch self {
        case .command(let item): return item.title
        case .action(let action): return action.name
        case .global(let doc): return doc.title
        case .file(let url): return url.lastPathComponent
        case .cliSuggestion(let word): return word
        }
    }

    var isAction: Bool {
        if case .action = self { return true }
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
        policy: FrontmostMenuMatcher.Policy = .cornerAppChat
    ) -> [AppChatRow] {
        let typed = DockTextMatch.normalized(query)

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
            let score = DockTextMatch.rankedScore(
                query: typed,
                primary: item.title,
                contexts: [
                    item.path.dropLast().last ?? "",
                    item.path.joined(separator: " "),
                ]) ?? 0
            scored.append((.command(item), score))
        }

        for action in actions {
            // Triggers are aliases the author gave the action — "reopen" for Open Recent —
            // and are exactly what the alias band of the score is for.
            // A zero is a miss, not a weak hit: the multi-token band returns 0 rather
            // than nil when none of the words land, and adding the tie-break edge to that
            // zero is what let a sentence produce five "matches".
            guard let score = DockTextMatch.rankedScore(
                query: typed,
                primary: action.name,
                aliases: action.triggers,
                contexts: [action.category ?? "", action.description]),
                score > 0
            else { continue }
            scored.append((.action(action), score + curatedActionEdge))
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
}
