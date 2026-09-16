// Context-DockTests/PluginSearchEntryTests.swift
//
// An installed plugin has to answer to its own name, and it has to REPLACE the legacy item it
// was migrated from rather than appearing beside it — two rows doing the same thing, one of
// them the old path, is worse than either alone.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct PluginSearchEntryTests {
    private func migrated(_ name: String, legacy: UUID) -> PluginManifest {
        var m = PluginManifest(
            id: PluginMigration.slug(name), name: name,
            views: PluginViews(panel: PluginPanelView(root: PluginNode(component: "list"))))
        m.keywords = [PluginSupersession.keyword(forLegacyID: legacy.uuidString)]
        return m
    }

    @Test func aMigratedPluginRemembersWhatItReplaces() {
        let legacy = UUID()
        let plugin = migrated("Ports", legacy: legacy)
        #expect(PluginSupersession.legacyIDs(in: [plugin]) == [legacy.uuidString])
    }

    @Test func aPluginAuthoredFromScratchReplacesNothing() {
        let fresh = PluginManifest(id: "fresh", name: "Fresh", keywords: ["a", "b"])
        #expect(PluginSupersession.legacyIDs(in: [fresh]).isEmpty)
    }

    @Test func theLegacyItemIsHiddenOnlyWhileItsPluginIsInstalled() {
        let legacy = UUID()
        let covered = PluginSupersession.legacyIDs(in: [migrated("Ports", legacy: legacy)])
        #expect(PluginSupersession.supersedes(legacyID: legacy.uuidString, covered: covered))
        #expect(PluginSupersession.supersedes(legacyID: UUID().uuidString, covered: covered) == false)
        // Uninstall the plugin and the original comes back — nothing was deleted.
        #expect(PluginSupersession.supersedes(legacyID: legacy.uuidString, covered: []) == false)
    }

    @Test func theStampSurvivesTheJSONAPluginIsWrittenAs() throws {
        // It rides in `keywords`, which is part of the manifest, so it is still there after a
        // plugin is written to disk and read back by the registry.
        let legacy = UUID()
        let data = try JSONEncoder().encode(migrated("Ports", legacy: legacy))
        let again = try JSONDecoder().decode(PluginManifest.self, from: data)
        #expect(PluginSupersession.legacyIDs(in: [again]) == [legacy.uuidString])
    }

    @Test func theStampIsNotShownToAnyoneAsAKeyword() {
        let plugin = migrated("Ports", legacy: UUID())
        #expect(PluginSupersession.userVisibleKeywords(of: plugin).isEmpty)
        var mixed = plugin
        mixed.keywords.append("ports")
        #expect(PluginSupersession.userVisibleKeywords(of: mixed) == ["ports"])
    }
}
