// GlobalQuery.swift
// Context-Dock
//
// Global Context reads what is typed before it lists anything (owner 2026-10-17, S1 of the
// smarter-search plan): which words name an app, which are a time ("today"), which are glue
// ("in", "the"), and which are what is actually asked for. Two rules follow from it:
//
// - A row must answer the asked-for words, not only the app's name: "today history in
//   safari" listed "Copy GitHub Links" because it ran in a browser.
// - A command that destroys something — clear, delete, quit — is never the answer Return
//   takes unless its verb was typed: "safari history" put "Clear History…" first.

import Foundation

enum GlobalQuery {
    static let glueWords: Set<String> = ["in", "on", "the", "a", "an", "my", "for", "of", "from", "to", "at", "with", "and"]
    static let timeWords: Set<String> = ["today", "yesterday", "tonight", "week", "month", "recent", "recently", "last"]
    static let destructiveVerbs: Set<String> = ["clear", "delete", "erase", "remove", "quit", "reset", "empty", "trash"]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The words that say what is asked for: not glue, not a time, not an app's name.
    static func askedWords(in query: String, appNames: Set<String>) -> [String] {
        let appTokens = Set(appNames.flatMap(words))
        return words(query).filter {
            !glueWords.contains($0) && !timeWords.contains($0) && !appTokens.contains($0)
        }
    }

    /// The verb a destructive row starts with, if it does.
    static func destructiveVerb(of row: AppChatRow) -> String? {
        guard let first = words(row.title).first, destructiveVerbs.contains(first) else { return nil }
        return first
    }

    /// What a row can be found by, beyond its app's name. History and bookmark rows answer
    /// "history" and "bookmark" though their titles are page names.
    static func haystack(of row: AppChatRow) -> [String] {
        var text: [String] = [row.title]
        switch row {
        case .dock(let pill):
            text += [pill.menuContext ?? "", pill.badge ?? ""] + pill.menuPath
            if pill.rankingKind == "recentURL" || pill.resolvedURL.map({ !$0.isFileURL }) == true {
                let label = (pill.menuContext ?? "").lowercased()
                text.append(label.contains("bookmark") ? "bookmark bookmarks" : "history page site visited")
            }
        case .global(let doc):
            text.append(doc.subtitle)
            if case .browserURL = doc.action { text.append("history bookmark page site visited") }
            if case .cachedMenu(_, _, let path, _, _) = doc.action { text += path }
        case .command(let item): text += item.path
        case .file(let url): text.append(url.deletingLastPathComponent().lastPathComponent)
        case .action(let action): text.append(action.description)
        case .app, .cliSuggestion: break
        }
        return words(text.joined(separator: " "))
    }

    /// The rows, read against the query: rows that answer only the app's name are dropped
    /// (never all of them), apps are always kept, and destructive rows nobody asked for
    /// follow the safe ones.
    static func refine(_ rows: [AppChatRow], query: String) -> [AppChatRow] {
        let (safe, risky) = split(rows, query: query)
        return safe + risky
    }

    /// The refined rows as two lists: what answers the query, and the destructive rows
    /// nobody asked for — which Global lists after its fallbacks, so Return never offers to
    /// clear or delete when nothing safe matched (owner 2026-10-17).
    static func split(_ rows: [AppChatRow], query: String) -> (safe: [AppChatRow], risky: [AppChatRow]) {
        let appNames = Set(rows.map(GlobalResultSection.appName(of:)).filter { !$0.isEmpty }
            + rows.compactMap { if case .app(let entry) = $0 { return entry.name } else { return nil } }
            + rows.compactMap { row -> String? in
                guard GlobalResultSection.title(for: row) == GlobalResultSection.applications else { return nil }
                return row.title
            })
        let asked = askedWords(in: query, appNames: appNames)
        let typed = Set(words(query))

        func answers(_ row: AppChatRow) -> Bool {
            if GlobalResultSection.title(for: row) == GlobalResultSection.applications { return true }
            let hay = haystack(of: row)
            return asked.contains { word in hay.contains { $0.hasPrefix(word) || word.hasPrefix($0) && $0.count >= 4 } }
        }
        var kept = asked.isEmpty ? rows : rows.filter(answers)
        if !kept.contains(where: { GlobalResultSection.title(for: $0) != GlobalResultSection.applications }) {
            kept = rows
        }
        func isUnaskedDestructive(_ row: AppChatRow) -> Bool {
            guard let verb = destructiveVerb(of: row) else { return false }
            return !typed.contains(verb)
        }
        return (kept.filter { !isUnaskedDestructive($0) }, kept.filter(isUnaskedDestructive))
    }

    static let topHitSection = "Top Hit"

    /// The one row that plainly answers the query (S2): an app's own command — not a page,
    /// not a file — whose app the words name and whose title holds every asked word, never a
    /// destructive one nobody asked for. "safari history" → Show Personal History.
    static func topHit(_ rows: [AppChatRow], query: String) -> AppChatRow? {
        let typed = Set(words(query))
        let appNames = Set(rows.map(GlobalResultSection.appName(of:)).filter { !$0.isEmpty })
        let asked = askedWords(in: query, appNames: appNames)
        guard !asked.isEmpty else { return nil }
        return rows.first { row in
            let app = words(GlobalResultSection.appName(of: row))
            guard !app.isEmpty, app.allSatisfy(typed.contains) else { return false }
            guard [GlobalResultSection.menuCommands, GlobalResultSection.commands]
                .contains(GlobalResultSection.title(for: row) ?? "")
            else { return false }
            if let verb = destructiveVerb(of: row), !typed.contains(verb) { return false }
            let title = words(row.title)
            return asked.allSatisfy { word in title.contains { $0.hasPrefix(word) } }
        }
    }

    /// A named app's menu commands that hold an asked word, from the index's documents, that
    /// the rows do not already have.
    static func namedAppCommands(
        _ documents: [GlobalSearchService.SearchDocument], query: String, besides rows: [AppChatRow]
    ) -> [AppChatRow] {
        let typed = Set(words(query))
        let have = Set(rows.map { "\(GlobalResultSection.appName(of: $0).lowercased())|\($0.title.lowercased())" })
        return documents.compactMap { doc -> AppChatRow? in
            guard case .cachedMenu(_, let appName, _, _, _) = doc.action else { return nil }
            let app = words(appName)
            guard !app.isEmpty, app.allSatisfy(typed.contains) else { return nil }
            let asked = askedWords(in: query, appNames: [appName])
            let title = words(doc.title)
            guard !asked.isEmpty, asked.contains(where: { word in title.contains { $0.hasPrefix(word) } })
            else { return nil }
            guard !have.contains("\(appName.lowercased())|\(doc.title.lowercased())") else { return nil }
            return .global(doc)
        }
    }
}
