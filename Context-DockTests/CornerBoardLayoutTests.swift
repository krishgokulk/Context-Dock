// Context-DockTests/CornerBoardLayoutTests.swift
//
// The split result board (#191): the list stays over the field at the field's width, and the
// highlighted row's panel opens beside it — a file's preview, an app, a menu command.

import AppKit
import Foundation
import Testing

@testable import Context_Dock

@Suite("Split result board")
@MainActor
struct CornerBoardLayoutTests {
    typealias L = CornerBoardLayout

    private func doc(
        _ id: String, title: String = "T", bundleId: String = "", filePath: String? = nil,
        action: GlobalSearchService.ActionSpec
    ) -> GlobalSearchService.SearchDocument {
        GlobalSearchService.SearchDocument(
            id: id, title: title, subtitle: "", bundleId: bundleId, filePath: filePath,
            normalizedTitle: title.lowercased(), titleWords: [title.lowercased()],
            acronym: "t", aliases: [], aliasWords: [], sourceKind: .installed,
            rankingBoost: 0, icon: nil, usageTrackingKey: id, action: action)
    }

    @Test("No highlighted row, no panel")
    func nothingHighlightedShowsNoPanel() {
        #expect(L.preview(for: nil) == nil)
        let list = CGSize(width: 600, height: 230)
        #expect(L.boardSize(list: list, preview: nil) == list)
        #expect(L.listWidth(board: 600, preview: nil) == 600)
    }

    @Test("A file, a folder and an image preview as files")
    func filesPreviewAsFiles() {
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        #expect(L.preview(for: .file(file)) == .file(file))
        let folder = URL(fileURLWithPath: "/Users/x/Documents")
        #expect(L.preview(for: .file(folder)) == .file(folder))
        // A Global result standing for a file.
        let image = doc("img", filePath: "/tmp/photo.png", action: .launchPath("/tmp/photo.png"))
        #expect(L.preview(for: .global(image)) == .file(URL(fileURLWithPath: "/tmp/photo.png")))
        // A Dock row whose path is a file.
        var pill = DockPill(id: "p", name: "notes.md", icon: "doc", badge: nil, execute: {})
        pill.previewPath = "/tmp/notes.md"
        #expect(L.preview(for: .dock(pill)) == .file(URL(fileURLWithPath: "/tmp/notes.md")))
    }

