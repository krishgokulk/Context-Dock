// Context-DockTests/DoraxPackV2Tests.swift
//
// Tests for .doraxpack v2 parsing, capability registration, legacy migration,
// and the 5 first-party packs loading cleanly.

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct DoraxPackV2Tests {

    // MARK: - v2 Parsing

    @Test("Loads a minimal .doraxpack v2 folder")
    func loadMinimalPack() throws {
        let dir = try Self.makeTempPack(
            id: "test-minimal", name: "Test Minimal",
            capabilities: [
                ["id": "test.hello", "name": "Hello",
                 "intent": "Say hello", "triggers": ["hello"],
                 "type": "aiPrompt", "script": "say hello", "safety": "read"]
            ])
        let pack = try DoraxPackV2Loader.load(from: dir)
        #expect(pack.metadata.id == "test-minimal")
        #expect(pack.metadata.name == "Test Minimal")
        #expect(pack.metadata.formatVersion == 2)
        #expect(pack.metadata.capabilities.count == 1)
        #expect(pack.metadata.capabilities[0].id == "test.hello")
    }

    @Test("Rejects format_version != 2")
    func rejectsBadVersion() throws {
        let dir = try Self.makeTempPack(
            id: "old-pack", name: "Old Pack",
            capabilities: [], formatVersion: 1)
        #expect(throws: DoraxPackError.self) {
            try DoraxPackV2Loader.load(from: dir)
        }
    }

    @Test("Loads AGENT.md when present")
    func loadsAgentMD() throws {
        let dir = try Self.makeTempPack(
            id: "with-agent", name: "With Agent", capabilities: [])
        try "You are a test agent.".write(
            to: dir.appendingPathComponent("AGENT.md"),
            atomically: true, encoding: .utf8)
        let pack = try DoraxPackV2Loader.load(from: dir)
        #expect(pack.agentInstructions == "You are a test agent.")
    }

    @Test("Loads skills from skills/ subdirectories")
    func loadsSkills() throws {
        let dir = try Self.makeTempPack(
            id: "with-skills", name: "With Skills", capabilities: [])
        let skillDir = dir.appendingPathComponent("skills/my-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "Do the thing.".write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8)
        let pack = try DoraxPackV2Loader.load(from: dir)
        #expect(pack.skills.count == 1)
        #expect(pack.skills[0].id == "my-skill")
        #expect(pack.skills[0].content == "Do the thing.")
    }

    @Test("discoverPacks finds .doraxpack directories")
    func discoverPacks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-discover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Create two .doraxpack folders and one non-pack
        for name in ["alpha.doraxpack", "beta.doraxpack", "not-a-pack"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let found = DoraxPackV2Loader.discoverPacks(in: root)
        #expect(found.count == 2)
        #expect(found[0].lastPathComponent == "alpha.doraxpack")
        #expect(found[1].lastPathComponent == "beta.doraxpack")
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Conversion to PluginManifest

    @Test("toPluginManifest preserves ID, name, capabilities")
    func toPluginManifest() throws {
        let dir = try Self.makeTempPack(
            id: "converter-test", name: "Converter Test",
            bundleId: "com.example.test",
            capabilities: [
                ["id": "ct.read", "name": "Read", "intent": "Read things",
                 "triggers": ["read"], "type": "aiPrompt",
                 "script": "read it", "safety": "read"],
                ["id": "ct.write", "name": "Write", "intent": "Write things",
                 "triggers": ["write"], "type": "aiPrompt",
                 "script": "write it", "safety": "write"]
            ])
        let pack = try DoraxPackV2Loader.load(from: dir)
        let manifest = pack.toPluginManifest()
        #expect(manifest.id == "converter-test")
        #expect(manifest.name == "Converter Test")
        #expect(manifest.targetApp?.bundleId == "com.example.test")
        #expect(manifest.capabilities?.count == 2)
        #expect(manifest.capabilities?[0].id == "ct.read")
    }

    @Test("toPluginManifest sets agent from AGENT.md")
    func manifestAgent() throws {
        let dir = try Self.makeTempPack(
            id: "agent-test", name: "Agent Test", capabilities: [])
        try "Be helpful.".write(
            to: dir.appendingPathComponent("AGENT.md"),
            atomically: true, encoding: .utf8)
        let pack = try DoraxPackV2Loader.load(from: dir)
        let manifest = pack.toPluginManifest()
        #expect(manifest.agent?.instructions == "Be helpful.")
    }

    // MARK: - Capability registration via installV2

    @Test("installV2 registers capabilities in CapabilityRegistry")
    func installV2RegistersCapabilities() throws {
        let dir = try Self.makeTempPack(
            id: "reg-test", name: "Registry Test",
            bundleId: "com.example.regtest",
            capabilities: [
                ["id": "reg.action", "name": "Action",
                 "intent": "Do something", "triggers": ["act"],
                 "type": "aiPrompt", "script": "do it", "safety": "read"]
            ])
        let pack = try DoraxPackV2Loader.load(from: dir)
        let result = try StorePackInstaller.installV2(pack, persistToDisk: false)
        #expect(result.packID == "reg-test")
        #expect(result.registeredCapabilityIDs.contains("reg.action"))
        #expect(CapabilityRegistry.shared.capability(id: "reg.action") != nil)
    }

    // MARK: - Legacy migration

    @Test("Migrates a PluginManifest to .doraxpack v2 folder")
    func legacyMigration() throws {
        let manifest = PluginManifest(
            id: "legacy-plugin", name: "Legacy Plugin",
            version: "1.0.0", icon: "star",
            description: "A legacy plugin",
            keywords: ["test"],
            agent: PluginAgent(instructions: "Be nice.", skills: ["helper"], tools: []),
            targetApp: PluginTargetApp(bundleId: "com.example.legacy", name: "Legacy"),
            capabilities: [
                PluginPackCapability(
                    id: "legacy.greet", name: "Greet",
                    intent: "Say hi", triggers: ["greet"],
                    type: "aiPrompt", script: "greet the user", safety: "read")
            ],
            skills: [
                PluginPackSkill(
                    id: "helper", name: "Helper",
                    summary: "Helps", instructions: "Help the user.")
            ])

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-migrate-\(UUID().uuidString)", isDirectory: true)
        let packURL = try DoraxPackV2Migration.migrate(manifest, to: outputDir)
        #expect(packURL.lastPathComponent == "legacy-plugin.doraxpack")

        // Verify pack.json
        let data = try Data(contentsOf: packURL.appendingPathComponent("pack.json"))
        let metadata = try JSONDecoder().decode(DoraxPackMetadata.self, from: data)
        #expect(metadata.id == "legacy-plugin")
        #expect(metadata.formatVersion == 2)
        #expect(metadata.bundleId == "com.example.legacy")
        #expect(metadata.capabilities.count == 1)

        // Verify AGENT.md
        let agent = try String(contentsOf: packURL.appendingPathComponent("AGENT.md"), encoding: .utf8)
        #expect(agent == "Be nice.")

        // Verify skill
        let skill = try String(
            contentsOf: packURL.appendingPathComponent("skills/helper/SKILL.md"),
            encoding: .utf8)
        #expect(skill == "Help the user.")

        // Round-trip: load the migrated pack
        let reloaded = try DoraxPackV2Loader.load(from: packURL)
        #expect(reloaded.metadata.id == "legacy-plugin")
        #expect(reloaded.agentInstructions == "Be nice.")
        #expect(reloaded.skills.count == 1)

        try? FileManager.default.removeItem(at: outputDir)
    }

    // MARK: - First-party packs

    @Test("All 5 first-party packs load and convert to manifests")
    func firstPartyPacksLoad() throws {
        guard let packsDir = FirstPartyPacks.resolvePacksDirectory() else {
            Issue.record("Packs/ directory not found — cannot test first-party packs")
            return
        }
        let packs = DoraxPackV2Loader.discoverPacks(in: packsDir)
        #expect(packs.count >= 5, "Expected at least 5 first-party packs, found \(packs.count)")

        var loadedIDs: Set<String> = []
        for url in packs {
            let pack = try DoraxPackV2Loader.load(from: url)
            loadedIDs.insert(pack.metadata.id)

            #expect(pack.metadata.formatVersion == 2)
            #expect(!pack.metadata.name.isEmpty)
            #expect(!pack.metadata.capabilities.isEmpty,
                    "\(pack.metadata.id) has no capabilities")

            // Convert to manifest — should not throw
            let manifest = pack.toPluginManifest()
            #expect(manifest.id == pack.metadata.id)
        }

        for expected in FirstPartyPacks.expectedPackIDs {
            #expect(loadedIDs.contains(expected),
                    "Missing first-party pack: \(expected)")
        }
    }

    @Test("Each first-party pack has an AGENT.md")
    func firstPartyPacksHaveAgentMD() throws {
        guard let packsDir = FirstPartyPacks.resolvePacksDirectory() else { return }
        for url in DoraxPackV2Loader.discoverPacks(in: packsDir) {
            let pack = try DoraxPackV2Loader.load(from: url)
            #expect(pack.agentInstructions != nil && !pack.agentInstructions!.isEmpty,
                    "\(pack.metadata.id) missing AGENT.md")
        }
    }

    @Test("Each first-party pack has at least one skill")
    func firstPartyPacksHaveSkills() throws {
        guard let packsDir = FirstPartyPacks.resolvePacksDirectory() else { return }
        for url in DoraxPackV2Loader.discoverPacks(in: packsDir) {
            let pack = try DoraxPackV2Loader.load(from: url)
            #expect(!pack.skills.isEmpty,
                    "\(pack.metadata.id) has no skills")
        }
    }

    // MARK: - Helpers

    private static func makeTempPack(
        id: String, name: String,
        bundleId: String? = nil,
        capabilities: [[String: Any]],
        formatVersion: Int = 2
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-test-\(UUID().uuidString)", isDirectory: true)
        let packDir = root.appendingPathComponent("\(id).doraxpack", isDirectory: true)
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        var json: [String: Any] = [
            "format_version": formatVersion,
            "id": id,
            "name": name,
            "version": "1.0.0",
            "icon": "star",
            "description": "Test pack",
            "capabilities": capabilities
        ]
        if let bid = bundleId { json["bundle_id"] = bid }
        let data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        try data.write(to: packDir.appendingPathComponent("pack.json"))
        return packDir
    }
}
