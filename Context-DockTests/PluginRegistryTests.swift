// Context-DockTests/PluginRegistryTests.swift
// The registry is the one list every host reads. Enabled is the default; disabling is
// remembered; a plugin with schema errors is loaded (so Settings can show why) but never
// enabled.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin registry")
@MainActor
struct PluginRegistryTests {

    private func root(with packs: [String: [String: String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)")
        for (packName, plugins) in packs {
            let folder = root.appendingPathComponent(packName)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("plugins"), withIntermediateDirectories: true)
            try #"{ "id": "\#(packName)", "version": "1.0.0" }"#.write(to: folder.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
            for (id, json) in plugins {
                let dir = folder.appendingPathComponent("plugins/\(id)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try json.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            }
        }
        return root
    }

    private let ok = #"{ "id": "ok", "name": "OK", "views": { "panel": { "title": "hi" } } }"#
    private let broken = #"{ "id": "broken", "name": "B", "views": { "panel": { "hologram": {} } } }"#

    @Test("Everything loads; only error-free plugins are enabled")
    func loadsAndFiltersErrors() throws {
        let r = try root(with: ["one": ["ok": ok, "broken": broken]])
        let state = r.appendingPathComponent("state.json")
        let registry = PluginRegistry(roots: [r], stateFile: state)
        #expect(registry.plugins.map(\.id).sorted() == ["broken", "ok"])
        #expect(registry.enabledPlugins.map(\.id) == ["ok"])
        #expect(registry.plugin(id: "broken")?.hasErrors == true)
    }

    @Test("Disabling is remembered across a reload and a new registry")
    func disableIsPersistent() throws {
        let r = try root(with: ["one": ["ok": ok]])
        let state = r.appendingPathComponent("state.json")
        let registry = PluginRegistry(roots: [r], stateFile: state)
        registry.setEnabled(false, pluginID: "ok")
        #expect(registry.enabledPlugins.isEmpty)
        registry.reload()
        #expect(registry.enabledPlugins.isEmpty)
        let fresh = PluginRegistry(roots: [r], stateFile: state)
        #expect(fresh.enabledPlugins.isEmpty)
        fresh.setEnabled(true, pluginID: "ok")
        #expect(fresh.enabledPlugins.map(\.id) == ["ok"])
    }

    @Test("Two roots merge; the same plugin id in two packs keeps the newer pack's copy")
    func rootsMergeNewestWins() throws {
        let a = try root(with: ["essentials": ["ok": ok]])
        let b = try root(with: ["essentials": ["ok": #"{ "id": "ok", "name": "OK v2", "views": { "panel": { "title": "hi" } } }"#]])
        try #"{ "id": "essentials", "version": "2.0.0" }"#.write(to: b.appendingPathComponent("essentials/pack.json"), atomically: true, encoding: .utf8)
        let registry = PluginRegistry(roots: [a, b], stateFile: a.appendingPathComponent("state.json"))
        #expect(registry.plugins.count == 1)
        #expect(registry.plugin(id: "ok")?.manifest.name == "OK v2")
    }

    @Test("The folder of a plugin is the directory holding its manifest")
    func folderLookup() throws {
        let r = try root(with: ["one": ["ok": ok]])
        let registry = PluginRegistry(roots: [r], stateFile: r.appendingPathComponent("state.json"))
        #expect(registry.folder(forPlugin: "ok")?.lastPathComponent == "ok")
    }

    @Test("A missing root is not an error")
    func missingRoot() {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")
        let registry = PluginRegistry(roots: [r], stateFile: r.appendingPathComponent("state.json"))
        #expect(registry.plugins.isEmpty)
    }
}
