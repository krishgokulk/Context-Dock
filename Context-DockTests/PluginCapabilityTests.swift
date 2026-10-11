// Context-DockTests/PluginCapabilityTests.swift
//
// A plugin action, described as the app's own capability so it can go through the app's one
// approval surface rather than a second one grown beside it.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct PluginCapabilityTests {
    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private let sonos = #"""
    { "id": "sonos", "name": "Sonos",
      "actions": { "toggle": { "type": "bash", "script": "t.sh", "title": "Play / Pause", "risk": "low" },
                   "wipe": { "type": "bash", "script": "w.sh", "risk": "high" },
                   "look": { "type": "bash", "script": "l.sh", "risk": "read" } } }
    """#

    @Test func aCapabilityIsNamespacedByItsPluginSoTwoPluginsNeverCollide() throws {
        let m = try manifest(sonos)
        let capability = try #require(PluginCapability.make(named: "toggle", manifest: m))
        #expect(capability.id == "plugin.sonos.toggle")
    }

    @Test func itRunsItselfRatherThanClaimingAnAdapter() throws {
        // runsWithoutAdapter is the existing flag for a capability that executes itself —
        // the file tools use it. A plugin has no adapter, and saying it did would hide it
        // from every chat and lie about how it dispatches.
        let m = try manifest(sonos)
        let capability = try #require(PluginCapability.make(named: "toggle", manifest: m))
        #expect(capability.runsWithoutAdapter)
        #expect(capability.appBundleID == nil)
    }

    @Test func theTitleIsWhatTheActionCallsItself() throws {
        let m = try manifest(sonos)
        #expect(PluginCapability.make(named: "toggle", manifest: m)?.title == "Sonos: Play / Pause")
        // With no title of its own, the action's name is what a person is shown.
        #expect(PluginCapability.make(named: "wipe", manifest: m)?.title == "Sonos: wipe")
    }

    @Test func riskCarriesAcrossSoTheGateAsksTheSameQuestion() throws {
        let m = try manifest(sonos)
        #expect(PluginCapability.make(named: "look", manifest: m)?.riskLevel == .low)
        #expect(PluginCapability.make(named: "toggle", manifest: m)?.riskLevel == .medium)
        #expect(PluginCapability.make(named: "wipe", manifest: m)?.riskLevel == .high)
        // A plugin's `read` maps to the capability registry's `low`, which is the level that
        // does not require approval there — the two vocabularies meet here and nowhere else.
        #expect(PluginCapability.make(named: "look", manifest: m)?.riskLevel.requiresApproval == false)
        #expect(PluginCapability.make(named: "toggle", manifest: m)?.riskLevel.requiresApproval == true)
    }

    @Test func anActionTheManifestNeverDeclaredHasNoCapability() throws {
        #expect(PluginCapability.make(named: "teleport", manifest: try manifest(sonos)) == nil)
    }

    @Test func thePlanSaysWhatWillHappenAndWhere() throws {
        let m = try manifest(sonos)
        let plan = PluginCapability.plan(
            for: PluginActionRequest(name: "toggle", value: .string("kitchen")), manifest: m)
        #expect(plan.capability == "plugin.sonos.toggle")
        #expect(plan.explanation.contains("Sonos"))
        #expect(plan.input["value"] == "kitchen")
    }
}
