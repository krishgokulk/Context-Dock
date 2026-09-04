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
    /// Linked macOS Shortcuts. Stored on the adapter as actions, surfaced as a resource.
    let shortcuts: [AdapterAction]
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

/// The reader already carries a stable `id`; this only lets it drive a `ForEach` without
/// restating that identity at every call site.
extension AdapterContextReader: Identifiable {}

extension AdapterSkill {
    /// Skills provide steering text to scoped chat; they are not executable authority.
    var grantsExecutionAuthority: Bool { false }
}

/// What removing an integration actually does.
///
/// Removal deletes the adapter — its actions go with it — and drops this app's CLI links.
/// Skills, MCP servers, and API connections live in their own stores and are left alone, so
/// they are counted separately: a confirmation that implied it cleaned up Keychain-backed
/// API connections would be describing work nobody performs.
struct IntegrationRemovalPreview: Equatable {
    let removedActionCount: Int
    let unlinkedCLIToolCount: Int
    let retainedSkillCount: Int
    let retainedMCPCount: Int
    let retainedAPIConnectionCount: Int
    /// CLI tools that stay linked to another app or to Global after this one is unlinked.
    let retainedSharedResourceNames: [String]
}

/// The workspace's own navigation state.
///
/// Selection is reconciled against the app rows that actually exist rather than trusted,
/// so an integration removed elsewhere can never leave stale detail on screen. Reconciliation
/// is a value operation with no store access, which is why it is testable without a running app.
struct IntegrationSelectionState: Equatable {
    var scope: IntegrationScope = .apps
    var selectedAppID: String?
    var tab: IntegrationDetailTab = .overview
    var focus: IntegrationFocus?
    private var previousOrder: [String] = []

    init(
        scope: IntegrationScope = .apps,
        selectedAppID: String? = nil,
        tab: IntegrationDetailTab = .overview,
        focus: IntegrationFocus? = nil
    ) {
        self.scope = scope
        self.selectedAppID = selectedAppID
        self.tab = tab
        self.focus = focus
    }

    /// Keeps the selection on a row that exists, preferring the row that took the removed
    /// row's place and falling back to the last row when the list shrank past it.
    mutating func reconcile(availableAppIDs: [String]) {
        defer { previousOrder = availableAppIDs }
        guard !availableAppIDs.isEmpty else {
            selectedAppID = nil
            return
        }
        guard let current = selectedAppID else {
            selectedAppID = availableAppIDs.first
            return
        }
        guard !availableAppIDs.contains(current) else { return }
        let oldIndex = previousOrder.firstIndex(of: current) ?? 0
        selectedAppID = availableAppIDs[min(oldIndex, availableAppIDs.count - 1)]
    }

    /// Applies a deep link atomically so scope, app, tab, and focus can never land half-applied.
    mutating func apply(_ destination: IntegrationDestination) {
        scope = destination.scope
        tab = destination.tab
        focus = destination.focus
        if let bundleID = destination.bundleID {
            selectedAppID = bundleID
        }
    }
}

/// Translates between the settings deep-link notification and a typed destination.
///
/// Both directions live here, and `SettingsView` is the only decoder: a caller that posts a
/// legacy page raw value predates this workspace and must still land in the right scope,
/// so neither side of that compatibility can drift.
enum SettingsRouteResolver {
    enum PayloadKey {
        static let page = "page"
        static let scope = "integrationScope"
        static let tab = "integrationTab"
        static let bundleID = "bundleID"
        static let focus = "integrationFocus"
    }

    /// Encodes a destination as primitive user-info values, so the notification stays
    /// readable by callers that know nothing about these types.
    static func notificationPayload(
        for destination: IntegrationDestination
    ) -> [AnyHashable: Any] {
        var payload: [AnyHashable: Any] = [
            PayloadKey.page: SettingsPage.integrations.rawValue,
            PayloadKey.scope: destination.scope.rawValue,
            PayloadKey.tab: destination.tab.rawValue
        ]
        payload[PayloadKey.bundleID] = destination.bundleID
        payload[PayloadKey.focus] = destination.focus?.rawValue
        return payload
    }

    /// Reads a destination out of a notification, accepting both the typed payload and a
    /// bare legacy page raw value.
    static func destination(from payload: [AnyHashable: Any]?) -> IntegrationDestination? {
        guard let payload,
              let rawPage = payload[PayloadKey.page] as? String,
              let page = SettingsPage(rawValue: rawPage)
        else { return nil }

        guard page == .integrations else { return destination(for: page) }

        let scope = (payload[PayloadKey.scope] as? String)
            .flatMap(IntegrationScope.init(rawValue:)) ?? .apps
        let tab = (payload[PayloadKey.tab] as? String)
            .flatMap(IntegrationDetailTab.init(rawValue:)) ?? .overview
        let focus = (payload[PayloadKey.focus] as? String)
            .flatMap(IntegrationFocus.init(rawValue:))

        return IntegrationDestination(
            scope: scope,
            bundleID: payload[PayloadKey.bundleID] as? String,
            tab: tab,
            focus: focus)
    }

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
