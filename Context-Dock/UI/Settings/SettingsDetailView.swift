import SwiftUI

struct SettingsDetailView: View {
    let page: SettingsPage
    let integrationDestination: IntegrationDestination?

    var body: some View {
        VStack(spacing: 0) {
            if page != .extensionImport {
                SettingsPageHeader(page: page)
                Divider()
            }
            pageContent
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general:
            GeneralSettingsPage()
        case .aiProviders:
            AIProvidersSettingsPage()
        case .integrations:
            SettingsPlaceholderPage(
                icon: page.icon,
                title: page.title,
                message: "The Integrations workspace will appear here."
            )
        case .extensionsGlobalWithSelection,
             .extensionsGlobalWithoutSelection,
             .extensionsCLIToolScope,
             .frontmostAppAdapters,
             .workflows,
             .shortcutSheetWorkflows:
            ExtensionsSettingsPage(page: page)
        case .extensionImport:
            AutomationImportPanel(onClose: {})
        case .mediaActions:
            MediaActionsSettingsPage()
        case .permissions:
            PermissionsSettingsPage()
        case .appearance:
            AppearanceSettingsPage()
        case .hotkeys:
            HotkeysSettingsPage()
        case .dataStorage:
            DataStorageSettingsPage()
        case .updates:
            UpdatesSettingsPage()
        case .advanced:
            AdvancedSettingsPage()
        case .about:
            AboutSettingsPage()
        }
    }
}

struct SettingsPageHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(page.color.gradient)
                    .frame(width: 38, height: 38)
                Image(systemName: page.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .font(.system(size: 22, weight: .bold))
                Text(page.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct SettingsPlaceholderPage: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(title, systemImage: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
