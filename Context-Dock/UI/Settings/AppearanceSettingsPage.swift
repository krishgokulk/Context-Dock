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

                CardSection(title: "Launcher Presentation", systemImage: "macwindow") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Launcher Mode", selection: $settings.launcherPresentationModeRaw) {
                            Text("Centre of Display (Raycast / Spotlight)").tag(AppSettings.LauncherPresentationMode.centerScreen.rawValue)
                            Text("Bottom Dock").tag(AppSettings.LauncherPresentationMode.bottomDock.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if settings.launcherPresentationMode == .centerScreen {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Opens as a floating, draggable launcher in the middle of your screen. Context-Dock remembers where you move it.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Text("Window position:")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    if settings.centredLauncherX >= 0 {
                                        Text("Custom (\(Int(settings.centredLauncherX)), \(Int(settings.centredLauncherY)))")
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.primary)
                                    } else {
                                        Text("Screen Center (Default)")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.primary)
                                    }
                                    Spacer()
                                    Button("Reset to Center") {
                                        settings.resetCentredLauncherPosition()
                                        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(settings.centredLauncherX < 0)
                                }
                                .padding(.top, 4)
                            }
                            .padding(.top, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Dock Position along the bottom screen edge:")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)

                                Picker("Position", selection: $settings.bottomDockPositionRaw) {
                                    Text("Left Corner").tag(AppSettings.BottomDockPosition.left.rawValue)
                                    Text("Centre").tag(AppSettings.BottomDockPosition.center.rawValue)
                                    Text("Right Corner").tag(AppSettings.BottomDockPosition.right.rawValue)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()

                                Divider().padding(.vertical, 4)

                                Toggle(isOn: $settings.cornerDockAutoHide) {
                                    Text("Automatically hide and show the bottom dock")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .toggleStyle(.switch)
                                Text("At rest the bottom dock slides below the screen. Move the pointer to the bottom edge to bring it back.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 10)
                }

                CardSection(title: "Dynamic Notch (Dynamic Island)", systemImage: "sparkles") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $settings.notchLiveActivityEnabled) {
                            Text("Show Dynamic Island in Camera Notch")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .toggleStyle(.switch)
                        Text(
                            """
                            Independent Dynamic Island attached directly to your MacBook camera notch. \
                            Displays real-time media player, file drop shelf, frontmost app extensions, \
                            window controls, and AI approvals.
                            """)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Divider().padding(.vertical, 4)

                        Toggle(isOn: $settings.notchCompactIslandAtRest) {
                            Text("Compact Dynamic Island at rest")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .toggleStyle(.switch)
                        Text("Keep a minimal pill framing the camera notch when idle, expanding downwards smoothly on hover.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Divider().padding(.vertical, 4)

                        Toggle(isOn: $settings.notchOpenOnHover) {
                            Text("Open on hover")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .toggleStyle(.switch)
                        Text("The island opens smoothly when the pointer rests on it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Divider().padding(.vertical, 4)

                        Toggle(isOn: $settings.notchSwellOnHover) {
                            Text("Swell on hover")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .toggleStyle(.switch)
                        Text("The island grows slightly under the pointer before expanding.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }

                CardSection(title: "Liquid Glass", systemImage: "circle.lefthalf.filled") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Glass Darkness")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(Int(settings.glassDarkness * 100))%")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.glassDarkness, in: 0...1)
                        Text("Darken the dock's Liquid Glass — 0% is pure glass, higher is darker.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
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
