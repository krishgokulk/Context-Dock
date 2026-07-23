import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case aiProviders
    case extensionsGlobalWithSelection
    case extensionsGlobalWithoutSelection
    case extensionsCLIToolScope
    case extensionImport
    case frontmostAppAdapters
    case mediaActions
    case workflows
    case shortcutSheetWorkflows
    case permissions
    case appearance
    case hotkeys
    case dataStorage
    case updates
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .aiProviders: return "AI Providers"
        case .extensionsGlobalWithSelection: return "With Selection"
        case .extensionsGlobalWithoutSelection: return "Commands"
        case .extensionsCLIToolScope: return "CLI Tool Scope"
        case .extensionImport: return "Create Extension"
        case .frontmostAppAdapters: return "App Adapters"
        case .mediaActions: return "Media Actions"
        case .workflows: return "Automation / Workflows"
        case .shortcutSheetWorkflows: return "Selection Scope"
        case .permissions: return "Permissions"
        case .appearance: return "Appearance"
        case .hotkeys: return "Hotkeys"
        case .dataStorage: return "Data & Storage"
        case .updates: return "Updates"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Launch, layers, clipboard, and app behavior."
        case .aiProviders: return "Choose provider and verify model access."
        case .extensionsGlobalWithSelection: return "Actions shown for selected text, files, URLs, and media."
        case .extensionsGlobalWithoutSelection: return "Always-available global commands."
        case .extensionsCLIToolScope: return "Pinned command-line tools available everywhere."
        case .extensionImport: return "Create manually or paste AI-generated extension JSON."
        case .frontmostAppAdapters: return "App-specific adapters and actions."
        case .mediaActions: return "Image, video, audio, and PDF actions."
        case .workflows: return "Context rules and automation flows."
        case .shortcutSheetWorkflows: return "Actions for the Selection Scope — share and act on selected text or files."
        case .permissions: return "Accessibility, automation, files, network, and AI risk."
        case .appearance: return "Visual preferences for dock and panels."
        case .hotkeys: return "Global keyboard shortcuts and launcher bindings."
        case .dataStorage: return "Backups, local indexes, cache, and storage."
        case .updates: return "Version and update policy."
        case .advanced: return "Developer metadata, menu cache, and diagnostics."
        case .about: return "App identity and build information."
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .aiProviders: return "brain.head.profile"
        case .extensionsGlobalWithSelection: return "selection.pin.in.out"
        case .extensionsGlobalWithoutSelection: return "globe"
        case .extensionsCLIToolScope: return "terminal.fill"
        case .extensionImport: return "plus.app.fill"
        case .frontmostAppAdapters: return "app.connected.to.app.below.fill"
        case .mediaActions: return "photo.on.rectangle.angled"
        case .workflows: return "point.topleft.down.curvedto.point.bottomright.up"
        case .shortcutSheetWorkflows: return "command.square"
        case .permissions: return "lock.shield.fill"
        case .appearance: return "paintpalette.fill"
        case .hotkeys: return "keyboard.fill"
        case .dataStorage: return "internaldrive.fill"
        case .updates: return "arrow.down.circle.fill"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return .blue
        case .aiProviders: return .purple
        case .extensionsGlobalWithSelection: return .teal
        case .extensionsGlobalWithoutSelection: return .indigo
        case .extensionsCLIToolScope: return .green
        case .extensionImport: return .purple
        case .frontmostAppAdapters: return .orange
        case .mediaActions: return .pink
        case .workflows: return .red
        case .shortcutSheetWorkflows: return .red
        case .permissions: return .yellow
        case .appearance: return .cyan
        case .hotkeys: return .mint
        case .dataStorage: return .brown
        case .updates: return .blue
        case .advanced: return .gray
        case .about: return .secondary
        }
    }

    var automationCategory: AutomationCategory? {
        switch self {
        case .extensionsGlobalWithSelection: return .contextTriggers
        case .extensionsGlobalWithoutSelection: return .systemCommands
        case .extensionsCLIToolScope: return .systemCommands
        case .frontmostAppAdapters: return .appActions
        case .workflows: return .contextTriggers
        case .shortcutSheetWorkflows: return .contextTriggers
        case .advanced: return .menuCache
        default: return nil
        }
    }
}

struct SettingsSidebarSection: Identifiable {
    let id: String
    let title: String
    let rows: [SettingsSidebarRow]
}

struct SettingsSidebarRow: Identifiable {
    let id: String
    let title: String
    let page: SettingsPage?
    let children: [SettingsPage]

    init(_ title: String, page: SettingsPage? = nil, children: [SettingsPage] = []) {
        self.id = page?.id ?? title
        self.title = title
        self.page = page
        self.children = children
    }
}

extension SettingsSidebarSection {
    static let all: [SettingsSidebarSection] = [
        SettingsSidebarSection(
            id: "general",
            title: "General",
            rows: [
                SettingsSidebarRow("General", page: .general),
                SettingsSidebarRow("AI Providers", page: .aiProviders)
            ]
        ),
        SettingsSidebarSection(
            id: "extensions",
            title: "Extensions",
            rows: [
                SettingsSidebarRow("Create Extension", page: .extensionImport),
                SettingsSidebarRow("Global Actions", children: [
                    .extensionsGlobalWithoutSelection,
                    .extensionsCLIToolScope
                ]),
                SettingsSidebarRow("Frontmost App Actions", children: [
                    .frontmostAppAdapters
                ]),
                SettingsSidebarRow("Selection Scope", page: .shortcutSheetWorkflows)
            ]
        ),
        SettingsSidebarSection(
            id: "system",
            title: "System",
            rows: [
                SettingsSidebarRow("Permissions", page: .permissions),
                SettingsSidebarRow("Appearance", page: .appearance),
                SettingsSidebarRow("Hotkeys", page: .hotkeys),
                SettingsSidebarRow("Data & Storage", page: .dataStorage),
                SettingsSidebarRow("Updates", page: .updates),
                SettingsSidebarRow("Advanced", page: .advanced),
                SettingsSidebarRow("About", page: .about)
            ]
        )
    ]
}
