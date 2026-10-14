// GlobalResultSection.swift
// Context-Dock
//
// Global Context's results in sections, as Raycast lists them (owner 2026-10-14, #258 G1):
// one header per kind — Applications, Commands, Menu commands, Files & Folders, Web — the
// kind with the best match first. The ranking is the engine's; this only gathers each kind's
// rows under its header, keeping their order.

import Foundation

enum GlobalResultSection {
    static let applications = "Applications"
    static let commands = "Commands"
    static let menuCommands = "Menu commands"
    static let files = "Files & Folders"
    static let web = "Web"

    /// A Global search result's section, by what it is — the old launcher's own buckets
    /// (`SearchResults.add`), with CLI tools among the commands.
    static func title(for type: SearchResult.ResultType) -> String {
        switch type {
        case .application: return applications
        case .extensionCommand, .shortcut, .cliTool: return commands
        case .file, .folder, .document, .photo: return files
        case .webSearch: return web
        case .contact: return "Contacts"
        case .calendarEvent, .reminder, .note, .mail, .message: return "Calendar & Notes"
        }
    }

    /// A row's section: what the engine said it is, else what its kind says.
    static func title(for pill: DockPill) -> String {
        if !pill.resultSection.isEmpty { return pill.resultSection }
        switch pill.rankingKind {
        case "menu", "submenuChild", "finderMenu", "safariCommand": return menuCommands
        case "web", "recentURL", "webSearch", "spotlightSearch": return web
        case "application", "appLaunch", "appSwitch": return applications
        default:
            if let path = pill.previewPath, !path.isEmpty, !path.hasSuffix(".app") { return files }
            return commands
        }
    }

    /// A search document's section, by what the preview beside it says it is.
    static func title(for doc: GlobalSearchService.SearchDocument) -> String {
        switch CornerBoardLayout.preview(for: doc) {
        case .app, .appScope: return applications
        case .command: return menuCommands
        case .file: return files
        case .web: return web
        case .cliTool, .cliSubcommand, .systemCommand, .windowLayout, nil: return commands
        }
    }

    /// A Global row's section; nil for a row that is not a Global result.
    static func title(for row: AppChatRow) -> String? {
        switch row {
        case .dock(let pill): return title(for: pill)
        case .global(let doc): return title(for: doc)
        default: return nil
        }
    }

    /// The rows gathered by section: each section where its first (best) row stood, its rows
    /// in their own order.
    static func grouped(_ rows: [AppChatRow]) -> [AppChatRow] {
        var order: [String] = []
        var bySection: [String: [AppChatRow]] = [:]
        for row in rows {
            let title = title(for: row) ?? ""
            if bySection[title] == nil { order.append(title) }
            bySection[title, default: []].append(row)
        }
        return order.flatMap { bySection[$0] ?? [] }
    }

    /// The header to draw above each row that starts a section, by row index. None when any
    /// row is not a Global result.
    static func headers(for rows: [AppChatRow]) -> [Int: String] {
        var headers: [Int: String] = [:]
        var last: String?
        for (index, row) in rows.enumerated() {
            guard let title = title(for: row) else { return [:] }
            if title != last { headers[index] = title }
            last = title
        }
        return headers
    }

    /// A section's own row that opens the rest of it (#258 G4).
    static let showMoreKind = "showMore"
    /// How many rows a section shows before "Show N more", when there is more than one.
    static let cap = 5

    /// Each long section cut to its best `cap` rows and a "Show N more" row, while the list
    /// has more than one section — one section is the whole answer and stays whole. The
    /// fallbacks and the sections already opened are never cut.
    static func capped(
        _ rows: [AppChatRow], expanded: Set<String>,
        showMore: (_ section: String, _ hidden: Int) -> DockPill
    ) -> [AppChatRow] {
        let titles = rows.map { title(for: $0) ?? "" }
        // The fallbacks close every typed list; they do not make a second section of matches.
        guard Set(titles.filter { $0 != GlobalFallbacks.section }).count > 1 else { return rows }
        var result: [AppChatRow] = []
        var index = 0
        while index < rows.count {
            let section = titles[index]
            var end = index
            while end < rows.count, titles[end] == section { end += 1 }
            let count = end - index
            if count > cap, section != GlobalFallbacks.section, !expanded.contains(section) {
                result += rows[index..<(index + cap)]
                result.append(.dock(showMore(section, count - cap)))
            } else {
                result += rows[index..<end]
            }
            index = end
        }
        return result
    }
}
