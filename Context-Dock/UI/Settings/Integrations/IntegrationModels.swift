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
