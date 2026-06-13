import SwiftUI

struct UpdatesSettingsPage: View {
    @State private var isChecking = false
    @State private var lastChecked: Date? = nil

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
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Context Dock is up to date")
                                    .font(.system(size: 13, weight: .medium))
                                if let checked = lastChecked {
                                    Text("Last checked \(checked, style: .relative) ago")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Checks run automatically on launch")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                checkForUpdates()
                            } label: {
                                if isChecking {
                                    HStack(spacing: 6) {
                                        ProgressView().scaleEffect(0.75)
                                        Text("Checking…")
                                    }
                                    .frame(minWidth: 90)
                                } else {
                                    Text("Check Now")
                                        .frame(minWidth: 90)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isChecking)
                        }
                    }
                    .padding(.vertical, 12)
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
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(28)
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

    private func checkForUpdates() {
        isChecking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isChecking = false
            lastChecked = Date()
        }
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
