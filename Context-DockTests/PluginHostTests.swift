// Context-DockTests/PluginHostTests.swift
//
// The host's decisions, held apart from its drawing: which view a push shows, what a back
// step returns to, and which node a presentation renders.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct PluginHostTests {
    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private let withWindow = #"""
    { "id": "s", "name": "S",
      "views": { "panel": { "list": { "items": "{{lines}}" } },
                 "window": { "width": "wide", "root": { "title": "Detail" } } } }
    """#

    @Test func aPresentationDrawsItsOwnRoot() throws {
        let m = try manifest(withWindow)
        #expect(PluginHostModel(manifest: m, presentation: .panel).root?.component == "list")
        #expect(PluginHostModel(manifest: m, presentation: .window).root?.component == "title")
    }

    @Test func aPresentationTheManifestNeverDeclaredFallsBackToItsPanel() throws {
        // ▢ opens a window for a plugin that only declares a panel. Showing nothing there
        // would read as a broken plugin rather than as one with no window of its own.
        let panelOnly = try manifest(#"{ "id": "p", "name": "P", "views": { "panel": { "title": "hi" } } }"#)
        let model = PluginHostModel(manifest: panelOnly, presentation: .window)
        #expect(model.root?.component == "title")
    }

    @Test func aPluginWithNoViewsAtAllHasNothingToDraw() throws {
        let agentOnly = try manifest(#"{ "id": "a", "name": "A", "agent": { "instructions": "hi" } }"#)
        #expect(PluginHostModel(manifest: agentOnly, presentation: .panel).root == nil)
    }

    @Test func aPushActionShowsThatViewAndBackReturns() throws {
        // `push:detail` is emitted by the compact rule and, until now, consumed by nobody.
        let m = try manifest(withWindow)
        let model = PluginHostModel(manifest: m, presentation: .panel)
        #expect(model.depth == 0)
        #expect(model.handle(PluginActionRequest(name: "push:window")))
        #expect(model.depth == 1)
        #expect(model.root?.component == "title")
        model.back()
        #expect(model.depth == 0)
        #expect(model.root?.component == "list")
    }

    @Test func aPushToAViewThatDoesNotExistIsRefusedRatherThanShowingBlank() throws {
        let m = try manifest(withWindow)
        let model = PluginHostModel(manifest: m, presentation: .panel)
        #expect(model.handle(PluginActionRequest(name: "push:icon")) == false)
        #expect(model.depth == 0)
    }

    @Test func anOrdinaryActionIsNotTheHostsBusiness() throws {
        // Only push:* belongs to navigation; everything else goes to the runtime, and a host
        // that swallowed it would make actions silently do nothing.
        let m = try manifest(withWindow)
        let model = PluginHostModel(manifest: m, presentation: .panel)
        #expect(model.handle(PluginActionRequest(name: "toggle")) == false)
    }

    @Test func theCornerGetsCompactTraitsAndTheSheetRegularOnes() throws {
        #expect(PluginHostModel.traits(for: .panel, compact: true).widthClass == .compact)
        #expect(PluginHostModel.traits(for: .panel, compact: false).widthClass == .regular)
        // A window sizes itself from its declared width, not from the caller's guess.
        let m = try manifest(withWindow)
        let model = PluginHostModel(manifest: m, presentation: .window)
        #expect(model.traits.width == 640)  // "wide"
    }
}
