// Context-DockTests/CornerRemainingScopesTests.swift
//
// Task 7 (inventory D4–D5): in the Corner's Global results the rows are the Dock's own pills,
// and a Global Command's pill ran the command outright ("Sleep" from ↩). A pill whose search
// document is a scope — a command, an extension, a CLI tool — steps into it in the Corner's
// board instead, from ↩ and from →.

import AppKit
import Foundation
import Testing

@testable import Context_Dock

@MainActor
private func document(
    _ title: String, _ action: GlobalSearchService.ActionSpec
) -> GlobalSearchService.SearchDocument {
    GlobalSearchService.SearchDocument(
        id: "doc-\(title)", title: title, subtitle: "", bundleId: "", filePath: nil,
        normalizedTitle: title.lowercased(), titleWords: [title.lowercased()],
        acronym: String(title.prefix(1)), aliases: [], aliasWords: [], sourceKind: .cli,
        rankingBoost: 0, icon: nil, usageTrackingKey: title, action: action)
}

@Suite("Corner remaining scopes")
@MainActor
struct CornerRemainingScopesTests {

    private final class Ran { var value = false }

    private func pill(_ doc: GlobalSearchService.SearchDocument?, ran: Ran) -> DockPill {
        var pill = DockPill(
            id: "global-result-\(doc?.title ?? "x")", name: doc?.title ?? "x", icon: "app",
            badge: "", execute: { ran.value = true })
        pill.searchDocumentID = doc?.id
        return pill
    }

    @Test("A Dock row finds its scope only for commands, extensions and tools")
    func scopeDocumentKinds() {
        let command = document("Sleep", .systemCommandScope(commandKey: UUID().uuidString))
        let ext = document("Currency", .userExtension(id: UUID()))
        let cli = document("git", .cliScope(command: "git", displayName: "git"))
        let app = document("Calculator", .launchPath("/System/Applications/Calculator.app"))
        let all = [command, ext, cli, app]
        let lookup: (String) -> GlobalSearchService.SearchDocument? = { id in
            all.first { $0.id == id }
        }
        let ran = Ran()
        #expect(AppChatPromptModel.scopeDocument(for: pill(command, ran: ran), lookup: lookup)?.id == command.id)
        #expect(AppChatPromptModel.scopeDocument(for: pill(ext, ran: ran), lookup: lookup)?.id == ext.id)
        #expect(AppChatPromptModel.scopeDocument(for: pill(cli, ran: ran), lookup: lookup)?.id == cli.id)
        #expect(AppChatPromptModel.scopeDocument(for: pill(app, ran: ran), lookup: lookup) == nil)
        #expect(AppChatPromptModel.scopeDocument(for: pill(nil, ran: ran), lookup: lookup) == nil)
    }

    @Test("↩ on a Global Command's Dock row never runs the command (D4)")
    func returnDoesNotRunTheCommand() {
        let command = document("Sleep", .systemCommandScope(commandKey: UUID().uuidString))
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.searchDocumentLookup = { $0 == command.id ? command : nil }
        model.summonGlobalContext()
        let ran = Ran()
        model.rows = [.dock(pill(command, ran: ran))]
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.runFocusedRow())
        #expect(!ran.value)
    }

    @Test("→ on a CLI tool's Dock row steps into the tool (D4–D5 path)")
    func rightArrowStepsIntoTheTool() {
        let cli = document("git", .cliScope(command: "git", displayName: "git"))
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.searchDocumentLookup = { $0 == cli.id ? cli : nil }
        model.summonGlobalContext()
        let ran = Ran()
        model.rows = [.dock(pill(cli, ran: ran))]
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.stepIntoFocusedRow())
        #expect(!ran.value)
        #expect(model.isCLIScope)
        #expect(model.cliCommand == "git")
    }

    @Test("An ordinary Dock row still runs the Dock's own closure")
    func ordinaryRowsRun() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.searchDocumentLookup = { _ in nil }
        model.summonGlobalContext()
        let ran = Ran()
        model.rows = [.dock(pill(nil, ran: ran))]
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.runFocusedRow())
        #expect(ran.value)
    }

    // MARK: D7 — Finder's front folder

    @Test("Only an existing folder is attachable")
    func finderFolderToAttach() {
        #expect(AppChatPromptModel.finderFolderToAttach(path: NSTemporaryDirectory()) != nil)
        #expect(AppChatPromptModel.finderFolderToAttach(path: "  ") == nil)
        #expect(AppChatPromptModel.finderFolderToAttach(path: nil) == nil)
        #expect(AppChatPromptModel.finderFolderToAttach(path: "/nonexistent/folder") == nil)
        #expect(AppChatPromptModel.finderFolderToAttach(path: "/bin/ls") == nil)  // a file
    }

    @Test("In Finder, the front window's folder is attached once; elsewhere never (D7)")
    func attachFrontFinderFolder() {
        let folder = FileManager.default.temporaryDirectory
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Finder", bundleID: "com.apple.finder")
        #expect(model.attachFrontFinderFolder(read: { folder.path }))
        #expect(model.attachments == [folder.standardizedFileURL])
        #expect(!model.attachFrontFinderFolder(read: { folder.path }))  // not twice
        #expect(model.attachments.count == 1)

        let other = AppChatPromptModel(conversation: AppChatConversation())
        other.summon(app: "brew", bundleID: "cli://brew")
        #expect(!other.attachFrontFinderFolder(read: { folder.path }))
        #expect(other.attachments.isEmpty)
    }
}


