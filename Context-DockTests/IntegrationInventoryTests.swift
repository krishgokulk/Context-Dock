import Foundation
import Testing

@testable import Context_Dock

@Suite("Integration inventory")
struct IntegrationInventoryTests {
    @Test func appAndGlobalCapabilitiesStaySeparated() throws {
        let appBundleID = "com.example.editor"
        let appPackage = TerminalPackage.fixture(
            command: "fmt",
            bundleIDs: [appBundleID])
        let globalPackage = TerminalPackage.fixture(
            command: "rg",
            bundleIDs: ["cli://rg"])
        let snapshot = IntegrationInventorySnapshot.fixture(
            adapters: [.fixture(
                bundleID: appBundleID,
                actions: [.fixture(name: "Format")])],
            skills: [.fixture(bundleID: appBundleID, name: "Editing Guide")],
            packages: [appPackage, globalPackage],
            globalPackageIDs: [globalPackage.id],
            mcpServers: [.fixture(name: "Docs", bundleIDs: [appBundleID])],
            commands: [.fixture(name: "Lock Screen")])

        let result = IntegrationInventoryBuilder.build(from: snapshot)
        let app = try #require(result.apps.first)
        #expect(app.bundleID == appBundleID)
        #expect(app.counts.actions == 1)
        #expect(app.counts.skills == 1)
        #expect(app.counts.cliTools == 1)
        #expect(app.counts.mcpServers == 1)
        #expect(result.global.commands.count == 1)
        #expect(result.global.cliTools.map(\.command) == ["rg"])
        #expect(!result.global.cliTools.contains { $0.command == "fmt" })
    }

    @Test func searchMatchesNameBundleIDCapabilityAndType() {
        let inventory = IntegrationInventory.fixture()

        #expect(IntegrationInventoryBuilder.filter(inventory.apps, query: "editor").count == 1)
        #expect(IntegrationInventoryBuilder.filter(inventory.apps, query: "com.example").count == 1)
        #expect(IntegrationInventoryBuilder.filter(inventory.apps, query: "mcp").count == 1)
    }
}

private extension IntegrationInventorySnapshot {
    static func fixture(
        adapters: [AppAdapter] = [],
        skills: [AdapterSkill] = [],
        packages: [TerminalPackage] = [],
        globalPackageIDs: Set<UUID> = [],
        mcpServers: [MCPServerConfig] = [],
        apiConnections: [APIConnection] = [],
        extensions: [ILExtension] = [],
        selectionRules: [AXTriggerRule] = [],
        commands: [SystemCommand] = []
    ) -> Self {
        Self(
            adapters: adapters,
            skills: skills,
            packages: packages,
            globalPackageIDs: globalPackageIDs,
            mcpServers: mcpServers,
            apiConnections: apiConnections,
            extensions: extensions,
            selectionRules: selectionRules,
            commands: commands)
    }
}

private extension IntegrationInventory {
    static func fixture() -> Self {
        let appBundleID = "com.example.editor"
        return IntegrationInventoryBuilder.build(from: .fixture(
            adapters: [.fixture(bundleID: appBundleID)],
            skills: [.fixture(bundleID: appBundleID, name: "Editing Guide")],
            packages: [.fixture(command: "fmt", bundleIDs: [appBundleID])],
            mcpServers: [.fixture(name: "Docs", bundleIDs: [appBundleID])],
            apiConnections: [.fixture(bundleID: appBundleID, name: "Editor API")]))
    }
}

private extension AppAdapter {
    static func fixture(
        bundleID: String,
        appName: String = "Example Editor",
        actions: [AdapterAction] = [],
        contextReaders: [AdapterContextReader] = []
    ) -> Self {
        Self(
            id: bundleID,
            appName: appName,
            bundleId: bundleID,
            icon: "document",
            actions: actions,
            contextReaders: contextReaders)
    }
}

private extension AdapterAction {
    static func fixture(name: String, type: AdapterActionType = .menubar) -> Self {
        Self(id: name, name: name, icon: "bolt", type: type)
    }
}

private extension AdapterSkill {
    static func fixture(bundleID: String, name: String) -> Self {
        Self(
            id: "skill.\(bundleID).\(name)",
            adapterBundleId: bundleID,
            name: name,
            instructions: "Fixture steering text",
            updatedAt: Date(timeIntervalSince1970: 0))
    }
}

private extension TerminalPackage {
    static func fixture(command: String, bundleIDs: [String]) -> Self {
        Self(
            name: command,
            command: command,
            description: "Fixture CLI tool",
            installedPath: "/usr/local/bin/\(command)",
            contextAppBundleIds: bundleIDs)
    }
}

private extension MCPServerConfig {
    static func fixture(name: String, bundleIDs: [String]) -> Self {
        Self(name: name, command: "fixture-mcp", bundleIds: bundleIDs)
    }
}

private extension APIConnection {
    static func fixture(bundleID: String, name: String) -> Self {
        Self(
            id: "api.\(bundleID).\(name)",
            adapterBundleId: bundleID,
            name: name,
            baseURL: "https://example.invalid",
            permissions: "Fixture permissions",
            createdAt: Date(timeIntervalSince1970: 0),
            lastSync: nil,
            status: .connected)
    }
}

private extension SystemCommand {
    static func fixture(name: String) -> Self {
        Self(name: name, icon: "lock", keywords: [], scriptType: "bash", script: "true")
    }
}
