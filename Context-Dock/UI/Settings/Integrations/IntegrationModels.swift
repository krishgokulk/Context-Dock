import Foundation

enum IntegrationScope: String, CaseIterable, Identifiable, Codable {
    case apps, global

    var id: Self { self }
}

enum IntegrationDetailTab: String, CaseIterable, Identifiable, Codable {
    case overview, actions, resources, access

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum IntegrationFocus: String, Codable, Equatable {
    case selectionActions, commands, cliTools, mcpServers
}

struct IntegrationDestination: Codable, Equatable {
    var scope: IntegrationScope
    var bundleID: String?
    var tab: IntegrationDetailTab
    var focus: IntegrationFocus?

    init(
        scope: IntegrationScope,
        bundleID: String? = nil,
        tab: IntegrationDetailTab = .overview,
        focus: IntegrationFocus? = nil
    ) {
        self.scope = scope
        self.bundleID = bundleID
        self.tab = tab
        self.focus = focus
    }
}

struct IntegrationResourceCounts: Equatable {
    let actions: Int
    let skills: Int
    let cliTools: Int
    let mcpServers: Int
    let apiConnections: Int
    let shortcuts: Int
    let contextReaders: Int

    var resources: Int {
        skills + cliTools + mcpServers + apiConnections + shortcuts + contextReaders
    }
}

enum IntegrationHealth: Equatable {
    case healthy
    case needsAttention([String])
}

struct IntegrationInventorySnapshot {
    let adapters: [AppAdapter]
    let skills: [AdapterSkill]
    let packages: [TerminalPackage]
    /// Package identities already classified by the snapshot owner as deliberately global.
    /// Keeping this value in the snapshot prevents inventory composition from consulting
    /// `TerminalPackageManager` or its persisted settings.
    let globalPackageIDs: Set<UUID>
    let mcpServers: [MCPServerConfig]
    let apiConnections: [APIConnection]
    let extensions: [ILExtension]
    let selectionRules: [AXTriggerRule]
    let commands: [SystemCommand]
}

struct IntegrationInventory {
    let apps: [AppIntegrationSummary]
    let global: GlobalIntegrationSummary
}

struct AppIntegrationSummary: Identifiable {
    let bundleID: String
    let appName: String
    let icon: String
    let adapter: AppAdapter?
    let appActions: [AdapterAction]
    let browserActions: [AdapterAction]
    let skills: [AdapterSkill]
    let cliTools: [TerminalPackage]
    let mcpServers: [MCPServerConfig]
    let apiConnections: [APIConnection]
    let contextReaders: [AdapterContextReader]
    let counts: IntegrationResourceCounts
    let health: IntegrationHealth

    var id: String { bundleID }

    var actions: [AdapterAction] {
        appActions + browserActions
    }

    /// Skills are prompt context only; they never grant execution authority.
    var skillsGrantExecutionAuthority: Bool { false }
}

struct GlobalIntegrationSummary {
    let commands: [SystemCommand]
    let selectionExtensions: [ILExtension]
    /// Kept distinct from selection extensions because AX rules have different ownership
    /// and execution semantics.
    let selectionRules: [AXTriggerRule]
    let cliTools: [TerminalPackage]
    let mcpServers: [MCPServerConfig]
}

extension AdapterSkill {
    /// Skills provide steering text to scoped chat; they are not executable authority.
    var grantsExecutionAuthority: Bool { false }
}

enum SettingsRouteResolver {
    static func destination(for page: SettingsPage) -> IntegrationDestination? {
        switch page {
        case .frontmostAppAdapters:
            return .init(scope: .apps)
        case .extensionsGlobalWithoutSelection:
            return .init(scope: .global, tab: .actions, focus: .commands)
        case .extensionsCLIToolScope:
            return .init(scope: .global, tab: .resources, focus: .cliTools)
        case .shortcutSheetWorkflows:
            return .init(scope: .global, tab: .actions, focus: .selectionActions)
        default:
            return nil
        }
    }
}
