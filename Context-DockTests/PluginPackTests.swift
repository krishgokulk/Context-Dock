// Context-DockTests/PluginPackTests.swift
// A pack is a folder. These build folders in a temporary directory and load them, so the
// layout the spec draws is the layout the loader reads.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin pack")
@MainActor
struct PluginPackTests {

    private func makePack(_ name: String, version: String = "1.0.0", plugins: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString)")
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        let pack = """
        { "id": "\(name)", "name": "\(name.capitalized)", "author": "test", "version": "\(version)", "icon": "puzzlepiece", "description": "d" }
        """
        try pack.write(to: folder.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
        for (id, json) in plugins {
            let dir = folder.appendingPathComponent("plugins/\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        }
        return folder
    }

    @Test("A pack folder loads its plugins and validates each")
    func loadsPlugins() throws {
        let folder = try makePack("sonos", plugins: [
            "now-playing": PluginManifestTests.sonos,
            "broken": #"{ "id": "broken", "name": "B", "views": { "panel": { "hologram": {} } } }"#,
        ])
        let pack = try PluginPack.load(from: folder)
        #expect(pack.info.id == "sonos")
        #expect(pack.plugins.map(\.id).sorted() == ["broken", "sonos-now-playing"])
        #expect(pack.diagnostics["sonos-now-playing"]?.filter { $0.severity == .error }.isEmpty == true)
        #expect(pack.diagnostics["broken"]?.contains { $0.message.contains("hologram") } == true)
        #expect(pack.loadErrors.isEmpty)
    }

    @Test("A manifest that will not decode is reported, not fatal")
    func undecodableManifestIsReported() throws {
        let folder = try makePack("mixed", plugins: [
            "ok": #"{ "id": "ok", "name": "OK", "views": { "panel": { "title": "hi" } } }"#,
            "junk": "not json",
        ])
        let pack = try PluginPack.load(from: folder)
        #expect(pack.plugins.map(\.id) == ["ok"])
        #expect(pack.loadErrors.count == 1)
        #expect(pack.loadErrors[0].contains("junk"))
    }

    @Test("A folder without pack.json is not a pack")
    func missingPackJSON() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nopack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: PluginPackError.missingPackJSON(folder)) {
            try PluginPack.load(from: folder)
        }
    }

    @Test("Versions compare as semver, not as strings")
    func semver() {
        #expect(PluginPack.compareVersions("1.10.0", "1.9.0") == .orderedDescending)
        #expect(PluginPack.compareVersions("1.0", "1.0.0") == .orderedSame)
        #expect(PluginPack.compareVersions("2", "1.99.99") == .orderedDescending)
        #expect(PluginPack.compareVersions("0.9", "1.0") == .orderedAscending)
    }

    @Test("Duplicate plugin ids are reported, first one kept")
    func duplicatePluginIds() throws {
        let folder = try makePack("dup-test", plugins: [
            "alpha": #"{ "id": "same-id", "name": "Alpha", "views": { "panel": { "title": "A" } } }"#,
            "beta": #"{ "id": "same-id", "name": "Beta", "views": { "panel": { "title": "B" } } }"#,
        ])
        let pack = try PluginPack.load(from: folder)
        #expect(pack.plugins.map(\.id) == ["same-id"])
        #expect(pack.plugins[0].name == "Alpha")
        #expect(pack.diagnostics["same-id"] != nil)
        #expect(pack.loadErrors.count == 1)
        #expect(pack.loadErrors[0].contains("Duplicate"))
        #expect(pack.loadErrors[0].contains("same-id"))
        #expect(pack.loadErrors[0].contains("beta"))
    }

    @Test("Unreadable plugins directory is reported")
    func unreadablePluginsDirectory() throws {
        let folder = try makePack("unreadable", plugins: [
            "ok": #"{ "id": "ok", "name": "OK", "views": { "panel": { "title": "hi" } } }"#,
        ])
        let pluginsDir = folder.appendingPathComponent("plugins")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: pluginsDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pluginsDir.path)
        }
        let pack = try PluginPack.load(from: folder)
        #expect(pack.info.id == "unreadable")
        #expect(pack.loadErrors.count > 0)
        #expect(pack.loadErrors[0].contains("plugins/"))
    }
}
