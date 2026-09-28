// Context-DockTests/CornerRemainingScopesTests.swift
//
// Task 7 (inventory D4–D5): in the Corner's Global results the rows are the Dock's own pills,
// and a Global Command's pill ran the command outright ("Sleep" from ↩). A pill whose search
// document is a scope — a command, an extension, a CLI tool — steps into it in the Corner's
// board instead, from ↩ and from →.

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

