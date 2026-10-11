// Context-DockTests/PluginSeedUpgradeTests.swift
//
// A shipped plugin has to be able to CHANGE in a later build without stepping on a plugin the
// person has edited. Those two requirements pull against each other, and the stamp is what
// tells them apart: the app wrote this exact text, or somebody has been in here since.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct PluginSeedUpgradeTests {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func installedManifest(_ root: URL, _ id: String) throws -> PluginManifest {
        let url = root.appendingPathComponent(
            "\(PluginEssentials.packID)/plugins/\(id)/manifest.json")
        return try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
    }

    private func write(_ manifest: PluginManifest, to root: URL) throws {
        try PluginInstaller.install(
            [manifest], into: root, packID: PluginEssentials.packID,
            packName: PluginEssentials.packName)
    }

    @Test("A fresh machine gets every shipped plugin, stamped")
    func seedsFresh() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PluginEssentials.seed(into: root)

        for shipped in PluginEssentials.all {
            let installed = try installedManifest(root, shipped.id)
            #expect(PluginShipped.stamp(of: installed) == PluginShipped.stamp(for: shipped))
        }
    }

    @Test("A stamped copy from an older build is replaced")
    func upgradesAnUntouchedCopy() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // What an older build left behind: the app's own text, stamped for that text.
        var old = try #require(PluginEssentials.all.first { $0.id == "sleep" })
        old.description = "An older description"
        old.keywords = PluginShipped.stamped(old.keywords, with: PluginShipped.stamp(for: old))
        try write(old, to: root)

        try PluginEssentials.seed(into: root)
        let now = try installedManifest(root, "sleep")
        let current = try #require(PluginEssentials.all.first { $0.id == "sleep" })
        #expect(now.description != "An older description")
        #expect(PluginShipped.stamp(of: now) == PluginShipped.stamp(for: current))
    }

    @Test("An edited copy is left exactly as the person left it")
    func neverOverwritesAnEdit() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PluginEssentials.seed(into: root)

        // Someone opens it in the Creator and changes something. The stamp no longer matches
        // the text it is attached to, which is exactly what "edited" means.
        var edited = try installedManifest(root, "sleep")
        edited.name = "My Sleep"
        try write(edited, to: root)

        try PluginEssentials.seed(into: root)
        #expect(try installedManifest(root, "sleep").name == "My Sleep")
    }

    @Test("An edited copy is offered a reset, an untouched one is not")
    func offersAResetOnlyWhereThereIsAnEdit() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PluginEssentials.seed(into: root)
        #expect(PluginShipped.editedShippedPlugins(installedIn: root).isEmpty)

        var edited = try installedManifest(root, "sleep")
        edited.name = "My Sleep"
        try write(edited, to: root)
        #expect(PluginShipped.editedShippedPlugins(installedIn: root) == ["sleep"])
    }

    @Test("A plugin the user wrote themselves is never touched or offered a reset")
    func ignoresPluginsTheAppDoesNotShip() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A real one: the schema refuses a plugin with nothing to show and nothing to do.
        let mine = PluginManifest(
            id: "mine", name: "Mine",
            views: PluginViews(panel: PluginPanelView(root: PluginNode(
                component: "title", props: ["text": .string("Mine")]))))
        try write(mine, to: root)
        try PluginEssentials.seed(into: root)

        #expect(try installedManifest(root, "mine").name == "Mine")
        #expect(PluginShipped.editedShippedPlugins(installedIn: root).isEmpty)
    }

    @Test("Resetting brings the shipped version back")
    func resetRestoresTheShippedCopy() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PluginEssentials.seed(into: root)
        var edited = try installedManifest(root, "sleep")
        edited.name = "My Sleep"
        try write(edited, to: root)

        try PluginEssentials.reset(pluginID: "sleep", in: root)
        #expect(try installedManifest(root, "sleep").name == "Sleep")
        #expect(PluginShipped.editedShippedPlugins(installedIn: root).isEmpty)
    }

    @Test("The stamp is bookkeeping, never a keyword anybody searches or reads")
    func theStampIsHidden() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PluginEssentials.seed(into: root)
        let installed = try installedManifest(root, "sleep")
        #expect(installed.keywords.contains { $0.hasPrefix(PluginShipped.prefix) })
        #expect(PluginShipped.userVisibleKeywords(of: installed)
            .allSatisfy { !$0.hasPrefix(PluginShipped.prefix) })
    }
}
