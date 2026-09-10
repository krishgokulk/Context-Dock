// CornerCLIScopeTests.swift
// Context-DockTests
//
// Arrowing down to a CLI tool and pressing Tab or → did nothing: both keys ignored the
// focused row — Tab acted on the top match, → completed the ghost — so the row under the
// highlight was the one thing neither of them could take.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
private func cliDocument(_ command: String) -> GlobalSearchService.SearchDocument {
    GlobalSearchService.SearchDocument(
        id: "cli://\(command)", title: command, subtitle: "cli://\(command)",
        bundleId: "cli://\(command)", filePath: nil, normalizedTitle: command,
        titleWords: [command], acronym: String(command.prefix(1)), aliases: [], aliasWords: [],
        sourceKind: .cli, rankingBoost: 0, icon: nil, usageTrackingKey: "cli:\(command)",
        action: .cliScope(command: command, displayName: command))
}

@Suite("Corner CLI scope")
@MainActor
struct CornerCLIScopeTests {

    private func globalModel() -> AppChatPromptModel {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        return model
    }

    @Test("The focused row is what Tab and the right arrow take")
    func enteringTakesTheFocusedRow() {
        let model = globalModel()
        model.rows = [.global(cliDocument("tailscale"))]

        // Nothing focused: the keys have no row to take, and say so.
        #expect(model.enterFocusedRow() == false)

        model.moveMenuFocus(by: 1)
        #expect(model.enterFocusedRow())
        #expect(model.isCLIScope)
        #expect(model.cliCommand == "tailscale")
    }

    @Test("Stepping into a tool leaves Global behind, and leaving comes back to it")
    func theScopeCanBeLeft() {
        let model = globalModel()
        model.rows = [.global(cliDocument("tailscale"))]
        model.moveMenuFocus(by: 1)
        model.enterFocusedRow()

        #expect(model.isCLIScope)
        #expect(model.returnsToGlobalScope)

        #expect(model.leaveScopeForGlobal())
        #expect(model.isGlobalScope)
        #expect(model.isCLIScope == false)
    }

    @Test("A chosen scope survives the frontmost app changing under it")
    func aChosenScopeIsNotTakenByTheFrontmostApp() {
        let model = globalModel()
        model.rows = [.global(cliDocument("tailscale"))]
        model.moveMenuFocus(by: 1)
        model.enterFocusedRow()

        // Clicking away used to swap the field to whatever came forward, losing the tool
        // the user had just stepped into.
        model.frontmostAppDidChange(
            app: "Safari", bundleID: "com.apple.Safari", suggestions: [], summary: "")

        #expect(model.isCLIScope)
        #expect(model.cliCommand == "tailscale")
    }

    @Test("Global Context is not taken by the frontmost app either")
    func globalSurvivesAnAppSwitch() {
        let model = globalModel()

        model.frontmostAppDidChange(
            app: "Safari", bundleID: "com.apple.Safari", suggestions: [], summary: "")

        #expect(model.isGlobalScope)
    }

    @Test("A Global Command opens its panel in the board, not a window")
    func globalCommandOpensInTheBoard() {
        // Quick Note and Currency Converter are `syscmd://` — the extension work before
        // this covered `userext://` only, so Tab on one of these did nothing at all.
        let model = globalModel()
        let command = SystemCommand(
            name: "Quick Note", icon: "note.text", keywords: ["note"],
            scriptType: "url", script: "x-note://new")

        model.scopeIntoCommand(command)

        #expect(model.showsExtensionPanel)
        #expect(model.scopedCommand?.name == "Quick Note")
        #expect(model.returnsToGlobalScope)
    }

    @Test("A tool's scope shows no window snapshot — it has no window")
    func toolsHaveNoSnapshot() {
        let model = globalModel()
        model.rows = [.global(cliDocument("tailscale"))]
        model.moveMenuFocus(by: 1)
        model.enterFocusedRow()

        #expect(model.showsWindowSnapshot == false)
    }

    @Test("The scope opens showing the tool, not the search it was entered from")
    func rowsDoNotSurviveTheStepIn() {
        let model = globalModel()
        model.rows = [.global(cliDocument("tailscale")), .global(cliDocument("other"))]
        model.moveMenuFocus(by: 1)
        model.enterFocusedRow()

        // Whatever the scope offers, it is not the Global results that led here.
        #expect(!model.rows.contains { $0.id == "global:cli://other" })
    }
}
