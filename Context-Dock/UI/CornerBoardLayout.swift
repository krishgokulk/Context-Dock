// CornerBoardLayout.swift
// Context-Dock
//
// The split result board (#191): one card over the field, at the field's own width, with the
// list in its left half and whatever row is highlighted in its right — a file's preview, an
// app, a menu command — the way Raycast lays a list beside its detail (owner 2026-10-05:
// "not a separate card, inside the same window").
//
// One board in the one shell, two columns: not a second window and not a second floating
// container (Unified Dock Surface rule). Pure, like every other corner size, because the
// corner draws this frame and hit-tests the same number.

import CoreGraphics
import Foundation

/// What the side panel shows for the highlighted row.
enum CornerBoardPreview: Hashable {
    /// A file, an image, a document or a folder.
    case file(URL)
    /// An application.
    case app(bundleID: String, name: String)
    /// A menu command: where it lives in its app's menus.
    case command(title: String, path: [String], appName: String, bundleID: String)
    /// A command-line tool: what it is, where it lives, its subcommands and its own help.
    case cliTool(command: String, name: String)
    /// One of a CLI tool's subcommands, inside that tool's scope: the tool's help for it.
    case cliSubcommand(command: String, subcommand: String)
    /// A Global Command: what it does and the script it runs.
    case systemCommand(id: String, name: String)
    /// A web page from the browser's history or tabs: the page itself, previewed.
    case web(url: URL, title: String, domain: String, browserName: String)
}

enum CornerBoardLayout {
    /// The list's share of the card while a preview shows.
    static let listFraction: CGFloat = 0.5
    /// The hairline between the two halves.
    static let dividerWidth: CGFloat = 1
    /// The least height the card keeps while a preview shows, so a short list still leaves
    /// the preview room to read.
    static let minimumPreviewHeight: CGFloat = 280

    /// The list's column: the whole card, or its left half beside a preview.
    static func listWidth(board: CGFloat, preview: CornerBoardPreview?) -> CGFloat {
        preview == nil ? board : (board * listFraction).rounded()
    }

    /// The preview's column: what the list and the hairline leave.
    static func panelWidth(board: CGFloat) -> CGFloat {
        board - listWidth(board: board, preview: .file(URL(fileURLWithPath: "/"))) - dividerWidth
    }

    /// What the panel shows for this row, or nil when it has nothing worth a panel — an
    /// action, a CLI subcommand, a row nothing resolves for. Nil also when no row is
    /// highlighted: the panel follows the arrows, it does not guess.
    ///
    /// `lookup` resolves a Global row's search document by id (the model's own
    /// `searchDocumentLookup`), so a test can hand it documents without the index.
    static func preview(
        for row: AppChatRow?, appName: String = "", appBundleID: String = "",
        cliCommand: String = "",
        lookup: (String) -> GlobalSearchService.SearchDocument? = { _ in nil }
    ) -> CornerBoardPreview? {
        guard let row else { return nil }
        switch row {
        case .file(let url):
            return .file(url)
        case .global(let doc):
            return preview(for: doc)
        case .dock(let pill):
            if let path = pill.previewPath, !path.isEmpty {
                return .file(URL(fileURLWithPath: path))
            }
            if let id = pill.searchDocumentID, let doc = lookup(id) {
                return preview(for: doc)
            }
            return nil
        case .command(let item):
            return .command(
                title: item.title, path: item.path,
                appName: item.sourceAppName.isEmpty ? appName : item.sourceAppName,
                bundleID: appBundleID)
        case .cliSuggestion(let word):
            // A subcommand is only a subcommand inside its tool's scope.
            guard !cliCommand.isEmpty else { return nil }
            return .cliSubcommand(command: cliCommand, subcommand: word)
        case .action:
            return nil
        }
    }

    /// A Global result: the file it stands for, the app it opens, or the command it runs.
    static func preview(for doc: GlobalSearchService.SearchDocument) -> CornerBoardPreview? {
        // What the row *is* comes first: a CLI tool's document may carry its binary's path,
        // and a tool is not previewed as a file.
        switch doc.action {
        case .cliScope(let command, let displayName):
            return .cliTool(command: command, name: displayName.isEmpty ? command : displayName)
        case .systemCommandScope(let key):
            return .systemCommand(id: key, name: doc.title)
        case .browserURL(let url, _, let browserName, _, let domain):
            return .web(url: url, title: doc.title, domain: domain, browserName: browserName)
        default:
            break
        }
        if let path = doc.filePath, !path.isEmpty, !path.hasSuffix(".app") {
            return .file(URL(fileURLWithPath: path))
        }
        switch doc.action {
        case .launchPath(let path) where !path.hasSuffix(".app"):
            return .file(URL(fileURLWithPath: path))
        case .launchBundleId(let bundleID, _), .activatePID(_, let bundleID, _):
            return .app(bundleID: bundleID, name: doc.title)
        case .launchPath:
            return doc.bundleId.isEmpty ? nil : .app(bundleID: doc.bundleId, name: doc.title)
        case .cachedMenu(let bundleID, let appName, let path, _, _):
            return .command(
                title: path.last ?? doc.title, path: path, appName: appName, bundleID: bundleID)
        default:
            return nil
        }
    }

