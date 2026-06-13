import SwiftUI
import AppKit

struct AppearanceSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardSection(title: "Interface Style", systemImage: "sun.max.fill") {
                    Picker("", selection: $settings.appearanceMode) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.vertical, 12)
                    .onChange(of: settings.appearanceMode) { _, mode in
                        applyAppearance(mode)
                    }
                }

                CardSection(title: "Window Appearance", systemImage: "macwindow") {
                    VStack(spacing: 0) {
                        SettingsPageRow(
                            icon: "circle.lefthalf.filled",
                            iconColor: .blue,
                            title: "Window Opacity",
                            subtitle: "Transparency of the launcher window."
                        ) {
                            HStack(spacing: 8) {
                                Slider(value: $settings.launcherWindowOpacity, in: 0.7...1.0, step: 0.05)
                                    .frame(width: 100)
                                Text("\(Int(settings.launcherWindowOpacity * 100))%")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 38, alignment: .trailing)
                            }
                        }
                        Divider()
                        SettingsPageRow(
                            icon: "aqi.medium",
                            iconColor: .teal,
                            title: "Background Blur",
                            subtitle: "Frosted glass effect on launcher background."
                        ) {
                            HStack(spacing: 8) {
                                Slider(value: $settings.glassBlurRadius, in: 0.0...1.0, step: 0.1)
                                    .frame(width: 100)
                                Text(blurLabel)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 38, alignment: .trailing)
                            }
                        }
                    }
                }

                CardSection(title: "Taskbar Mode", systemImage: "menubar.dock.rectangle.badge.record") {
                    SettingsPageRow(
                        icon: "rectangle.bottomhalf.inset.filled",
                        iconColor: .blue,
                        title: "Always on Bottom",
                        subtitle: "Pin Context-Dock to the bottom of your screen like a Windows taskbar, always visible above all apps."
                    ) {
                        Toggle("", isOn: $settings.alwaysDockAtBottom)
                            .labelsHidden()
                            .onChange(of: settings.alwaysDockAtBottom) { _, _ in
                                NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                            }
                    }
                }

                CardSection(title: "Pill Layout", systemImage: "rectangle.grid.1x2") {
                    SettingsPageRow(
                        icon: "list.bullet",
                        iconColor: .indigo,
                        title: "List View",
                        subtitle: "Show actions as a vertical list instead of horizontal scroll."
                    ) {
                        Toggle("", isOn: $settings.useListViewForPills)
                            .labelsHidden()
                    }
                }
            }
            .padding(28)
        }
        .onAppear {
            applyAppearance(settings.appearanceMode)
        }
    }

    private var blurLabel: String {
        if settings.glassBlurRadius == 0 { return "None" }
        if settings.glassBlurRadius >= 1.0 { return "Full" }
        return "\(Int(settings.glassBlurRadius * 100))%"
    }

    private func applyAppearance(_ mode: String) {
        let appearance: NSAppearance? = switch mode {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        NSApp.appearance = appearance
    }
}
