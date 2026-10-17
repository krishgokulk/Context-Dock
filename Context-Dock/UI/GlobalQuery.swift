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
}
