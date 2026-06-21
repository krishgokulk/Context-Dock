import SwiftUI
import AppKit

struct GeneralSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardSection(title: "Release", systemImage: "testtube.2") {
                    SettingsPageRow(
                        icon: "testtube.2",
                        iconColor: .purple,
                        title: "Context-Dock Beta",
                        subtitle: "Open-source beta for testing Global Context, Context Dock, media, AI chat, and selection actions."
                    ) {
                        Text("1.1 beta")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.thinMaterial, in: Capsule(style: .continuous))
                    }
                }

                CardSection(title: "Startup", systemImage: "power") {
                    VStack(spacing: 0) {
                        SettingsPageRow(
                            icon: "arrow.clockwise.circle.fill",
                            iconColor: .blue,
                            title: "Launch at Login",
                            subtitle: "Open Context-Dock automatically when you log in."
                        ) {
                            LaunchAtLoginToggle()
                        }
                        Divider()
                        SettingsPageRow(
                            icon: "menubar.rectangle",
                            iconColor: .teal,
                            title: "Show Menu Bar Icon",
                            subtitle: "Keep Context-Dock accessible from menu bar."
                        ) {
                            Toggle("", isOn: Binding(
                                get: { settings.showMenuBarIcon },
                                set: {
                                    settings.showMenuBarIcon = $0
                                    NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
                                }
                            ))
                            .labelsHidden()
                        }
                    }
                }

                CardSection(title: "Dock Behavior", systemImage: "dock.rectangle") {
                    VStack(spacing: 0) {
                        SettingsPageRow(
                            icon: "pin.fill",
                            iconColor: .pink,
                            title: "Always Float Dock",
                            subtitle: "Keep the dock visible after running actions — don't auto-hide on focus loss. Dismiss with Escape."
                        ) {
                            Toggle("", isOn: $settings.alwaysFloatDock)
                                .labelsHidden()
                        }
                        Divider()
                        SettingsPageRow(
                            icon: "puzzlepiece.extension.fill",
                            iconColor: .orange,
                            title: "Built-in Extensions",
                            subtitle: "Show first-party actions based on selection and frontmost app."
                        ) {
                            Toggle("", isOn: $settings.enableContextAIExtensions)
                                .labelsHidden()
                        }
                    }
                }

                CardSection(title: "Layers", systemImage: "square.3.layers.3d.top.filled") {
                    VStack(spacing: 0) {
                        SettingsPageRow(
                            icon: "rectangle.grid.1x2.fill",
                            iconColor: .indigo,
                            title: "Context Dock",
                            subtitle: "Enable frontmost-app action layer."
                        ) {
                            Toggle("", isOn: $settings.enableLayer2)
                                .labelsHidden()
                        }
                        Divider()
                        SettingsPageRow(
                            icon: "music.note.tv.fill",
                            iconColor: .pink,
                            title: "Media Dock",
                            subtitle: "Enable now-playing and media action layer."
                        ) {
                            Toggle("", isOn: $settings.enableLayer3)
                                .labelsHidden()
                        }
                        Divider()
                        SettingsPageRow(
                            icon: "brain.head.profile",
                            iconColor: .cyan,
                            title: "AI Chat Mode",
                            subtitle: "Allow AI chat from dock layers."
                        ) {
                            Toggle("", isOn: $settings.enableAIMode)
                                .labelsHidden()
                        }
                    }
                }

                CardSection(title: "Smart Context", systemImage: "sparkles") {
                    VStack(spacing: 0) {
                        SettingsPageRow(
                            icon: "doc.on.clipboard.fill",
                            iconColor: .orange,
                            title: "Clipboard-Aware Pills",
                            subtitle: "Surface actions from current clipboard content."
                        ) {
                            Toggle("", isOn: $settings.clipboardAwarePills)
                                .labelsHidden()
                        }
                    }
                }

                CardSection(title: "Clipboard History", systemImage: "clock.arrow.circlepath") {
                    VStack(spacing: 0) {
                        SettingsPageRow(
                            icon: "number",
                            iconColor: .blue,
                            title: "History Limit",
                            subtitle: "Maximum clipboard entries kept."
                        ) {
                            Stepper(value: $settings.clipboardHistoryLimit, in: 5...50, step: 5) {
                                Text("\(settings.clipboardHistoryLimit)")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .frame(minWidth: 34, alignment: .trailing)
                            }
                        }
                        Divider()
                        SettingsPageRow(
                            icon: "timer",
                            iconColor: .red,
                            title: "Auto-Remove After",
                            subtitle: "Remove clipboard entries after this many hours."
                        ) {
                            Stepper(value: $settings.clipboardHistoryRetentionHours, in: 1...24, step: 1) {
                                Text("\(settings.clipboardHistoryRetentionHours)h")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .frame(minWidth: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

struct SettingsPageRow<Accessory: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            accessory()
        }
        .padding(.vertical, 11)
    }
}
