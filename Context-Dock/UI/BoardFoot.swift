// BoardFoot.swift
// Context-Dock
//
// What the result board's foot says, as Raycast's does (owner 2026-10-14): on the left what
// Return is about to act on — its icon and its kind — and on the right what Return does to it.
// Both follow the arrows. One answer, read from the row, so the foot cannot disagree with the
// row or with the preview beside it.

import AppKit

struct BoardFoot: Equatable {
    /// What the row is: "Calculator · Menu", "Application", "Folder".
    var title: String
    /// What Return does: "Run", "Open", "Quit", "Ask AI".
    var verb: String
    /// The app the row belongs to, for its icon; empty when the row has none.
    var bundleID: String = ""
    /// The file the row stands for, for its icon.
    var fileURL: URL? = nil
    /// The symbol drawn when there is neither.
    var symbol: String = "sparkle"
    /// An app that is open now: its row says ● Running instead of its kind.
    var isRunningApp: Bool = false

    /// The kind alone — "Menu", "Application", "Web page" — what a row says on its right
    /// (#258 G2), the same word the foot ends with.
    var kind: String { title.components(separatedBy: " · ").last ?? title }

    /// The foot for the row Return takes. Nil row: nothing will run but the question, so the
    /// foot names the scope and Return asks AI.
    static func foot(
        for row: AppChatRow?, scopeName: String, scopeBundleID: String, isGlobal: Bool,
        cliCommand: String = "",
        lookup: (String) -> GlobalSearchService.SearchDocument? = { _ in nil }
    ) -> BoardFoot {
        guard let row else {
            return BoardFoot(
                title: scopeName, verb: "Ask AI",
                bundleID: isGlobal ? "" : scopeBundleID,
                symbol: isGlobal ? "globe" : "sparkle")
        }
        switch row {
        case .command(let item):
            let app = item.sourceAppName.isEmpty ? scopeName : item.sourceAppName
            return BoardFoot(
                title: "\(app) · Menu",
                verb: MenuExecutionCoordinator.isQuitMenuPath(item.path) ? "Quit" : "Run",
                // A Global row carries its own app (`runMenuItem`).
                bundleID: item.sourcePID != 0
                    ? NSRunningApplication(processIdentifier: item.sourcePID)?.bundleIdentifier
                        ?? scopeBundleID
                    : scopeBundleID,
                symbol: "filemenu.and.selection")
        case .action:
            return BoardFoot(
                title: "\(scopeName) · Action", verb: "Run", bundleID: scopeBundleID,
                symbol: "bolt")
        case .file(let url):
            return fileFoot(url)
        case .cliSuggestion:
            return BoardFoot(
                title: cliCommand.isEmpty ? "Subcommand" : "\(cliCommand) · Subcommand",
                verb: "Run", symbol: "terminal")
        case .app(let entry):
            return appFoot(entry.bundleId)
        case .global(let doc):
            return foot(for: CornerBoardLayout.preview(for: doc), fallbackTitle: doc.title)
        case .dock(let pill):
            switch pill.rankingKind {
            case GlobalFallbacks.askKind:
                return BoardFoot(title: "Ask AI", verb: "Ask", symbol: "sparkles")
            case GlobalFallbacks.webKind:
                return BoardFoot(title: "Web search", verb: "Search", symbol: "globe")
            case GlobalFallbacks.terminalKind:
                return BoardFoot(
                    title: "Terminal", verb: "Run", bundleID: "com.apple.Terminal",
                    symbol: "terminal")
            default: break
            }
            if MenuExecutionCoordinator.isQuitMenuPath([pill.name]) {
                return BoardFoot(
                    title: pill.sourceAppName.isEmpty ? "Running App" : "\(pill.sourceAppName) · Running",
                    verb: "Quit", bundleID: pill.sourceBundleId, symbol: "xmark.circle")
            }
            let preview = CornerBoardLayout.preview(
                for: row, appName: scopeName, appBundleID: scopeBundleID, lookup: lookup)
            var foot = foot(for: preview, fallbackTitle: "Command")
            if foot.bundleID.isEmpty, foot.fileURL == nil { foot.bundleID = pill.sourceBundleId }
            return foot
        }
    }

    /// The foot for what the preview panel shows, so the two say the same thing.
    private static func foot(for preview: CornerBoardPreview?, fallbackTitle: String) -> BoardFoot {
        switch preview {
        case .file(let url):
            return fileFoot(url)
        case .app(let bundleID, _), .appScope(let bundleID, _):
            return appFoot(bundleID)
        case .command(_, _, let appName, let bundleID):
            return BoardFoot(
                title: appName.isEmpty ? "Menu" : "\(appName) · Menu", verb: "Run",
                bundleID: bundleID, symbol: "filemenu.and.selection")
        case .cliTool(_, let name):
            return BoardFoot(title: "\(name) · Command-line tool", verb: "Open", symbol: "terminal")
        case .cliSubcommand(let command, _):
            return BoardFoot(title: "\(command) · Subcommand", verb: "Run", symbol: "terminal")
        case .systemCommand:
            return BoardFoot(title: "Command", verb: "Run", symbol: "command")
        case .web(_, _, let domain, _):
            return BoardFoot(
                title: domain.isEmpty ? "Web page" : "\(domain) · Web page", verb: "Open",
                symbol: "safari")
        case .windowLayout(_, _, let appName, let bundleID):
            return BoardFoot(
                title: appName.isEmpty ? "Window layout" : "\(appName) · Window layout",
                verb: "Arrange", bundleID: bundleID, symbol: "rectangle.split.2x1")
        case nil:
            return BoardFoot(title: fallbackTitle, verb: "Run", symbol: "command")
        }
    }

    /// A running app comes forward, as its preview says; a closed one opens.
    private static func appFoot(_ bundleID: String) -> BoardFoot {
        let running = AppResultActions.runningApp(bundleID) != nil
        return BoardFoot(
            title: "Application", verb: running ? "Bring forward" : "Open",
            bundleID: bundleID, isRunningApp: running)
    }

    private static func fileFoot(_ url: URL) -> BoardFoot {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        return BoardFoot(title: isFolder ? "Folder" : "File", verb: "Open", fileURL: url)
    }

    /// The icon: the file's own, the app's own, or nil for the symbol.
    var icon: NSImage? {
        if let fileURL { return NSWorkspace.shared.icon(forFile: fileURL.path) }
        guard !bundleID.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

extension AppChatPromptModel {
    /// What one row is, in the foot's words — read by the row's status on its right.
    func foot(for row: AppChatRow) -> BoardFoot {
        BoardFoot.foot(
            for: row, scopeName: isGlobalScope ? Self.globalScopeName : appName,
            scopeBundleID: appBundleID, isGlobal: isGlobalScope, cliCommand: cliCommand,
            lookup: searchDocumentLookup)
    }

    /// The row Return takes — the highlighted one, else the top one (the list draws that
    /// row as chosen) — read by the board's foot.
    var boardFoot: BoardFoot {
        let row = showsAskAIRow ? focusedRow : (focusedRow ?? rows.first)
        return BoardFoot.foot(
            for: row, scopeName: isGlobalScope ? Self.globalScopeName : appName,
            scopeBundleID: appBundleID, isGlobal: isGlobalScope, cliCommand: cliCommand,
            lookup: searchDocumentLookup)
    }
}
