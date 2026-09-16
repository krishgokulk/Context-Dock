import SwiftUI

/// What "Add" can mean at one place in the workspace.
///
/// The set is derived from the scope and section on screen, so the menu never offers a
/// capability that has nowhere to go: an app-scoped skill has no meaning in Global, and an
/// MCP server has no global storage to be written to.
enum IntegrationAddAction: String, CaseIterable, Equatable, Identifiable {
    case chooseApp
    case importIntegration
    case addAction
    case addSkill
    case addCLITool
    case addMCPServer
    case connectAPI
    case linkShortcut
    case addCommand
    case addSelectionAction

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chooseApp: return "Choose App…"
        case .importIntegration: return "Import Integration…"
        case .addAction: return "Add Action…"
        case .addSkill: return "Add Skill…"
        case .addCLITool: return "Add CLI Tool…"
        case .addMCPServer: return "Add MCP Server…"
        case .connectAPI: return "Connect API…"
        case .linkShortcut: return "Link Shortcut…"
        case .addCommand: return "Add Command…"
        case .addSelectionAction: return "Add Selection Action…"
        }
    }

    var icon: String {
        switch self {
        case .chooseApp: return "app.badge.checkmark"
        case .importIntegration: return "square.and.arrow.down"
        case .addAction: return "bolt"
        case .addSkill: return "brain.head.profile"
        case .addCLITool: return "terminal"
        case .addMCPServer: return "server.rack"
        case .connectAPI: return "link"
        case .linkShortcut: return "command"
        case .addCommand: return "globe"
        case .addSelectionAction: return "selection.pin.in.out"
        }
    }

    static func available(
        scope: IntegrationScope,
        tab: IntegrationDetailTab
    ) -> [IntegrationAddAction] {
        switch (scope, tab) {
        case (.apps, .actions):
            return [.addAction, .importIntegration]
        case (.apps, .resources):
            return [.addSkill, .addCLITool, .addMCPServer, .connectAPI, .linkShortcut]
        case (.apps, _):
            return [.chooseApp, .importIntegration]
        case (.global, .actions):
            return [.addCommand, .addSelectionAction]
        case (.global, .resources):
            // No MCP: a server exists only as a link to an app, so there is no global one
            // to create. The section still lists and explains what is there.
            return [.addCLITool]
        case (.global, _):
            return [.addCommand, .addSelectionAction, .addCLITool]
        }
    }
}

/// The one Add control in the workspace. It renders whatever the current scope and section
/// allow and reports the choice; presenting the editor is the page's job.
struct IntegrationAddMenu: View {
    let actions: [IntegrationAddAction]
    let perform: (IntegrationAddAction) -> Void

    var body: some View {
        Menu {
            ForEach(actions) { action in
                Button {
                    perform(action)
                } label: {
                    Label(action.title, systemImage: action.icon)
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(actions.isEmpty)
        .accessibilityLabel("Add integration capability")
    }
}
