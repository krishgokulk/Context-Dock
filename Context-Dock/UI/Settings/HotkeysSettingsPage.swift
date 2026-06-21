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

                CardSection(title: "Context Dock", systemImage: "rectangle.grid.1x2.fill") {
                    VStack(spacing: 0) {
                        HotkeysInfoRow(keys: "⌘R", action: "Refresh Context — re-scan the frontmost app's live menus")
                    }
                }

                CardSection(title: "Dock Key Map", systemImage: "command") {
                    VStack(spacing: 0) {
                        HotkeysInfoRow(keys: "⌘", action: "Switch between Global Context and Context Dock")
                        Divider()
                        HotkeysInfoRow(keys: "→", action: "Autocomplete to scope the highlighted app")
                        Divider()
                        HotkeysInfoRow(keys: "↩", action: "Run the focused result or pill")
                        Divider()
                        HotkeysInfoRow(keys: "Esc", action: "Close — clear focus / dismiss the dock")
                    }
                }

                CardSection(title: "Navigation", systemImage: "arrow.up.arrow.down") {
                    DockNavigationDiagram()
                        .padding(.vertical, 12)
                }
            }
            .padding(28)
        }
    }
}

/// Compact map of how the dock surfaces relate: ↑/↓ cycles Global ↔ Context Dock ↔ Media,
/// and ←/→ switches into General AI Chat.
private struct DockNavigationDiagram: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            modeChip("sparkles", "General AI Chat", "Ask anything…", .purple)

            VStack(spacing: 2) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.blue)
                Text("← / →")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                modeChip("globe", "Global Context", "Search apps, files, commands", .blue)
                arrowBetween
                modeChip("rectangle.grid.1x2", "Context Dock", "Frontmost app — menus & actions", .green)
                arrowBetween
                modeChip("music.note", "Media Dock", "Now playing controls", .pink)
            }
        }
    }

    private var arrowBetween: some View {
        VStack(spacing: 1) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.blue)
            Text("↑ / ↓")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func modeChip(_ icon: String, _ title: String, _ subtitle: String, _ tint: Color)
        -> some View
    {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 240, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.2)))
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
