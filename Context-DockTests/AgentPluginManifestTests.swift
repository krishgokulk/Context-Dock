import Testing
import Foundation
@testable import Context_Dock

// The plugin manager is only as trustworthy as its mapping: the owner must be able to read
// "what can this plugin do" off the manifest and have it match what the index actually
// ranks. These tests pin the projection — every registered capability appears exactly
// once, with its kind, surface and read/write carried over intact.

@Suite("AgentPluginManifest mapping")
struct AgentPluginManifestTests {

    /// The five Mail adapter tools from plan §2b, plus a couple of others, as the builder's
    /// pure core sees them.
    private func mailRecords() -> [CapabilityRecord] {
        [
            CapabilityRecord(id: "adapter.mail.recent", app: "Mail", kind: .adapterAction,
                title: "Recent mail", isWrite: false, surface: .headless),
            CapabilityRecord(id: "adapter.mail.read", app: "Mail", kind: .adapterAction,
                title: "Read message", isWrite: false, surface: .headless),
            CapabilityRecord(id: "adapter.mail.search", app: "Mail", kind: .adapterAction,
                title: "Search mail", isWrite: false, surface: .headless),
            CapabilityRecord(id: "adapter.mail.currentMessage", app: "Mail", kind: .adapterAction,
                title: "Current message", isWrite: false, surface: .headless),
            CapabilityRecord(id: "adapter.mail.createDraft", app: "Mail", kind: .adapterAction,
                title: "Create draft", isWrite: true, surface: .opensApp),
        ]
    }

    private var bundleMap: [String: [String]] { ["Mail": ["com.apple.mail"]] }

    @Test("Every record appears exactly once, lossless")
    func everyRecordOnce() {
        let records = mailRecords() + [
            CapabilityRecord(id: "capability.reminders.create", app: "Reminders",
                kind: .capability, title: "Create reminder", isWrite: true, surface: .headless),
            CapabilityRecord(id: "globalcmd.bluetooth", app: "", kind: .globalCommand,
                title: "Toggle Bluetooth", isWrite: true, surface: .headless),
        ]
        let manifests = AgentPluginManifestBuilder.manifests(
            from: records, bundleIDForApp: bundleMap)

        let projected = manifests.flatMap(\.capabilities)
        // No capability is dropped and none is duplicated.
        #expect(projected.count == records.count)
        #expect(Set(projected.map(\.id)) == Set(records.map(\.id)))

        // Kind, surface and read/write survive the projection unchanged.
        for record in records {
            let cap = projected.first { $0.id == record.id }
            #expect(cap?.kind == record.kind)
            #expect(cap?.surface == record.surface)
            #expect(cap?.isWrite == record.isWrite)
        }
    }

    @Test("One manifest per (app, kind); the five Mail adapter tools group together")
    func groupsByAppAndKind() {
        let manifests = AgentPluginManifestBuilder.manifests(
            from: mailRecords(), bundleIDForApp: bundleMap)

        #expect(manifests.count == 1)
        let mail = try! #require(manifests.first)
        #expect(mail.app == "Mail")
        #expect(mail.kind == .adapterAction)
        #expect(mail.capabilities.count == 5)
        #expect(mail.bundleIDs == ["com.apple.mail"])
        #expect(mail.id == "com.apple.mail/adapterAction")
        // Four reads, one write (createDraft).
        #expect(mail.reads.count == 4)
        #expect(mail.writes.map(\.id) == ["adapter.mail.createDraft"])
    }

    @Test("Different kinds for one app become different manifests")
    func splitsKindsWithinApp() {
        let records = [
            CapabilityRecord(id: "adapter.mail.read", app: "Mail", kind: .adapterAction,
                title: "Read", isWrite: false, surface: .headless),
            CapabilityRecord(id: "cli.mail.archive", app: "Mail", kind: .cliTool,
                title: "Archive", isWrite: true, surface: .headless),
        ]
        let manifests = AgentPluginManifestBuilder.manifests(
            from: records, bundleIDForApp: bundleMap)
        #expect(manifests.count == 2)
        #expect(Set(manifests.map(\.kind)) == [.adapterAction, .cliTool])
    }

    @Test("Origin is read off the kind and cannot be self-raised")
    func originFromKind() {
        #expect(AgentPluginManifest.Origin(kind: .adapterAction) == .builtIn)
        #expect(AgentPluginManifest.Origin(kind: .capability) == .builtIn)
        #expect(AgentPluginManifest.Origin(kind: .globalCommand) == .builtIn)
        #expect(AgentPluginManifest.Origin(kind: .cliTool) == .userAdded)
        #expect(AgentPluginManifest.Origin(kind: .mcpTool) == .userAdded)
    }

    @Test("Machine-wide capabilities carry no bundle id and sort under System")
    func machineWideHasNoBundle() {
        let records = [
            CapabilityRecord(id: "globalcmd.bluetooth", app: "", kind: .globalCommand,
                title: "Toggle Bluetooth", isWrite: true, surface: .headless),
        ]
        let manifests = AgentPluginManifestBuilder.manifests(
            from: records, bundleIDForApp: bundleMap)
        let system = try! #require(manifests.first)
        #expect(system.app == "")
        #expect(system.bundleIDs.isEmpty)
        #expect(system.id == "system/globalCommand")
    }

    @Test("Capabilities within a manifest are sorted by title")
    func capabilitiesSorted() {
        let records = [
            CapabilityRecord(id: "a", app: "Mail", kind: .adapterAction,
                title: "Zebra", isWrite: false, surface: .headless),
            CapabilityRecord(id: "b", app: "Mail", kind: .adapterAction,
                title: "apple", isWrite: false, surface: .headless),
            CapabilityRecord(id: "c", app: "Mail", kind: .adapterAction,
                title: "Mango", isWrite: false, surface: .headless),
        ]
        let manifests = AgentPluginManifestBuilder.manifests(
            from: records, bundleIDForApp: bundleMap)
        #expect(manifests.first?.capabilities.map(\.title) == ["apple", "Mango", "Zebra"])
    }
}