    @Test("An app previews as the app, never as its bundle on disk")
    func appsPreviewAsApps() {
        let safari = doc(
            "com.apple.Safari", title: "Safari", bundleId: "com.apple.Safari",
            filePath: "/Applications/Safari.app",
            action: .launchBundleId("com.apple.Safari", path: "/Applications/Safari.app"))
        #expect(L.preview(for: .global(safari)) == .app(bundleID: "com.apple.Safari", name: "Safari"))
        let running = doc(
            "run", title: "Notes",
            action: .activatePID(42, bundleId: "com.apple.Notes", path: nil))
        #expect(L.preview(for: .global(running)) == .app(bundleID: "com.apple.Notes", name: "Notes"))
        // The Corner's Global rows are the Dock's pills: resolved through their document.
        var pill = DockPill(id: "d", name: "Safari", icon: "app", badge: nil, execute: {})
        pill.searchDocumentID = "com.apple.Safari"
        #expect(
            L.preview(for: .dock(pill), lookup: { $0 == "com.apple.Safari" ? safari : nil })
                == .app(bundleID: "com.apple.Safari", name: "Safari"))
    }

    @Test("A menu command previews as where it lives")
    func commandsPreviewTheirPath() {
        let menu = doc(
            "m", title: "Duplicate",
            action: .cachedMenu(
                bundleId: "com.apple.TextEdit", appName: "TextEdit",
                path: ["File", "Duplicate"], shortcutChar: "s", shortcutModifiers: 1))
        #expect(
            L.preview(for: .global(menu))
                == .command(
                    title: "Duplicate", path: ["File", "Duplicate"], appName: "TextEdit",
                    bundleID: "com.apple.TextEdit"))
    }

    @Test("Rows with nothing to show take no panel")
    func actionsTakeNoPanel() {
        // A subcommand outside its tool's scope is just a word.
        #expect(L.preview(for: .cliSuggestion("status")) == nil)
        let bare = DockPill(id: "b", name: "Sleep", icon: "moon", badge: nil, execute: {})
        #expect(L.preview(for: .dock(bare)) == nil)
    }

    @Test("A CLI tool, a Global Command and a web page each get their card")
    func toolsCommandsAndPagesPreview() {
        // A tool's document may carry its binary's path; it is still the tool.
        let brew = doc(
            "cli://brew", title: "brew", filePath: "/opt/homebrew/bin/brew",
            action: .cliScope(command: "brew", displayName: ""))
        #expect(L.preview(for: .global(brew)) == .cliTool(command: "brew", name: "brew"))
        // Inside the tool's scope, a subcommand row is that subcommand's help.
        #expect(
            L.preview(for: .cliSuggestion("up"), cliCommand: "tailscale")
                == .cliSubcommand(command: "tailscale", subcommand: "up"))
        let sleep = doc("syscmd://1", title: "Sleep", action: .systemCommandScope(commandKey: "1"))
        #expect(L.preview(for: .global(sleep)) == .systemCommand(id: "1", name: "Sleep"))
        let page = URL(string: "https://github.com/krishgokulk/Context-Dock/pull/190")!
        let tab = doc(
            "web", title: "Task 189",
            action: .browserURL(
                url: page, browserBundleId: "com.apple.Safari", browserName: "Safari",
                kind: "history", domain: "github.com"))
        #expect(
            L.preview(for: .global(tab))
                == .web(url: page, title: "Task 189", domain: "github.com", browserName: "Safari"))
    }

    @Test("A subcommand's card quotes the tool's help lines that name it")
    func helpLinesForASubcommand() {
        let help = """
            Usage: tailscale [flags] <subcommand>

            Subcommands:
              up          Connect to Tailscale, logging in if needed
              down        Disconnect from Tailscale
              update      Update Tailscale to the latest version
            """
        // Its own line, not the next entry and not "update", which only contains it.
        let up = L.helpLines(mentioning: "up", in: help)
        #expect(up.count == 1)
        #expect(up.first?.contains("Connect to Tailscale") == true)
        // A description continued on a deeper-indented line comes with it.
        let wrapped = "  login       Log in\n                to a tailnet\n  logout      Log out"
        #expect(L.helpLines(mentioning: "login", in: wrapped).count == 2)
        #expect(L.helpLines(mentioning: "down", in: help).first?.contains("Disconnect") == true)
        #expect(L.helpLines(mentioning: "frobnicate", in: help).isEmpty)
    }

    @Test("One card at the field's width: the list on the left, the preview on the right")
    func thePreviewSharesTheCard() {
        let list = CGSize(width: 600, height: 120)
        let preview = CornerBoardPreview.file(URL(fileURLWithPath: "/tmp/a.pdf"))
        let board = L.boardSize(list: list, preview: preview)
        // Never wider than the field: one card, split, not a second card beside it.
        #expect(board.width == list.width)
        // A short list still leaves the preview room to read.
        #expect(board.height == L.minimumPreviewHeight)
        #expect(L.boardSize(list: CGSize(width: 600, height: 400), preview: preview).height == 400)
        // The halves and the hairline add up to the card.
        let left = L.listWidth(board: board.width, preview: preview)
        #expect(left == 300)
        #expect(left + L.dividerWidth + L.panelWidth(board: board.width) == board.width)
    }

    @Test("The model's panel follows the arrows and the window reserves the same board")
    func theModelFollowsTheHighlight() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        #expect(model.boardPreview == nil)
        #expect(model.boardSize == AppChatListMetrics.size(
            rows: model.listRowCount, width: AppChatPromptMetrics.boardWidth(for: model)))
    }
}
