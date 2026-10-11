// Context-DockTests/PluginInstallerTests.swift
//
// Installing is what makes a migrated Global Command a real plugin: until a manifest is on
// disk in a pack, PluginRegistry cannot see it and no host can show it. These write into a
// temporary directory, never the user's own plugin folder.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct PluginInstallerTests {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-installer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifest(_ id: String, _ name: String) -> PluginManifest {
        PluginManifest(
            id: id, name: name,
            views: PluginViews(panel: PluginPanelView(root: PluginNode(
                component: "title", props: ["text": .string(name)]))))
    }

    @Test func installingWritesAPackTheRegistryCanLoad() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = try PluginInstaller.install(
            [manifest("ports", "Ports"), manifest("deploy", "Deploy")],
            into: root, packID: "migrated", packName: "Migrated")

        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pack.json").path))
        let pack = try PluginPack.load(from: folder)
        #expect(pack.plugins.map(\.id).sorted() == ["deploy", "ports"])
        #expect(pack.loadErrors.isEmpty)
    }

    @Test func aPluginLandsInItsOwnFolderNamedByItsID() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try PluginInstaller.install(
            [manifest("ports", "Ports")], into: root, packID: "migrated", packName: "Migrated")
        let manifestURL = folder
            .appendingPathComponent("plugins/ports/manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    @Test func installingAgainReplacesRatherThanDuplicates() throws {
        // Re-installing after editing a legacy command must not leave two plugins with the
        // same id — PluginPack keeps the first and silently drops the rest.
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try PluginInstaller.install(
            [manifest("ports", "Ports")], into: root, packID: "migrated", packName: "Migrated")
        let folder = try PluginInstaller.install(
            [manifest("ports", "Ports Renamed")], into: root, packID: "migrated", packName: "Migrated")
        let pack = try PluginPack.load(from: folder)
        #expect(pack.plugins.count == 1)
        #expect(pack.plugins.first?.name == "Ports Renamed")
    }

    @Test func aPluginThatDoesNotValidateIsNeverWritten() throws {
        // A manifest with schema errors installs as a plugin that cannot work. Refusing here
        // keeps the failure where somebody can read it, rather than in the registry's
        // hasErrors flag after the fact.
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = PluginManifest(
            id: "Bad Id", name: "Broken",
            views: PluginViews(panel: PluginPanelView(root: PluginNode(component: "orbitCluster"))))
        #expect(throws: PluginInstallError.self) {
            try PluginInstaller.install(
                [broken], into: root, packID: "migrated", packName: "Migrated")
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("migrated").path) == false)
    }

    @Test func removingTakesTheFolderWithIt() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try PluginInstaller.install(
            [manifest("ports", "Ports"), manifest("deploy", "Deploy")],
            into: root, packID: "migrated", packName: "Migrated")
        try PluginInstaller.remove(pluginID: "ports", from: folder)
        let pack = try PluginPack.load(from: folder)
        #expect(pack.plugins.map(\.id) == ["deploy"])
    }
}
