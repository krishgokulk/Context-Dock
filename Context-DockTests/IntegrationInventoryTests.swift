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

    @Test func actionsPreserveExecutionSurfaceGroups() throws {
        let adapter = AppAdapter.fixture(
            bundleID: "com.example.editor",
            actions: [
                .fixture(name: "Open Project", type: .menubar),
                .fixture(name: "Read Page", type: .pageJS),
                .fixture(name: "Export Notes", type: .shortcut)
            ])

        let app = try #require(
            IntegrationInventoryBuilder.build(from: .fixture(adapters: [adapter])).apps.first)

        #expect(app.appActions.map(\.name) == ["Open Project"])
        #expect(app.browserActions.map(\.name) == ["Read Page"])
    }

    /// Shortcuts are linked resources, not app actions. Counting them in both places is how
    /// the old page's totals would drift from the rows it actually shows.
    @Test func linkedShortcutsCountAsResourcesNotActions() throws {
        let adapter = AppAdapter.fixture(
            bundleID: "com.example.editor",
            actions: [
                .fixture(name: "Open Project", type: .menubar),
                .fixture(name: "Export Notes", type: .shortcut)
            ])

        let app = try #require(
            IntegrationInventoryBuilder.build(from: .fixture(adapters: [adapter])).apps.first)

        #expect(app.counts.actions == 1)
        #expect(app.counts.shortcuts == 1)
        #expect(!app.actions.contains { $0.type == .shortcut })
    }

    @Test func appsAreOrderedByDisplayName() {
        let inventory = IntegrationInventoryBuilder.build(from: .fixture(adapters: [
            .fixture(bundleID: "com.example.zeta", appName: "Alpha"),
            .fixture(bundleID: "com.example.alpha", appName: "Zeta")
        ]))

        #expect(inventory.apps.map(\.appName) == ["Alpha", "Zeta"])
    }

    @Test func brokenResourceOnlyMarksItsIntegrationNeedsAttention() {
        let brokenBundleID = "com.example.broken"
        let healthyBundleID = "com.example.healthy"
        let inventory = IntegrationInventoryBuilder.build(from: .fixture(
            adapters: [
                .fixture(bundleID: brokenBundleID, appName: "Broken"),
                .fixture(bundleID: healthyBundleID, appName: "Healthy")
            ],
            packages: [
                .fixture(command: "missing", bundleIDs: [brokenBundleID], isInstalled: false),
                .fixture(command: "present", bundleIDs: [healthyBundleID])
            ]))

        #expect(inventory.apps.map(\.appName) == ["Broken", "Healthy"])
        #expect(inventory.apps[0].health == .needsAttention(["CLI tool is not installed"]))
        #expect(inventory.apps[1].health == .healthy)
    }

    @Test func resourcesCountIndependentlyAndSkillsAreNonExecutable() throws {
        let bundleID = "com.example.app"
        let app = try #require(
            IntegrationInventoryBuilder.build(from: .fixture(
                adapters: [.fixture(bundleID: bundleID)],
                skills: [.fixture(bundleID: bundleID, name: "Guide")],
                packages: [.fixture(command: "codex", bundleIDs: [bundleID])],
                mcpServers: [.fixture(name: "Files", bundleIDs: [bundleID])],
                apiConnections: [.fixture(bundleID: bundleID, name: "Service")]
            )).apps.first)

        #expect(app.counts.skills == 1)
        #expect(app.counts.cliTools == 1)
        #expect(app.counts.mcpServers == 1)
        #expect(app.counts.apiConnections == 1)
        #expect(app.skills.allSatisfy { !$0.grantsExecutionAuthority })
    }

    /// Removing an integration deletes the adapter and drops its CLI links; the skills,
    /// MCP servers, and API connections in other stores are left where they are. The
    /// confirmation has to say that, or it promises a cleanup that never happens.
    @Test func removalPreviewSeparatesDeletedRecordsFromRetainedOnes() throws {
        let bundleID = "com.example.editor"
        let otherBundleID = "com.example.other"
        let inventory = IntegrationInventoryBuilder.build(from: .fixture(
            adapters: [
                .fixture(
                    bundleID: bundleID,
                    actions: [
                        .fixture(name: "Format"),
                        .fixture(name: "Read Page", type: .pageJS),
                        .fixture(name: "Export", type: .shortcut)
                    ]),
                .fixture(bundleID: otherBundleID, appName: "Other")
            ],
            skills: [.fixture(bundleID: bundleID, name: "Guide")],
            packages: [
                .fixture(command: "shared", bundleIDs: [bundleID, otherBundleID]),
                .fixture(command: "solo", bundleIDs: [bundleID])
            ],
            mcpServers: [.fixture(name: "Docs", bundleIDs: [bundleID])],
            apiConnections: [.fixture(bundleID: bundleID, name: "Service")]))

        let app = try #require(inventory.apps.first { $0.bundleID == bundleID })
        let preview = IntegrationInventoryBuilder.removalPreview(for: app)

        #expect(preview.removedActionCount == 3)
        #expect(preview.unlinkedCLIToolCount == 2)
        #expect(preview.retainedSkillCount == 1)
        #expect(preview.retainedMCPCount == 1)
        #expect(preview.retainedAPIConnectionCount == 1)
        #expect(preview.retainedSharedResourceNames == ["shared"])
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
    static func fixture(
        command: String,
        bundleIDs: [String],
        isInstalled: Bool = true
    ) -> Self {
        Self(
            name: command,
            command: command,
            description: "Fixture CLI tool",
            installedPath: isInstalled ? "/usr/local/bin/\(command)" : nil,
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