@Suite("Corner Finder in front and window layouts")
@MainActor
struct CornerFinderMenusAndLayoutsTests {

    @Test("Finder lists its menus in front and from Global; inside a folder, that folder")
    func finderModes() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Finder", bundleID: "com.apple.finder")
        #expect(model.isFinderScope)
        #expect(!model.isFinderFileSearch)
        model.finderBrowseStack = [FileManager.default.temporaryDirectory]
        #expect(model.isFinderFileSearch)
        model.finderBrowseStack = []

        let scoped = AppChatPromptModel(conversation: AppChatConversation())
        scoped.summonGlobalContext()
        scoped.scopeIntoApp(name: "Finder", bundleID: "com.apple.finder")
        #expect(!scoped.isFinderFileSearch)
        #expect(scoped.finderSkipsLiveMenus)
        #expect(!model.finderSkipsLiveMenus)
    }

    @Test("The Dock's window layouts lead the app's rows while typing")
    func windowLayoutsLead() {
        let source = GlobalContextResultSource.shared
        let saved = source.windowLayoutResults
        defer { source.windowLayoutResults = saved }
        var asked: (String, String, String)?
        source.windowLayoutResults = { query, bundleID, appName in
            asked = (query, bundleID, appName)
            return [DockPill(id: "native-window-quarters", name: "Quarters", icon: "rectangle.split.2x2",
                             badge: "Window", execute: {})]
        }
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Claude", bundleID: "com.anthropic.claudefordesktop")
        model.query = "ar"
        model.queryChanged()
        #expect(asked?.0 == "ar")
        #expect(asked?.1 == "com.anthropic.claudefordesktop")
        // Only a switch-to-app row ("ar" also matches a running Safari) may stand before them.
        let lead = model.rows.drop { row in
            if case .dock(let pill) = row { return pill.rankingKind == "appSwitch" }
            return false
        }
        #expect(lead.first?.title == "Quarters")
    }

    @Test("A Window-menu command a layout covers gives way to the layout, as in the Dock")
    func layoutsReplaceTheirMenuCommands() {
        let source = GlobalContextResultSource.shared
        let saved = source.windowLayoutResults
        defer { source.windowLayoutResults = saved }
        source.windowLayoutResults = { _, _, _ in
            [DockPill(id: "native-window-center", name: "Centre", icon: "rectangle.center.inset.filled",
                      badge: "Window", execute: {})]
        }
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summon(app: "Claude", bundleID: "com.anthropic.claudefordesktop")
        model.allMenuItems = [
            AXMenuItem(title: "Centre", path: ["Window", "Centre"], isEnabled: true,
                       element: AXUIElementCreateSystemWide(), children: []),
            AXMenuItem(title: "Center Text", path: ["Format", "Center Text"], isEnabled: true,
                       element: AXUIElementCreateSystemWide(), children: []),
        ]
        model.query = "cen"
        model.updateMenuMatches()
        #expect(model.rows.first?.title == "Centre")
        #expect(!model.rows.contains { if case .command(let item) = $0 { return item.path == ["Window", "Centre"] }; return false })
        #expect(model.rows.contains { $0.title == "Center Text" })
    }
}

