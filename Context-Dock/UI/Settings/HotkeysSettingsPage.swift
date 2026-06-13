import SwiftUI

struct HotkeysSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardSection(title: "Launch Shortcut", systemImage: "bolt.fill") {
                    HStack(spacing: 12) {
                        Text("⌥⌥")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.orange)
                            .frame(width: 38, height: 30)
                            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Double-press Option")
                                .font(.system(size: 13, weight: .medium))
                            Text("Tap Option twice quickly from anywhere to show launcher.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.useDoubleOptionLaunch },
                            set: {
                                settings.useDoubleOptionLaunch = $0
                                NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                            }
                        ))
                        .labelsHidden()
                    }
                    .padding(.vertical, 12)
                }

                CardSection(title: "Global Launcher", systemImage: "globe") {
                    VStack(spacing: 0) {
                        HotkeysInfoRow(keys: "⌃⌥G", action: "Open Global Context (with selection)")
                        Divider()
                        HotkeysInfoRow(keys: "⌃⌥H", action: "Open Global Context (without selection)")
                        Divider()
                        HotkeysInfoRow(keys: "⌃⌥A", action: "Open AI Chat")
                        Divider()
                        HotkeysInfoRow(keys: "⌃⌥M", action: "Show Media Dock")
                    }
                }

                CardSection(title: "Context Dock", systemImage: "rectangle.grid.1x2.fill") {
                    VStack(spacing: 0) {
                        HotkeysInfoRow(keys: "⌃⌥D", action: "Show Context Dock")
                        Divider()
                        HotkeysInfoRow(keys: "⌘R", action: "Refresh Context")
                    }
                }

                CardSection(title: "Dock Key Map", systemImage: "command") {
                    VStack(spacing: 0) {
                        HotkeysInfoRow(keys: "⌥", action: "Focus or unfocus Context Dock input")
                        Divider()
                        HotkeysInfoRow(keys: "⌘", action: "Switch to Global Context and focus input")
                        Divider()
                        HotkeysInfoRow(keys: "Tab", action: "Activate app scope or AI mode")
                        Divider()
                        HotkeysInfoRow(keys: "↩", action: "Run visible result or pill")
                        Divider()
                        HotkeysInfoRow(keys: "Esc", action: "Clear or exit current focused state")
                    }
                }
            }
            .padding(28)
        }
    }
}

private struct HotkeysInfoRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 58)
                .frame(minHeight: 28)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 10)
    }
}
