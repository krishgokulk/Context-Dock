import SwiftUI

struct ExtensionsSettingsPage: View {
    let page: SettingsPage

    var body: some View {
        VStack(spacing: 0) {
            extensionScopeBanner
            Divider()
            AutomationSettingsView(settingsPage: page)
                .id(page)
        }
    }

    private var extensionScopeBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: page.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(page.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(scopeTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(scopeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var scopeTitle: String {
        switch page {
        case .extensionsGlobalWithSelection:
            return "Global Actions • With Selection"
        case .extensionsGlobalWithoutSelection:
            return "Global Actions • Commands"
        case .extensionsCLIToolScope:
            return "Global Actions • CLI Tool Scope"
        case .frontmostAppAdapters:
            return "Frontmost App Actions • App Adapters"
        case .workflows:
            return "Automation / Workflows"
        case .shortcutSheetWorkflows:
            return "Automation / Workflows • Shortcut Sheet"
        default:
            return page.title
        }
    }

    private var scopeDescription: String {
        switch page {
        case .extensionsGlobalWithSelection:
            return "Shown when selected text, files, URLs, images, or media are available. Runner type stays inside action details."
        case .extensionsGlobalWithoutSelection:
            return "Always-available commands such as Wi-Fi, Bluetooth, Sleep, Restart, Shut Down, and AI chat."
        case .extensionsCLIToolScope:
            return "Pinned CLI tools such as yt-dlp, localsend, and ffmpeg. They remain global and provider-neutral."
        case .frontmostAppAdapters:
            return "Actions scoped to current/frontmost app, including Finder, Safari, Xcode, Mail, and custom adapters."
        case .workflows:
            return "Rules and workflows triggered by context. Technical trigger metadata stays in editor details."
        case .shortcutSheetWorkflows:
            return "Actions shown when user long-presses Command on selected text, files, URLs, or app context."
        default:
            return page.subtitle
        }
    }
}
