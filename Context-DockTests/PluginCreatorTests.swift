// Context-DockTests/PluginCreatorTests.swift
//
// The Creator edits a manifest as text and shows what it draws. Its decisions — is this valid,
// can it be saved, what does the preview show while it is broken — are held here.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct PluginCreatorTests {
    private let sleep = """
    { "id": "sleep", "name": "Sleep", "icon": "moon.fill",
      "actions": { "sleep": { "type": "bash", "script": "pmset sleepnow", "risk": "medium" } },
      "primaryAction": "sleep" }
    """

    @Test func validTextParsesAndIsSavable() {
        let model = PluginCreatorModel(text: sleep)
        #expect(model.manifest?.id == "sleep")
        #expect(model.diagnostics.isEmpty)
        #expect(model.canSave)
    }

    @Test func brokenJSONSaysSoAndCannotBeSaved() {
        let model = PluginCreatorModel(text: "{ not json")
        #expect(model.manifest == nil)
        #expect(model.diagnostics.contains { $0.message.lowercased().contains("json") })
        #expect(model.canSave == false)
    }

    @Test func aManifestThatParsesButBreaksTheRulesCannotBeSavedEither() {
        // It decodes — so a preview could draw something — but installing it would produce a
        // plugin that cannot work, which is what the schema is for.
        let model = PluginCreatorModel(text: #"{ "id": "Bad Id", "name": "B", "views": { "panel": { "orbitCluster": {} } } }"#)
        #expect(model.manifest != nil)
        #expect(model.diagnostics.contains { $0.severity == .error })
        #expect(model.canSave == false)
    }

    @Test func aWarningDoesNotStopASave() {
        // "your binding is not in sample" is advice, not a defect. Refusing to save on a
        // warning would make the Creator unusable while a plugin is half-written.
        let model = PluginCreatorModel(text: #"{ "id": "w", "name": "W", "sample": { "a": 1 }, "views": { "panel": { "title": "{{b}}" } } }"#)
        #expect(model.diagnostics.contains { $0.severity == .warning })
        #expect(model.diagnostics.allSatisfy { $0.severity != .error })
        #expect(model.canSave)
    }

    @Test func theLastGoodManifestKeepsDrawingWhileTheTextIsMidEdit() {
        // Every keystroke makes JSON briefly invalid. Blanking the preview on each one makes
        // the editor flicker and tells the author nothing.
        let model = PluginCreatorModel(text: sleep)
        let good = model.previewManifest
        model.text = "{ not json"
        #expect(model.manifest == nil)
        #expect(model.previewManifest?.id == good?.id)
    }

    @Test func editingAnInstalledPluginKeepsItsIdentity() throws {
        let installed = try #require(PluginEssentials.all.first { $0.id == "sleep" })
        let model = PluginCreatorModel(editing: installed)
        #expect(model.manifest?.id == "sleep")
        #expect(model.text.contains("pmset sleepnow"))
    }
}
