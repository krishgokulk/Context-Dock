// Context-DockTests/CornerPluginBoardTests.swift
//
// Inventory D6 (owner 2026-09-28): a plugin opened from Global search opens its panel in the
// Corner's board, as a strip pin's card already did — not a window beside the Corner. A
// one-shot plugin still just runs.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
private func document(_ id: String) -> GlobalSearchService.SearchDocument {
    GlobalSearchService.SearchDocument(
        id: "doc-\(id)", title: id, subtitle: "", bundleId: "", filePath: nil,
        normalizedTitle: id, titleWords: [id], acronym: String(id.prefix(1)), aliases: [],
        aliasWords: [], sourceKind: .cli, rankingBoost: 0, icon: nil, usageTrackingKey: id,
        action: .plugin(id: id))
}

/// A plugin with a panel (any declared view opens as one), or one with nothing to show.
private func manifest(_ id: String, panel: Bool) throws -> PluginManifest {
    PluginManifest(
        id: id, name: id.capitalized,
        views: panel ? PluginViews(window: PluginWindowView(root: nil)) : PluginViews())
}

@Suite("Corner plugin board")
@MainActor
struct CornerPluginBoardTests {

    @Test("A panel plugin is stepped into; a one-shot is not")
    func whichPluginsStepIn() throws {
        let panel = try manifest("converter", panel: true)
        let oneShot = try manifest("sleeper", panel: false)  // no panel: never stepped into
        let lookup: (String) -> PluginManifest? = { id in [panel, oneShot].first { $0.id == id } }
        #expect(PluginLaunch.behaviour(for: panel) == .openPanel)
        #expect(AppChatPromptModel.panelPlugin(for: document("converter"), manifest: lookup)?.id == "converter")
        #expect(AppChatPromptModel.panelPlugin(for: document("sleeper"), manifest: lookup) == nil)
        #expect(AppChatPromptModel.panelPlugin(for: document("missing"), manifest: lookup) == nil)
    }

    @Test("↩ on a panel plugin from Global opens it in the board; Backspace leaves it")
    func opensInTheBoard() throws {
        let panel = try manifest("converter", panel: true)
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.pluginManifestLookup = { $0 == panel.id ? panel : nil }
        model.summonGlobalContext()
        model.rows = [.global(document("converter"))]
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.runFocusedRow())
        #expect(model.scopedPlugin?.id == "converter")
        #expect(model.showsExtensionPanel)
        #expect(model.returnsToGlobalScope)

        #expect(model.applyEmptyBackspace())
        #expect(model.scopedPlugin == nil)
        #expect(model.isGlobalScope)
    }

    @Test("The Dock's own pill for a panel plugin opens it in the board too")
    func dockPillOpensInTheBoard() throws {
        let panel = try manifest("converter", panel: true)
        let doc = document("converter")
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.pluginManifestLookup = { $0 == panel.id ? panel : nil }
        model.searchDocumentLookup = { $0 == doc.id ? doc : nil }
        model.summonGlobalContext()
        var ran = false
        var pill = DockPill(id: "p", name: "Converter", icon: "app", badge: "", execute: { ran = true })
        pill.searchDocumentID = doc.id
        model.rows = [.dock(pill)]
        #expect(model.moveMenuFocus(by: 1))
        #expect(model.stepIntoFocusedRow())
        #expect(!ran)
        #expect(model.scopedPlugin?.id == "converter")
    }

    @Test("Stepping into an extension or back to Global puts the plugin away")
    func otherScopesClearIt() throws {
        let panel = try manifest("converter", panel: true)
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.scopeIntoPlugin(panel)
        #expect(model.scopedPlugin != nil)
        model.summonGlobalContext()
        #expect(model.scopedPlugin == nil)
    }
}
