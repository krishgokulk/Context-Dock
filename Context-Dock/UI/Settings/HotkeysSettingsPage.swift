import Carbon.HIToolbox
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

                CardSection(title: "Custom Shortcuts", systemImage: "keyboard") {
                    VStack(spacing: 0) {
                        ClipboardHotkeyRecorderRow(
                            icon: "doc.on.clipboard", iconColor: .orange,
                            title: "Clipboard Scope",
                            subtitle: "Open clipboard history as a chat-ready scope from anywhere",
                            displayString: settings.clipboardScopeHotkeyDisplayString,
                            onClear: {
                                settings.clipboardScopeHotkeyKeyCode = 0
                                settings.clipboardScopeHotkeyModifiers = 0
                                NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                            }
                        ) { kc, mod in
                            settings.clipboardScopeHotkeyKeyCode = kc
                            settings.clipboardScopeHotkeyModifiers = mod
                            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                        }
                        Divider()
                        captureHotkeyRow(
                            icon: "note.text", color: .indigo,
                            title: "Quick Note",
                            subtitle: "Open a floating pinned note anywhere",
                            display: settings.quickNoteHotkeyDisplayString,
                            clear: {
                                settings.quickNoteHotkeyKeyCode = 0
                                settings.quickNoteHotkeyModifiers = 0
                            },
                            apply: {
                                settings.quickNoteHotkeyKeyCode = $0
                                settings.quickNoteHotkeyModifiers = $1
                            })
                        Divider()
                        captureHotkeyRow(
                            icon: "macwindow.on.rectangle", color: .cyan,
                            title: "Window Review",
                            subtitle: "Preview and restore the current app's open and minimized windows",
                            display: settings.windowReviewHotkeyDisplayString,
                            clear: {
                                settings.windowReviewHotkeyKeyCode = 0
                                settings.windowReviewHotkeyModifiers = 0
                            },
                            apply: {
                                settings.windowReviewHotkeyKeyCode = $0
                                settings.windowReviewHotkeyModifiers = $1
                            })
                        Divider()
                        captureHotkeyRow(
                            icon: "text.viewfinder", color: .blue,
                            title: "Capture Text",
                            subtitle: "Select text on screen, OCR it, and save it to Clipboard",
                            display: settings.captureTextHotkeyDisplayString,
                            clear: {
                                settings.captureTextHotkeyKeyCode = 0
                                settings.captureTextHotkeyModifiers = 0
                            },
                            apply: {
                                settings.captureTextHotkeyKeyCode = $0
                                settings.captureTextHotkeyModifiers = $1
                            })
                        Divider()
                        captureHotkeyRow(
                            icon: "crop", color: .purple,
                            title: "Capture Area",
                            subtitle: "Select a screen region; save it to Pictures and Clipboard",
                            display: settings.captureAreaHotkeyDisplayString,
                            clear: {
                                settings.captureAreaHotkeyKeyCode = 0
                                settings.captureAreaHotkeyModifiers = 0
                            },
                            apply: {
                                settings.captureAreaHotkeyKeyCode = $0
                                settings.captureAreaHotkeyModifiers = $1
                            })
                        Divider()
                        captureHotkeyRow(
                            icon: "camera.viewfinder", color: .green,
                            title: "Screenshot",
                            subtitle: "Capture the full screen; save it to Pictures and Clipboard",
                            display: settings.captureScreenshotHotkeyDisplayString,
                            clear: {
                                settings.captureScreenshotHotkeyKeyCode = 0
                                settings.captureScreenshotHotkeyModifiers = 0
                            },
                            apply: {
                                settings.captureScreenshotHotkeyKeyCode = $0
                                settings.captureScreenshotHotkeyModifiers = $1
                            })
                    }
                    .padding(.vertical, 4)
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

    private func captureHotkeyRow(
        icon: String, color: Color, title: String, subtitle: String, display: String,
        clear: @escaping () -> Void,
        apply: @escaping (UInt32, UInt32) -> Void
    ) -> some View {
        ClipboardHotkeyRecorderRow(
            icon: icon, iconColor: color, title: title, subtitle: subtitle,
            displayString: display,
            onClear: {
                clear()
                NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
            }
        ) { keyCode, modifiers in
            apply(keyCode, modifiers)
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        }
        .padding(.vertical, 4)
    }
}

/// Compact map of how the dock surfaces relate: ↑/↓ cycles Global ↔ Context Dock ↔ Media,
/// and ←/→ switches into AI Assistant.
private struct DockNavigationDiagram: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            modeChip("sparkles", "AI Assistant", "Ask or do anything…", .purple)

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

/// Records a global shortcut (needs ≥1 modifier) for the active Hotkeys page.
private struct ClipboardHotkeyRecorderRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let displayString: String
    let onClear: (() -> Void)?
    let apply: (UInt32, UInt32) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if isRecording {
                Text("Press keys…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                Button("Cancel") { stopRecording() }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Button { startRecording() } label: {
                    Text(displayString)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(displayString == "Not Set" ? .tertiary : .primary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                if let clear = onClear, displayString != "Not Set" {
                    Button { clear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary).font(.system(size: 14))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            var carbon: UInt32 = 0
            if event.modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
            if event.modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if carbon != 0 {
                self.apply(UInt32(event.keyCode), carbon)
                self.stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
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