    /// The help's lines that name this subcommand as a word, each with the line under it
    /// when that line is indented deeper — a description continued, not the next entry.
    static func helpLines(mentioning subcommand: String, in help: String) -> [String] {
        let lines = help.components(separatedBy: .newlines)
        var picked: [String] = []
        for (index, line) in lines.enumerated() {
            let words = line.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            guard words.contains(where: { $0 == subcommand }) else { continue }
            picked.append(line)
            if index + 1 < lines.count {
                let next = lines[index + 1]
                if !next.trimmingCharacters(in: .whitespaces).isEmpty,
                    indent(of: next) > indent(of: line), !picked.contains(next)
                {
                    picked.append(next)
                }
            }
            if picked.count >= 12 { break }
        }
        return picked
    }

    private static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).count
    }

    /// The whole card: always the list's width — the field's — and, while a preview shows,
    /// at least tall enough for it.
    static func boardSize(list: CGSize, preview: CornerBoardPreview?) -> CGSize {
        guard preview != nil else { return list }
        return CGSize(width: list.width, height: max(list.height, minimumPreviewHeight))
    }
}

// MARK: - The Context Dock's live panel (#191, part 2)

/// An app's Context Dock keeps a panel beside its conversation, the way Claude keeps its
/// Progress and Context panel beside a chat (owner 2026-10-05): what DoraX is doing in the
/// app — the steps as they run, a command's output — and what the turn left behind: the
/// files it made or named, the uploads it was given, the connectors and the adapter it can
/// reach. A toggle in the header hides it; it stays put across turns.
enum CornerLivePanelLayout {
    /// The panel's share of the chat card. The conversation keeps the larger part, as in
    /// Claude.
    static let panelFraction: CGFloat = 0.42

    /// The panel's width in a chat card this wide.
    static func panelWidth(card: CGFloat) -> CGFloat {
        (card * panelFraction).rounded()
    }

    /// Whether the chat card shows the panel. Only an app's Context Dock (Global's results
    /// have their own preview, General is its own surface), only in its conversation, only
    /// while the user has it open, and only once there is a turn to show.
    static func shows(
        isAppScope: Bool, phase: AppChatPromptPhase, isOpen: Bool, hasConversation: Bool
    ) -> Bool {
        isAppScope && phase == .chat && isOpen && hasConversation
    }

    /// The steps the panel lists: the turn running now, or the last one that finished.
    static func steps(
        isAnswering: Bool, live: [ActivityStep], finished: [ActivityStep]
    ) -> [ActivityStep] {
        isAnswering ? live : finished
    }

    /// Everything the user attached in this conversation, oldest first, each once.
    static func uploads(_ attachments: [[URL]]) -> [URL] {
        var seen: Set<String> = []
        return attachments.flatMap { $0 }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// How many of the output's last lines the panel quotes.
    static let outputLines = 14

    /// A command's output as the panel quotes it: its last `lines` non-empty-trailing lines,
    /// because the end is what a running command just said.
    static func outputTail(_ output: String, lines: Int = outputLines) -> String {
        var all = output.components(separatedBy: .newlines)
        while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            all.removeLast()
        }
        guard all.count > lines else { return all.joined(separator: "\n") }
        return "…\n" + all.suffix(lines).joined(separator: "\n")
    }

    /// The step whose output the panel shows: the latest shell command — the one running
    /// now, or the last one that said something.
    static func terminalStep(in steps: [ActivityStep]) -> ActivityStep? {
        let shells = steps.filter { $0.kind == .command || $0.kind == .providerShell }
        return shells.last { $0.status == .running } ?? shells.last { !$0.output.isEmpty }
            ?? shells.last
    }

    /// The connectors in play: the MCP servers linked to this app, then any other server
    /// this turn called, each named once.
    static func connectors(linked: [String], steps: [ActivityStep]) -> [String] {
        var names: [String] = []
        for name in linked + steps.filter({ $0.kind == .mcp }).map(server(of:))
        where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        return names
    }

    /// The server an MCP step called: "Ran search via github" → "github"; a step that does
    /// not name its server is named by its tool.
    static func server(of step: ActivityStep) -> String {
        if let via = step.title.range(of: " via ", options: .backwards) {
            return String(step.title[via.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let title = step.title.hasPrefix("Ran ") ? String(step.title.dropFirst(4)) : step.title
        return title.trimmingCharacters(in: .whitespaces)
    }
}

extension AppChatPromptModel {
    /// The side panel for the row the arrows are on (#191). Read by the board that draws it
    /// and by the window that hit-tests it, so the two are one answer.
    var boardPreview: CornerBoardPreview? {
        CornerBoardLayout.preview(
            for: focusedRow, appName: appName, appBundleID: appBundleID,
            cliCommand: cliCommand, lookup: searchDocumentLookup)
    }

    /// The list card and its panel together: the size the window reserves for the board.
    var boardSize: CGSize {
        CornerBoardLayout.boardSize(
            list: AppChatListMetrics.size(
                rows: listRowCount, width: AppChatPromptMetrics.boardWidth(for: self)),
            preview: boardPreview)
    }

    /// The Context Dock's panel shows (#191, part 2). Read by the card that draws it.
    var showsLivePanel: Bool {
        CornerLivePanelLayout.shows(
            isAppScope: !isGlobalScope, phase: phase, isOpen: livePanelOpen,
            hasConversation: isAnswering || !messages.isEmpty)
    }
}
