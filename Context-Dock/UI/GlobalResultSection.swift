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
    static let openTabs = "Open tabs"
    static let windowLayouts = "Window layouts"
    static let actions = "Actions"
    static let pinnedPrefix = "★ Pinned for "
    static let contextualActionsPrefix = "Contextual Actions (Frontmost: "

    static func pinnedSectionTitle(forApp appName: String) -> String {
        "\(pinnedPrefix)\(appName)"
    }

    static func contextualActionsTitle(forApp appName: String) -> String {
        "\(contextualActionsPrefix)\(appName))"
    }

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
        case "nativeWindow": return windowLayouts
        default:
            if let path = pill.previewPath, !path.isEmpty, !path.hasSuffix(".app") { return files }
            return commands
        }
    }

    /// A search document's section, by what the preview beside it says it is.
    static func title(for doc: GlobalSearchService.SearchDocument) -> String {
        if case .browserURL(_, _, _, BrowserURLLibraryEntry.Kind.tab.rawValue, _) = doc.action {
            return openTabs
        }
        switch CornerBoardLayout.preview(for: doc) {
        case .app, .appScope, .appJump: return applications
        case .command: return menuCommands
        case .file: return files
        case .web: return web
        case .windowLayout: return windowLayouts
        case .cliTool, .cliSubcommand, .systemCommand, .rowSummary, nil:
            return commands
        }
    }

    /// A row's section; nil for a CLI tool's subcommand, which has no kind of its own.
    /// An app's Context Dock lists in the same sections (#258 G4).
    static func title(for row: AppChatRow) -> String? {
        switch row {
        case .dock(let pill): return title(for: pill)
        case .global(let doc): return title(for: doc)
        case .command: return menuCommands
        case .action: return actions
        case .file: return files
        case .app: return applications
        case .cliSuggestion: return nil
        }
    }

    /// Canonical order of sections for Global Context search results (Raycast / Spotlight hierarchy).
    static let canonicalOrder: [String] = [
        applications,
        commands,
        windowLayouts,
        openTabs,
        menuCommands,
        actions,
        files,
        web,
        "Contacts",
        "Calendar & Notes"
    ]

    /// The rows gathered by section. When `useCanonicalSectionOrder` is true, sections are ordered
    /// according to `canonicalOrder` (Raycast / Spotlight hierarchy: Applications first, then Commands,
    /// Open tabs, Menu commands, Actions, Window layouts, Files & Folders, Web, etc.).
    /// Within a section, rows are prioritized by:
    /// 1. Named app relevance (if query names the app)
    /// 2. Exact match on title
    /// 3. Prefix match on title
    /// 4. Frecency boost from UsageTracker
    /// 5. Preserved original score/order
    static func grouped(
        _ rows: [AppChatRow],
        query: String = "",
        useCanonicalSectionOrder: Bool = false
    ) -> [AppChatRow] {
        var order: [String] = []
        var bySection: [String: [AppChatRow]] = [:]
        for row in rows {
            let title = title(for: row) ?? ""
            if bySection[title] == nil { order.append(title) }
            bySection[title, default: []].append(row)
        }

        if useCanonicalSectionOrder {
            order.sort { s1, s2 in
                let p1 = s1.hasPrefix(pinnedPrefix)
                let p2 = s2.hasPrefix(pinnedPrefix)
                if p1 != p2 { return p1 }
                let c1 = s1.hasPrefix(contextualActionsPrefix)
                let c2 = s2.hasPrefix(contextualActionsPrefix)
                if c1 != c2 { return c1 }
                let idx1 = canonicalOrder.firstIndex(of: s1) ?? Int.max
                let idx2 = canonicalOrder.firstIndex(of: s2) ?? Int.max
                if idx1 != idx2 { return idx1 < idx2 }
                return s1 < s2
            }
        }

        let typed = query.lowercased()
        func isNamed(_ row: AppChatRow) -> Bool {
            let app = appName(of: row).lowercased()
            return !app.isEmpty && typed.contains(app)
        }

        return order.flatMap { section -> [AppChatRow] in
            let sectionRows = bySection[section] ?? []
            if typed.isEmpty {
                return sectionRows
            }
            if !useCanonicalSectionOrder {
                return sectionRows.filter(isNamed) + sectionRows.filter { !isNamed($0) }
            }

            return sectionRows.sorted { a, b in
                let aNamed = isNamed(a)
                let bNamed = isNamed(b)
                if aNamed != bNamed { return aNamed && !bNamed }

                let aTitle = a.title.lowercased()
                let bTitle = b.title.lowercased()

                let aExact = aTitle == typed
                let bExact = bTitle == typed
                if aExact != bExact { return aExact }

                let aPrefix = aTitle.hasPrefix(typed)
                let bPrefix = bTitle.hasPrefix(typed)
                if aPrefix != bPrefix { return aPrefix }

                let aFrecency = UsageTracker.shared.getScore(for: a.id)
                let bFrecency = UsageTracker.shared.getScore(for: b.id)
                if abs(aFrecency - bFrecency) > 10 {
                    return aFrecency > bFrecency
                }

                return false
            }
        }
    }

    /// The app a row belongs to, by name; empty when it belongs to none.
    static func appName(of row: AppChatRow) -> String {
        switch row {
        case .dock(let pill): return pill.sourceAppName
        case .command(let item): return item.sourceAppName
        case .global(let doc):
            if case .command(_, _, let appName, _) = CornerBoardLayout.preview(for: doc) { return appName }
            return ""
        default: return ""
        }
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
