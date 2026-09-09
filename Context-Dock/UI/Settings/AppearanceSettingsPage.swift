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

                CardSection(title: "Corner Position", systemImage: "rectangle.bottomthird.inset.filled") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $settings.cornerDockAnchorRaw) {
                            ForEach(CornerDockAnchor.allCases, id: \.rawValue) { anchor in
                                Text(anchor.label).tag(anchor.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(
                            """
                            Where the chat, clipboard, selection and shelf sit along the \
                            bottom of the screen. Centred, they read as a dock.
                            """)
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
