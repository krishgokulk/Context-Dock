import AppKit
import Foundation

/// Query-grounded retrieval for General Chat.
///
/// The capability prompt tells the model what DoraX *can* do (adapters, tools, an app
/// inventory) but nothing about what is actually on this Mac **for the question being
/// asked**. Without that, an app question is answered from the model's training data —
/// which is where invented menu items, invented file names, and invented app behaviour
/// come from.
///
/// This is the retrieve step of retrieve → augment → generate, run against the indexes
/// DoraX already maintains: the global search index (installed and running apps, cached
/// app menus, browser history and bookmarks, Global Commands, CLI tools), macOS Recent
/// Documents, and the Spotlight-backed file index. Results are ranked best-first and
/// capped per source — top-k, not top-everything, because every extra row costs context
/// and attention is quadratic in sequence length.
@MainActor
enum GeneralChatLocalEvidence {
    /// Per-source caps. Tuned so a full evidence block stays a few hundred tokens rather
    /// than displacing the conversation itself.
    private static let appLimit = 6
    private static let menuLimit = 8
    private static let browserLimit = 6
    private static let fileLimit = 6
    private static let recentLimit = 5
    private static let titleCap = 90

    /// Prompt lines for the current query, or `[]` when nothing matched — an empty
    /// evidence block is itself signal, and the rules tell the model to say so rather
    /// than fill the gap from memory.
    static func promptLines(query: String) -> [String] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Below 2 characters every index degenerates to "everything", which is noise, not
        // evidence.
        guard raw.count >= 2 else { return [] }

        var apps: [String] = []
        var menus: [String] = []
        var browser: [String] = []
        var commands: [String] = []

        // One ranked pass over the shared index. Order is preserved end-to-end so "row 1"
        // in the prompt is the same row the launcher would put first.
        let documents = GlobalSearchService.shared.query(
            raw,
            limit: 48,
            includeCachedMenus: true,
            includeRunningCachedMenus: true
        )
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
                .map { $0.lowercased() }
        )

        for doc in documents {
            switch doc.action {
            case .cachedMenu(_, let appName, let path, let shortcutChar, _):
                guard menus.count < menuLimit else { continue }
                let trail = path.filter { !$0.isEmpty }.joined(separator: " ▸ ")
                let shortcut = (shortcutChar?.isEmpty == false) ? "  [⌘\(shortcutChar!)]" : ""
                menus.append("\(appName): \(trail.isEmpty ? doc.title : trail)\(shortcut)")

            case .browserURL(let url, _, let browserName, let kind, _):
                guard browser.count < browserLimit else { continue }
                browser.append(
                    "\(clip(doc.title)) — \(url.absoluteString) (\(browserName) \(kind))")

            case .systemCommandScope:
                guard commands.count < 4 else { continue }
                commands.append("\(doc.title) (DoraX Global Command)")

            case .cliScope(let command, let displayName):
                guard commands.count < 4 else { continue }
                commands.append("\(displayName) (CLI tool `\(command)`)")

            case .adapterAction(_, let appName, _):
                guard commands.count < 4 else { continue }
                commands.append("\(doc.title) (\(appName) action you added in App Adapters)")

            case .launchPath, .launchBundleId, .activatePID:
                guard apps.count < appLimit else { continue }
                let state = running.contains(doc.bundleId.lowercased()) ? "running" : "installed"
                apps.append("\(doc.title) (\(state)\(doc.bundleId.isEmpty ? "" : ", \(doc.bundleId)"))")
            }
        }

        // Recent Documents is a list, not a search index — filter it by the query tokens so
        // the block stays about this question.
        let tokens = raw.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
        var recents: [String] = []
        if !tokens.isEmpty {
            for doc in RecentItemsService.shared.recentDocuments() {
                guard recents.count < recentLimit else { break }
                let name = doc.name.lowercased()
                guard tokens.contains(where: { name.contains($0) }) else { continue }
                recents.append("\(doc.name) — \(doc.url.path)")
            }
        }

        var files: [String] = []
        for result in FileIndexManager.shared.search(query: raw, limit: fileLimit) {
            let path = result.filePath ?? result.subtitle
            files.append(path.isEmpty ? result.title : "\(result.title) — \(path)")
        }

        let sections: [(String, [String])] = [
            ("Apps on this Mac", apps),
            ("Cached app menu commands", menus),
            ("Browser history / bookmarks", browser),
            ("DoraX commands and CLI tools", commands),
            ("Recently opened documents", recents),
            ("Indexed files and folders", files),
        ]
        let populated = sections.filter { !$0.1.isEmpty }
        guard !populated.isEmpty else {
            return [
                "",
                "LOCAL EVIDENCE for this question: DoraX searched its indexes (apps, cached "
                    + "app menus, browser history, recent documents, indexed files) and found "
                    + "no matching rows.",
                "Say that nothing matched and name what you searched. Do NOT answer an "
                    + "app/file/menu question from general knowledge — an invented menu item or "
                    + "file path is worse than \"I couldn't find it\".",
            ]
        }

        var lines: [String] = [
            "",
            "LOCAL EVIDENCE — retrieved from DoraX's own indexes for THIS question, best "
                + "match first:",
        ]
        for (title, rows) in populated {
            lines.append("\(title):")
            for (index, row) in rows.enumerated() {
                lines.append("  \(index + 1). \(clip(row))")
            }
        }
        lines.append(contentsOf: [
            "How to use this evidence:",
            "- These rows are the ground truth about this Mac. They outrank anything you "
                + "recall about how an app works — a cached menu path from this index is real, "
                + "your memory of that app's menus may be from a different version.",
            "- Rank order is meaningful: row 1 is the closest match. Lead with it.",
            "- Name the row you used (the app, the menu path, the file, the URL) so the user "
                + "can verify the answer.",
            "- Never invent an app, menu item, shortcut, file path, or URL that is not listed "
                + "above. If the evidence doesn't answer the question, say what was searched and "
                + "that it wasn't found, then offer the closest listed row.",
            "- Absence of a row is not proof the thing doesn't exist — the index covers "
                + "installed apps, cached menus, browser history and indexed files, so say "
                + "\"not in the index\" rather than \"doesn't exist\".",
        ])
        return lines
    }

    private static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > titleCap ? String(flat.prefix(titleCap)) + "…" : flat
    }
}
