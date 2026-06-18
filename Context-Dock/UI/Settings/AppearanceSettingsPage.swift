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

    private func applyAppearance(_ mode: String) {
        let appearance: NSAppearance? = switch mode {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        NSApp.appearance = appearance
    }
}
