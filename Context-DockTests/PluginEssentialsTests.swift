// Context-DockTests/PluginEssentialsTests.swift
//
// The plugins the app ships. These are authored as manifests, not converted from anything, and
// they are the first real test of whether the format is pleasant to write in.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct PluginEssentialsTests {

    @Test("Every shipped plugin validates")
    func essentialsValidate() {
        for manifest in PluginEssentials.all {
            let errors = PluginSchema.validate(manifest).filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(manifest.id): \(errors.map(\.message))")
        }
    }

    @Test("Sleep is a one-shot: a primary action, no panel to open")
    func sleepIsOneShot() throws {
        let sleep = try #require(PluginEssentials.all.first { $0.id == "sleep" })
        #expect(sleep.primaryAction == "sleep")
        #expect(sleep.views.panel == nil)
        let action = try #require(sleep.actions["sleep"])
        #expect(action.script == "pmset sleepnow")
    }

    @Test("Sleep asks before it runs")
    func sleepAsksFirst() throws {
        // It interrupts whatever the machine is doing. `read` would run it the instant a
        // fuzzy match put it under the cursor and someone pressed return.
        let sleep = try #require(PluginEssentials.all.first { $0.id == "sleep" })
        let action = try #require(sleep.actions["sleep"])
        #expect(action.risk != .read)
        #expect(PluginPermissions.needsApproval(action))
    }

    @Test("A plugin with a panel opens it; a plugin without one runs its primary action")
    func launchBehaviour() throws {
        let sleep = try #require(PluginEssentials.all.first { $0.id == "sleep" })
        #expect(PluginLaunch.behaviour(for: sleep) == .run("sleep"))

        let panelled = PluginManifest(
            id: "p", name: "P",
            views: PluginViews(panel: PluginPanelView(root: PluginNode(component: "list"))))
        #expect(PluginLaunch.behaviour(for: panelled) == .openPanel)
    }

    @Test("A plugin that can neither be opened nor run says so rather than doing nothing")
    func nothingToDo() {
        let agentOnly = PluginManifest(id: "a", name: "A")
        #expect(PluginLaunch.behaviour(for: agentOnly) == .nothing)
    }

    @Test("A plugin with both a panel and a primary action opens the panel")
    func panelWins() {
        // The panel is the richer surface and contains the action anyway; running it outright
        // would skip the thing the author built.
        var manifest = PluginManifest(
            id: "b", name: "B",
            actions: ["go": PluginAction(type: "bash", script: "true", risk: .low)],
            primaryAction: "go",
            views: PluginViews(panel: PluginPanelView(root: PluginNode(component: "list"))))
        manifest.keywords = []
        #expect(PluginLaunch.behaviour(for: manifest) == .openPanel)
    }

    @Test("Seeding writes the shipped plugins once and never overwrites an edited one")
    func seedingIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("essentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try PluginEssentials.seed(into: root)
        let folder = root.appendingPathComponent("essentials")
        let manifestURL = folder.appendingPathComponent("plugins/sleep/manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        // Someone edits the shipped plugin. Seeding again must leave their edit alone —
        // a pack that rewrites itself at every launch is a pack nobody can change.
        try "{ \"id\": \"sleep\", \"name\": \"Edited\" }".write(
            to: manifestURL, atomically: true, encoding: .utf8)
        try PluginEssentials.seed(into: root)
        let after = try String(contentsOf: manifestURL, encoding: .utf8)
        #expect(after.contains("Edited"))
    }
}
