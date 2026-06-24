import SwiftUI

struct UpdatesSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = AppUpdateService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardSection(title: "Installed Version", systemImage: "info.circle.fill") {
                    SettingsPageRow(
                        icon: "app.badge.checkmark.fill",
                        iconColor: .blue,
                        title: "Context Dock",
                        subtitle: bundleVersion
                    ) { EmptyView() }
                }

                CardSection(title: "Software Update", systemImage: "arrow.down.circle.fill") {
                    VStack(spacing: 0) {
                        SettingsPageRow(
                            icon: "arrow.triangle.2.circlepath.circle.fill",
                            iconColor: .green,
                            title: "Automatic Updates",
                            subtitle: "Check on launch, download beta DMG, and open installer when update is ready."
                        ) {
                            Toggle("", isOn: $settings.automaticUpdatesEnabled)
                                .labelsHidden()
                        }
                        Divider()
                        SettingsPageRow(
                            icon: "shippingbox.fill",
                            iconColor: .blue,
                            title: updateTitle,
                            subtitle: updateSubtitle
                        ) {
                            updateAccessory
                        }
                    }
                }

                CardSection(title: "What's New", systemImage: "note.text") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Version \(shortVersion)")
                            .font(.system(size: 13, weight: .semibold))
                        VStack(alignment: .leading, spacing: 5) {
                            ReleaseNoteRow("Global Context ranks apps, useful menus, and recent menu use first")
                            ReleaseNoteRow("Context Dock result sheets stay stable while typing")
                            ReleaseNoteRow("Menu actions use native shortcuts and frontmost-app routing")
                            ReleaseNoteRow("Settings, extensions, and shortcut sheet import flow polished")
                            ReleaseNoteRow("AI profiles and provider routing prepared for beta testing")
                            ReleaseNoteRow("Open-source beta update channel uses GitHub-hosted release manifest")
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(28)
        }
    }

    @ViewBuilder
    private var updateAccessory: some View {
        switch updater.status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.75)
                Text("Checking")
            }
            .frame(minWidth: 100)
        case .available(let manifest):
            Button("Download") {
                updater.downloadAndOpen(manifest)
            }
            .buttonStyle(.borderedProminent)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.75)
                Text("Downloading")
            }
            .frame(minWidth: 110)
        case .downloaded:
            Button("Open DMG") {
                updater.openDownloadedUpdate()
            }
            .buttonStyle(.borderedProminent)
        default:
            Button("Check Now") {
                updater.checkForUpdates()
            }
            .buttonStyle(.bordered)
        }
    }

    private var updateTitle: String {
        switch updater.status {
        case .checking: return "Checking for Updates"
        case .upToDate: return "Context-Dock is up to date"
        case .available(let manifest): return "Context-Dock \(manifest.version) beta available"
        case .downloading(let manifest): return "Downloading \(manifest.version) beta"
        case .downloaded(let manifest, _): return "\(manifest.version) beta ready to install"
        case .failed: return "Update check failed"
        case .idle: return "Check for Updates"
        }
    }

    private var updateSubtitle: String {
        let checkedText: String
        if let checked = updater.lastChecked {
            let relative = RelativeDateTimeFormatter()
            checkedText = "Last checked \(relative.localizedString(for: checked, relativeTo: Date()))."
        } else {
            checkedText = settings.automaticUpdatesEnabled
                ? "Auto-check runs after launch."
                : "Auto-check is disabled."
        }

        switch updater.status {
        case .available(let manifest):
            return "\(manifest.channel.capitalized) build \(manifest.build). \(manifest.notes.first ?? checkedText)"
        case .downloaded(_, let url):
            return "Downloaded to \(url.path). Open DMG, drag app to Applications."
        case .failed(let message):
            return "\(message). \(checkedText)"
        default:
            return checkedText
        }
    }

    private var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (Build \(build))"
    }

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
    }

}

private struct ReleaseNoteRow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
