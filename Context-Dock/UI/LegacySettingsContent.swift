//
//  SettingsView.swift
//  ILauncher
//
//  Created by Krishgokul on 20/11/2025.
//

import SwiftUI
import AppKit
import Carbon
import UniformTypeIdentifiers
import WebKit

struct LegacySettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            AIProviderSettingsView()
                .tabItem { Label("AI", systemImage: "brain.head.profile") }
                .tag(1)

            AutomationSettingsView()
                .tabItem { Label("Automation", systemImage: "bolt.badge.automatic.fill") }
                .tag(2)

            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(4)
        }
        .frame(width: 960, height: 700)
    }
}

// MARK: - General Settings Tab

enum GeneralSection: String, CaseIterable, Identifiable {
    case launcher   = "Launcher"
    case shortcuts  = "Shortcuts"
    case layers     = "Layers"
    case appearance = "Appearance"
    case clipboard  = "Clipboard"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .launcher:   return "square.grid.2x2.fill"
        case .shortcuts:  return "keyboard.fill"
        case .layers:     return "square.3.layers.3d.top.filled"
        case .appearance: return "paintpalette.fill"
        case .clipboard:  return "doc.on.clipboard.fill"
        }
    }

    var color: Color {
        switch self {
        case .launcher:   return .blue
        case .shortcuts:  return .teal
        case .layers:     return .purple
        case .appearance: return .pink
        case .clipboard:  return .orange
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var selected: GeneralSection = .launcher

    var body: some View {
        HStack(spacing: 0) {
            // ── Modern sidebar ──────────────────────────────────────────────
            VStack(spacing: 0) {
                // App branding header
                HStack(spacing: 10) {
                    Image(systemName: "dock.rectangle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text("Context-Dock")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)

                Divider()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        sidebarGroup("App") {
                            sidebarItem(.launcher)
                            sidebarItem(.shortcuts)
                        }
                        sidebarGroup("Navigation") {
                            sidebarItem(.layers)
                        }
                        sidebarGroup("Customize") {
                            sidebarItem(.appearance)
                            sidebarItem(.clipboard)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
            }
            .frame(width: 200)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // ── Detail panel ───────────────────────────────────────────────
            VStack(spacing: 0) {
                // Section header
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected.color.gradient)
                            .frame(width: 36, height: 36)
                        Image(systemName: selected.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text(selected.rawValue)
                        .font(.system(size: 22, weight: .bold))
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        detailContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    @ViewBuilder
    private func sidebarGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 3)
            content()
        }
    }

    private func sidebarItem(_ section: GeneralSection) -> some View {
        Button { selected = section } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(section.color.gradient)
                        .frame(width: 28, height: 28)
                    Image(systemName: section.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(section.rawValue)
                    .font(.system(size: 13, weight: selected == section ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected == section ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected == section ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selected {
        case .launcher:   launcherPanel
        case .shortcuts:  shortcutsPanel
        case .layers:     layersPanel
        case .appearance: appearancePanel
        case .clipboard:  clipboardPanel
        }
    }

    // MARK: - Launcher panel
    private var launcherPanel: some View {
        VStack(spacing: 20) {
            CardSection(title: "Menu Bar Icon", systemImage: "menubar.rectangle") {
                VStack(spacing: 0) {
                    SettingsRow {
                        GeneralToggleLabel("Show Menu Bar Icon",
                            caption: "Display Context Dock icon in the macOS menu bar.")
                        Toggle("", isOn: Binding(
                            get: { settings.showMenuBarIcon },
                            set: { settings.showMenuBarIcon = $0
                                  NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil) }
                        )).labelsHidden()
                    }
                    SettingsDivider()
                    LaunchAtLoginToggle()
                }
            }

            CardSection(title: "Smart Features", systemImage: "sparkles") {
                VStack(spacing: 0) {
                    SettingsRow {
                        GeneralToggleLabel("Clipboard-Aware Pills",
                            caption: "Surface one-tap actions from clipboard content (URL, text, file).")
                        Toggle("", isOn: $settings.clipboardAwarePills).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow {
                        GeneralToggleLabel("Session Detection",
                            caption: "Detects dev / browse / comms sessions and re-ranks adapter pills.")
                        Toggle("", isOn: $settings.sessionDetectionPills).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow {
                        GeneralToggleLabel("Let the AI decide how to answer",
                            caption: "Keyword matches become suggestions the AI can weigh, "
                                + "instead of answering for it. Turn off to restore the older "
                                + "keyword-first behaviour.")
                        Toggle("", isOn: $settings.agentModelFirstRouting).labelsHidden()
                    }
                }
            }

            CardSection(title: "Built-in Extensions", systemImage: "puzzlepiece.extension") {
                SettingsRow {
                    GeneralToggleLabel("Enable Built-in Extensions",
                        caption: "Show AI-powered suggestions based on what's selected or open in the frontmost app.")
                    Toggle("", isOn: $settings.enableContextAIExtensions).labelsHidden()
                }
            }

            CardSection(title: "Backup & Restore", systemImage: "arrow.up.arrow.down.circle") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export all your settings, shortcuts, and extensions for safekeeping or to move to another Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button {
                            let result = SettingsBackupManager.shared.exportSettings().map { _ in () }
                            showAlert(result: result, successMessage: "Settings exported successfully!")
                        } label: {
                            Label("Export Settings", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            let result = SettingsBackupManager.shared.importSettings().map { _ in () }
                            showAlert(result: result, successMessage: "Settings imported! Some changes may require a restart.")
                        } label: {
                            Label("Import Settings", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }

            CardSection(title: "Quit App", systemImage: "power") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quit Context Dock")
                            .font(.system(size: 13, weight: .medium))
                        Text("Completely exit the app and remove it from the menu bar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
        }
    }

    // MARK: - Shortcuts panel
    private var shortcutsPanel: some View {
        VStack(spacing: 20) {
            CardSection(title: "Launch Shortcut", systemImage: "bolt.fill") {
                VStack(spacing: 0) {
                    SettingsRow {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.orange.opacity(0.15))
                                    .frame(width: 34, height: 34)
                                Text("⌥⌥")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.orange)
                            }
                            GeneralToggleLabel("Double-press ⌥ Option",
                                caption: "Tap Option twice quickly from anywhere to show the launcher.")
                        }
                        Toggle("", isOn: Binding(
                            get: { settings.useDoubleOptionLaunch },
                            set: {
                                settings.useDoubleOptionLaunch = $0
                                NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                            }
                        )).labelsHidden()
                    }
                }
            }

            CardSection(title: "Custom Shortcuts", systemImage: "keyboard") {
                HotkeyRecorderRow(
                    icon: "doc.on.clipboard", iconColor: .orange,
                    title: "Clipboard Scope",
                    subtitle: "Open clipboard history as a chat-ready scope",
                    displayString: settings.clipboardScopeHotkeyDisplayString,
                    onClear: {
                        settings.clipboardScopeHotkeyKeyCode = 0
                        settings.clipboardScopeHotkeyModifiers = 0
                        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                    }
                ) { kc, mod in
                    settings.clipboardScopeHotkeyKeyCode = kc
                    settings.clipboardScopeHotkeyModifiers = mod
                }

                HotkeyRecorderRow(
                    icon: "note.text", iconColor: .indigo,
                    title: "Quick Note",
                    subtitle: "Open a floating pinned note anywhere",
                    displayString: settings.quickNoteHotkeyDisplayString,
                    onClear: {
                        settings.quickNoteHotkeyKeyCode = 0
                        settings.quickNoteHotkeyModifiers = 0
                        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                    }
                ) { kc, mod in
                    settings.quickNoteHotkeyKeyCode = kc
                    settings.quickNoteHotkeyModifiers = mod
                }
            }

            CardSection(title: "Dock Key Map", systemImage: "command") {
                VStack(spacing: 0) {
                    DockKeyMapRow(keys: "⌥", action: "Focus or unfocus Context Dock input")
                    SettingsDivider()
                    DockKeyMapRow(keys: "⌘", action: "Switch to Global Context and focus input")
                    SettingsDivider()
                    DockKeyMapRow(keys: "Tab", action: "Global Context: activate app scope. Context Dock: ignored")
                    SettingsDivider()
                    DockKeyMapRow(keys: "→", action: "Complete ghost text")
                    SettingsDivider()
                    DockKeyMapRow(keys: "↩", action: "Run the visible result or pill")
                    SettingsDivider()
                    DockKeyMapRow(keys: "↑ / ↓", action: "Switch dock layers when available")
                    SettingsDivider()
                    DockKeyMapRow(keys: "Esc", action: "Clear or exit the current focused state")
                    SettingsDivider()
                    DockKeyMapRow(keys: "⌘ hold", action: "Show available menu command shortcuts")
                }
            }

            CardSection(title: "How to Record", systemImage: "info.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "cursorarrow.click").foregroundStyle(.blue).font(.system(size: 13))
                        Text("Click the shortcut badge to start recording, then press your desired key combination.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "keyboard").foregroundStyle(.purple).font(.system(size: 13))
                        Text("Shortcuts require at least one modifier key: ⌘ Command, ⌥ Option, ⌃ Control, or ⇧ Shift.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Layers panel
    private var layersPanel: some View {
        VStack(spacing: 20) {
            CardSection(title: "Layer 1 — Global Context", systemImage: "globe") {
                VStack(spacing: 0) {
                    SettingsRow {
                        GeneralToggleLabel("Pinned Apps, Files & Folders",
                            caption: "Pinned apps stay available in the base search layer.")
                        Toggle("", isOn: .constant(true)).disabled(true).labelsHidden()
                    }
                }
            }

            CardSection(title: "Layer 2 — Context Dock", systemImage: "rectangle.grid.1x2") {
                SettingsRow {
                    GeneralToggleLabel("Enable Context Dock",
                        caption: "Swipe up from Layer 1 to connect to the frontmost app and surface one-tap actions.")
                    Toggle("", isOn: $settings.enableLayer2).labelsHidden()
                }
            }

            CardSection(title: "Layer 3 — Media Dock", systemImage: "music.note.tv") {
                SettingsRow {
                    GeneralToggleLabel("Enable Media Dock",
                        caption: "Swipe up from Layer 2 to open the now-playing controller for active media.")
                    Toggle("", isOn: $settings.enableLayer3).labelsHidden()
                }
            }

            CardSection(title: "AI Assistant", systemImage: "brain.head.profile") {
                SettingsRow {
                    GeneralToggleLabel("Enable AI Assistant Mode",
                        caption: "Swipe left/right — or press Tab — to open AI Assistant from any layer.")
                    Toggle("", isOn: $settings.enableAIMode).labelsHidden()
                }
            }

            CardSection(title: "Navigation", systemImage: "arrow.up.arrow.down") {
                VStack(spacing: 10) {
                    HStack(spacing: 0) {
                        LayerChip(number: "1", label: "Global\nContext", color: .blue,   enabled: true)
                        LayerArrow(enabled: settings.enableLayer2)
                        LayerChip(number: "2", label: "Context\nDock",  color: .purple, enabled: settings.enableLayer2)
                        LayerArrow(enabled: settings.enableLayer3)
                        LayerChip(number: "3", label: "Media\nDock",    color: .teal,   enabled: settings.enableLayer3)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("Swipe left / right from any layer")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        LayerChip(number: "✦", label: "AI\nChat", color: .indigo, enabled: settings.enableAIMode)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Appearance panel
    private var appearancePanel: some View {
        VStack(spacing: 20) {
            CardSection(title: "Dock Icon", systemImage: "app") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Icon shown in the top-right corner of the dock.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $settings.dockLogoStyle) {
                        Text("D Logo").tag("d_logo")
                        Text("Apple Logo").tag("apple")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            CardSection(title: "Dock Size", systemImage: "dock.rectangle") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("S").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 14)
                        Slider(value: $settings.dockIconSize, in: 28...72, step: 2)
                        Text("L").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 14)
                        Text("\(Int(settings.dockIconSize))pt")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary).frame(minWidth: 36, alignment: .trailing)
                    }
                    Text("App icon and pill size in the dock.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Clipboard panel
    private var clipboardPanel: some View {
        VStack(spacing: 20) {
            CardSection(title: "History", systemImage: "clock.arrow.circlepath") {
                VStack(spacing: 0) {
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("History Limit").font(.system(size: 13, weight: .medium))
                            Text("Number of clipboard entries kept. Press ↑ in the dock to expand inline.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Stepper(value: $settings.clipboardHistoryLimit, in: 5...50, step: 5) {
                            Text("\(settings.clipboardHistoryLimit) items")
                                .font(.system(size: 13, weight: .medium))
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                    }
                    SettingsDivider()
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Remove After").font(.system(size: 13, weight: .medium))
                            Text("Items and dropped file groups are removed after this duration.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Stepper(value: $settings.clipboardHistoryRetentionHours, in: 1...24, step: 1) {
                            Text("\(settings.clipboardHistoryRetentionHours)h")
                                .font(.system(size: 13, weight: .medium))
                                .frame(minWidth: 36, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func showAlert(result: Result<Void, Error>, successMessage: String) {
        let alert = NSAlert()
        switch result {
        case .success:
            alert.messageText = "Success"
            alert.informativeText = successMessage
            alert.alertStyle = .informational
        case .failure(let error):
            alert.messageText = "Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Row layout helpers

private struct SettingsRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            content()
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 0)
    }
}

private struct DockKeyMapRow: View {
    let keys: String
    let action: String

    var body: some View {
        SettingsRow {
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 58)
                .frame(minHeight: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )

            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

// MARK: - Layer flow diagram helpers

private struct LayerChip: View {
    let number: String
    let label: String
    let color: Color
    let enabled: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(enabled ? color.opacity(0.18) : Color.secondary.opacity(0.10))
                    .frame(minWidth: 60, maxWidth: 80, minHeight: 48)
                VStack(spacing: 2) {
                    Text(number)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(enabled ? color : .secondary)
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(enabled ? color.opacity(0.8) : .secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                }
            }
            if !enabled {
                Text("off")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct LayerArrow: View {
    let enabled: Bool
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(enabled ? Color.primary.opacity(0.4) : Color.secondary.opacity(0.25))
            .frame(width: 24)
            .padding(.bottom, 16) // align with chip center
    }
}

// MARK: - Small reusable helpers for General settings

private struct GeneralToggleLabel: View {
    let title: String
    let caption: String
    var isSubItem: Bool = false
    init(_ title: String, caption: String, isSubItem: Bool = false) {
        self.title = title; self.caption = caption; self.isSubItem = isSubItem
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(isSubItem ? .subheadline : .headline)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct GeneralSlider: View {
    let icon: String
    let iconColor: Color
    let label: String
    @Binding var value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(iconColor).font(.system(size: 13))
                Text(label).font(.subheadline).fontWeight(.medium)
                Spacer()
                Text("\(Int(value * 100))%").font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0.0...1.0, step: 0.05)
        }
    }
}

struct CardSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section label
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .padding(.leading, 4)

            // Content card
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - File Index Status View (Spotlight-backed — always live)
struct FileIndexStatusView: View {
    @ObservedObject var fileIndexManager = FileIndexManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("File Index")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if fileIndexManager.progress.isIndexing {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.6)
                        Text("Loading…").font(.caption).foregroundStyle(.orange)
                    }
                } else if fileIndexManager.isReady {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.system(size: 12))
                        Text("Ready").font(.caption).foregroundStyle(.green)
                    }
                }
            }

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files Indexed").font(.caption2).foregroundStyle(.secondary)
                    Text("\(fileIndexManager.indexedFiles.count)")
                        .font(.system(size: 16, weight: .semibold))
                }
                if let last = fileIndexManager.metadata.lastFullIndexDate {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last Updated").font(.caption2).foregroundStyle(.secondary)
                        Text(last, style: .relative).font(.caption)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            // Spotlight badge
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .foregroundStyle(.blue).font(.system(size: 12))
                Text("Powered by Spotlight — always up-to-date, no rebuild needed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Search Directories List View
struct SearchDirectoriesListView: View {
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Search Directories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button(action: addDirectory) {
                    Label("Add Directory", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            
            if settings.searchDirectories.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)

                    Text("No directories added")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Add directories to limit search scope. If notes aren't appearing in results, ensure their parent folders are included here or turn off custom directories.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(Color.gray.opacity(0.06))
                .cornerRadius(8)
            } else {
                VStack(spacing: 4) {
                    ForEach(settings.searchDirectories) { directory in
                        SearchDirectoryRow(directory: directory)
                    }
                }
                .padding(8)
                .background(Color.gray.opacity(0.06))
                .cornerRadius(8)
            }
        }
    }
    
    func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a directory to search"
        panel.prompt = "Select"

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
                settings.addSearchDirectory(url: url, displayName: displayName)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}

// MARK: - Search Directory Row
struct SearchDirectoryRow: View {
    let directory: SearchDirectory
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(directory.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                
                Text(directory.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            Button(action: {
                settings.removeSearchDirectory(directory)
            }) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove directory")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.5))
        .cornerRadius(6)
    }
}

// MARK: - AI Provider Settings Tab
struct AIProviderSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult? = nil
    @State private var isFetchingModels = false
    @State private var fetchedOllamaModels: [OllamaModel] = []
    @State private var isDiscoveringCompatibleModels = false
    @State private var compatibleModels: [String] = []
    @State private var compatibleModelDiscoveryError: String?
    @State private var firstPartyModels: [String] = []
    @State private var discoveredFirstPartyProvider: AIProvider?
    @State private var firstPartyModelDiscoveryError: String?
    @State private var isDiscoveringFirstPartyModels = false
    @State private var modelDiscoveryTask: Task<Void, Never>?
    @State private var isTestingAppleScriptModel = false
    @State private var appleScriptModelTestMessage: String?
    @State private var appleScriptModelTestOK = false
    @State private var isRunningProviderQA = false
    
    enum ConnectionTestResult {
        case success(String)
        case failure(String)
    }
    
    /// One prompt that steers every AI surface. Lives here rather than per-surface so
    /// tone, language and standing rules are set once — the router folds it into whatever
    /// system prompt General Chat, Context Dock chat or an extension panel builds.
    @ViewBuilder
    private var globalContextPromptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Global Context Prompt")
                .font(.headline)

            Text("Prepended to every AI surface — General Chat, Context Dock chat and "
                 + "extension panels. Use it for standing instructions: who you are, "
                 + "preferred language, how answers should be formatted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $settings.globalContextPrompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 90)
                .padding(6)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if settings.globalContextPrompt.isEmpty {
                        Text("e.g. Answer concisely. I'm a macOS developer working in Swift.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text("\(settings.globalContextPrompt.count) characters")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !settings.globalContextPrompt.isEmpty {
                    Button("Clear") { settings.globalContextPrompt = "" }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Provider")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Select and configure your preferred AI provider for the AI mode.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                globalContextPromptSection

                // Provider Selection
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select Provider")
                        .font(.headline)
                    
                    ForEach(AIProviderSupportTier.allCases) { tier in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tier.rawValue)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)

                            ForEach(AIProvider.allCases.filter { $0.supportTier == tier }) { provider in
                                AIProviderRow(
                                    provider: provider,
                                    isSelected: settings.selectedAIProvider == provider,
                                    isConfigured: settings.isProviderConfigured(provider)
                                ) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        settings.selectedAIProvider = provider
                                    }
                                }
                            }
                        }
                    }
                }
                
                Divider()
                
                // Configuration Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Configuration")
                            .font(.headline)
                        
                        Spacer()
                        
                        if settings.isProviderConfigured(settings.selectedAIProvider) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Configured")
                                    .foregroundStyle(.green)
                            }
                            .font(.caption)
                        }
                    }
                    
                    providerConfigurationView
                }

                Divider()

                appleScriptAutomationModelView

                // Test Connection Button
                if settings.selectedAIProvider != .onDevice && settings.selectedAIProvider != .shortcuts {
                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(action: testConnection) {
                                HStack(spacing: 8) {
                                    if isTestingConnection {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "network")
                                    }
                                    Text("Test Connection")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTestingConnection || !settings.isProviderConfigured(settings.selectedAIProvider))

                            if let result = connectionTestResult {
                                connectionResultView(result)
                            }
                        }
                        HStack {
                            Button("Test Text") { testProviderText() }
                            Button("Test Vision") { testProviderVision() }
                            Button("Test Tool Calls") { testProviderToolCalls() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            isRunningProviderQA
                                || !settings.isProviderConfigured(settings.selectedAIProvider)
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Privacy")
                        .font(.headline)
                    Toggle(
                        "Allow selected text to be sent to cloud AI providers",
                        isOn: $settings.allowSelectedTextCloudSharing
                    )
                    Text("Local and on-device providers can always use selected text. Cloud requests still require the existing private-data approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Cloud providers never receive a continuous screen feed. They receive your prompt plus context used for that request: explicit attachments, approved selected text or browser content, and—in app-scoped Context Dock chat—a textual summary of the active app. Screenshots are sent only when explicitly attached or captured with approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(24)
        }
    }
    
    @ViewBuilder
    private var providerConfigurationView: some View {
        switch settings.selectedAIProvider {
        case .onDevice:
            onDeviceConfigView
        case .openAI:
            VStack(alignment: .leading, spacing: 12) {
                apiKeyConfigView(
                    title: "OpenAI API Key",
                    key: $settings.openAIAPIKey,
                    placeholder: "sk-...",
                    helpURL: "https://platform.openai.com/api-keys"
                )
                firstPartyModelPicker(
                    selection: $settings.selectedOpenAIModel,
                    provider: .openAI,
                    apiKey: settings.openAIAPIKey)
            }
        case .googleGemini:
            apiKeyConfigView(
                title: "Google Gemini API Key",
                key: $settings.googleGeminiAPIKey,
                placeholder: "AIza...",
                helpURL: "https://makersuite.google.com/app/apikey"
            )
        case .anthropic:
            VStack(alignment: .leading, spacing: 12) {
                apiKeyConfigView(
                    title: "Anthropic API Key",
                    key: $settings.anthropicAPIKey,
                    placeholder: "sk-ant-...",
                    helpURL: "https://platform.claude.com/settings/workspaces/default/keys"
                )
                firstPartyModelPicker(
                    selection: $settings.selectedAnthropicModel,
                    provider: .anthropic,
                    apiKey: settings.anthropicAPIKey)
            }
        case .ollama:
            ollamaConfigView
        case .openAICompatible:
            openAICompatibleConfigView
        case .claudeBridge:
            bridgeConfigView(
                title: "Claude Pro Bridge",
                subtitle: "Connect via VibeProxy or any OpenAI-compatible bridge exposing your Claude subscription.",
                icon: "arrow.triangle.2.circlepath.circle.fill",
                iconColor: .purple,
                endpointBinding: $settings.claudeBridgeEndpoint,
                modelBinding: $settings.claudeBridgeModelID,
                defaultEndpoint: "http://localhost:8317/v1",
                defaultModel: "claude-opus-4-8",
                vibeProxyNote: "Claude Pro → VibeProxy :8317 → DoraX. Your existing subscription pays."
            )
        case .chatGPTBridge:
            bridgeConfigView(
                title: "ChatGPT Plus Bridge",
                subtitle: "Connect via VibeProxy or any OpenAI-compatible bridge exposing your ChatGPT subscription.",
                icon: "arrow.triangle.2.circlepath.circle",
                iconColor: .green,
                endpointBinding: $settings.chatGPTBridgeEndpoint,
                modelBinding: $settings.chatGPTBridgeModelID,
                defaultEndpoint: "http://localhost:8317/v1",
                defaultModel: "gpt-4o",
                vibeProxyNote: "ChatGPT Plus → VibeProxy :8317 → DoraX. Your existing subscription pays."
            )
        case .shortcuts:
            shortcutsConfigView
        }
    }
    
    private var onDeviceConfigView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 32))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("On-Device Intelligence")
                        .font(.headline)
                    Text("Powered by Apple's Foundation Models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                FeatureRow(icon: "lock.shield.fill", text: "Private - data never leaves your device", color: .green)
                FeatureRow(icon: "bolt.fill", text: "Fast - no network latency", color: .orange)
                FeatureRow(icon: "key.slash", text: "No API key required", color: .blue)
                FeatureRow(icon: "macbook", text: "Requires Apple Silicon Mac", color: .purple)
            }
            .padding()
            .background(Color.gray.opacity(0.06))
            .cornerRadius(12)


            // Custom System Prompt
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("System Prompt")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()
                }

                Text("Customize the behavior and personality of the AI assistant")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $settings.onDeviceSystemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 100)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )

                HStack {
                    Button("Reset to Default") {
                        settings.onDeviceSystemPrompt = "You are a helpful AI assistant for quick queries and information. Provide concise, accurate answers to user questions. Keep responses brief and to the point."
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)

                    Spacer()

                    Text("\(settings.onDeviceSystemPrompt.count) characters")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Note: On-device AI uses Apple Intelligence and requires macOS 15+ and an Apple Silicon Mac with sufficient RAM.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    private func apiKeyConfigView(title: String, key: Binding<String>, placeholder: String, helpURL: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            
            HStack {
                SecureField(placeholder, text: key)
                    .textFieldStyle(.roundedBorder)
                
                if !key.wrappedValue.isEmpty {
                    Button(action: {
                        key.wrappedValue = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            HStack {
                Button(action: {
                    if let url = URL(string: helpURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle")
                        Text("Get API Key")
                    }
                    .font(.caption)
                }
                .buttonStyle(.link)
                
                Spacer()
                
                Text("Your API key is stored securely in your Mac's Keychain")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func firstPartyModelPicker(
        selection: Binding<String>,
        provider: AIProvider,
        apiKey: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chat Model")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Button(action: { discoverFirstPartyModels(provider: provider, apiKey: apiKey) }) {
                    if isDiscoveringFirstPartyModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh Models", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(apiKey.isEmpty || isDiscoveringFirstPartyModels)
            }

            if firstPartyModels.isEmpty || discoveredFirstPartyProvider != provider {
                TextField("Model ID", text: selection)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("Available Model", selection: selection) {
                    if !firstPartyModels.contains(selection.wrappedValue) {
                        Text(selection.wrappedValue).tag(selection.wrappedValue)
                    }
                    ForEach(firstPartyModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
            }

            if let firstPartyModelDiscoveryError {
                Text(firstPartyModelDiscoveryError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("The selected model is used for chat, attachments, and tool calls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: apiKey) { _, newKey in
            modelDiscoveryTask?.cancel()
            guard newKey.count > 10 else { return }
            modelDiscoveryTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    discoverFirstPartyModels(provider: provider, apiKey: newKey)
                }
            }
        }
        .onAppear {
            guard apiKey.count > 10,
                (firstPartyModels.isEmpty || discoveredFirstPartyProvider != provider)
            else { return }
            discoverFirstPartyModels(provider: provider, apiKey: apiKey)
        }
    }

    private func discoverFirstPartyModels(provider: AIProvider, apiKey: String) {
        isDiscoveringFirstPartyModels = true
        firstPartyModelDiscoveryError = nil
        Task {
            do {
                let models: [String]
                switch provider {
                case .openAI:
                    models = try await FirstPartyModelDiscovery.openAI(apiKey: apiKey)
                case .anthropic:
                    models = try await FirstPartyModelDiscovery.anthropic(apiKey: apiKey)
                default:
                    models = []
                }
                await MainActor.run {
                    firstPartyModels = models
                    discoveredFirstPartyProvider = provider
                    if models.isEmpty {
                        firstPartyModelDiscoveryError = "The provider returned no chat models."
                    }
                    isDiscoveringFirstPartyModels = false
                }
            } catch {
                await MainActor.run {
                    firstPartyModelDiscoveryError = error.localizedDescription
                    isDiscoveringFirstPartyModels = false
                }
            }
        }
    }

    private var openAICompatibleConfigView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OpenAI-Compatible Endpoint")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Experimental")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text("Use user-managed OpenRouter, LM Studio, or compatible `/v1` gateways. Context-Dock does not support subscription login, browser cookies, or desktop-app sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("OpenRouter Preset") {
                    settings.openAICompatibleEndpoint = "https://openrouter.ai/api/v1"
                    settings.openAICompatibleModelID = "openai/gpt-4o-mini"
                }
                Button("LM Studio Preset") {
                    settings.openAICompatibleEndpoint = "http://localhost:1234/v1"
                    settings.openAICompatibleModelID = ""
                }
            }
            .buttonStyle(.bordered)
            TextField("http://localhost:1234/v1", text: $settings.openAICompatibleEndpoint)
                .textFieldStyle(.roundedBorder)
            Text("Model ID")
                .font(.subheadline)
                .fontWeight(.medium)
            HStack {
                TextField("model-name", text: $settings.openAICompatibleModelID)
                    .textFieldStyle(.roundedBorder)
                Button(action: discoverCompatibleModels) {
                    if isDiscoveringCompatibleModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Discover Models", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isDiscoveringCompatibleModels || settings.openAICompatibleEndpoint.isEmpty)
            }
            if !compatibleModels.isEmpty {
                Picker("Discovered Model", selection: $settings.openAICompatibleModelID) {
                    ForEach(compatibleModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
            }
            if let compatibleModelDiscoveryError {
                Text(compatibleModelDiscoveryError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            apiKeyConfigView(
                title: "API Key (optional for local endpoints)",
                key: $settings.openAICompatibleAPIKey,
                placeholder: "Optional",
                helpURL: "https://platform.openai.com/docs/api-reference"
            )
        }
    }

    // Optional specialist backend: a model fine-tuned for NL→AppleScript (e.g. Osaurus
    // AppleScript-8B/16B). Independent of the chat provider above — used only by the
    // action/execution layer when no deterministic route exists. Chat stays on whatever
    // provider is selected.
    private var appleScriptAutomationModelView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "applescript")
                    .foregroundStyle(.orange)
                Text("AppleScript Automation Model")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $settings.appleScriptModelEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text("Optional specialist that turns automation requests into AppleScript in the action layer — your chat provider above is unchanged. Great with Osaurus AppleScript-8B/16B; it does NOT chat, so don't set it as your main model.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.appleScriptModelEnabled {
                Button("Osaurus Preset") {
                    settings.appleScriptModelEndpoint = "http://127.0.0.1:1337/v1"
                    if settings.appleScriptModelID.isEmpty {
                        settings.appleScriptModelID = "AppleScript-8B"
                    }
                }
                .buttonStyle(.bordered)

                Text("Endpoint")
                    .font(.subheadline).fontWeight(.medium)
                TextField("http://127.0.0.1:1337/v1", text: $settings.appleScriptModelEndpoint)
                    .textFieldStyle(.roundedBorder)

                Text("Model ID")
                    .font(.subheadline).fontWeight(.medium)
                TextField("AppleScript-8B", text: $settings.appleScriptModelID)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button(action: testAppleScriptModel) {
                        HStack(spacing: 6) {
                            if isTestingAppleScriptModel {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "network")
                            }
                            Text("Test AppleScript Model")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        isTestingAppleScriptModel
                        || settings.appleScriptModelEndpoint.isEmpty
                        || settings.appleScriptModelID.isEmpty)
                    if let appleScriptModelTestMessage {
                        Label(
                            appleScriptModelTestMessage,
                            systemImage: appleScriptModelTestOK
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(appleScriptModelTestOK ? .green : .red)
                        .lineLimit(2)
                    }
                }
            }
        }
    }

    private func testAppleScriptModel() {
        isTestingAppleScriptModel = true
        appleScriptModelTestMessage = nil
        Task {
            let result = await AppleScriptModelService.shared.testConnection()
            await MainActor.run {
                isTestingAppleScriptModel = false
                switch result {
                case let .success(message):
                    appleScriptModelTestOK = true
                    appleScriptModelTestMessage = message
                case let .failure(error):
                    appleScriptModelTestOK = false
                    appleScriptModelTestMessage = error.localizedDescription
                }
            }
        }
    }

    private func bridgeConfigView(
        title: String,
        subtitle: String,
        icon: String,
        iconColor: Color,
        endpointBinding: Binding<String>,
        modelBinding: Binding<String>,
        defaultEndpoint: String,
        defaultModel: String,
        vibeProxyNote: String
    ) -> some View {
        BridgeConfigView(
            title: title,
            subtitle: subtitle,
            icon: icon,
            iconColor: iconColor,
            endpointBinding: endpointBinding,
            modelBinding: modelBinding,
            defaultEndpoint: defaultEndpoint,
            defaultModel: defaultModel,
            vibeProxyNote: vibeProxyNote
        )
    }

    private var ollamaConfigView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Endpoint Configuration
            VStack(alignment: .leading, spacing: 8) {
                Text("Ollama Endpoint")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack {
                    TextField("http://localhost:11434", text: $settings.ollamaEndpoint)
                        .textFieldStyle(.roundedBorder)
                    
                    Button(action: fetchOllamaModels) {
                        HStack(spacing: 4) {
                            if isFetchingModels {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Fetch Models")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isFetchingModels || settings.ollamaEndpoint.isEmpty)
                }
            }
            
            // Model Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Select Model")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if fetchedOllamaModels.isEmpty && settings.ollamaModels.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        
                        Text("No models found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text("Make sure Ollama is running and click 'Fetch Models'")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.06))
                    .cornerRadius(8)
                } else {
                    let models = fetchedOllamaModels.isEmpty ? settings.ollamaModels : fetchedOllamaModels
                    
                    Picker("Model", selection: $settings.selectedOllamaModel) {
                        Text("Select a model").tag("")
                        ForEach(models) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            
            // Help text
            VStack(alignment: .leading, spacing: 4) {
                Text("To use Ollama:")
                    .font(.caption)
                    .fontWeight(.medium)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Install Ollama from ollama.ai")
                    Text("2. Run 'ollama pull llama3.2' to download a model")
                    Text("3. Click 'Fetch Models' above to see available models")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.blue.opacity(0.06))
            .cornerRadius(8)
        }
    }
    
    private var shortcutsConfigView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Shortcuts")
                        .font(.headline)
                    Text("Use any shortcut as your AI provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                FeatureRow(icon: "wand.and.stars", text: "Fully customizable workflow", color: .blue)
                FeatureRow(icon: "lock.shield.fill", text: "Private - you control the data", color: .green)
                FeatureRow(icon: "key.slash", text: "No API key needed from us", color: .orange)
                FeatureRow(icon: "app.badge.checkmark", text: "Works with any AI service", color: .purple)
            }
            .padding()
            .background(Color.gray.opacity(0.06))
            .cornerRadius(12)
            
            Divider()
            
            // Shortcut Picker
            VStack(alignment: .leading, spacing: 12) {
                Text("Select Shortcut")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("Choose a shortcut that accepts text input and provides a text response")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                ShortcutPickerView(selectedShortcut: $settings.shortcutsProviderShortcut)
            }
            .padding()
            .background(Color.blue.opacity(0.06))
            .cornerRadius(12)

            // Help text
            VStack(alignment: .leading, spacing: 8) {
                Text("💡 How to create a compatible shortcut:")
                    .font(.caption)
                    .fontWeight(.medium)
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("1. Open Shortcuts app")
                    Text("2. Create new shortcut with 'Shortcut Input'")
                    Text("3. Add your AI integration (ChatGPT, Claude, etc.)")
                    Text("4. Make sure it outputs text result")
                    Text("5. Enable 'Show in Share Sheet' and 'Receive Input'")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.orange.opacity(0.06))
            .cornerRadius(8)
            
            Text("Note: Your shortcut will receive the user's query as input and should return a text response.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private func connectionResultView(_ result: ConnectionTestResult) -> some View {
        switch result {
        case .success(let message):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .foregroundStyle(.green)
            }
            .font(.caption)
        case .failure(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
            }
            .font(.caption)
        }
    }
    
    private func testConnection() {
        isTestingConnection = true
        connectionTestResult = nil
        
        Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000) // Simulate network delay
                
                switch settings.selectedAIProvider {
                case .ollama:
                    // Test Ollama connection
                    let endpoint = settings.ollamaEndpoint.trimmingCharacters(in: .whitespaces)
                    guard let url = URL(string: "\(endpoint)/api/tags") else {
                        throw NSError(domain: "Invalid URL", code: -1)
                    }
                    
                    let (_, response) = try await URLSession.shared.data(from: url)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        await MainActor.run {
                            connectionTestResult = .success("Connected to Ollama")
                        }
                    } else {
                        throw NSError(domain: "Connection failed", code: -1)
                    }
                    
                case .openAI, .googleGemini, .anthropic:
                    // For API-based providers, we just verify the key format
                    let key = settings.getAPIKey(for: settings.selectedAIProvider)
                    if key.count > 10 {
                        await MainActor.run {
                            connectionTestResult = .success("API key looks valid")
                        }
                    } else {
                        throw NSError(domain: "API key too short", code: -1)
                    }

                case .openAICompatible:
                    guard settings.isProviderConfigured(.openAICompatible) else {
                        throw NSError(domain: "Endpoint and model are required", code: -1)
                    }
                    let response = try await AIProviderRouter.shared.send(
                        AIRequest(
                            text: "Reply with OK.",
                            context: .none,
                            source: .aiChat,
                            additionalContextPrompt: "Connection test. Return only OK."
                        ),
                        provider: .openAICompatible
                    )
                    guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw NSError(domain: "Compatible endpoint returned an empty response", code: -1)
                    }
                    await MainActor.run {
                        connectionTestResult = .success("OpenAI-compatible endpoint responded")
                    }
                    
                default:
                    break
                }
            } catch {
                await MainActor.run {
                    connectionTestResult = .failure("Connection failed: \(error.localizedDescription)")
                }
            }
            
            await MainActor.run {
                isTestingConnection = false
            }
        }
    }
    
    private func fetchOllamaModels() {
        isFetchingModels = true
        
        Task {
            let models = await settings.fetchOllamaModels()
            
            await MainActor.run {
                fetchedOllamaModels = models
                settings.ollamaModels = models
                isFetchingModels = false
                
                // Auto-select first model if none selected
                if settings.selectedOllamaModel.isEmpty && !models.isEmpty {
                    settings.selectedOllamaModel = models[0].name
                }
            }
        }
    }

    private func discoverCompatibleModels() {
        isDiscoveringCompatibleModels = true
        compatibleModelDiscoveryError = nil
        Task {
            do {
                let models = try await OpenAICompatibleModelDiscovery.discover(
                    endpoint: settings.openAICompatibleEndpoint,
                    apiKey: settings.openAICompatibleAPIKey
                )
                await MainActor.run {
                    compatibleModels = models
                    if settings.openAICompatibleModelID.isEmpty, let first = models.first {
                        settings.openAICompatibleModelID = first
                    }
                    if models.isEmpty {
                        compatibleModelDiscoveryError = "Endpoint returned no models."
                    }
                    isDiscoveringCompatibleModels = false
                }
            } catch {
                await MainActor.run {
                    compatibleModelDiscoveryError = error.localizedDescription
                    isDiscoveringCompatibleModels = false
                }
            }
        }
    }

    private func testProviderText() {
        runProviderQA {
            let response = try await AIProviderRouter.shared.send(
                AIRequest(text: "Reply with TEXT_OK only.", context: .none, source: .aiChat),
                provider: settings.selectedAIProvider
            )
            guard response.uppercased().contains("TEXT_OK") else {
                throw AIServiceError.emptyResponse("Text test returned unexpected response")
            }
            return "Text test passed"
        }
    }

    private func testProviderVision() {
        runProviderQA {
            guard AIProviderRouter.shared.capabilities(for: settings.selectedAIProvider)
                .supportsImages
            else {
                throw AIServiceError.unsupportedProvider(
                    "The selected provider or model does not support image input")
            }
            guard let data = visionTestImageData() else {
                throw AIServiceError.networkError("Could not create vision test image")
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("context-dock-vision-test.png")
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url) }
            let response = try await AIProviderRouter.shared.send(
                AIRequest(
                    text: "What is the dominant color of this image? Reply briefly.",
                    context: .none,
                    attachments: [.init(kind: .image, url: url)],
                    source: .aiChat
                ),
                provider: settings.selectedAIProvider
            )
            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIServiceError.emptyResponse("Vision test returned empty response")
            }
            return "Vision test passed"
        }
    }

    /// A provider-safe fixture. The previous 1×1 PNG was valid but below the practical
    /// minimum accepted by several vision APIs, which made every provider look broken.
    private func visionTestImageData() -> Data? {
        let width = 128
        let height = 128
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let pixels = bitmap.bitmapData else { return nil }

        for index in stride(from: 0, to: width * height * 4, by: 4) {
            pixels[index] = 45
            pixels[index + 1] = 115
            pixels[index + 2] = 230
            pixels[index + 3] = 255
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func testProviderToolCalls() {
        runProviderQA {
            let provider = settings.selectedAIProvider
            guard provider != .onDevice, provider != .shortcuts else {
                throw AIServiceError.unsupportedProvider("Selected provider does not support tool-call QA")
            }
            let key = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : nil
            let result = try await AIProviderService.shared.sendWithTools(
                "Call run_command once with command `echo TOOL_OK` and purpose `Provider tool-call QA`.",
                context: .none,
                provider: provider,
                apiKey: key,
                conversationHistory: [],
                commandExecutor: { command, _, _ in
                    (true, command.contains("TOOL_OK") ? "TOOL_OK" : "Simulated tool output")
                },
                maxIterations: 2,
                systemPromptOverride: "You are running provider QA. Call requested tool exactly once.",
                simulateAllTools: true
            )
            guard !result.executedCommands.isEmpty else {
                throw AIServiceError.emptyResponse("Provider did not produce a tool call")
            }
            return "Tool-call test passed"
        }
    }

    private func runProviderQA(_ operation: @escaping @MainActor () async throws -> String) {
        isRunningProviderQA = true
        connectionTestResult = nil
        Task {
            do {
                let message = try await operation()
                connectionTestResult = .success(message)
            } catch {
                connectionTestResult = .failure("QA failed: \(error.localizedDescription)")
            }
            isRunningProviderQA = false
        }
    }
}

/// MARK: - App Adapters Settings

private struct ContextDockApp: Identifiable {
    let id: String          // bundleId
    let bundleId: String
    let appName: String
    let icon: NSImage?
    let adapterActionsCount: Int
    let starredCount: Int
}

struct AppAdaptersSettingsView: View {
    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @ObservedObject private var l2Manager = L2ExtensionManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedBundleId: String? = nil
    @State private var showAutomations = false
    @State private var searchText = ""
    @State private var showNewAdapterSheet = false
    @State private var importPreview: AdapterPackPreview?
    @State private var importError: String?

    private func importAdapterPack() {
        guard let url = AdapterPackImporter.shared.pickPack() else { return }
        do {
            importPreview = try AdapterPackImporter.shared.loadPreview(from: url)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func resolvedName(bundleId: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            return app.localizedName ?? bundleId.components(separatedBy: ".").last ?? bundleId
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleId.components(separatedBy: ".").last ?? bundleId
    }

    private func resolvedIcon(bundleId: String) -> NSImage? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            return app.icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private var contextDockApps: [ContextDockApp] {
        var byBundleId: [String: ContextDockApp] = [:]
        // From adapters
        for adapter in adapterManager.adapters {
            byBundleId[adapter.bundleId] = ContextDockApp(
                id: adapter.bundleId, bundleId: adapter.bundleId,
                appName: adapter.appName,
                icon: resolvedIcon(bundleId: adapter.bundleId),
                adapterActionsCount: adapter.visibleActions.count,
                starredCount: 0
            )
        }
        // From favourites — merge into existing or add new
        let favDict = settings.allFavouriteMenuPills()
        for (bid, names) in favDict where !names.isEmpty {
            if let existing = byBundleId[bid] {
                byBundleId[bid] = ContextDockApp(
                    id: existing.bundleId, bundleId: existing.bundleId,
                    appName: existing.appName, icon: existing.icon,
                    adapterActionsCount: existing.adapterActionsCount,
                    starredCount: names.count
                )
            } else {
                byBundleId[bid] = ContextDockApp(
                    id: bid, bundleId: bid,
                    appName: resolvedName(bundleId: bid),
                    icon: resolvedIcon(bundleId: bid),
                    adapterActionsCount: 0,
                    starredCount: names.count
                )
            }
        }
        return byBundleId.values.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    private var filteredContextDockApps: [ContextDockApp] {
        if searchText.isEmpty { return contextDockApps }
        let q = searchText.lowercased()
        return contextDockApps.filter {
            $0.appName.lowercased().contains(q) || $0.bundleId.lowercased().contains(q)
        }
    }

    var body: some View {
        HSplitView {
            // MARK: Left sidebar
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Search apps…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))

                Divider()

                // Context Dock Apps header
                HStack {
                    Text("Context Dock Apps")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(contextDockApps.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Button {
                        showNewAdapterSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Add new app adapter")
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

                // Unified app list
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        if filteredContextDockApps.isEmpty {
                            Text("No apps yet")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(16)
                        } else {
                            ForEach(filteredContextDockApps) { app in
                                let isSelected = selectedBundleId == app.bundleId
                                Button {
                                    selectedBundleId = app.bundleId
                                    showAutomations = false
                                } label: {
                                    HStack(spacing: 8) {
                                        Group {
                                            if let icon = app.icon {
                                                Image(nsImage: icon)
                                                    .resizable()
                                                    .frame(width: 22, height: 22)
                                                    .cornerRadius(5)
                                            } else {
                                                Image(systemName: "app.fill")
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(isSelected ? .white : Color.accentColor)
                                                    .frame(width: 22, height: 22)
                                            }
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.appName)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(isSelected ? .white : .primary)
                                                .lineLimit(1)
                                            HStack(spacing: 4) {
                                                if app.adapterActionsCount > 0 {
                                                    Text("\(app.adapterActionsCount) adapter")
                                                        .font(.system(size: 9))
                                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                                        .background(isSelected ? Color.white.opacity(0.2) : Color.blue.opacity(0.12),
                                                                    in: Capsule())
                                                        .foregroundStyle(isSelected ? .white : .blue)
                                                }
                                                if app.starredCount > 0 {
                                                    Text("\(app.starredCount) starred")
                                                        .font(.system(size: 9))
                                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                                        .background(isSelected ? Color.white.opacity(0.2) : Color.yellow.opacity(0.18),
                                                                    in: Capsule())
                                                        .foregroundStyle(isSelected ? .white : Color(nsColor: .systemOrange))
                                                }
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Color.accentColor : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }

                // Automations section
                Divider()

                Button {
                    showAutomations = true
                    selectedBundleId = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(showAutomations ? .white : Color.indigo)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Automations")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(showAutomations ? .white : .primary)
                            Text("\(l2Manager.extensions.count) script\(l2Manager.extensions.count == 1 ? "" : "s")")
                                .font(.system(size: 10))
                                .foregroundStyle(showAutomations ? .white.opacity(0.7) : .secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(showAutomations ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)

                Divider()

                // Footer
                HStack {
                    Button {
                        if showAutomations {
                            l2Manager.openExtensionsFolder()
                        } else {
                            NSWorkspace.shared.open(adapterManager.adaptersDirectory)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.system(size: 11))
                            Text(showAutomations ? "Open Scripts Folder" : "Open Adapters Folder")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if !showAutomations {
                        Button(action: importAdapterPack) {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.down").font(.system(size: 11))
                                Text("Import Adapter…").font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Import an App Adapter Pack (.adapterpack, .zip, .json)")
                    }

                    Button {
                        Task {
                            await adapterManager.loadUserAdapters()
                            await l2Manager.loadExtensions()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reload from disk")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(minWidth: 200, maxWidth: 240)
            .sheet(item: $importPreview) { preview in
                AdapterPackImportPreviewSheet(
                    preview: preview,
                    onCancel: { importPreview = nil },
                    onImport: {
                        Task {
                            let ok = await AdapterPackImporter.shared.install(preview)
                            await MainActor.run {
                                importPreview = nil
                                if ok { selectedBundleId = preview.adapter.bundleId }
                                else { importError = "Couldn't install the adapter pack." }
                            }
                        }
                    })
            }
            .alert(
                "Import Failed", isPresented: .constant(importError != nil),
                actions: { Button("OK") { importError = nil } },
                message: { Text(importError ?? "") })

            // MARK: Right panel
            VStack(spacing: 0) {
                // Load error banner
                if !adapterManager.loadErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 12))
                            Text("\(adapterManager.loadErrors.count) file\(adapterManager.loadErrors.count == 1 ? "" : "s") failed to load")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                        }
                        ForEach(adapterManager.loadErrors, id: \.file) { err in
                            Text("• \(err.file): \(err.message)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                    Divider()
                }

                if showAutomations {
                    AutomationsDetailView()
                } else if let bid = selectedBundleId {
                    ContextDockAppDetailView(bundleId: bid)
                } else {
                    AdapterCreationGuide(onAddAdapter: { showNewAdapterSheet = true })
                }
            }
        }
        .padding(0)
        .sheet(isPresented: $showNewAdapterSheet) {
            NewAdapterSheet { appName, bundleId, icon in
                Task { await adapterManager.createAdapter(appName: appName, bundleId: bundleId, icon: icon) }
                showNewAdapterSheet = false
            }
        }
    }
}

// MARK: - Automations detail panel

private struct AutomationsDetailView: View {
    @ObservedObject private var l2Manager = L2ExtensionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automations")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Shell, AppleScript & JXA scripts that appear as Context Dock pills")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    l2Manager.openExtensionsFolder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text("Open Folder").font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(16)

            Divider()

            if l2Manager.extensions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 32))
                        .foregroundStyle(.quaternary)
                    Text("No automations yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Add folders to ~/Library/Application Support/ILauncher/L2Extensions/")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(l2Manager.extensions) { ext in
                            AutomationRowView(ext: ext)
                            Divider().padding(.leading, 48)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct AutomationRowView: View {
    let ext: L2Extension
    @ObservedObject private var l2Manager = L2ExtensionManager.shared

    var isEnabled: Bool {
        l2Manager.extensions.first(where: { $0.toolName == ext.toolName })?.isEnabled ?? ext.isEnabled
    }

    var scriptTypeColor: Color {
        switch ext.scriptType {
        case .bash, .python, .ruby, .node: return .green
        case .appleScript: return .orange
        case .jxa: return .yellow
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ext.icon)
                .font(.system(size: 16))
                .foregroundStyle(isEnabled ? scriptTypeColor : Color.secondary.opacity(0.5))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ext.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    Text(ext.scriptType.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(scriptTypeColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(scriptTypeColor)
                }
                Text(ext.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !ext.contextApps.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "app.badge.checkmark").font(.system(size: 9))
                        Text(ext.contextApps.joined(separator: ", "))
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { _ in l2Manager.toggleEnabled(ext) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Adapter Creation Guide (empty state)

private struct AdapterCreationGuide: View {
    let onAddAdapter: () -> Void

    private struct ActionTypeInfo {
        let icon: String; let color: Color; let name: String; let what: String; let example: String
    }
    private let types: [ActionTypeInfo] = [
        .init(icon: "menubar.rectangle",        color: .blue,   name: "menubar",
              what: "Click any macOS menu item",
              example: #""menuPath": ["File", "Export", "PDF…"]"#),
        .init(icon: "applescript",              color: .orange, name: "applescript",
              what: "Run AppleScript on the frontmost app",
              example: #""script": "tell application \"Photos\" to activate""#),
        .init(icon: "curlybraces",              color: .yellow, name: "jxa",
              what: "JavaScript for Automation — read live data",
              example: #""script": "Application('Photos').selection().length + ' selected'"#),
        .init(icon: "terminal.fill",            color: .green,  name: "shell",
              what: "Bash script — $CURRENT_URL, $WINDOW_TITLE etc. auto-injected",
              example: #""script": "echo $FRONTMOST_APP is open""#),
        .init(icon: "link",                     color: .teal,   name: "urlScheme",
              what: "Open a URL / deep-link with context vars",
              example: #""urlScheme": "obsidian://new?content=$AX_SELECTED_TEXT""#),
        .init(icon: "sparkles",                 color: .indigo, name: "aiPrompt",
              what: "Pre-fill the AI chat with live context",
              example: #""aiPromptTemplate": "Summarize: $AX_SELECTED_TEXT""#),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Title
                VStack(alignment: .leading, spacing: 6) {
                    Text("How to create an App Adapter")
                        .font(.system(size: 16, weight: .semibold))
                    Text("An adapter is a JSON file that defines actions for one app.\nWhen that app is frontmost, its actions appear as pills in the Context Dock.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Quick start
                VStack(alignment: .leading, spacing: 8) {
                    Label("Quick start", systemImage: "bolt.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        Text("1. Click ").font(.system(size: 12))
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 4)
                        Text(" above → pick a running app → Create Adapter").font(.system(size: 12))
                    }
                    Text("2. The blank JSON file opens — add actions from the types below.")
                        .font(.system(size: 12))
                    Text("3. Save the file → press ⟳ Reload → actions appear instantly.")
                        .font(.system(size: 12))
                    HStack(spacing: 6) {
                        Text("4. See ").font(.system(size: 12))
                        Button("Photos.json") {
                            let url = AppAdapterManager.shared.adaptersDirectory
                                .appendingPathComponent("Photos.json")
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 12))
                        Text("for a complete real-world example of every type.").font(.system(size: 12))
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                // Action type cards
                VStack(alignment: .leading, spacing: 6) {
                    Text("6 ACTION TYPES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(types, id: \.name) { t in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: t.icon)
                                .font(.system(size: 14))
                                .foregroundStyle(t.color)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(t.name)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    Text("—")
                                        .foregroundStyle(.tertiary)
                                    Text(t.what)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Text(t.example)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 5)
                        if t.name != types.last?.name { Divider().padding(.leading, 32) }
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                Button("Create my first adapter") { onAddAdapter() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - New Adapter Sheet

struct NewAdapterSheet: View {
    let onCreate: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared

    enum Mode { case app, cli }
    @State private var mode: Mode = .app

    // App mode state
    @State private var appName = ""
    @State private var bundleId = ""
    @State private var icon = "app.fill"
    @State private var installedApps: [InstalledApplicationEntry] = []
    @State private var searchText = ""
    @State private var selectedAppID: String? = nil

    // CLI mode state
    @State private var cliSearchText = ""
    @State private var selectedCLICommand: String? = nil

    private var canCreate: Bool {
        mode == .app ? (!appName.isEmpty && !bundleId.isEmpty) : (selectedCLICommand != nil)
    }
    private var filteredApps: [InstalledApplicationEntry] {
        guard !searchText.isEmpty else { return installedApps }
        let query = searchText.localizedLowercase
        return installedApps.filter {
            $0.name.localizedLowercase.contains(query) || $0.bundleId.localizedLowercase.contains(query)
        }
    }
    private var filteredCLIPackages: [TerminalPackage] {
        guard !cliSearchText.isEmpty else { return pkgMgr.packages }
        let query = cliSearchText.localizedLowercase
        return pkgMgr.packages.filter {
            $0.name.localizedLowercase.contains(query) || $0.command.localizedLowercase.contains(query)
        }
    }
    private var selectedInstalledApp: InstalledApplicationEntry? {
        guard let selectedAppID else { return nil }
        return installedApps.first(where: { $0.id == selectedAppID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("New App Adapter")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            appPickerContent

            Divider()

            HStack {
                Spacer()
                Button("Create Adapter") {
                    if mode == .app {
                        onCreate(appName.trimmingCharacters(in: .whitespacesAndNewlines),
                                 bundleId.trimmingCharacters(in: .whitespacesAndNewlines),
                                 icon)
                    } else if let cmd = selectedCLICommand,
                              let pkg = pkgMgr.packages.first(where: { $0.command == cmd }) {
                        onCreate(pkg.name, "cli://\(cmd)", "terminal.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
            .padding(20)
        }
        .frame(width: 520, height: 660)
        .task {
            guard installedApps.isEmpty else { return }
            let discovered = await Task.detached(priority: .userInitiated) {
                InstalledApplicationsCatalog.discoverInstalledApps()
            }.value
            installedApps = discovered
        }
    }

    private var appPickerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PICK AN INSTALLED APP")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Browse Applications Folder…") {
                            browseForApplication()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                        TextField("Search installed apps…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredApps) { app in
                                let isSelected = selectedAppID == app.id
                                Button {
                                    selectedAppID = app.id
                                    appName = app.name
                                    bundleId = app.bundleId
                                    icon = "app.fill"
                                } label: {
                                    HStack(spacing: 10) {
                                        if let nsImg = app.icon {
                                            Image(nsImage: nsImg)
                                                .resizable()
                                                .interpolation(.high)
                                                .frame(width: 28, height: 28)
                                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        } else {
                                            Image(systemName: "app.fill").frame(width: 28, height: 28)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(app.bundleId)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(minHeight: 180, maxHeight: 220)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("OR FILL MANUALLY")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LabeledField("App Name") {
                        TextField("e.g. Photos", text: $appName).textFieldStyle(.roundedBorder)
                    }
                    LabeledField("Bundle ID") {
                        TextField("e.g. com.apple.Photos", text: $bundleId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    if let selectedInstalledApp {
                        LabeledField("App Path") {
                            Text(selectedInstalledApp.url.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        Text("If the app is not listed, fill in the app name and bundle ID manually.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var cliPickerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search CLI tools…", text: $cliSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !cliSearchText.isEmpty {
                    Button { cliSearchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if filteredCLIPackages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(pkgMgr.packages.isEmpty ? "No CLI tools found. Add tools in the CLI Tools section first." : "No results")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedCLICommand) {
                    ForEach(filteredCLIPackages, id: \.command) { pkg in
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.green.opacity(0.12))
                                    .frame(width: 28, height: 28)
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.green)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pkg.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(pkg.command)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                        .tag(pkg.command)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func browseForApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard
            let bundle = Bundle(url: url),
            let selectedBundleId = bundle.bundleIdentifier
        else { return }

        let selectedName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent

        let entry = InstalledApplicationEntry(
            bundleId: selectedBundleId,
            name: selectedName,
            url: url,
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )

        if !installedApps.contains(where: { $0.bundleId == selectedBundleId }) {
            installedApps.append(entry)
            installedApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        selectedAppID = selectedBundleId
        appName = selectedName
        bundleId = selectedBundleId
        icon = "app.fill"
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: Adapter row

private struct AdapterRowView: View {
    let adapter: AppAdapter
    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @State private var showRename = false
    @State private var renameText = ""

    var isEnabled: Bool {
        adapterManager.adapters.first(where: { $0.id == adapter.id })?.isEnabled ?? adapter.isEnabled
    }

    private var categories: [String] {
        Array(Set(adapter.actions.compactMap {
            $0.category?.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })).sorted()
    }

    private func exportAdapter() {
        guard let src = adapterManager.exportFileURL(for: adapter.bundleId) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(adapter.appName).json"
        panel.allowedFileTypes = ["json"]
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: src, to: dest)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            AppBundleIconView(bundleId: adapter.bundleId, fallbackSymbol: adapter.icon, size: 22, cornerRadius: 5)
                .opacity(isEnabled ? 1.0 : 0.55)

            VStack(alignment: .leading, spacing: 1) {
                Text(adapter.appName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Text("\(adapter.visibleActions.count) action\(adapter.visibleActions.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if adapter.isBuiltIn {
                Text("Built-in")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { adapterManager.setEnabled($0, for: adapter.bundleId) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .contextMenu {
            Text("\(adapter.visibleActions.count) actions" +
                (categories.isEmpty ? "" : " · \(categories.count) categories"))
            Divider()
            Button {
                renameText = adapter.appName
                showRename = true
            } label: { Label("Rename…", systemImage: "pencil") }
            Button {
                Task { await adapterManager.duplicateAdapter(bundleId: adapter.bundleId) }
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(action: exportAdapter) {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            if let src = adapterManager.exportFileURL(for: adapter.bundleId) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([src])
                } label: { Label("Show Source in Finder", systemImage: "folder") }
            }
            Divider()
            Button(role: .destructive) {
                Task { await adapterManager.deleteAdapter(bundleId: adapter.bundleId) }
            } label: { Label("Delete", systemImage: "trash") }
        }
        .alert("Rename Adapter", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task { await adapterManager.renameAdapter(bundleId: adapter.bundleId, to: renameText) }
            }
        }
    }
}

// MARK: Adapter detail

private struct AdapterDetailView: View {
    let adapter: AppAdapter
    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @State private var showAddActionSheet = false
    @State private var editingAction: AdapterAction? = nil

    var currentAdapter: AppAdapter {
        adapterManager.adapters.first(where: { $0.id == adapter.id }) ?? adapter
    }

    var visibleActions: [AdapterAction] {
        currentAdapter.visibleActions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── App header ────────────────────────────────────────────────
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 44, height: 44)
                        AppBundleIconView(bundleId: currentAdapter.bundleId, fallbackSymbol: currentAdapter.icon, size: 28, cornerRadius: 7)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentAdapter.appName)
                            .font(.system(size: 15, weight: .semibold))
                        Text(currentAdapter.bundleId)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let fileURL = currentAdapter.sourceFileURL {
                        Button {
                            NSWorkspace.shared.open(fileURL)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil").font(.system(size: 11))
                                Text("Edit JSON").font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open \(fileURL.lastPathComponent) in your default editor")
                    }
                    Toggle("Adapter", isOn: Binding(
                        get: { currentAdapter.isEnabled },
                        set: { adapterManager.setEnabled($0, for: currentAdapter.bundleId) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(16)

                Divider()

                // ── Actions header with + button ─────────────────────────────
                HStack {
                    Text("Adapter Actions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(visibleActions.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        editingAction = nil
                        showAddActionSheet = true
                    } label: {
                        Label("Add Action", systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

                // ── Action rows ───────────────────────────────────────────────
                ForEach(visibleActions) { action in
                    AdapterActionRowView(action: action,
                                        isCustom: !currentAdapter.isBuiltIn || currentAdapter.sourceFileURL != nil)
                    .contextMenu {
                        Button {
                            editingAction = action
                            showAddActionSheet = true
                        } label: {
                            Label("Edit Action", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            Task { await adapterManager.deleteAction(id: action.id, from: currentAdapter.bundleId) }
                        } label: {
                            Label("Delete Action", systemImage: "trash")
                        }
                    }
                    if action.id != currentAdapter.actions.last?.id {
                        Divider().padding(.leading, 44)
                    }
                }

                Spacer(minLength: 20)
            }
        }
        .sheet(isPresented: $showAddActionSheet) {
            AdapterActionEditorSheet(
                bundleId: currentAdapter.bundleId,
                existing: editingAction
            ) {
                showAddActionSheet = false
                editingAction = nil
            }
        }
    }
}

// MARK: Action row in detail view

private struct AdapterActionRowView: View {
    let action: AdapterAction
    var isCustom: Bool = false

    private var typeIcon: String {
        switch action.type {
        case .menubar:     return "menubar.rectangle"
        case .applescript: return "applescript"
        case .jxa:         return "chevron.left.forwardslash.chevron.right"
        case .shell:       return "terminal"
        case .cliTool:     return "terminal.fill"
        case .urlScheme:   return "link"
        case .openItem:    return "app.badge.checkmark"
        case .scriptFile:  return "doc.text"
        case .shortcut:    return "scissors"
        case .aiPrompt:    return "sparkles"
        case .pageJS:      return "safari"
        }
    }

    private var typeColor: Color {
        switch action.type {
        case .menubar:     return .blue
        case .applescript: return .orange
        case .jxa:         return .orange
        case .shell:       return .green
        case .cliTool:     return .green
        case .urlScheme:   return .teal
        case .openItem:    return .mint
        case .scriptFile:  return .brown
        case .shortcut:    return .purple
        case .aiPrompt:    return .indigo
        case .pageJS:      return .cyan
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(typeColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: action.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(typeColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(action.name)
                        .font(.system(size: 12, weight: .medium))
                    if action.requiresApproval {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Requires approval before executing")
                    }
                    if action.isDestructive {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .help("Destructive action")
                    }
                }
                if !action.description.isEmpty {
                    Text(action.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Type badge
            Text(action.type.displayName)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(typeColor.opacity(0.12), in: Capsule())
                .foregroundStyle(typeColor)

            // Detail: menu path or trigger keywords
            if let path = action.menuPath {
                Text(path.joined(separator: " › "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            } else if let cliToolCommand = action.cliToolCommand, !cliToolCommand.isEmpty {
                Text(cliToolCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            } else if !action.triggers.isEmpty {
                Text(action.triggers.prefix(3).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Adapter Action Editor Sheet

struct AdapterActionEditorSheet: View {
    let bundleId: String
    let existing: AdapterAction?
    let onDone: () -> Void

    @ObservedObject private var adapterManager = AppAdapterManager.shared
    // Form fields
    @State private var name: String        = ""
    @State private var description: String = ""
    @State private var iconName: String    = "bolt"
    @State private var triggersRaw: String = ""
    @State private var actionType: AdapterActionType = .urlScheme
    @State private var urlScheme: String   = ""
    @State private var script: String      = ""
    @State private var filePath: String    = ""
    @State private var requiresApproval: Bool = false
    @State private var shortcutName: String = ""

    @State private var isSaving = false
    @State private var previewIconValid = true

    var isEditing: Bool { existing != nil }

    @ViewBuilder private var riskBadge: some View {
        let r = actionType.riskLevel
        if r != .low {
            Label(r.label, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background((r == .high ? Color.red : Color.orange).opacity(0.15), in: Capsule())
                .foregroundStyle(r == .high ? Color.red : Color.orange)
        }
    }

    private var resolvedActionName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Title bar ────────────────────────────────────────────────────
            HStack {
                Text(isEditing ? "Edit Action" : "Add Action")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(resolvedActionName.isEmpty || payloadEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // ── Name & Icon ──────────────────────────────────────────
                    HStack(alignment: .top, spacing: 12) {
                        // Icon preview
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: previewIconValid ? iconName : "questionmark")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.accentColor)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledField("Name") {
                                TextField("e.g. Open Wi-Fi", text: $name)
                                    .textFieldStyle(.roundedBorder)
                            }
                            LabeledField("SF Symbol") {
                                TextField("e.g. wifi", text: $iconName)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: iconName) { v in
                                        previewIconValid = NSImage(systemSymbolName: v, accessibilityDescription: nil) != nil
                                    }
                            }
                        }
                    }

                    // ── Description ──────────────────────────────────────────
                    LabeledField("Description") {
                        TextField("Short description shown in settings", text: $description)
                            .textFieldStyle(.roundedBorder)
                    }

                    // ── Trigger Keywords ─────────────────────────────────────
                    LabeledField("Trigger Keywords") {
                        TextField("comma-separated: wifi, wireless, network", text: $triggersRaw)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("When the user types any of these keywords in the dock, this action surfaces automatically.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.top, -8)

                    Divider()

                    // ── Action (intent-grouped) ──────────────────────────────
                    LabeledField("Action") {
                        HStack(spacing: 8) {
                            Picker("", selection: $actionType) {
                                Section("Recommended") {
                                    Text("Open URL / Deep Link").tag(AdapterActionType.urlScheme)
                                    Text("Open Application or File").tag(AdapterActionType.openItem)
                                    Text("Run Shortcut").tag(AdapterActionType.shortcut)
                                    Text("AI Prompt").tag(AdapterActionType.aiPrompt)
                                }
                                Section("Automation") {
                                    Text("Menu Item").tag(AdapterActionType.menubar)
                                    Text("AppleScript").tag(AdapterActionType.applescript)
                                    Text("JavaScript for Automation").tag(AdapterActionType.jxa)
                                }
                                Section("Browser") {
                                    Text("Browser JavaScript").tag(AdapterActionType.pageJS)
                                }
                                Section("Advanced") {
                                    Text("Terminal Command").tag(AdapterActionType.shell)
                                    Text("External Script").tag(AdapterActionType.scriptFile)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .onChange(of: actionType) { t in
                                if t.riskLevel == .high { requiresApproval = true }
                            }
                            riskBadge
                            Spacer()
                        }
                    }

                    // ── Payload ──────────────────────────────────────────────
                    switch actionType {
                    case .urlScheme:
                        LabeledField("URL Scheme") {
                            TextField("x-apple.systempreferences:com.apple...", text: $urlScheme)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                        }
                        Text("Supports $CURRENT_URL, $SELECTED_TEXT variables.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, -8)

                    case .openItem:
                        LabeledField("Target App / File / URL") {
                            HStack(spacing: 8) {
                                TextField("/Applications/WhatsApp.app or ~/Documents/file.pdf", text: $filePath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                Button("Browse") {
                                    chooseFilePath(canChooseDirectories: true, canChooseFiles: true, allowedFileTypes: nil)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        Text("Opens any installed app, file, folder, or file:// URL.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, -8)

                    case .applescript, .shell, .jxa, .aiPrompt:
                        LabeledField(editorLabel) {
                            TextEditor(text: $script)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minHeight: 80)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.1)))
                        }

                    case .pageJS:
                        LabeledField("Page JavaScript") {
                            TextEditor(text: $script)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minHeight: 120)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.1)))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Runs directly inside the active Safari page — full access to document, window, fetch, localStorage, etc.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Text("Variables: $CURRENT_URL · $PAGE_TITLE · $PAGE_TEXT · $SELECTED_TEXT · {{query}}")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            Text("Example: return document.querySelector('.price')?.innerText ?? 'not found'")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        .padding(.top, -8)

                    case .scriptFile:
                        LabeledField("Script File") {
                            HStack(spacing: 8) {
                                TextField("script.sh, tool.py, automation.js, helper.rb", text: $filePath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                Button("Browse") {
                                    chooseFilePath(
                                        canChooseDirectories: false,
                                        canChooseFiles: true,
                                        allowedFileTypes: ["sh", "py", "js", "rb", "scpt", "applescript"]
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        Text("Supports .sh, .py, .js, .rb, .scpt, and .applescript files. Relative paths are resolved from the AppAdapters folder.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, -8)

                    case .menubar:
                        LabeledField("Menu Path (comma-separated)") {
                            TextField("File, New Tab", text: $script)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text("e.g. \"View, Zoom In\" clicks View › Zoom In in the menu bar.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, -8)

                    case .shortcut:
                        LabeledField("Shortcut Name") {
                            TextField("Exact macOS Shortcut name", text: $shortcutName)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text("Runs a macOS Shortcut by name (Shortcuts.app).")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    default:
                        EmptyView()
                    }

                    if actionType.riskLevel == .high {
                        Label(
                            "High-risk action — DoraX will ask for confirmation before it runs.",
                            systemImage: "exclamationmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }

                    // ── Options ──────────────────────────────────────────────
                    Toggle("Require confirmation before running", isOn: $requiresApproval)
                        .font(.system(size: 12))

                    // ── Preview ──────────────────────────────────────────────
                    Divider()
                    Text("PREVIEW")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Image(systemName: previewIconValid ? iconName : "bolt")
                            .font(.system(size: 14))
                            .foregroundStyle(.teal)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resolvedActionName.isEmpty ? "Action name" : resolvedActionName)
                                .font(.system(size: 12, weight: .medium))
                            Text(actionType.displayName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        riskBadge
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    Text("How this action appears in DoraX.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
            }
        }
        .frame(width: 500, alignment: .leading)
        .onAppear { prefill() }
    }

    private var payloadEmpty: Bool {
        switch actionType {
        case .urlScheme: return urlScheme.trimmingCharacters(in: .whitespaces).isEmpty
        case .openItem, .scriptFile: return filePath.trimmingCharacters(in: .whitespaces).isEmpty
        case .menubar:   return script.trimmingCharacters(in: .whitespaces).isEmpty
        case .shortcut:  return shortcutName.trimmingCharacters(in: .whitespaces).isEmpty
        default:         return script.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var editorLabel: String {
        switch actionType {
        case .cliTool:   return "CLI Command"
        case .shell:     return "Shell Command"
        case .aiPrompt:  return "AI Prompt Template"
        case .jxa:       return "JXA"
        case .pageJS:    return "Page JavaScript"
        default:         return "AppleScript"
        }
    }

    private func prefill() {
        guard let a = existing else { return }
        name        = a.name
        description = a.description
        iconName    = a.icon
        triggersRaw = a.triggers.joined(separator: ", ")
        actionType  = a.type
        urlScheme   = a.urlScheme ?? ""
        filePath    = a.scriptFile ?? ""
        script      = a.script ?? a.cliToolCommand ?? a.menuPath?.joined(separator: ", ") ?? a.aiPromptTemplate ?? ""
        shortcutName = a.shortcutName ?? ""
        requiresApproval = a.requiresApproval
    }

    private func save() {
        isSaving = true
        let triggers = triggersRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let finalName = resolvedActionName
        let id = existing?.id ?? "\(bundleId.components(separatedBy: ".").last ?? "custom").\(finalName.lowercased().replacingOccurrences(of: " ", with: "."))"

        let menuPath: [String]? = actionType == .menubar
            ? script.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            : nil

        let action = AdapterAction(
            id: id,
            name: finalName,
            icon: iconName,
            description: description,
            triggers: triggers,
            type: actionType,
            menuPath: menuPath,
            script: inlineScriptPayload,
            scriptFile: filePathPayload,
            urlScheme: actionType == .urlScheme ? urlScheme : nil,
            cliToolCommand: actionType == .cliTool ? script.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            shortcutName: actionType == .shortcut ? shortcutName.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            aiPromptTemplate: actionType == .aiPrompt ? script : nil,
            requiresApproval: requiresApproval || actionType.riskLevel == .high
        )

        Task {
            await adapterManager.appendAction(action, to: bundleId)
            await MainActor.run { onDone() }
        }
    }

    private var inlineScriptPayload: String? {
        switch actionType {
        case .applescript, .shell, .jxa, .aiPrompt, .pageJS:
            return script
        default:
            return nil
        }
    }

    private var filePathPayload: String? {
        switch actionType {
        case .openItem, .scriptFile:
            return filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return nil
        }
    }

    private func chooseFilePath(canChooseDirectories: Bool, canChooseFiles: Bool, allowedFileTypes: [String]?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = canChooseDirectories
        panel.canChooseFiles = canChooseFiles
        panel.allowsMultipleSelection = false
        if let allowedFileTypes {
            panel.allowedContentTypes = allowedFileTypes.compactMap { UTType(filenameExtension: $0) }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        filePath = url.path
    }
}

// MARK: - Prompt Templates Section
struct PromptTemplatesSection: View {
    @State private var selectedTemplate = 0
    @State private var copied = false

    private struct Template: Identifiable {
        let id: Int
        let title: String
        let icon: String
        let description: String
        let prompt: String
    }

    private let templates: [Template] = [
        Template(
            id: 0,
            title: "Global Command",
            icon: "command",
            description: "Runs from the search bar anywhere — type its name and press Return. Also builds live-list scopes (like Process Monitor): a searchable, auto-refreshing list where each row runs an action. Paste this into any AI, then paste the JSON back here.",
            prompt: """
You generate a Context-Dock GLOBAL COMMAND. It runs from the search bar in
Global Context — the user types its name (or a keyword) and presses Return.

Variable: $CD_QUERY — whatever the user typed after the command name.
  - bash: env var "$CD_QUERY"   - AppleScript: system attribute "CD_QUERY"

Output ONLY this JSON (no prose, no markdown fences):
{
  "version": "1.0",
  "type": "system_commands",
  "systemCommands": [
    {
      "name": "Say Text",
      "description": "Speak the typed text aloud.",
      "icon": "speaker.wave.2.fill",
      "keywords": ["say", "speak", "tts"],
      "scriptType": "bash",
      "script": "say \\"$CD_QUERY\\""
    }
  ]
}

Rules:
- "type" MUST be exactly "system_commands".
- "scriptType" is "bash", "applescript", or "jxa".
- Use a tool's absolute path (e.g. /opt/homebrew/bin/brew) so it runs outside
  an interactive shell. Wrapping a CLI tool is just script "/abs/tool $CD_QUERY".
- "icon" is a valid SF Symbol name. "keywords" are words that surface it.
- Optional "presets": [..] adds tappable preset values.

────────────────────────────────────────────────────────
ADVANCED — LIVE SCOPE (a panel of rows, like Process Monitor):
Add keyword "provider:custom" to turn the command into a live PANEL. Then:
- "script" is a ROWS script printing ONE JSON object PER LINE (NDJSON):
  {"id":"unique","title":"shown","subtitle":"dim","badge":"tag","icon":"SFSymbol-or-/abs/path"}
  Only "id" and "title" are required. No other output — one object per line.
- "undoScript" is the ROW ACTION, run on Return. Selected row = $CD_ROW_ID, $CD_ROW_TITLE.
- Add "refresh:N" to auto-refresh every N seconds. All runs in the background.

FIRST decide which of the TWO panel kinds you are building — they behave differently:

1. BROWSE panel — the rows exist independently of what the user types
   (ports, files, containers, branches). Print ALL rows; Context Dock filters
   them by the typed text for you. Do NOT read $CD_QUERY.

2. COMPUTED panel — the typed text IS the input; the rows are the answer
   (currency converter, unit converter, calculator, a web search).
   Read $CD_QUERY and print the RESULT rows. Never filter by the query — the
   answer to "20 gbp" does not contain the text "20 gbp", so filtering it would
   leave the panel empty.

Reading $CD_QUERY in the rows script is what marks a panel COMPUTED. The script
then re-runs as the user types (debounced), instead of being filtered.

A COMPUTED panel MUST handle the empty query — print one hint row telling the
user what to type, or the panel looks broken before they start typing.

For file rows: put the ABSOLUTE PATH in "id". That gives the row the real file
icon and thumbnail, Return opens it, and Space previews it in Quick Look.

ROW LAYOUTS — a row can choose how it draws:
- default: title + subtitle on one line, icon on the left.
- "layout":"compare" — two values with a symbol between them, for conversions
  and before/after results. Extra fields:
    "left"        the input value, shown dimmer on the left
    "right"       the result, shown large on the right
    "centerIcon"  SF Symbol between them (default "arrow.right";
                  "arrow.up.arrow.down" reads as a swap)
  With compare, "title" becomes the small caption under the left value and
  "badge" the caption under the right.
  {"id":"gbp","layout":"compare","left":"100 USD","right":"78.40 GBP",
   "title":"US Dollar","badge":"Pound Sterling","centerIcon":"arrow.right"}
Pick compare whenever the row means "X becomes Y". Use the default row for
lists of things.

Live-scope example (Ports — Return kills the process):
{
  "version": "1.0",
  "type": "system_commands",
  "systemCommands": [
    {
      "name": "Ports",
      "description": "Listening TCP ports — Return kills the process.",
      "icon": "network",
      "keywords": ["ports", "provider:custom", "refresh:5"],
      "scriptType": "bash",
      "script": "lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 { printf \\"{\\\\\\"id\\\\\\":\\\\\\"%s\\\\\\",\\\\\\"title\\\\\\":\\\\\\"port %s\\\\\\",\\\\\\"subtitle\\\\\\":\\\\\\"%s (pid %s)\\\\\\",\\\\\\"icon\\\\\\":\\\\\\"network\\\\\\"}\\\\n\\", $2, $9, $1, $2 }'",
      "undoScriptType": "bash",
      "undoScript": "kill -9 \\"$CD_ROW_ID\\""
    }
  ]
}
COMPUTED-panel example (Celsius → Fahrenheit; note the hint row and that the
query is READ, never used as a filter):
{
  "version": "1.0",
  "type": "system_commands",
  "systemCommands": [
    {
      "name": "Temp Convert",
      "description": "Convert Celsius to Fahrenheit and Kelvin.",
      "icon": "thermometer.medium",
      "keywords": ["temp", "celsius", "provider:custom"],
      "scriptType": "bash",
      "script": "q=$CD_QUERY; if [ -z \\"$q\\" ]; then echo '{\\"id\\":\\"hint\\",\\"title\\":\\"Type a temperature in Celsius\\",\\"subtitle\\":\\"e.g. 21\\",\\"icon\\":\\"questionmark.circle\\"}'; else echo \\"$q\\" | awk '{f=$1*9/5+32; k=$1+273.15; printf \\"{\\\\\\"id\\\\\\":\\\\\\"f\\\\\\",\\\\\\"title\\\\\\":\\\\\\"%.2f degF\\\\\\",\\\\\\"subtitle\\\\\\":\\\\\\"%s degC\\\\\\",\\\\\\"icon\\\\\\":\\\\\\"thermometer.sun\\\\\\"}\\\\n{\\\\\\"id\\\\\\":\\\\\\"k\\\\\\",\\\\\\"title\\\\\\":\\\\\\"%.2f K\\\\\\",\\\\\\"subtitle\\\\\\":\\\\\\"%s degC\\\\\\",\\\\\\"icon\\\\\\":\\\\\\"thermometer.snowflake\\\\\\"}\\\\n\\", f, $1, k, $1}'; fi",
      "undoScriptType": "bash",
      "undoScript": "printf '%s' \\"$CD_ROW_TITLE\\" | pbcopy"
    }
  ]
}
A currency converter is the same shape: read $CD_QUERY, call a rates API with
curl, print one row per target currency, and copy the row on Return.

Build anything as a live scope: ports, Docker containers, git branches, a
password store, a file box, a converter, a web-app dashboard.

Now create one for: "<describe the command OR live scope you want>"
"""
        ),
        Template(
            id: 1,
            title: "Context Dock",
            icon: "rectangle.grid.1x2",
            description: "AI-built adapter pack for ANY app. Paste this, tell the AI the app + share its links; it researches the app and returns a ready-to-import pack. No manual Add Action.",
            prompt: """
You build a Context-Dock APP ADAPTER PACK — the complete, ready-to-run extension for ONE
macOS app. The user pastes your JSON back into Context-Dock → Create Extension and it works
immediately, appearing as actions while that app is frontmost. Do NOT skip the interview.

STEP 1 — ASK FIRST (do not output JSON yet). Ask the user:
  1) Which app? (name, and bundle id if they know it)
  2) What do you want it to do? (the tasks / agent behaviour you want)
  3) Paste any references so you can research the app's REAL capabilities:
       - the app's website / support / help page
       - its KEYBOARD-SHORTCUTS page (each shortcut is a menu command you can trigger)
       - URL-scheme / deep-link docs
       - a GitHub repo or CLI docs
       - any MCP server the app offers
Then RESEARCH EXHAUSTIVELY — don't stop at what they paste. Check every source that
could reveal a capability: the app's official site and support/help pages, its full
keyboard-shortcut list, documented URL schemes / deep links, its GitHub repo and any
CLI it ships, community forums/wikis, the app's AppleScript dictionary, and MCP
directories for a matching server. Cover the whole app, not just the one task.
Build ONLY from capabilities you can actually verify from those sources — never invent
a URL scheme, menu path, or command you have not confirmed.

STEP 2 — DESIGN. For each task, choose the SAFEST native route, in this order:
  urlScheme (deep link)  >  menubar (a menu command — this is how you fire a keyboard
  shortcut)  >  shortcut (a Shortcuts.app shortcut)  >  applescript / jxa  >
  scriptFile / shell (last resort)  >  aiPrompt (for "explain / summarise" tasks).
  - Keyboard shortcuts: a "menubar" action with the exact menuPath (e.g. New Board Cmd-N
    becomes menuPath ["File","New Board"]). Context-Dock clicks that menu item via macOS
    Accessibility = the shortcut fires. Never synthesise raw keystrokes.
  - Anything that writes / sends / deletes: set requiresApproval true (and isDestructive
    true for delete), so Context-Dock shows its approval card first.
  - If the app has a real CLI, add a "cliTool" action with the exact command. If it offers
    an official MCP server, DON'T put it in this JSON — note it in STEP 4 so the user links
    it in Settings.

STEP 3 — OUTPUT ONE JSON (no prose, no markdown fences), exactly this shape:
{
  "id": "com.apple.freeform",
  "appName": "Freeform",
  "bundleId": "com.apple.freeform",
  "icon": "square.on.square",
  "isEnabled": true,
  "actions": [
    {
      "id": "new-board",
      "name": "New Board",
      "icon": "plus.square.on.square",
      "description": "Create a new Freeform board.",
      "triggers": ["new", "board", "create"],
      "type": "menubar",
      "menuPath": ["File", "New Board"],
      "requiresApproval": false,
      "isDestructive": false
    },
    {
      "id": "open-freeform",
      "name": "Open Freeform",
      "icon": "square.on.square",
      "description": "Open the Freeform app.",
      "triggers": ["open", "freeform"],
      "type": "urlScheme",
      "urlScheme": "freeform://",
      "requiresApproval": false,
      "isDestructive": false
    }
  ]
}

FIELD RULES:
- Action "type" is one of: menubar, urlScheme, openItem, shortcut, applescript, jxa,
  scriptFile, shell, cliTool, aiPrompt.
- Set ONLY the matching payload for the type:
    menubar    -> "menuPath" (array of the exact menu-bar titles, top to item)
    urlScheme  -> "urlScheme"        openItem -> "urlScheme" (an app / file path)
    shortcut   -> "shortcutName"     cliTool  -> "cliToolCommand"
    applescript / jxa / shell -> "script"     scriptFile -> "scriptFile" (absolute path)
    aiPrompt   -> "aiPromptTemplate"
- "id" / "bundleId" MUST be the app's real bundle id; "appName" is the display name.
- "triggers" are the words that surface the action while typing in the dock.
- Scripts and prompts may use context vars: $CURRENT_URL, $WINDOW_TITLE, $AX_SELECTED_TEXT,
  and $CD_QUERY (the user's natural-language request, so an action can parameterize itself).

ADDING MORE LATER (incremental packs): if the user already set this app up and now wants
MORE, keep the SAME "id" / "bundleId" and output an adapter whose "actions" contains ONLY
the NEW actions, each with a NEW unique "actionId". Context-Dock MERGES by actionId — it
ADDS your new actions and keeps every action already installed. Do not re-list old actions
unless you are deliberately changing one (reuse its exact id to update it). Never send a
shrunken pack expecting a replace; same app id = merge, always.

STEP 4 — EXPLAIN. After the JSON, in one short paragraph: which routes you built, what the
app does NOT support (be honest — e.g. "Freeform has no CLI"), and whether an official MCP
server exists that the user should link separately in Settings.

Begin now by asking the STEP 1 questions.
"""
        ),
        Template(
            id: 2,
            title: "Selection Scope",
            icon: "text.viewfinder",
            description: "Runs on the user's current text/file selection (Cmd-hold sheet). Use a 'selection' trigger. Paste the JSON back here.",
            prompt: """
You generate a Context-Dock SELECTION EXTENSION. It appears in the Selection
Scope sheet that opens on the user's current selection (text or files).

The selected text/path is passed to the script on stdin and as $CD_TEXT.

Output ONLY this JSON (no prose, no markdown fences):
{
  "version": "1.0",
  "extensions": [
    {
      "name": "Word Count",
      "description": "Count words in the selected text.",
      "icon": "textformat.123",
      "layer": "L2",
      "tags": ["text"],
      "triggers": [ { "type": "selection" } ],
      "scriptType": "bash",
      "script": "printf '%s' \\"$CD_TEXT\\" | wc -w"
    }
  ]
}

Rules:
- MUST include a trigger of { "type": "selection" } so it lands in the
  Selection Scope sheet.
- "scriptType": bash, applescript, jxa, python, or swift.
- "layer": use "L2" for selection/context extensions.
- "icon" is a valid SF Symbol name.

Now create one for: "<what to do with the selected text or files>"
"""
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(.indigo)
                Text("Prompt Templates")
                    .font(.headline)
                Text("Copy a template, paste it into any AI, then paste the JSON it returns into Create Extension above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Tab row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(templates) { tpl in
                        Button {
                            selectedTemplate = tpl.id
                            copied = false
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tpl.icon).font(.caption)
                                Text(tpl.title).font(.caption).fontWeight(.medium)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedTemplate == tpl.id ? Color.accentColor : Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(selectedTemplate == tpl.id ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let tpl = templates.first(where: { $0.id == selectedTemplate }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tpl.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ZStack(alignment: .topTrailing) {
                        ScrollView {
                            Text(tpl.prompt)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(height: 200)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(tpl.prompt, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.caption)
                                Text(copied ? "Copied" : "Copy")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                }
            }
        }
    }
}

// MARK: - Bridge Config View

private struct BridgeConfigView: View {
    let title: String
    let subtitle: String
    let icon: String
    let iconColor: Color
    let endpointBinding: Binding<String>
    let modelBinding: Binding<String>
    let defaultEndpoint: String
    let defaultModel: String
    let vibeProxyNote: String

    @State private var testState: TestState = .idle
    @State private var discoveredModels: [String] = []

    enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }

            // Feature callouts
            VStack(alignment: .leading, spacing: 6) {
                BridgeFeatureRow(icon: "creditcard.slash.fill", color: .green,
                                 text: "No extra billing — uses your existing subscription")
                BridgeFeatureRow(icon: "arrow.left.arrow.right.circle.fill", color: .blue,
                                 text: vibeProxyNote)
                BridgeFeatureRow(icon: "app.connected.to.app.below.fill", color: .orange,
                                 text: "AI's connected tools (GitHub, Notion, Calendar…) flow through")
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

            Divider()

            // Endpoint
            VStack(alignment: .leading, spacing: 8) {
                Text("Bridge Endpoint")
                    .font(.subheadline).fontWeight(.medium)

                HStack(spacing: 6) {
                    Button("VibeProxy :8317") {
                        endpointBinding.wrappedValue = "http://localhost:8317/v1"
                    }
                    .buttonStyle(.bordered).controlSize(.small)

                    Button("Port 3000") {
                        endpointBinding.wrappedValue = "http://localhost:3000/v1"
                    }
                    .buttonStyle(.bordered).controlSize(.small)

                    Button("Port 4000") {
                        endpointBinding.wrappedValue = "http://localhost:4000/v1"
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }

                TextField(defaultEndpoint, text: endpointBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            // Model ID
            VStack(alignment: .leading, spacing: 8) {
                Text("Model ID")
                    .font(.subheadline).fontWeight(.medium)

                HStack {
                    TextField(defaultModel, text: modelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    if !discoveredModels.isEmpty {
                        Menu("Pick") {
                            ForEach(discoveredModels, id: \.self) { m in
                                Button(m) { modelBinding.wrappedValue = m }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                Text("Model name the bridge exposes. Run Test Connection to discover models.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Test Connection
            HStack(spacing: 10) {
                Button {
                    Task { await testConnection() }
                } label: {
                    if case .testing = testState {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.75)
                            Text("Testing…")
                        }
                        .frame(minWidth: 120)
                    } else {
                        Label("Test Connection", systemImage: "network")
                            .frame(minWidth: 120)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(endpointBinding.wrappedValue.isEmpty || testState == .testing)

                switch testState {
                case .idle: EmptyView()
                case .testing: EmptyView()
                case .success(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func testConnection() async {
        testState = .testing
        discoveredModels = []

        let base = endpointBinding.wrappedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Try GET /models first
        if let url = URL(string: "\(base)/models") {
            do {
                var req = URLRequest(url: url, timeoutInterval: 5)
                req.httpMethod = "GET"
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode < 500 {
                    // Parse models if possible
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let modelArray = json["data"] as? [[String: Any]] {
                        let ids = modelArray.compactMap { $0["id"] as? String }
                        await MainActor.run {
                            discoveredModels = ids
                            if !ids.isEmpty && modelBinding.wrappedValue.isEmpty {
                                modelBinding.wrappedValue = ids[0]
                            }
                        }
                    }
                    await MainActor.run {
                        testState = .success(discoveredModels.isEmpty ? "Bridge reachable" : "\(discoveredModels.count) model(s) found")
                    }
                    return
                }
            } catch { }
        }

        // Fallback: probe with a minimal chat completion
        if let url = URL(string: "\(base)/chat/completions") {
            do {
                var req = URLRequest(url: url, timeoutInterval: 5)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: Any] = [
                    "model": modelBinding.wrappedValue.isEmpty ? "default" : modelBinding.wrappedValue,
                    "messages": [["role": "user", "content": "ping"]],
                    "max_tokens": 1
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode < 500 {
                    await MainActor.run { testState = .success("Bridge reachable") }
                    return
                }
            } catch { }
        }

        await MainActor.run {
            testState = .failure("Not reachable — is VibeProxy running?")
        }
    }
}

private struct BridgeFeatureRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - AI Provider Row
struct AIProviderRow: View {
    let provider: AIProvider
    let isSelected: Bool
    let isConfigured: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.system(size: 20))

                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(rowAccent.opacity(isSelected ? 0.18 : 0.09))
                        .frame(width: 36, height: 36)
                    Image(systemName: provider.iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isSelected ? rowAccent : .primary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        if isConfigured && provider.requiresAPIKey {
                            Label("Ready", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.green)
                                .labelStyle(.iconOnly)
                        } else if provider.requiresAPIKey && !isConfigured {
                            Text("ADD KEY")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                        }
                    }

                    Text(provider.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? rowAccent.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? rowAccent.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var rowAccent: Color {
        switch provider {
        case .onDevice:     return .blue
        case .googleGemini: return .indigo
        case .openAI:       return .teal
        case .anthropic:    return .orange
        case .claudeBridge: return .purple
        case .chatGPTBridge: return .teal
        case .ollama:       return .green
        case .openAICompatible: return .mint
        case .shortcuts:    return .purple
        }
    }
}

// MARK: - Feature Row Helper
private struct FeatureRow: View {
    let icon: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Shortcuts Settings Tab
// MARK: - Reusable hotkey recorder row
private struct HotkeyRecorderRow: View {
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
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.red.opacity(0.3), lineWidth: 1))
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
        .padding(.vertical, 4)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            var carbon: UInt32 = 0
            if event.modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.option)  { carbon |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
            if event.modifierFlags.contains(.shift)   { carbon |= UInt32(shiftKey) }
            if carbon != 0 {
                self.apply(UInt32(event.keyCode), carbon)
                self.stopRecording()
                NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}


// MARK: - Terminal Settings Tab
struct TerminalSettingsView: View {
    @StateObject private var packageManager = TerminalPackageManager.shared
    @State private var isScanning = false
    @State private var isDetecting = false
    @State private var detectSummary: String? = nil
    @State private var selectedPackage: TerminalPackage?
    @State private var showAddPackageSheet = false
    @State private var searchQuery = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Terminal Packages (L2)")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("AI-powered terminal that auto-generates commands for your requests")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button(action: scanForTools) {
                        HStack(spacing: 4) {
                            if isScanning { ProgressView().scaleEffect(0.7) }
                            Image(systemName: "magnifyingglass")
                            Text("Scan")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isScanning)
                    .help("Scan for installed tools")

                    Button(action: {
                        Task { await detectAndAutoAddNewTools() }
                    }) {
                        HStack(spacing: 4) {
                            if isDetecting { ProgressView().scaleEffect(0.7) }
                            Image(systemName: "sparkle.magnifyingglass")
                            Text("Detect")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDetecting)
                    .help("Auto-detect new tools and assign intents")

                    Button(action: { showAddPackageSheet = true }) {
                        Label("Add", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()

            if let summary = detectSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(summary.hasPrefix("✅") ? Color.green : Color.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Quick Info Card
                    CardSection(title: "AI-Powered Terminal", systemImage: "sparkles") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Just ask L2 in natural language - it figures out the commands:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                FeatureRow(icon: "network", text: "\"show wifi details\" → auto-executes network commands", color: .blue)
                                FeatureRow(icon: "cpu", text: "\"check disk space\" → df -h", color: .green)
                                FeatureRow(icon: "arrow.down.circle", text: "\"download video\" → uses yt-dlp if configured", color: .orange)
                                FeatureRow(icon: "checkmark.shield", text: "Asks before installing missing packages", color: .purple)
                            }
                        }
                    }
                    
                    // Configured Packages
                    CardSection(title: "Configured Packages", systemImage: "shippingbox") {
                        VStack(alignment: .leading, spacing: 12) {
                            if packageManager.packages.isEmpty {
                                VStack(spacing: 16) {
                                    Image(systemName: "terminal")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.secondary)
                                    
                                    VStack(spacing: 8) {
                                        Text("No Packages Configured")
                                            .font(.headline)
                                        
                                        Text("Click 'Scan' to auto-detect, 'GitHub' to import, or 'Brew' to browse")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                            } else {
                                // Search bar
                                HStack {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(.secondary)
                                    TextField("Search packages...", text: $searchQuery)
                                        .textFieldStyle(.plain)
                                    
                                    if !searchQuery.isEmpty {
                                        Button(action: { searchQuery = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(8)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                                
                                Divider()
                                
                                // Package list
                                ForEach(filteredPackages) { package in
                                    TerminalPackageRow(
                                        package: package,
                                        onToggle: { togglePackage(package) },
                                        onEdit: { selectedPackage = package },
                                        onDelete: { packageManager.removePackage(package) }
                                    )
                                    
                                    if package.id != filteredPackages.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                    
                    // Universal Intent Assignments
                    CardSection(title: "Universal Intents (L2 Auto-Routing)", systemImage: "map") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("L2 automatically routes requests to the right tool based on intent. Set one tool per capability.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Divider()
                            IntentAssignmentsView()
                                .frame(minHeight: 200)
                        }
                    }

                    // Example Commands
                    CardSection(title: "Example Natural Language Commands", systemImage: "text.bubble") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Try these in L2 (Layer 2 chat):")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 8) {
                                ExampleCommandRow(
                                    icon: "wifi",
                                    example: "show wifi details",
                                    result: "Auto-executes network commands"
                                )
                                
                                ExampleCommandRow(
                                    icon: "arrow.up.circle",
                                    example: "update all packages",
                                    result: "Runs: brew upgrade"
                                )
                                
                                ExampleCommandRow(
                                    icon: "cpu",
                                    example: "check disk space",
                                    result: "Shows disk usage"
                                )
                                
                                ExampleCommandRow(
                                    icon: "play.rectangle",
                                    example: "download this video",
                                    result: "Uses yt-dlp if configured"
                                )
                            }
                            
                            Divider()
                            
                            HStack {
                                Image(systemName: "lightbulb")
                                    .foregroundStyle(.yellow)
                                Text("L2 auto-generates commands, asks before installing missing packages")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showAddPackageSheet) {
            AddPackageSheet(packageManager: packageManager)
        }
        .sheet(item: $selectedPackage) { package in
            EditPackageSheet(package: package, packageManager: packageManager)
        }
    }
    
    private var filteredPackages: [TerminalPackage] {
        if searchQuery.isEmpty {
            return packageManager.packages
        }
        let query = searchQuery.lowercased()
        return packageManager.packages.filter { package in
            package.name.lowercased().contains(query) ||
            package.command.lowercased().contains(query) ||
            package.description.lowercased().contains(query) ||
            package.keywords.contains(where: { $0.lowercased().contains(query) })
        }
    }
    
    private func scanForTools() {
        isScanning = true
        Task {
            let discovered = await packageManager.scanForInstalledTools()

            await MainActor.run {
                // Add newly discovered packages
                for package in discovered {
                    if !packageManager.packages.contains(where: { $0.command == package.command }) {
                        packageManager.addPackage(package)
                    }
                }
                isScanning = false
            }
        }
    }

    /// Scan binary dirs and populate the BinaryDiscoveryBanner for user review.
    /// Does NOT auto-add — user clicks "Add to L2" in the banner for each tool they want.
    private func detectAndAutoAddNewTools() async {
        isDetecting = true
        detectSummary = nil

        let watcher = BinaryWatcherService.shared
        let beforeCount = watcher.newToolsFound.filter { !$0.isAdded }.count

        // Use skipHelpScan=true so we don't hang spawning 100+ --help processes.
        // Help text is fetched on demand when the user clicks "Add to L2" in the banner.
        await watcher.scanNow(skipHelpScan: true)

        let found = watcher.newToolsFound.filter { !$0.isAdded }.count - beforeCount
        if found > 0 {
            detectSummary = "🔍 Found \(found) new tool\(found > 1 ? "s" : "") — open the terminal panel to review and add them"
        } else if watcher.newToolsFound.filter({ !$0.isAdded }).isEmpty {
            detectSummary = "✅ No new tools found — everything is already configured"
        } else {
            detectSummary = "🔍 \(watcher.newToolsFound.filter { !$0.isAdded }.count) tool(s) pending review in the terminal panel"
        }
        isDetecting = false
    }
    
    private func togglePackage(_ package: TerminalPackage) {
        var updated = package
        updated.isEnabled.toggle()
        packageManager.updatePackage(updated)
    }
}

// MARK: - Terminal Package Row
struct TerminalPackageRow: View {
    let package: TerminalPackage
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Toggle("", isOn: Binding(
                get: { package.isEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            
            // Icon
            Image(systemName: package.isInstalled ? "checkmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(package.isInstalled ? .green : .orange)
                .font(.title3)
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(package.name)
                        .font(.headline)
                    
                    Text(package.command)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(4)
                }
                
                Text(package.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if !package.keywords.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(package.keywords.prefix(5), id: \.self) { keyword in
                            Text(keyword)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .cornerRadius(3)
                        }
                    }
                }
                
                if let path = package.installedPath {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 8) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit package")
                
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Remove package")
            }
        }
        .padding(.vertical, 8)
        .opacity(package.isEnabled ? 1.0 : 0.6)
    }
}

// MARK: - Example Command Row
struct ExampleCommandRow: View {
    let icon: String
    let example: String
    let result: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("\"\(example)\"")
                    .font(.caption)
                    .fontWeight(.medium)
                
                Text("→ \(result)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Add Package Sheet
struct AddPackageSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var packageManager: TerminalPackageManager
    var onAdd: ((TerminalPackage) -> Void)? = nil
    
    @State private var name = ""
    @State private var command = ""
    @State private var description = ""
    @State private var keywords = ""
    @State private var isVerifying = false
    @State private var verificationResult: String? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Terminal Package")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
            // Form
            Form {
                Section {
                    TextField("Name (e.g., YouTube Downloader)", text: $name)
                    TextField("Command (e.g., yt-dlp)", text: $command)
                        .fontDesign(.monospaced)
                    TextField("Description", text: $description)
                    TextField("Keywords (comma separated)", text: $keywords)
                        .help("e.g., youtube, video, download")
                }
                
                Section {
                    HStack {
                        Button(action: verifyCommand) {
                            HStack {
                                if isVerifying {
                                    ProgressView().scaleEffect(0.7)
                                }
                                Text("Verify Installation")
                            }
                        }
                        .disabled(command.isEmpty || isVerifying)
                        
                        if let result = verificationResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.contains("✓") ? .green : .orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            
            Divider()
            
            // Actions
            HStack {
                Spacer()
                Button("Add Package") {
                    addPackage()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || command.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
    }
    
    private func verifyCommand() {
        isVerifying = true
        verificationResult = nil
        
        Task {
            if let path = await findCommandPath(command) {
                await MainActor.run {
                    verificationResult = "✓ Found at \(path)"
                    isVerifying = false
                }
            } else {
                await MainActor.run {
                    verificationResult = "⚠ Command not found in PATH"
                    isVerifying = false
                }
            }
        }
    }
    
    private func findCommandPath(_ cmd: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [cmd]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    return path
                }
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to verify command: \(error)")
            #endif
        }
        
        return nil
    }
    
    private func addPackage() {
        let keywordArray = keywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        let package = TerminalPackage(
            name: name,
            command: command,
            description: description,
            installedPath: nil,
            keywords: keywordArray
        )
        
        packageManager.addPackage(package)
        onAdd?(package)
        dismiss()
    }
}

// MARK: - Edit Package Sheet
struct EditPackageSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var packageManager: TerminalPackageManager
    
    @State private var package: TerminalPackage
    @State private var name: String
    @State private var command: String
    @State private var description: String
    @State private var keywords: String
    @State private var customNotes: String
    
    init(package: TerminalPackage, packageManager: TerminalPackageManager) {
        self.packageManager = packageManager
        _package = State(initialValue: package)
        _name = State(initialValue: package.name)
        _command = State(initialValue: package.command)
        _description = State(initialValue: package.description)
        _keywords = State(initialValue: package.keywords.joined(separator: ", "))
        _customNotes = State(initialValue: package.customNotes)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Package")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            
            Divider()
            
            // Form
            Form {
                Section("Basic Info") {
                    TextField("Name", text: $name)
                    TextField("Command", text: $command)
                        .fontDesign(.monospaced)
                    TextField("Description", text: $description)
                }
                
                Section("Keywords") {
                    TextField("Keywords (comma separated)", text: $keywords)
                    Text("Used for matching natural language queries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section("Usage Examples") {
                    if package.usageExamples.isEmpty {
                        Text("No examples available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(package.usageExamples.prefix(5), id: \.self) { example in
                            Text(example)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                
                Section("Notes") {
                    TextEditor(text: $customNotes)
                        .frame(height: 80)
                        .font(.caption)
                }
                
                if let path = package.installedPath {
                    Section("Installation") {
                        LabeledContent("Path") {
                            Text(path)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 600, height: 500)
    }
    
    private func saveAndDismiss() {
        var updated = package
        updated.name = name
        updated.command = command
        updated.description = description
        updated.keywords = keywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        updated.customNotes = customNotes
        
        packageManager.updatePackage(updated)
        dismiss()
    }
}

// MARK: - App Shortcuts Settings Tab
struct AppShortcutsSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared
    @ObservedObject private var l2Manager = L2ExtensionManager.shared
    @State private var selectedAppKey: String = "calendar"
    @State private var showAddShortcut = false
    @State private var editingShortcut: AppShortcut? = nil
    @State private var showAddApp = false
    @State private var showAddExtension = false
    @State private var editingExtension: AppToolExtension? = nil
    @State private var showAddCLITool = false
    @State private var showExportPanel = false
    @State private var showImportPanel = false
    @State private var showAddL2Tool = false        // Create new context dock tool
    @State private var editingL2Tool: L2Extension? = nil  // Edit existing context dock tool

    private let builtInApps: [(key: String, label: String, icon: String, appPath: String)] = [
        ("finder",          "Files & Folders",   "folder",           "/System/Library/CoreServices/Finder.app"),
        ("safari",          "Safari",            "safari",           "/Applications/Safari.app"),
        ("systemsettings",  "System Settings",   "gear.badge",       "/System/Applications/System Settings.app"),
        ("calendar",        "Calendar",          "calendar",         "/System/Applications/Calendar.app"),
        ("reminders",       "Reminders",         "checkmark.circle", "/System/Applications/Reminders.app"),
        ("notes",           "Notes",             "note.text",        "/System/Applications/Notes.app"),
        ("mail",            "Mail",              "envelope",         "/System/Applications/Mail.app"),
        ("photos",          "Photos",            "photo",            "/System/Applications/Photos.app"),
        ("messages",        "Messages",          "message",          "/System/Applications/Messages.app"),
        ("contacts",        "Contacts",          "person.2",         "/System/Applications/Contacts.app"),
    ]

    private var selectedLabel: String {
        if selectedAppKey == "homebrew" { return "Homebrew" }
        if selectedAppKey.hasPrefix("cli_") {
            let cmd = String(selectedAppKey.dropFirst(4))
            return pkgMgr.packages.first(where: { $0.command == cmd })?.name ?? cmd
        }
        return builtInApps.first(where: { $0.key == selectedAppKey })?.label
            ?? settings.customAppEntries.first(where: { $0.key == selectedAppKey })?.label
            ?? selectedAppKey.capitalized
    }

    private func removeCLIToolFromAppActions(_ package: TerminalPackage) {
        settings.unpinCLITool(package.command)
        settings.customAppEntries.removeAll { entry in
            entry.key == "cli_\(package.command)"
                || entry.key == "cli://\(package.command)"
                || entry.appPath == "cli://\(package.command)"
        }
        settings.appToolExtensions.removeAll {
            $0.appKey == "cli_\(package.command)" || $0.appKey == "cli://\(package.command)"
        }
        var updated = package
        updated.contextAppBundleIds.removeAll {
            $0 == "cli://\(package.command)" || $0 == "cli_\(package.command)"
        }
        pkgMgr.updatePackage(updated)
    }

    // All tool names already known to TerminalPackageManager
    private var installedToolNames: Set<String> {
        Set(pkgMgr.packages.map { $0.command })
    }

    // MARK: - Left sidebar
    @ViewBuilder
    private var appSidebarView: some View {
        VStack(spacing: 0) {
            List(selection: $selectedAppKey) {
                Section("Built-in Apps") {
                    ForEach(builtInApps, id: \.key) { item in
                        AppSidebarRow(label: item.label, appPath: item.appPath, fallbackIcon: item.icon)
                            .tag(item.key)
                    }
                }
                if !settings.customAppEntries.isEmpty {
                    Section("My Apps") {
                        ForEach(settings.customAppEntries) { entry in
                            AppSidebarRow(label: entry.label, appPath: entry.appPath, fallbackIcon: entry.iconName)
                                .tag(entry.key)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        settings.removeCustomApp(entry)
                                        if selectedAppKey == entry.key { selectedAppKey = "calendar" }
                                    } label: { Label("Remove App", systemImage: "trash") }
                                }
                        }
                    }
                }
                let brewInstalled = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
                    || FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
                if brewInstalled {
                    Section("Package Manager") {
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox.fill").font(.system(size: 14))
                                .foregroundStyle(Color.orange).frame(width: 20)
                            Text("Homebrew").font(.system(size: 13, weight: .medium))
                        }
                        .tag("homebrew")
                    }
                }
                let pinnedCmds = settings.pinnedCLITools
                let pinnedPkgs = pkgMgr.packages.filter { pinnedCmds.contains($0.command) }
                if !pinnedPkgs.isEmpty {
                    Section("My CLI Tools") {
                        ForEach(pinnedPkgs, id: \.command) { pkg in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.right.square.fill").font(.system(size: 14))
                                    .foregroundStyle(Color.accentColor).frame(width: 20)
                                Text(pkg.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            }
                            .tag("cli_\(pkg.command)")
                            .contextMenu {
                                Button(role: .destructive) {
                                    removeCLIToolFromAppActions(pkg)
                                    if selectedAppKey == "cli_\(pkg.command)" { selectedAppKey = "calendar" }
                                } label: { Label("Remove from My CLI Tools", systemImage: "minus.circle") }
                            }
                        }
                    }
                }
                let cliPkgs = pkgMgr.packages.filter { TerminalAIBridge.shared.isTUICommand($0.command) }.prefix(30)
                if !cliPkgs.isEmpty {
                    Section("TUI Apps") {
                        ForEach(cliPkgs, id: \.command) { pkg in
                            HStack(spacing: 8) {
                                Image(systemName: "terminal.fill").font(.system(size: 14))
                                    .foregroundStyle(Color.green).frame(width: 20)
                                Text(pkg.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            }
                            .tag("cli_\(pkg.command)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button { showAddApp = true } label: {
                Label("Add App", systemImage: "plus.app")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            Button { showAddCLITool = true } label: {
                Label("Add CLI Tool", systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor).padding(.bottom, 4)
        }
        .frame(minWidth: 160, maxWidth: 200)
    }

    // MARK: - Right panel
    @ViewBuilder
    private var appRightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedLabel).font(.title2).bold()
                Spacer()
                Button { showImportPanel = true } label: {
                    Label("Import", systemImage: "square.and.arrow.down").font(.caption)
                }
                .buttonStyle(.bordered).help("Import an app profile template (JSON)")
                Button { showExportPanel = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up").font(.caption)
                }
                .buttonStyle(.bordered).help("Export this app's shortcuts and tools as a JSON template")
            }
            .padding()
            Divider()
            ScrollView { appDetailScrollContent }
        }
    }

    // MARK: - App detail scroll content (extracted to reduce body complexity)
    @ViewBuilder
    private var appDetailScrollContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            let selectedCustomLabel = settings.customAppEntries.first(where: { $0.key == selectedAppKey })?.label ?? ""
            let toolPathsDict = Dictionary(
                pkgMgr.packages.compactMap { pkg -> (String, String)? in
                    guard let path = pkg.installedPath else { return nil }
                    return (pkg.command, path)
                },
                uniquingKeysWith: { first, _ in first }
            )

            // Hardcoded suggestions card
            if let suggestion = AppSuggestionsDB.suggestions(for: selectedAppKey, label: selectedCustomLabel) {
                AppSuggestionsCard(entry: suggestion, appKey: selectedAppKey,
                                  installedToolNames: installedToolNames,
                                  installedToolPaths: toolPathsDict) { sc in
                    settings.addShortcut(sc)
                } onAddExtension: { ext in
                    settings.addToolExtension(ext)
                }
                .padding(.bottom, 4)
            }

            // Auto-detected CLIs
            let autoDetected = AppSuggestionsDB.autoDetectedCLIs(
                for: selectedAppKey, label: selectedCustomLabel,
                installedPackages: pkgMgr.packages)
            if !autoDetected.isEmpty {
                AutoDetectedCLICard(appKey: selectedAppKey, packages: autoDetected) { ext in
                    settings.addToolExtension(ext)
                }
                .padding(.bottom, 4)
            }

            // TUI Permissions (only for TUI apps)
            if selectedAppKey.hasPrefix("cli_") {
                TUIPermissionsSection(command: String(selectedAppKey.dropFirst(4)))
                    .padding(.bottom, 4)
            }

            // Quick Actions
            appSectionHeader("Quick Actions", subtitle: "Appear at the top when you type \"\(selectedAppKey)\" in the launcher") {
                showAddShortcut = true
            }
            let shortcuts = settings.shortcuts(for: selectedAppKey)
            if shortcuts.isEmpty {
                Text("No actions yet. Tap + to add one.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.bottom, 8)
            } else {
                ForEach(shortcuts) { sc in
                    shortcutRow(sc)
                    Divider().padding(.leading, 52)
                }
            }

            // AI Extensions
            Divider().padding(.top, 12)
            appSectionHeader("AI Extensions", subtitle: "CLI tools the AI uses when this app is active") {
                showAddExtension = true
            }
            let exts = settings.toolExtensions(for: selectedAppKey)
            if exts.isEmpty {
                Text("No extensions. Tap + to assign a CLI tool.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.bottom, 8)
            } else {
                ForEach(exts) { ext in
                    extensionRow(ext)
                    Divider().padding(.leading, 52)
                }
            }

            // Context Dock Actions
            contextDockActionsSection

            // File Actions
            fileActionsSection
        }
    }

    // MARK: - Context Dock Actions section (extracted to reduce body complexity)
    @ViewBuilder
    private var contextDockActionsSection: some View {
        let appL2Tools = l2Manager.extensions.filter { tool in
            guard !tool.contextApps.isEmpty else { return false }
            return tool.contextApps.contains { ctx in
                ctx.lowercased().contains(selectedAppKey.lowercased())
                    || selectedAppKey.lowercased().contains(ctx.lowercased())
            }
        }
        Divider().padding(.top, 12)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Context Dock Actions").font(.headline)
                Text("One-tap pills in the L2 dock when this app is frontmost")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { L2ExtensionManager.shared.openExtensionsFolder() } label: {
                Image(systemName: "folder")
                    .frame(width: 28, height: 28)
                    .background(Color.purple.opacity(0.12), in: Circle())
                    .foregroundStyle(.purple)
            }
            .buttonStyle(.plain).help("Open extensions folder")
            Button { showAddL2Tool = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.purple)
            }
            .buttonStyle(.plain).help("New context dock action")
        }
        .padding()

        // User shortcuts placed in contextDock or both
        let dockShortcuts = settings.contextDockShortcuts(for: selectedAppKey)

        if appL2Tools.isEmpty && dockShortcuts.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed").foregroundStyle(.tertiary)
                Text("No dock actions yet — tap + to create one, or add a script via Quick Actions with placement set to \"Context Dock\".")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        } else {
            // AppShortcuts placed in contextDock / both
            ForEach(dockShortcuts) { sc in
                HStack(spacing: 12) {
                    Image(systemName: sc.iconName)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sc.name).fontWeight(.medium)
                        Text(sc.actionType.rawValue)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(sc.placement == .both ? "quick + dock" : "dock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.1), in: Capsule())
                    Button { editingShortcut = sc } label: {
                        Image(systemName: "pencil")
                    }.buttonStyle(.plain)
                    Button { settings.removeShortcut(sc) } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal).padding(.vertical, 8)
                Divider().padding(.leading, 52)
            }

            ForEach(appL2Tools) { tool in
                HStack(spacing: 12) {
                    Image(systemName: tool.icon)
                        .frame(width: 28, height: 28)
                        .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(tool.displayName).fontWeight(.medium)
                            Text(tool.toolName)
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.secondary.opacity(0.1), in: Capsule())
                        }
                        if tool.contextApps.count > 1 {
                            Text("Apps: \(tool.contextApps.joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(tool.description)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(tool.scriptType.rawValue)
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.08), in: Capsule())
                    Button { editingL2Tool = tool } label: {
                        Image(systemName: "pencil")
                    }.buttonStyle(.plain)
                    Button {
                        if let folder = tool.folderPath {
                            try? FileManager.default.removeItem(at: folder)
                            Task { await L2ExtensionManager.shared.loadExtensions() }
                        }
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal).padding(.vertical, 8)
                Divider().padding(.leading, 52)
            }
        }
    }

    // MARK: - File Actions section
    @ViewBuilder
    private var fileActionsSection: some View {
        let fileShortcuts = settings.appShortcuts.filter { $0.placement == .fileActions }
        Divider().padding(.top, 12)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("File Actions").font(.headline)
                Text("Action buttons that appear when a file is selected in search results")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showAddShortcut = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain).help("New file action")
        }
        .padding()

        if fileShortcuts.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape").foregroundStyle(.tertiary)
                Text("No file actions yet — tap + and choose \"File Actions\" as the placement.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        } else {
            ForEach(fileShortcuts) { sc in
                HStack(spacing: 12) {
                    Image(systemName: sc.iconName)
                        .frame(width: 28, height: 28)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sc.name).fontWeight(.medium)
                        if sc.fileTypes.isEmpty {
                            Text("All files · \(sc.actionType.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(sc.fileTypes.joined(separator: ", ") + " · \(sc.actionType.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !sc.triggerKeywords.isEmpty {
                        Text(sc.triggerKeywords.prefix(2).joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.secondary.opacity(0.1), in: Capsule())
                    }
                    Button { editingShortcut = sc } label: {
                        Image(systemName: "pencil")
                    }.buttonStyle(.plain)
                    Button { settings.removeShortcut(sc) } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal).padding(.vertical, 8)
                Divider().padding(.leading, 52)
            }
        }
    }

    var body: some View {
        HSplitView {
            appSidebarView
            appRightPanel
        }
        .task { await L2ExtensionManager.shared.loadExtensions() }
        .modifier(AppShortcutsSheets(
            selectedAppKey: selectedAppKey,
            builtInApps: builtInApps,
            showAddShortcut: $showAddShortcut,
            editingShortcut: $editingShortcut,
            showAddApp: $showAddApp,
            showAddCLITool: $showAddCLITool,
            showAddExtension: $showAddExtension,
            editingExtension: $editingExtension,
            showAddL2Tool: $showAddL2Tool,
            editingL2Tool: $editingL2Tool,
            showImportPanel: $showImportPanel,
            showExportPanel: $showExportPanel
        ))
    }

    @ViewBuilder
    private func appSectionHeader(_ title: String, subtitle: String, onAdd: @escaping () -> Void) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onAdd) {
                Image(systemName: "plus").fontWeight(.semibold)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    @ViewBuilder
    private func shortcutRow(_ sc: AppShortcut) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sc.iconName)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(sc.name).fontWeight(.medium)
                Text(sc.actionValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(sc.actionType.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.secondary.opacity(0.15), in: Capsule())
            Button { editingShortcut = sc } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
            Button { settings.removeShortcut(sc) } label: { Image(systemName: "trash").foregroundStyle(.red) }.buttonStyle(.plain)
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    @ViewBuilder
    private func extensionRow(_ ext: AppToolExtension) -> some View {
        let isScript    = ext.kind == .script
        let isInstalled = isScript || AppSettings.isToolInstalled(ext)
        let iconName    = ext.iconName.isEmpty
            ? (isScript ? (ext.scriptLanguage?.systemImage ?? "doc.text") : "terminal.fill")
            : ext.iconName
        let iconColor: Color = isScript ? .purple : (isInstalled ? .green : .orange)

        return HStack(spacing: 12) {
            Image(systemName: iconName)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ext.toolName).fontWeight(.medium).font(.system(.body, design: .monospaced))

                    if isScript {
                        Text(ext.scriptLanguage?.rawValue ?? "script")
                            .font(.caption2).foregroundStyle(.purple)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                    }
                    if ext.profile.isDestructive {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                            .help("Destructive — AI will confirm before running delete/overwrite operations")
                    }
                    if !isInstalled {
                        Text("not found")
                            .font(.caption2).foregroundStyle(.orange)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .help("Binary not found on disk — will not be injected into AI prompts until installed")
                    }
                }
                if !ext.profile.capabilities.isEmpty {
                    Text(ext.profile.capabilities.prefix(2).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !ext.aiHint.isEmpty {
                    // Show first meaningful line of hint
                    let firstLine = ext.aiHint.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? ""
                    Text(firstLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !ext.toolPath.isEmpty {
                    Text(ext.toolPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            // Re-scan help for CLI tools — refreshes the full recursive help tree
            if ext.kind == .cli {
                Button {
                    Task {
                        await TerminalPackageManager.shared.refreshHelpTextByCommand(ext.toolName)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Re-scan --help (refreshes full command tree for AI)")
            }
            Button { editingExtension = ext } label: {
                Image(systemName: "pencil").foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            Button {
                // Delete script file from disk when removing a script extension
                if ext.kind == .script && !ext.toolPath.isEmpty {
                    settings.deleteScript(at: ext.toolPath)
                }
                settings.removeToolExtension(ext)
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
}

// MARK: - AppShortcutsSheets ViewModifier (keeps body lean)
private struct AppShortcutsSheets: ViewModifier {
    let selectedAppKey: String
    let builtInApps: [(key: String, label: String, icon: String, appPath: String)]
    @Binding var showAddShortcut: Bool
    @Binding var editingShortcut: AppShortcut?
    @Binding var showAddApp: Bool
    @Binding var showAddCLITool: Bool
    @Binding var showAddExtension: Bool
    @Binding var editingExtension: AppToolExtension?
    @Binding var showAddL2Tool: Bool
    @Binding var editingL2Tool: L2Extension?
    @Binding var showImportPanel: Bool
    @Binding var showExportPanel: Bool
    @ObservedObject private var settings = AppSettings.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showAddShortcut) {
                AppShortcutEditSheet(appKey: selectedAppKey, shortcut: nil) { settings.addShortcut($0) }
            }
            .sheet(item: $editingShortcut) { sc in
                AppShortcutEditSheet(appKey: selectedAppKey, shortcut: sc) { settings.updateShortcut($0) }
            }
            .sheet(isPresented: $showAddApp) {
                AddCustomAppSheet { settings.addCustomApp($0) }
            }
            .sheet(isPresented: $showAddCLITool) {
                AddCLIToolSheet { command in settings.pinCLITool(command) }
            }
            .sheet(isPresented: $showAddExtension) {
                AddAppExtensionSheet(appKey: selectedAppKey) { settings.addToolExtension($0) }
            }
            .sheet(item: $editingExtension) { ext in
                AddAppExtensionSheet(appKey: selectedAppKey, existing: ext) { settings.updateToolExtension($0) }
            }
            .sheet(isPresented: $showAddL2Tool) { addL2ToolSheet }
            .sheet(item: $editingL2Tool) { tool in editL2ToolSheet(tool) }
            .fileImporter(isPresented: $showImportPanel, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result, let data = try? Data(contentsOf: url) {
                    try? settings.importTemplate(data)
                }
            }
            .fileExporter(
                isPresented: $showExportPanel,
                document: AppProfileJSONDocument(data: (try? settings.exportTemplate(for: selectedAppKey)) ?? Data()),
                contentType: .json,
                defaultFilename: "\(selectedAppKey)-profile.json"
            ) { _ in }
    }

    @ViewBuilder
    private var addL2ToolSheet: some View {
        let appDisplayName = builtInApps.first(where: { $0.key == selectedAppKey })?.label
            ?? settings.customAppEntries.first(where: { $0.key == selectedAppKey })?.label
            ?? selectedAppKey.capitalized
        L2ExtensionEditorSheet(
            initialJSON: "{\n  \"tool_name\": \"\(selectedAppKey)_action\",\n  \"display_name\": \"My Action\",\n  \"description\": \"Describe what this does\",\n  \"version\": \"1.0\",\n  \"author\": \"me\",\n  \"icon\": \"star.fill\",\n  \"parameters\": {},\n  \"script\": \"script.js\",\n  \"script_type\": \"jxa\",\n  \"task_category\": \"\(selectedAppKey)\",\n  \"context_app\": \"\(appDisplayName)\",\n  \"triggers\": [\"keyword1\", \"keyword2\"]\n}",
            initialScript: "// JXA — runs when user taps the pill\nvar app = Application(\"\(appDisplayName)\");\napp.includeStandardAdditions = true;\napp.displayNotification(\"Done!\", { withTitle: \"My Action\" });",
            onSave: { Task { await L2ExtensionManager.shared.loadExtensions() } }
        )
    }

    @ViewBuilder
    private func editL2ToolSheet(_ tool: L2Extension) -> some View {
        let jsonText: String = {
            guard let folder = tool.folderPath else { return "" }
            return (try? String(contentsOf: folder.appendingPathComponent("extension.json"), encoding: .utf8)) ?? ""
        }()
        let scriptText: String = {
            guard let scriptURL = tool.scriptURL else { return "" }
            return (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
        }()
        L2ExtensionEditorSheet(
            initialJSON: jsonText.isEmpty ? nil : jsonText,
            initialScript: scriptText.isEmpty ? nil : scriptText,
            onSave: { Task { await L2ExtensionManager.shared.loadExtensions() } }
        )
    }
}

// MARK: - TUI Permissions Section
struct TUIPermissionsSection: View {
    let command: String
    @ObservedObject private var settings = AppSettings.shared

    private var folderAccessEnabled: Bool {
        settings.isFolderAccessEnabled(for: command)
    }

    private let userFolders: [(name: String, path: String)] = {
        let home = NSHomeDirectory()
        return [
            ("Downloads",  "\(home)/Downloads"),
            ("Documents",  "\(home)/Documents"),
            ("Desktop",    "\(home)/Desktop"),
            ("Pictures",   "\(home)/Pictures"),
            ("Movies",     "\(home)/Movies"),
            ("Music",      "\(home)/Music"),
        ]
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.top, 12)

            HStack(spacing: 6) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Permissions")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Text("Allow the AI to access your home folders when controlling \(command). The AI will use real paths instead of placeholders like /Users/username.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 10)

            // Main toggle
            HStack(spacing: 12) {
                Image(systemName: folderAccessEnabled ? "folder.fill.badge.checkmark" : "folder.fill.badge.questionmark")
                    .font(.system(size: 20))
                    .foregroundStyle(folderAccessEnabled ? .orange : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow User Folder Access")
                        .font(.system(size: 13, weight: .medium))
                    Text(folderAccessEnabled
                         ? "AI can read/write ~/Downloads, ~/Documents, ~/Desktop and more"
                         : "AI will not access your personal folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { folderAccessEnabled },
                    set: { settings.setFolderAccess(for: command, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.orange)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)

            // Expanded folder list when enabled
            if folderAccessEnabled {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(userFolders, id: \.path) { folder in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange.opacity(0.7))
                            Text(folder.name)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 5)
                        if folder.path != userFolders.last?.path {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.2), lineWidth: 0.5))
                .padding(.horizontal)
                .padding(.top, 6)

                Text("These folders are shared with the AI only when you interact with \(command) in ILauncher. No data leaves your device.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Add CLI Tool Sheet
struct AddCLIToolSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var search = ""
    var onAdd: (String) -> Void

    /// All non-TUI installed packages, filtered by search
    private var filteredPackages: [TerminalPackage] {
        let all = pkgMgr.packages.filter { pkg in
            !TerminalAIBridge.shared.isTUICommand(pkg.command)
        }
        guard !search.isEmpty else { return all }
        let q = search.lowercased()
        return all.filter {
            $0.name.lowercased().contains(q) ||
            $0.command.lowercased().contains(q) ||
            $0.description.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add CLI Tool")
                        .font(.headline)
                    Text("Pick any installed CLI tool to add it to the dock's CLI workspace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search tools…", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.vertical, 8)

            if filteredPackages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(pkgMgr.packages.isEmpty
                         ? "No CLI tools detected yet.\nInstall tools via Homebrew and relaunch."
                         : "No results for \"\(search)\"")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredPackages, id: \.command) { pkg in
                        let pinned = settings.isCLIToolPinned(pkg.command)
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.right.square.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(pinned ? Color.accentColor : Color.secondary.opacity(0.4))
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(pkg.name)
                                    .font(.system(size: 13, weight: .semibold))
                                HStack(spacing: 6) {
                                    Text(pkg.command)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    if let path = pkg.installedPath {
                                        Text("·")
                                            .foregroundStyle(.tertiary)
                                        Text(path)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                if !pkg.description.isEmpty {
                                    Text(pkg.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()

                            if pinned {
                                Label("Added", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .labelStyle(.iconOnly)
                                    .font(.system(size: 18))
                            } else {
                                Button {
                                    onAdd(pkg.command)
                                    dismiss()
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }

            // Bottom: count
            Divider()
            Text("\(filteredPackages.count) CLI tools found")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 6)
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - App Sidebar Row (real app icon)
struct AppSidebarRow: View {
    let label: String
    let appPath: String
    let fallbackIcon: String

    private var appIcon: NSImage? {
        guard !appPath.isEmpty, FileManager.default.fileExists(atPath: appPath) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: appPath)
        return img
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable().interpolation(.high)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: fallbackIcon)
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Color.accentColor)
            }
            Text(label)
        }
    }
}

// MARK: - Add Custom App Sheet
struct AddCustomAppSheet: View {
    let onSave: (CustomAppEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""
    @State private var key: String = ""
    @State private var iconName: String = "app.fill"
    @State private var appPath: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add App").font(.title2).bold()

            Form {
                TextField("App Name (e.g. Slack)", text: $label)
                    .onChange(of: label) { _, v in
                        if key.isEmpty || key == label.lowercased().prefix(key.count).description {
                            key = v.lowercased().filter { $0.isLetter || $0.isNumber }
                        }
                    }

                TextField("Trigger keyword (e.g. slack)", text: $key)

                HStack {
                    TextField("App path (e.g. /Applications/Slack.app)", text: $appPath)
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.applicationBundle]
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            appPath = url.path
                            if label.isEmpty {
                                label = url.deletingPathExtension().lastPathComponent
                                key = label.lowercased().filter { $0.isLetter || $0.isNumber }
                            }
                        }
                    }
                }

                HStack {
                    TextField("SF Symbol icon (e.g. app.fill)", text: $iconName)
                    Image(systemName: iconName).foregroundStyle(Color.accentColor).frame(width: 24)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    guard !label.isEmpty, !key.isEmpty else { return }
                    onSave(CustomAppEntry(key: key, label: label, iconName: iconName, appPath: appPath))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(label.isEmpty || key.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 280)
    }
}

// MARK: - Add App Extension Sheet
// MARK: - Unified Add / Edit Extension Sheet

struct AddAppExtensionSheet: View {
    let appKey: String
    let existing: AppToolExtension?
    let onSave: (AppToolExtension) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var pkgMgr   = TerminalPackageManager.shared

    // Mode
    enum Mode: String, CaseIterable {
        case cli = "CLI Tool"; case script = "Custom Script"; case file = "Script File"; case prompt = "AI Prompt"
    }
    @State private var mode: Mode

    // ── CLI Tool fields ──────────────────────────────────────────────────────
    @State private var toolName: String
    @State private var toolPath: String
    @State private var aiHint: String
    @State private var capabilitiesText: String
    @State private var examplesText: String
    @State private var isDestructive: Bool
    /// Per-app entry command, e.g. "memo notes" when memo is set for Notes app.
    /// Auto-detected after help scan; user can override.
    @State private var appSubcommand: String = ""
    /// Context flag, e.g. "--reminders" for ekctl when panel is Reminders.
    @State private var appContextFlag: String = ""
    @State private var scannedHelp: String = ""
    @State private var isScanning = false
    @State private var scanDone = false
    // inline install
    @State private var showInstall = false
    @State private var installMethod: ToolInstallMethod = .brew
    @State private var installPkg: String = ""
    @State private var installLog: String = ""
    @State private var isInstalling = false
    @State private var installDone = false
    @State private var allInstalledBinaries: [String] = []

    // ── Custom Script fields ─────────────────────────────────────────────────
    @State private var scriptName: String = ""
    @State private var scriptLang: AppScriptLanguage = .bash
    @State private var scriptCode: String = ""
    @State private var scriptDesc: String = ""
    @State private var showTemplatePicker = false

    // ── Script File fields ───────────────────────────────────────────────────
    @State private var scriptFilePath: String = ""
    @State private var scriptFileDesc: String = ""
    @State private var showFilePicker = false

    // ── AI Prompt fields ─────────────────────────────────────────────────────
    @State private var promptName: String = ""
    @State private var promptTemplate: String = ""
    @State private var cacheTTLMinutes: Int = 0

    init(appKey: String, existing: AppToolExtension? = nil, initialMode: Mode? = nil, onSave: @escaping (AppToolExtension) -> Void) {
        self.appKey   = appKey
        self.existing = existing
        self.onSave   = onSave
        let isPrompt = existing?.kind == .prompt
        let isScript = existing?.kind == .script
        let isFile   = existing?.kind == .script && existing?.scriptCode.isEmpty == true
        _mode = State(initialValue: existing != nil
            ? (isPrompt ? .prompt : isFile ? .file : isScript ? .script : .cli)
            : (initialMode ?? .cli))
        _toolName          = State(initialValue: existing?.toolName ?? "")
        _toolPath          = State(initialValue: existing?.toolPath ?? "")
        _aiHint            = State(initialValue: existing?.aiHint ?? "")
        _capabilitiesText  = State(initialValue: existing?.profile.capabilities.joined(separator: ", ") ?? "")
        _examplesText      = State(initialValue: existing?.profile.exampleCommands.joined(separator: "\n") ?? "")
        _isDestructive     = State(initialValue: existing?.profile.isDestructive ?? false)
        _appSubcommand     = State(initialValue: existing?.appSubcommand ?? "")
        _appContextFlag    = State(initialValue: existing?.appContextFlag ?? "")
        _scriptName        = State(initialValue: existing?.toolName ?? "")
        _scriptLang        = State(initialValue: existing?.scriptLanguage ?? .bash)
        _scriptCode        = State(initialValue: existing?.scriptCode ?? "")
        _scriptDesc        = State(initialValue: existing?.aiHint ?? "")
        _scriptFilePath    = State(initialValue: (existing?.kind == .script && existing?.scriptCode.isEmpty == true) ? (existing?.toolPath ?? "") : "")
        _scriptFileDesc    = State(initialValue: existing?.aiHint ?? "")
        _promptName        = State(initialValue: existing?.toolName ?? "")
        _promptTemplate    = State(initialValue: existing?.promptTemplate ?? "")
        _cacheTTLMinutes   = State(initialValue: existing?.cacheTTLMinutes ?? 0)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "Add to \(appKey.capitalized)" : "Edit Extension")
                        .font(.system(size: 16, weight: .semibold))
                    Text("AI uses these tools when you interact with \(appKey.capitalized)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                // Mode picker (tab-bar style)
                HStack(spacing: 0) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Button(action: { mode = m }) {
                            Text(m.rawValue)
                                .font(.system(size: 11, weight: mode == m ? .semibold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(mode == m ? Color.accentColor.opacity(0.15) : Color.clear)
                                .foregroundStyle(mode == m ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        if m != Mode.allCases.last { Divider().frame(height: 18) }
                    }
                }
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.15)))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)

            Divider()

            // ── Content ───────────────────────────────────────────────────────
            ScrollView {
                Group {
                    switch mode {
                    case .cli:    cliContent
                    case .script: scriptContent
                    case .file:   fileContent
                    case .prompt: promptContent
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }

            Divider()

            // ── Footer ────────────────────────────────────────────────────────
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 600, height: 520)
        .task {
            if let e = existing, e.kind == .cli, !e.toolName.isEmpty, !e.aiHint.contains("--help output:") {
                triggerHelpScan(command: e.toolName)
            }
            // Populate full list of installed executables from bin dirs
            let bins = await scanInstalledBinaries()
            allInstalledBinaries = bins
        }
    }

    private func scanInstalledBinaries() async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let home = NSHomeDirectory()
            let dirs = [
                "/opt/homebrew/bin", "/opt/homebrew/sbin",
                "/usr/local/bin",
                "\(home)/.local/bin",
                "\(home)/.cargo/bin",
                "\(home)/go/bin",
                "\(home)/.npm-global/bin",
                "\(home)/.yarn/bin",
                "\(home)/.deno/bin",
                "\(home)/.bun/bin",
            ]
            let fm = FileManager.default
            var results: [String] = []
            for dir in dirs {
                guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for item in items {
                    let full = "\(dir)/\(item)"
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
                       fm.isExecutableFile(atPath: full) {
                        results.append(item)
                    }
                }
            }
            return Array(Set(results)).sorted()
        }.value
    }

    // MARK: - CLI content

    private var cliContent: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Tool name + known packages picker
            VStack(alignment: .leading, spacing: 6) {
                Label("Tool name", systemImage: "terminal").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    TextField("e.g. memo, rem, yt-dlp", text: $toolName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { triggerHelpScan(command: toolName) }

                    if !toolName.isEmpty {
                        let found = isCLIInstalled
                        Label(found ? "Found" : "Not found",
                              systemImage: found ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(found ? Color.green : Color.orange)
                    }
                }

                // Quick-pick from all installed binaries
                if !allInstalledBinaries.isEmpty {
                    Menu("Pick from installed tools… ▾") {
                        ForEach(allInstalledBinaries, id: \.self) { bin in
                            Button(bin) {
                                toolName = bin
                                toolPath = ""
                                triggerHelpScan(command: bin)
                            }
                        }
                    }
                    .font(.system(size: 11))
                    .menuStyle(.borderlessButton)
                } else if !pkgMgr.packages.isEmpty {
                    // Fallback while scan is running
                    Menu("Pick from installed tools… ▾") {
                        ForEach(pkgMgr.packages.filter { $0.installedPath != nil }) { pkg in
                            Button(pkg.command) {
                                toolName = pkg.command
                                toolPath = pkg.installedPath ?? ""
                                triggerHelpScan(command: pkg.command)
                            }
                        }
                    }
                    .font(.system(size: 11))
                    .menuStyle(.borderlessButton)
                }
            }

            // ── Install panel (shown when not installed) ──────────────────────
            if !toolName.isEmpty && !isCLIInstalled {
                installPanel
            }

            // ── Help scan status ──────────────────────────────────────────────
            if !toolName.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if isScanning {
                            ProgressView().scaleEffect(0.6)
                            Text("Scanning \(toolName)…").font(.caption).foregroundStyle(.secondary)
                        } else if scanDone && !scannedHelp.isEmpty {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                            let cmdCount = TerminalPackageManager.shared.scanLog
                                .filter { $0.hasPrefix("✓") }.count
                            Text("Scanned \(cmdCount) command path\(cmdCount == 1 ? "" : "s") — AI knows all \(toolName) subcommands")
                                .font(.caption).foregroundStyle(.green)
                        } else if scanDone && scannedHelp.isEmpty {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                            Text("\(toolName) --help returned nothing").font(.caption).foregroundStyle(.orange)
                        } else {
                            Button("Scan --help now") { triggerHelpScan(command: toolName) }
                                .font(.system(size: 11))
                        }
                        Spacer()
                        if scanDone && !scannedHelp.isEmpty {
                            Button { triggerHelpScan(command: toolName) } label: {
                                Label("Re-scan", systemImage: "arrow.clockwise")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                    // Live scan log — shows each command being scanned
                    let logLines = TerminalPackageManager.shared.scanLog
                    if !logLines.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(Array(logLines.enumerated()), id: \.offset) { i, line in
                                        HStack(spacing: 4) {
                                            Text(line)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(
                                                    line.hasPrefix("✓") ? Color.green.opacity(0.85) :
                                                    line.hasPrefix("✗") ? Color.orange.opacity(0.7) :
                                                    Color.secondary
                                                )
                                        }
                                        .id(i)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                            }
                            .frame(height: isScanning ? 90 : 70)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.4),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2)))
                            .onChange(of: logLines.count) { _, _ in
                                withAnimation { proxy.scrollTo(logLines.count - 1, anchor: .bottom) }
                            }
                        }
                    }
                }
            }

            Divider()

            // ── Entry command (auto-detected subcommand per app) ──────────────
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Label("Entry command for \(appKey.capitalized)", systemImage: "arrow.turn.down.right")
                        .font(.system(size: 12, weight: .semibold))
                    Text("(optional)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                TextField("e.g. memo notes  or  memo rem  (leave blank to use binary name as-is)", text: $appSubcommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                // Auto-detect hint from scan
                if appSubcommand.isEmpty && scanDone && !toolName.isEmpty {
                    let detected = TerminalPackageManager.shared.autoDetectSubcommand(
                        toolName: toolName, appKey: appKey, appLabel: appKey.capitalized)
                    if !detected.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles").foregroundStyle(.blue).font(.caption)
                            Text("Auto-detected: \(detected)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Button("Use this") { appSubcommand = detected }
                                .font(.system(size: 11))
                                .buttonStyle(.borderless)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                Text("When the same CLI handles multiple apps (e.g. memo notes vs memo rem), set the right entry here.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            // ── Context flag (flag-based multi-app CLIs like ekctl) ───────────
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Label("Context flag for \(appKey.capitalized)", systemImage: "flag")
                        .font(.system(size: 12, weight: .semibold))
                    Text("(optional)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                TextField("e.g. --reminders  or  --calendars  (leave blank if not needed)", text: $appContextFlag)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                // Auto-detect hint from scan
                if appContextFlag.isEmpty && scanDone && !toolName.isEmpty {
                    let detectedFlag = TerminalPackageManager.shared.autoDetectContextFlag(
                        toolName: toolName, appKey: appKey, appLabel: appKey.capitalized)
                    if !detectedFlag.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "flag.fill").foregroundStyle(.orange).font(.caption)
                            Text("Auto-detected flag: \(detectedFlag)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Button("Use this") { appContextFlag = detectedFlag }
                                .font(.system(size: 11))
                                .buttonStyle(.borderless)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Text("For CLIs that use flags to select context, e.g. `ekctl list --reminders` vs `ekctl list --calendars`.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Divider()

            // ── Capability hints ──────────────────────────────────────────────
            Group {
                labeledField("What can it do? (comma-separated, helps AI pick right tool)",
                             "e.g. list notes, add reminder, search files",
                             $capabilitiesText)
                labeledField("Example commands (one per line, optional)",
                             "memo notes add \"Buy milk\"\nmemo rem list",
                             $examplesText, multiline: true)
                Toggle("Destructive — AI will confirm before running delete/overwrite", isOn: $isDestructive)
                    .font(.system(size: 12))
            }
        }
    }

    // ── AI Prompt content ─────────────────────────────────────────────────────
    private var promptContent: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Name
            VStack(alignment: .leading, spacing: 5) {
                Label("Prompt name", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                TextField("e.g. notes-assistant, summarizer", text: $promptName)
                    .textFieldStyle(.roundedBorder)
            }

            // Template editor
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    Label("System prompt template", systemImage: "text.quote")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    // Variable insertion chips
                    ForEach(PromptVariable.all) { v in
                        Button(v.label) { promptTemplate += v.tag }
                            .font(.system(size: 10, design: .monospaced))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help(v.description)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if promptTemplate.isEmpty {
                        Text("You are a smart \(appKey.capitalized) assistant inside ILauncher.\nToday is {{date}}.\nAnswer this: {{query}}")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $promptTemplate)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("Click a variable chip above to insert it. The AI replaces each {{var}} before sending the prompt.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Divider()

            // Cache
            VStack(alignment: .leading, spacing: 6) {
                Label("Cache identical responses", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 10) {
                    Picker("Cache TTL", selection: $cacheTTLMinutes) {
                        ForEach(CacheTTLOption.options) { opt in
                            Text(opt.label).tag(opt.minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)
                    if cacheTTLMinutes > 0 {
                        Text("Same question → reuse cached answer for \(CacheTTLOption.label(for: cacheTTLMinutes))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text("Useful for deterministic prompts (e.g. formatting, summarizing). Leave off for live queries.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Divider()

            // How it works
            VStack(alignment: .leading, spacing: 4) {
                Label("How it works", systemImage: "info.circle")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("When you ask anything in the \(appKey.capitalized) panel, this template becomes the AI's system prompt — replacing the generic one. The AI answers directly using its knowledge, without running any shell commands. You can combine an AI Prompt with CLI/Script extensions: the AI will use your prompt as its persona and still call your scripts as tools when needed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ── Inline install panel ──────────────────────────────────────────────────
    private var installPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
                Text("\(toolName) is not installed").font(.system(size: 12, weight: .medium))
                Spacer()
                Button(showInstall ? "Hide" : "Install…") { showInstall.toggle() }
                    .font(.system(size: 11))
            }

            if showInstall {
                VStack(alignment: .leading, spacing: 8) {
                    // Method picker
                    Picker("Method", selection: $installMethod) {
                        ForEach(availableInstallMethods, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack(spacing: 8) {
                        TextField(installMethod.placeholder, text: $installPkg)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .onAppear { if installPkg.isEmpty { installPkg = toolName } }

                        Button(action: runInlineInstall) {
                            if isInstalling { ProgressView().scaleEffect(0.7) }
                            else { Label("Install", systemImage: "arrow.down.circle") }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isInstalling || installPkg.isEmpty)
                    }

                    if !installLog.isEmpty {
                        ScrollView {
                            Text(installLog)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 60)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                    }

                    if installDone {
                        Label("Installed! Re-scanning help…", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2)))
            }
        }
    }

    // MARK: - Custom Script content

    private var scriptContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a custom script for \(appKey.capitalized). Saved scripts can appear directly as app pills in the dock.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            labeledField("Script name (no spaces, used as the command)", "e.g. open-in-wtf", $scriptName)

            VStack(alignment: .leading, spacing: 6) {
                Label("Language", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $scriptLang) {
                    ForEach(AppScriptLanguage.allCases) { lang in
                        Label(lang.rawValue, systemImage: lang.systemImage).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: scriptLang) { _, lang in
                    // Replace template when user switches language and hasn't typed anything custom
                    let currentIsDefault = AppScriptLanguage.allCases.contains(where: {
                        scriptCode.trimmingCharacters(in: .whitespacesAndNewlines) ==
                        $0.starterTemplate(appKey: appKey, scriptName: scriptName).trimmingCharacters(in: .whitespacesAndNewlines)
                    })
                    if scriptCode.isEmpty || currentIsDefault {
                        scriptCode = lang.starterTemplate(appKey: appKey, scriptName: scriptName)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Script", systemImage: "doc.text").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    // Context hint changes by language
                    Group {
                        switch scriptLang {
                        case .bash:
                            Text("$FILE = file path  ·  $QUERY = user query")
                        case .python:
                            Text("sys.argv[1] = file path  ·  sys.argv[2] = query")
                        case .jxa:
                            Text("argv[0] = file path  ·  argv[1] = query")
                        case .applescript:
                            Text("item 1 of argv = file path")
                        case .lua:
                            Text("arg[1] = file path  ·  arg[2] = query  (via hs)")
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                TextEditor(text: $scriptCode)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    .overlay(
                        Group {
                            if scriptCode.isEmpty {
                                Text(scriptLang.shebang + "\n# Write your script here")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary.opacity(0.5))
                                    .padding(.horizontal, 5).padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }, alignment: .topLeading)
            }

            labeledField("What does this script do? (shown to AI as its capability)",
                         "e.g. Opens the selected file in WTF terminal file manager",
                         $scriptDesc)
        }
        .onAppear {
            if scriptCode.isEmpty {
                scriptCode = scriptLang.starterTemplate(appKey: appKey, scriptName: scriptName)
            }
        }
    }

    // MARK: - Script File content

    private var fileContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Script path", systemImage: "doc.badge.gearshape").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    TextField("/path/to/your-script.sh", text: $scriptFilePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Browse…") { showFilePicker = true }
                        .controlSize(.small)
                }
                if !scriptFilePath.isEmpty {
                    let exists = FileManager.default.fileExists(atPath: scriptFilePath)
                    Label(exists ? "File found" : "File not found", systemImage: exists ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.caption).foregroundStyle(exists ? Color.green : Color.orange)
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    scriptFilePath = url.path
                    if scriptFileDesc.isEmpty { scriptFileDesc = url.deletingPathExtension().lastPathComponent }
                }
            }

            // Show detected language badge when a file is picked
            if !scriptFilePath.isEmpty {
                let detectedLang = inferLanguage(from: scriptFilePath)
                HStack(spacing: 6) {
                    Image(systemName: detectedLang.systemImage).font(.caption).foregroundStyle(.purple)
                    Text(detectedLang.rawValue).font(.caption).foregroundStyle(.purple)
                    Text("·").foregroundStyle(.secondary).font(.caption)
                    Text("Run as: \(detectedLang.runCommand(scriptPath: scriptFilePath))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            labeledField("What does this script do? (for AI context)",
                         "e.g. Opens selected file in WTF; accepts path as first argument",
                         $scriptFileDesc, multiline: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Supported formats").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(AppScriptLanguage.allCases) { lang in
                        HStack(spacing: 4) {
                            Image(systemName: lang.systemImage).font(.system(size: 10))
                            Text(".\(lang.fileExtension)").font(.system(size: 10, design: .monospaced))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                    }
                }
                Text("Script receives: arg[1] = file path  ·  arg[2] = user query")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func inferLanguage(from path: String) -> AppScriptLanguage {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "py":           return .python
        case "js":           return .jxa
        case "applescript", "scpt": return .applescript
        case "lua":          return .lua
        default:             return .bash
        }
    }

    // MARK: - Helpers

    private var isCLIInstalled: Bool {
        AppSettings.isToolInstalled(AppToolExtension(appKey: appKey, toolName: toolName, toolPath: toolPath))
    }

    private var canSave: Bool {
        switch mode {
        case .cli:    return !toolName.isEmpty && !isScanning
        case .script: return !scriptName.isEmpty && !scriptCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file:   return !scriptFilePath.isEmpty && FileManager.default.fileExists(atPath: scriptFilePath)
        case .prompt: return !promptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && !promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var previousShebang: String { scriptLang.shebang }

    private var availableInstallMethods: [ToolInstallMethod] {
        let fm = FileManager.default
        var list: [ToolInstallMethod] = []
        if ["/opt/homebrew/bin/brew","/usr/local/bin/brew"].contains(where: { fm.fileExists(atPath: $0) }) { list.append(.brew) }
        if ["/opt/homebrew/bin/npm","/usr/local/bin/npm"].contains(where: { fm.fileExists(atPath: $0) })  { list.append(.npm) }
        if ["/opt/homebrew/bin/pip3","/usr/local/bin/pip3","/usr/bin/pip3"].contains(where: { fm.fileExists(atPath: $0) }) { list.append(.pip) }
        if fm.fileExists(atPath: "\(NSHomeDirectory())/.cargo/bin/cargo")                                  { list.append(.cargo) }
        if ["/opt/homebrew/bin/go","/usr/local/go/bin/go"].contains(where: { fm.fileExists(atPath: $0) }) { list.append(.goInstall) }
        list += [.gitClone, .custom]
        return list
    }

    private func labeledField(_ label: String, _ placeholder: String, _ binding: Binding<String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if multiline {
                TextEditor(text: binding)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.15)))
            } else {
                TextField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }

    // MARK: - Install

    private func runInlineInstall() {
        guard !installPkg.isEmpty else { return }
        isInstalling = true
        installLog   = ""
        Task {
            let env = buildInstallEnv()
            let cmd = makeInstallCommand()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", cmd]
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            guard (try? p.run()) != nil else {
                await MainActor.run { installLog = "Failed to start process"; isInstalling = false }
                return
            }
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let ok  = p.terminationStatus == 0
            await MainActor.run {
                installLog   = out
                isInstalling = false
                installDone  = ok
                if ok {
                    showInstall = false
                    Task {
                        await BinaryWatcherService.shared.scanNow(skipHelpScan: true)
                        triggerHelpScan(command: toolName)
                    }
                }
            }
        }
    }

    private func makeInstallCommand() -> String {
        let pkg = installPkg.trimmingCharacters(in: .whitespacesAndNewlines)
        let brew = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
        switch installMethod {
        case .brew:      return "\(brew) install \(pkg)"
        case .npm:       return "npm install -g \(pkg)"
        case .pip:       return "pip3 install \(pkg)"
        case .cargo:     return "\(NSHomeDirectory())/.cargo/bin/cargo install \(pkg)"
        case .goInstall: return "go install \(pkg)"
        case .gitClone:  return "git clone \"\(pkg)\""
        case .custom:    return pkg
        }
    }

    private func buildInstallEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extras = ["/opt/homebrew/bin","/usr/local/bin","/usr/bin","/bin",
                      "\(NSHomeDirectory())/.cargo/bin","\(NSHomeDirectory())/go/bin",
                      "\(NSHomeDirectory())/.local/bin","/usr/local/go/bin"]
        env["PATH"] = (extras + (env["PATH"] ?? "").components(separatedBy: ":")).joined(separator: ":")
        return env
    }

    // MARK: - Save

    private func save() {
        let ext: AppToolExtension
        switch mode {
        case .cli:
            let helpBase = scannedHelp.isEmpty
                ? "Use \(toolName) for \(appKey) tasks."
                : "Tool: \(toolName)\n--help output:\n\(String(scannedHelp.prefix(1200)))"
            let finalHint = aiHint.isEmpty ? helpBase : helpBase + "\n\nExtra: \(aiHint)"
            let path = toolPath.isEmpty
                ? (pkgMgr.packages.first(where: { $0.command == toolName })?.installedPath ?? "")
                : toolPath
            let caps  = capabilitiesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let exmps = examplesText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let profile = AppToolProfile(capabilities: caps, exampleCommands: exmps, fileTypes: [], isDestructive: isDestructive)
            ext = AppToolExtension(appKey: appKey, toolName: toolName, toolPath: path,
                                   aiHint: finalHint, profile: profile, kind: .cli,
                                   appSubcommand: appSubcommand.trimmingCharacters(in: .whitespaces),
                                   appContextFlag: appContextFlag.trimmingCharacters(in: .whitespaces))

        case .script:
            let name = scriptName.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "-")
            let savedPath = settings.saveScript(appKey: appKey, name: name,
                                                language: scriptLang, code: scriptCode) ?? ""
            let runCmd = scriptLang.runCommand(scriptPath: savedPath)
            let hint   = "Script: \(name)\nLanguage: \(scriptLang.rawValue)\nRun as: \(runCmd)\nDescription: \(scriptDesc)"
            ext = AppToolExtension(appKey: appKey, toolName: name, toolPath: savedPath,
                                   aiHint: hint, profile: AppToolProfile(),
                                   kind: .script, scriptLanguage: scriptLang, scriptCode: scriptCode)

        case .file:
            let name = URL(fileURLWithPath: scriptFilePath).deletingPathExtension().lastPathComponent
            let lang: AppScriptLanguage = inferLanguage(from: scriptFilePath)
            let runCmd = lang.runCommand(scriptPath: scriptFilePath)
            let hint   = "Script file: \(scriptFilePath)\nRun as: \(runCmd)\nDescription: \(scriptFileDesc)"
            ext = AppToolExtension(appKey: appKey, toolName: name, toolPath: scriptFilePath,
                                   aiHint: hint, profile: AppToolProfile(),
                                   kind: .script, scriptLanguage: lang, scriptCode: "")

        case .prompt:
            let name = promptName.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "-")
            // Save template to disk so it can be imported/shared
            let savedPath = PromptRunner.shared.savePromptFile(
                appKey: appKey, name: name, template: promptTemplate) ?? ""
            // Clear old cache when template is updated
            if let e = existing { PromptRunner.shared.clearCache(for: e) }
            ext = AppToolExtension(appKey: appKey, toolName: name, toolPath: savedPath,
                                   aiHint: promptTemplate, profile: AppToolProfile(),
                                   kind: .prompt, promptTemplate: promptTemplate,
                                   cacheTTLMinutes: cacheTTLMinutes)
        }

        onSave(ext)
        dismiss()
    }

    // MARK: - Help scan

    private func triggerHelpScan(command: String) {
        guard !command.isEmpty else { return }
        isScanning = true; scanDone = false; scannedHelp = ""
        Task {
            let result = await TerminalPackageManager.shared.scanDeepHelp(for: command) ?? ""
            await MainActor.run {
                scannedHelp = result
                isScanning = false
                scanDone = true
                if let idx = TerminalPackageManager.shared.packages.firstIndex(where: { $0.command == command }) {
                    TerminalPackageManager.shared.packages[idx].helpText = result
                }
            }
        }
    }
}

struct AppShortcutEditSheet: View {
    let appKey: String
    let shortcut: AppShortcut?
    let onSave: (AppShortcut) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var iconName: String
    @State private var actionType: AppShortcut.ActionType
    @State private var actionValue: String
    @State private var placement: AppShortcut.Placement
    @State private var targetAppKeys: [String]
    @State private var fileTypeFilter: String        // comma-separated file extensions for File Actions
    @State private var triggerKeywordStr: String     // comma-separated trigger keywords
    @State private var installedApps: [(key: String, name: String, bundleId: String)] = []
    @State private var selectedTemplateID: String = ""
    @State private var templateFolderName: String = ""
    @State private var templateNoteFolderName: String = ""
    @State private var templateReminderDelayMinutes: String = "5"
    @State private var templateRecipientName: String = ""

    init(appKey: String, shortcut: AppShortcut?, onSave: @escaping (AppShortcut) -> Void) {
        self.appKey = appKey
        self.shortcut = shortcut
        self.onSave = onSave
        _name               = State(initialValue: shortcut?.name ?? "")
        _iconName           = State(initialValue: shortcut?.iconName ?? "bolt.fill")
        _actionType         = State(initialValue: shortcut?.actionType ?? .openURL)
        _actionValue        = State(initialValue: shortcut?.actionValue ?? "")
        _placement          = State(initialValue: shortcut?.placement ?? .quickActions)
        _targetAppKeys      = State(initialValue: shortcut?.targetAppKeys ?? [])
        _fileTypeFilter     = State(initialValue: shortcut?.fileTypes.joined(separator: ", ") ?? "")
        _triggerKeywordStr  = State(initialValue: shortcut?.triggerKeywords.joined(separator: ", ") ?? "")
    }

    // Whether the current action type accepts file/text context
    private var isScriptType: Bool {
        actionType == .shellCommand || actionType == .appleScript || actionType == .jxa
    }

    private struct ShortcutTemplate: Identifiable {
        let id: String
        let name: String
        let iconName: String
        let actionType: AppShortcut.ActionType
        let placement: AppShortcut.Placement
        let targetAppKeys: [String]
        let triggerKeywords: [String]
    }

    private var availableTemplates: [ShortcutTemplate] {
        switch appKey {
        case "notes":
            return [
                ShortcutTemplate(
                    id: "notes_save_link_bookmarks",
                    name: "Save Link to Bookmark Notes",
                    iconName: "bookmark",
                    actionType: .appleScript,
                    placement: .contextDock,
                    targetAppKeys: ["safari"],
                    triggerKeywords: ["bookmark", "save link", "save page"]
                ),
                ShortcutTemplate(
                    id: "notes_save_selection",
                    name: "Save Selection to Notes",
                    iconName: "note.text.badge.plus",
                    actionType: .appleScript,
                    placement: .contextDock,
                    targetAppKeys: [],
                    triggerKeywords: ["save note", "save this", "quick note"]
                )
            ]
        case "mail":
            return [
                ShortcutTemplate(
                    id: "mail_compose_link",
                    name: "Compose Mail with Link",
                    iconName: "envelope.badge",
                    actionType: .openURL,
                    placement: .contextDock,
                    targetAppKeys: ["safari"],
                    triggerKeywords: ["email link", "mail this page", "share by email"]
                ),
                ShortcutTemplate(
                    id: "mail_compose_selection",
                    name: "Compose Mail with Selection",
                    iconName: "envelope.open",
                    actionType: .openURL,
                    placement: .contextDock,
                    targetAppKeys: [],
                    triggerKeywords: ["email this", "send by mail"]
                )
            ]
        case "reminders":
            return [
                ShortcutTemplate(
                    id: "reminders_5_min",
                    name: "Remind Me in 5 Minutes",
                    iconName: "clock.badge",
                    actionType: .appleScript,
                    placement: .contextDock,
                    targetAppKeys: [],
                    triggerKeywords: ["remind later", "5 min", "5 minutes"]
                ),
                ShortcutTemplate(
                    id: "reminders_from_selection",
                    name: "Create Reminder from Selection",
                    iconName: "list.bullet.clipboard",
                    actionType: .appleScript,
                    placement: .contextDock,
                    targetAppKeys: [],
                    triggerKeywords: ["remind me", "create reminder", "later"]
                )
            ]
        case "messages":
            return [
                ShortcutTemplate(
                    id: "messages_share_page",
                    name: "Share Current Page via Messages",
                    iconName: "message.badge",
                    actionType: .openURL,
                    placement: .contextDock,
                    targetAppKeys: ["safari"],
                    triggerKeywords: ["message this page", "send page", "share page"]
                )
            ]
        case "finder":
            return [
                ShortcutTemplate(
                    id: "finder_reveal_file",
                    name: "Reveal Selected File in Finder",
                    iconName: "folder",
                    actionType: .shellCommand,
                    placement: .contextDock,
                    targetAppKeys: [],
                    triggerKeywords: ["reveal file", "show in finder"]
                ),
                ShortcutTemplate(
                    id: "finder_move_to_folder",
                    name: "Move Selected File to Folder",
                    iconName: "folder.badge.plus",
                    actionType: .shellCommand,
                    placement: .contextDock,
                    targetAppKeys: [],
                    triggerKeywords: ["move file", "move to folder", "organize file"]
                )
            ]
        default:
            return []
        }
    }

    private var selectedTemplate: ShortcutTemplate? {
        availableTemplates.first(where: { $0.id == selectedTemplateID })
    }

    private var selectedTemplateParameterLabels: [(key: String, label: String, placeholder: String)] {
        switch selectedTemplateID {
        case "notes_save_link_bookmarks", "notes_save_selection":
            return [("noteFolder", "Note Folder Name", "Bookmarks")]
        case "reminders_5_min":
            return [("delay", "Reminder Delay (minutes)", "5")]
        case "messages_share_page":
            return [("recipient", "Recipient / Handle", "Ruby")]
        case "finder_move_to_folder":
            return [("folder", "Folder Name", "Invoices")]
        default:
            return []
        }
    }

    private func renderedTemplateActionValue(for templateID: String) -> String {
        let safeNoteFolder = templateNoteFolderName.isEmpty ? "ILauncher" : templateNoteFolderName
        let safeFolderName = templateFolderName.isEmpty ? "Organized" : templateFolderName
        let safeDelay = Int(templateReminderDelayMinutes) ?? 5
        let safeRecipient = templateRecipientName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch templateID {
        case "notes_save_link_bookmarks":
            return """
            set noteURL to "$CURRENT_URL"
            if noteURL is "" then set noteURL to "$AX_SELECTED_TEXT"
            set noteTitle to "$WINDOW_TITLE"
            if noteTitle is "" then set noteTitle to noteURL
            if noteURL is "" then error "No current URL or selected text found."

            tell application "Notes"
                activate
                try
                    set targetFolder to folder "\(safeNoteFolder)" of default account
                on error
                    set targetFolder to make new folder at default account with properties {name:"\(safeNoteFolder)"}
                end try
                make new note at targetFolder with properties {name:noteTitle, body:noteTitle & return & noteURL}
            end tell
            """
        case "notes_save_selection":
            return """
            set noteBody to "$AX_SELECTED_TEXT"
            if noteBody is "" then set noteBody to "$CURRENT_URL"
            if noteBody is "" then error "No selected text or current URL found."

            tell application "Notes"
                activate
                try
                    set targetFolder to folder "\(safeNoteFolder)" of default account
                on error
                    set targetFolder to make new folder at default account with properties {name:"\(safeNoteFolder)"}
                end try
                make new note at targetFolder with properties {name:"Quick Save", body:noteBody}
            end tell
            """
        case "mail_compose_link":
            return "mailto:?subject=$WINDOW_TITLE&body=$CURRENT_URL"
        case "mail_compose_selection":
            return "mailto:?body=$AX_SELECTED_TEXT"
        case "reminders_5_min":
            return """
            set reminderText to "$AX_SELECTED_TEXT"
            if reminderText is "" then set reminderText to "$WINDOW_TITLE"
            if reminderText is "" then set reminderText to "$CURRENT_URL"
            if reminderText is "" then error "No selected text, title, or URL found."
            set dueDate to (current date) + (\(safeDelay) * minutes)

            tell application "Reminders"
                activate
                tell default list
                    make new reminder with properties {name:reminderText, remind me date:dueDate}
                end tell
            end tell
            """
        case "reminders_from_selection":
            return """
            set reminderText to "$AX_SELECTED_TEXT"
            if reminderText is "" then set reminderText to "$CURRENT_URL"
            if reminderText is "" then error "No selected text or URL found."

            tell application "Reminders"
                activate
                tell default list
                    make new reminder with properties {name:reminderText}
                end tell
            end tell
            """
        case "messages_share_page":
            return safeRecipient.isEmpty
                ? "sms:&body=$CURRENT_URL"
                : "sms:\(safeRecipient)&body=$CURRENT_URL"
        case "finder_reveal_file":
            return "if [ -n \"$1\" ]; then open -R \"$1\"; elif [ -n \"$CD_FILE\" ]; then open -R \"$CD_FILE\"; fi"
        case "finder_move_to_folder":
            return "if [ -n \"$1\" ]; then mkdir -p \"$(dirname \"$1\")/\(safeFolderName)\" && mv \"$1\" \"$(dirname \"$1\")/\(safeFolderName)/\"; elif [ -n \"$CD_FILE\" ]; then mkdir -p \"$(dirname \"$CD_FILE\")/\(safeFolderName)\" && mv \"$CD_FILE\" \"$(dirname \"$CD_FILE\")/\(safeFolderName)/\"; fi"
        default:
            return actionValue
        }
    }

    private func applySelectedTemplate() {
        guard let template = selectedTemplate else { return }
        name = template.name
        iconName = template.iconName
        actionType = template.actionType
        actionValue = renderedTemplateActionValue(for: template.id)
        placement = template.placement
        targetAppKeys = template.targetAppKeys
        triggerKeywordStr = template.triggerKeywords.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(shortcut == nil ? "Add Action" : "Edit Action")
                .font(.title2).bold()

            Form {
                TextField("Name (e.g. Center Window)", text: $name)

                SFSymbolPickerButton(selected: $iconName)

                if !availableTemplates.isEmpty {
                    Picker("Starter Template", selection: $selectedTemplateID) {
                        Text("Custom").tag("")
                        ForEach(availableTemplates) { template in
                            Text(template.name).tag(template.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Templates prefill common cross-app actions using live context like $CURRENT_URL, $AX_SELECTED_TEXT, and $WINDOW_TITLE.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !selectedTemplateParameterLabels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Template Parameters")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(selectedTemplateParameterLabels, id: \.key) { parameter in
                            switch parameter.key {
                            case "folder":
                                TextField(parameter.placeholder, text: $templateFolderName)
                            case "noteFolder":
                                TextField(parameter.placeholder, text: $templateNoteFolderName)
                            case "delay":
                                TextField(parameter.placeholder, text: $templateReminderDelayMinutes)
                            case "recipient":
                                TextField(parameter.placeholder, text: $templateRecipientName)
                            default:
                                EmptyView()
                            }
                        }
                    }
                }

                // SHOWS IN — segmented picker (mirrors Extensions layer picker)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show In").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        placementTab(.quickActions, icon: "magnifyingglass",    label: "Quick Actions")
                        placementTab(.contextDock,  icon: "rectangle.grid.1x2", label: "Context Dock")
                        placementTab(.both,         icon: "square.grid.2x2",    label: "Both")
                        placementTab(.fileActions,  icon: "doc.badge.gearshape",label: "File Actions")
                    }
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
                    Text(placementDescription).font(.caption2).foregroundStyle(.secondary)
                }

                // File Actions extra fields
                if placement == .fileActions {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File types (leave blank for all files)").font(.caption).foregroundStyle(.secondary)
                        TextField("pdf, jpg, png", text: $fileTypeFilter)
                            .textFieldStyle(.roundedBorder)
                        Text("Comma-separated extensions — this action appears when a matching file is selected.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Trigger keywords (optional)").font(.caption).foregroundStyle(.secondary)
                        TextField("compress, zip, archive", text: $triggerKeywordStr)
                            .textFieldStyle(.roundedBorder)
                        Text("Comma-separated — typing one of these in search also surfaces this action.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                if placement != .fileActions {
                    crossAppPicker
                }

                Picker("Action Type", selection: $actionType) {
                    Text("Shortcut").tag(AppShortcut.ActionType.shortcut)
                    Text("Open URL / Deep Link").tag(AppShortcut.ActionType.openURL)
                    Text("Open File / App").tag(AppShortcut.ActionType.openFile)
                    Text("Shell Command").tag(AppShortcut.ActionType.shellCommand)
                    Text("AppleScript").tag(AppShortcut.ActionType.appleScript)
                    Text("JXA (JavaScript for Automation)").tag(AppShortcut.ActionType.jxa)
                    Text("Script File (.sh/.py/.js/.rb)").tag(AppShortcut.ActionType.scriptFile)
                }
                .pickerStyle(.menu)

                switch actionType {
                case .openURL:
                    TextField("URL (e.g. ical:// or mailto:)", text: $actionValue)
                case .openFile:
                    TextField("App/File path (e.g. /Applications/Calendar.app)", text: $actionValue)
                case .shellCommand:
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $actionValue)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100)
                            .border(.separator)
                        contextVarHints
                    }
                case .appleScript:
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $actionValue)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100)
                            .border(.separator)
                        contextVarHints
                    }
                case .jxa:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("JavaScript for Automation — runs via osascript -l JavaScript")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $actionValue)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                            .border(.separator)
                        contextVarHints
                    }
                case .scriptFile:
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("~/Scripts/my-script.sh", text: $actionValue)
                            Button("Choose…") {
                                let panel = NSOpenPanel()
                                panel.allowsOtherFileTypes = true
                                panel.canChooseDirectories = false
                                panel.begin { r in
                                    if r == .OK, let url = panel.url { actionValue = url.path }
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                        Text("Script receives context as $CD_URL, $CD_SELECTED_TEXT, $CD_FILE, $CD_APP_NAME, $CD_WINDOW_TITLE, $CD_CLIPBOARD, $CD_BUNDLE_ID")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .menuItem:
                    TextField("File > New Tab", text: $actionValue)
                case .shortcut:
                    ShortcutPickerInline(selectedName: $actionValue)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard !name.isEmpty, !actionValue.isEmpty else { return }
                    let parsedFileTypes = fileTypeFilter
                        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                    let parsedKeywords = triggerKeywordStr
                        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                    let sc = AppShortcut(name: name, iconName: iconName,
                                        actionType: actionType, actionValue: actionValue,
                                        appKey: appKey, placement: placement,
                                        targetAppKeys: targetAppKeys,
                                        fileTypes: parsedFileTypes,
                                        triggerKeywords: parsedKeywords)
                    onSave(sc)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || actionValue.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            // Load all registered apps for the cross-app picker (exclude current appKey)
            let settings = AppSettings.shared
            let builtIn: [(key: String, name: String, bundleId: String)] = [
                ("safari",         "Safari",          "com.apple.Safari"),
                ("systemsettings", "System Settings", "com.apple.systempreferences"),
                ("calendar",       "Calendar",        "com.apple.iCal"),
                ("reminders",      "Reminders",       "com.apple.reminders"),
                ("notes",          "Notes",           "com.apple.Notes"),
                ("mail",           "Mail",            "com.apple.mail"),
                ("photos",         "Photos",          "com.apple.Photos"),
                ("messages",       "Messages",        "com.apple.MobileSMS"),
                ("contacts",       "Contacts",        "com.apple.AddressBook"),
                ("finder",         "Finder",          "com.apple.finder"),
            ]
            let custom = settings.customAppEntries.map { entry in
                (key: entry.key, name: entry.label, bundleId: entry.key)
            }
            installedApps = (builtIn + custom).filter { $0.key != appKey }
        }
        .onChange(of: selectedTemplateID) { _, newValue in
            guard !newValue.isEmpty else { return }
            switch newValue {
            case "notes_save_link_bookmarks":
                templateNoteFolderName = "Bookmarks"
            case "notes_save_selection":
                templateNoteFolderName = "ILauncher"
            case "reminders_5_min":
                templateReminderDelayMinutes = "5"
            case "messages_share_page":
                templateRecipientName = ""
            case "finder_move_to_folder":
                templateFolderName = "Organized"
            default:
                break
            }
            applySelectedTemplate()
        }
        .onChange(of: templateFolderName) { _, _ in if !selectedTemplateID.isEmpty { applySelectedTemplate() } }
        .onChange(of: templateNoteFolderName) { _, _ in if !selectedTemplateID.isEmpty { applySelectedTemplate() } }
        .onChange(of: templateReminderDelayMinutes) { _, _ in if !selectedTemplateID.isEmpty { applySelectedTemplate() } }
        .onChange(of: templateRecipientName) { _, _ in if !selectedTemplateID.isEmpty { applySelectedTemplate() } }
    }

    @ViewBuilder
    private func placementTab(_ p: AppShortcut.Placement, icon: String, label: String) -> some View {
        Button { placement = p } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(.system(size: 9)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(placement == p ? Color.accentColor.opacity(0.18) : Color.clear)
            .foregroundStyle(placement == p ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var placementDescription: String {
        switch placement {
        case .quickActions:  return "Appears in the search dock when you type the app name."
        case .contextDock:   return "Pill in the L2 Context Dock when this app is frontmost."
        case .both:          return "Shows in both Quick Actions search and Context Dock."
        case .fileActions:   return "Action button appears when a matching file is selected in search."
        }
    }

    @ViewBuilder
    private var crossAppPicker: some View {
        if !installedApps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Also show for apps")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Share this action with other apps in addition to \"\(appKey)\"")
                    .font(.caption2).foregroundStyle(.tertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(installedApps, id: \.key) { app in
                            crossAppChip(app)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func crossAppChip(_ app: (key: String, name: String, bundleId: String)) -> some View {
        let selected = targetAppKeys.contains(app.key)
        Button {
            if selected { targetAppKeys.removeAll { $0 == app.key } }
            else { targetAppKeys.append(app.key) }
        } label: {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor).font(.caption2)
                }
                Text(app.name).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Chip row showing available context variables for shell/AppleScript actions
    @ViewBuilder
    private var contextVarHints: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Available variables — click to insert:")
                .font(.caption2).foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(contextVars, id: \.0) { variable, desc in
                        Button {
                            actionValue += variable
                        } label: {
                            HStack(spacing: 3) {
                                Text(variable)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                Text("·")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Text(desc)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var contextVars: [(String, String)] {
        switch actionType {
        case .jxa:
            return [
                ("argv[0]",  "1st selected file path"),
                ("argv[1]",  "query / search term"),
                ("argv[2]",  "selected text"),
            ]
        case .appleScript:
            return [
                ("$1",                "1st selected file path"),
                ("$2",                "2nd selected file path"),
                ("$SELECTED_TEXT",    "selected text in the app used before ILauncher"),
                ("$SELECTED_FILES",   "all selected files, space-separated"),
                ("$FRONTMOST_APP",    "name of the app active before ILauncher (e.g. \"Finder\")"),
                ("$FRONTMOST_BUNDLE", "bundle ID of that app (e.g. \"com.apple.finder\")"),
                ("$CURRENT_URL",      "URL currently open in the frontmost browser window (AX-read)"),
                ("$WINDOW_TITLE",     "title of the frontmost window (AX-read)"),
                ("$AX_SELECTED_TEXT", "selected text read via Accessibility API (more reliable)"),
                ("$CD_FILE",          "selected file path passed to script-file actions"),
                ("$CD_URL",           "current URL env var used by script-file actions"),
            ]
        default:
            return [
                ("$1",                "1st selected file"),
                ("$2",                "2nd selected file"),
                ("$SELECTED_TEXT",    "text selected in the app you used before opening ILauncher"),
                ("$SELECTED_FILES",   "all selected files (space-separated)"),
                ("$SELECTED_FILE",    "first selected file (env var)"),
                ("$FRONTMOST_APP",    "name of the app that was active before ILauncher opened"),
                ("$FRONTMOST_BUNDLE", "bundle ID of that app (e.g. \"com.apple.Terminal\")"),
                ("$CURRENT_URL",      "URL currently open in the frontmost browser (AX-read, no script needed)"),
                ("$WINDOW_TITLE",     "title of the frontmost window (AX-read)"),
                ("$AX_SELECTED_TEXT", "selected text via Accessibility API (works in more apps than clipboard)"),
                ("$CD_FILE",          "selected file path used in script-file env vars"),
                ("$CD_URL",           "current URL used in script-file env vars"),
                ("$CD_SELECTED_TEXT", "selected text used in script-file env vars"),
            ]
        }
    }
}

// MARK: - Permissions Settings Tab
struct PermissionsSettingsView: View {
    @State private var hasAccessibilityPermission = false
    @State private var isTestingAutomation = false
    @State private var automationTestMessage: String? = nil
    
    @State private var commandInput: String = ""
    @State private var commandOutput: String = ""
    @State private var isRunningCommand: Bool = false
    @State private var recentCommands: [String] = []
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                permissionHero
                permissionCapabilityGrid

                Form {
                    SystemPermissionsSection()
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity)
            }
            .padding(30)
        }
        .onAppear {
            checkPermissions()
        }
    }

    private var permissionHero: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill((hasAccessibilityPermission ? Color.green : Color.orange).opacity(0.16))
                    .frame(width: 72, height: 72)
                Image(systemName: hasAccessibilityPermission ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(hasAccessibilityPermission ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(hasAccessibilityPermission ? "Core permissions are ready" : "Core permission needed")
                        .font(.title3.bold())
                    statusPill(hasAccessibilityPermission ? "Authorized" : "Action required", color: hasAccessibilityPermission ? .green : .orange)
                }
                Text("Context-Dock is more than a launcher. It reads frontmost-app context, menu caches, selected text/files, app data, and safe automation routes so AI Assistant, Context Dock Chat, and Selection Scope can act with the correct boundary.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Open System Settings") { openAccessibilitySettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Check Again") { checkPermissions() }
                        .buttonStyle(.bordered)
                    Text("Spotlight and Raycast mostly launch or search. Context-Dock needs explicit macOS grants because it can understand and act inside apps.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    private var permissionCapabilityGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            permissionCapabilityCard(
                icon: "accessibility",
                title: "Accessibility",
                detail: "Hotkey launch, frontmost app identity, selected text/files, menu cache, and menu-click actions.",
                color: hasAccessibilityPermission ? .green : .orange
            )
            permissionCapabilityCard(
                icon: "rectangle.inset.filled.and.person.filled",
                title: "Screen context",
                detail: "Window previews and visual grounding when an app has no API, MCP, CLI, or adapter route.",
                color: .blue
            )
            permissionCapabilityCard(
                icon: "calendar.badge.clock",
                title: "Apple data",
                detail: "Calendar, Reminders, Contacts, Photos, Notes, Mail, and Messages answers through native stores where possible.",
                color: .purple
            )
            permissionCapabilityCard(
                icon: "applescript",
                title: "Automation",
                detail: "Approved AppleScript/menu actions for app-scoped workflows. Write/send/move actions still require approval.",
                color: .teal
            )
        }
    }

    private func permissionCapabilityCard(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05))
        )
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
    
    func checkPermissions() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }
    
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func triggerAutomationPrompt() {
        isTestingAutomation = true
        automationTestMessage = nil

        func run(script: String) -> String? {
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                _ = appleScript.executeAndReturnError(&error)
                if let error {
                    return "AppleScript error: \(error)"
                } else {
                    return nil
                }
            } else {
                return "Failed to create AppleScript"
            }
        }

        func launch(appName: String) {
            NSWorkspace.shared.launchApplication(appName)
        }

        func containsMinus600(_ message: String) -> Bool {
            return message.contains("-600") || message.localizedCaseInsensitiveContains("Application isn’t running") || message.localizedCaseInsensitiveContains("Application isn't running")
        }

        Task.detached(priority: .utility) {
            // 1) Try System Events first (commonly available)
            let systemEventsScript = """
            tell application \"System Events\"
                count of processes
            end tell
            """

            let result: String
            if let sysErr = run(script: systemEventsScript) {
                // 2) Try Shortcuts: launch, wait, then ask for list of shortcuts
                launch(appName: "Shortcuts")
                try? await Task.sleep(nanoseconds: 700_000_000)
                let shortcutsScript = """
                tell application \"Shortcuts\"
                    get name of every shortcut
                end tell
                """
                if let scErr = run(script: shortcutsScript) {
                    if containsMinus600(scErr) {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        if let scErrRetry = run(script: shortcutsScript) {
                            // 3) Fallback: Terminal launch + no-op, with retry on -600
                            launch(appName: "Terminal")
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            let terminalScript = """
                            tell application \"Terminal\"
                                do script \"echo automation-test\"
                            end tell
                            """
                            if let termErr = run(script: terminalScript) {
                                if containsMinus600(termErr) {
                                    try? await Task.sleep(nanoseconds: 700_000_000)
                                    if let termErrRetry = run(script: terminalScript) {
                                        result = termErrRetry
                                    } else {
                                        result = "Automation request sent to Terminal. If prompted, approve access and then check System Settings > Privacy & Security > Automation."
                                    }
                                } else {
                                    result = termErr
                                }
                            } else {
                                result = "Automation request sent to Terminal. If prompted, approve access and then check System Settings > Privacy & Security > Automation."
                            }
                        } else {
                            result = "Automation request sent to Shortcuts. If prompted, approve access and then check System Settings > Privacy & Security > Automation."
                        }
                    } else {
                        result = scErr
                    }
                } else {
                    result = "Automation request sent to Shortcuts. If prompted, approve access and then check System Settings > Privacy & Security > Automation."
                }
            } else {
                result = "Automation request sent to System Events. If prompted, approve access and then check System Settings > Privacy & Security > Automation."
            }

            let finalResult = result
            await MainActor.run {
                automationTestMessage = finalResult
                isTestingAutomation = false
            }
        }
    }
    
    func runCommand() {
        let cmd = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }

        isRunningCommand = true
        commandOutput = ""

        // Keep a short history
        if recentCommands.last != cmd {
            recentCommands.append(cmd)
            if recentCommands.count > 20 { recentCommands.removeFirst(recentCommands.count - 20) }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", cmd]

            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.commandOutput = "Failed to start process: \(error.localizedDescription)"
                    self.isRunningCommand = false
                }
                return
            }

            process.waitUntilExit()

            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdoutStr = String(data: outData, encoding: .utf8) ?? ""
            let stderrStr = String(data: errData, encoding: .utf8) ?? ""
            let status = process.terminationStatus

            DispatchQueue.main.async {
                var combined = ""
                if !stdoutStr.isEmpty { combined += stdoutStr }
                if !stderrStr.isEmpty {
                    if !combined.isEmpty { combined += "\n" }
                    combined += stderrStr
                }
                combined += "\n(exit status: \(status))"
                self.commandOutput = combined
                self.isRunningCommand = false
            }
        }
    }
}

// MARK: - Shortcut Picker View
struct ShortcutPickerView: View {
    @Binding var selectedShortcut: String
    @State private var availableShortcuts: [String] = []
    @State private var isLoadingShortcuts = false
    @State private var loadError: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isLoadingShortcuts {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading shortcuts...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = loadError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if availableShortcuts.isEmpty {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text("No shortcuts found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(action: loadShortcuts) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingShortcuts)
            }
            
            if !availableShortcuts.isEmpty {
                Picker("Shortcut", selection: $selectedShortcut) {
                    Text("Select a shortcut").tag("")
                    ForEach(availableShortcuts, id: \.self) { shortcut in
                        HStack {
                            Image(systemName: "bolt.fill")
                            Text(shortcut)
                        }
                        .tag(shortcut)
                    }
                }
                .pickerStyle(.menu)
                
                if !selectedShortcut.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Using shortcut: \(selectedShortcut)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To create a shortcut:")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1. Open the Shortcuts app")
                        Text("2. Create a new shortcut")
                        Text("3. Add 'Ask for Input' and 'Text' actions")
                        Text("4. Return here and click 'Refresh'")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.gray.opacity(0.06))
                .cornerRadius(6)
            }
        }
        .onAppear {
            loadShortcuts()
        }
    }
    
    private func loadShortcuts() {
        isLoadingShortcuts = true
        loadError = nil
        
        Task {
            do {
                let query = ShortcutsLinkQuery()
                let shortcuts = try query.shortcuts()
                
                await MainActor.run {
                    availableShortcuts = shortcuts.map { $0.name }
                    isLoadingShortcuts = false
                    
                    if shortcuts.isEmpty {
                        loadError = "No shortcuts found in Shortcuts app"
                    }
                }
            } catch {
                await MainActor.run {
                    loadError = "Failed to load shortcuts: \(error.localizedDescription)"
                    isLoadingShortcuts = false
                }
            }
        }
    }
}
// MARK: - Notification Names
// MARK: - Launch at Login Toggle
struct LaunchAtLoginToggle: View {
    @StateObject private var launchHelper = LaunchAtLoginHelper.shared

    var body: some View {
        if #available(macOS 13.0, *) {
            HStack(alignment: .center) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launch at Login")
                        .font(.headline)
                    Text("Start ILauncher automatically when you log in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { launchHelper.isEnabled },
                    set: { launchHelper.setEnabled($0) }
                ))
                .toggleStyle(.switch)
            }
        } else {
            HStack(alignment: .center) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launch at Login")
                        .font(.headline)
                    Text("Requires macOS 13 or later")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: .constant(false))
                    .toggleStyle(.switch)
                    .disabled(true)
                    .opacity(0.5)
            }
        }
    }
}


// MARK: - FileDocument for App Profile JSON export
struct AppProfileJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}


#Preview {
    SettingsView()
}


// MARK: - Context Dock App Detail (adapter actions + starred menu items combined)

private struct ContextDockAppDetailView: View {
    let bundleId: String
    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showAddActionSheet = false
    @State private var editingAction: AdapterAction? = nil

    private var adapter: AppAdapter? {
        adapterManager.adapters.first { $0.bundleId == bundleId }
    }

    private var starredItems: [String] {
        Array(settings.favouriteMenuPills(for: bundleId)).sorted()
    }

    private var appName: String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            return app.localizedName ?? bundleId
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleId
    }

    private var appIcon: NSImage? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            return app.icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private var isBuiltInWithoutOverride: Bool {
        guard let adapter else { return false }
        return adapter.isBuiltIn && adapter.sourceFileURL == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // App header
                HStack(spacing: 12) {
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 40, height: 40)
                            .cornerRadius(9)
                    } else {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 40, height: 40)
                            .overlay(Image(systemName: "app.fill").foregroundStyle(Color.accentColor))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appName)
                            .font(.system(size: 15, weight: .semibold))
                        Text(bundleId)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Adapter controls (enable toggle + edit JSON) if adapter exists
                    if let adp = adapter {
                        if isBuiltInWithoutOverride {
                            Button {
                                editingAction = nil
                                showAddActionSheet = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 11))
                                    Text("Customize")
                                        .font(.system(size: 11))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Create a user override for this built-in adapter")
                        }
                        if let fileURL = adp.sourceFileURL {
                            Button {
                                NSWorkspace.shared.open(fileURL)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "pencil").font(.system(size: 11))
                                    Text("Edit JSON").font(.system(size: 11))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Toggle("Adapter", isOn: Binding(
                            get: { adp.isEnabled },
                            set: { adapterManager.setEnabled($0, for: adp.bundleId) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                .padding(16)

                Divider()

                // MARK: Adapter Actions section
                if let adp = adapter, !adp.visibleActions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.accentColor)
                            Text("Adapter Actions")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(adp.visibleActions.count)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Button {
                                editingAction = nil
                                showAddActionSheet = true
                            } label: {
                                Label("Add Action", systemImage: "plus")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 8)

                        ForEach(adp.visibleActions) { action in
                            AdapterActionRowView(action: action)
                                .contextMenu {
                                    Button {
                                        editingAction = action
                                        showAddActionSheet = true
                                    } label: {
                                        Label("Edit Action", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        Task {
                                            await adapterManager.deleteAction(id: action.id, from: bundleId)
                                        }
                                    } label: {
                                        Label("Delete Action", systemImage: "trash")
                                    }
                                }
                            if action.id != adp.visibleActions.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }

                        if adp.isBuiltIn && adp.sourceFileURL == nil {
                            Divider().padding(.top, 8)
                            HStack(spacing: 8) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.accentColor)
                                Text("Built-in adapter. Add, edit, or delete actions here to create a user override you can keep customizing.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        } else if !adp.isBuiltIn {
                            Divider().padding(.top, 8)
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text("User adapter — edit the JSON file to modify actions.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }

                    Divider().padding(.top, 4)
                }

                // MARK: Starred Menu Items section
                if !starredItems.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow)
                            Text("Starred Menu Items")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(starredItems.count)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 8)

                        ForEach(starredItems, id: \.self) { name in
                            HStack(spacing: 10) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.yellow)
                                    .frame(width: 20)
                                Text(name)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    settings.toggleFavouriteMenuPill(name, for: bundleId)
                                } label: {
                                    Image(systemName: "star.slash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove from Favourites")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            if name != starredItems.last {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                }

                // Empty state — no adapter and no starred items
                if adapter == nil && starredItems.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No context dock items")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("Add an adapter file or star menu items in the context dock to see them here.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 260)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }

                Spacer(minLength: 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showAddActionSheet) {
            AdapterActionEditorSheet(
                bundleId: bundleId,
                existing: editingAction
            ) {
                showAddActionSheet = false
                editingAction = nil
            }
        }
    }
}

// MARK: - Favourite Menus sidebar section (kept for reference, no longer used in main panel)

private struct FavouriteMenusSidebarSection: View {
    @Binding var showFavMenus: Bool
    @Binding var selectedFavBundleId: String?
    let onSelect: () -> Void

    @ObservedObject private var settings = AppSettings.shared

    /// Apps that have at least one favourited pill — sorted by name.
    private var favApps: [(bundleId: String, appName: String, icon: NSImage?, count: Int)] {
        let dict = settings.allFavouriteMenuPills()
        return dict
            .filter { !$0.value.isEmpty }
            .map { bundleId, names in
                let appName = resolvedName(bundleId: bundleId)
                let icon    = resolvedIcon(bundleId: bundleId)
                return (bundleId: bundleId, appName: appName, icon: icon, count: names.count)
            }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            HStack(spacing: 4) {
                Text("Favourite Menus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer()
                Text("\(favApps.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if favApps.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "star.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("Right-click any menu pill in the dock to star it")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            } else {
                ForEach(favApps, id: \.bundleId) { app in
                    let isSelected = selectedFavBundleId == app.bundleId
                    Button {
                        selectedFavBundleId = app.bundleId
                        showFavMenus = true
                        onSelect()
                    } label: {
                        HStack(spacing: 8) {
                            // App icon
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                    .cornerRadius(4)
                            } else {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(isSelected ? .white : Color.yellow)
                                    .frame(width: 18, height: 18)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.appName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(isSelected ? .white : .primary)
                                    .lineLimit(1)
                                Text("\(app.count) starred")
                                    .font(.system(size: 10))
                                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isSelected ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func resolvedName(bundleId: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            return app.localizedName ?? bundleId.components(separatedBy: ".").last ?? bundleId
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleId.components(separatedBy: ".").last ?? bundleId
    }

    private func resolvedIcon(bundleId: String) -> NSImage? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            return app.icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

// MARK: - Favourite Menus detail panel

private struct FavouriteMenusDetailView: View {
    let bundleId: String
    @ObservedObject private var settings = AppSettings.shared

    private var appName: String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            return app.localizedName ?? bundleId
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleId
    }

    private var appIcon: NSImage? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            return app.icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private var favourites: [String] {
        Array(settings.favouriteMenuPills(for: bundleId)).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.2))
                        .frame(width: 36, height: 36)
                        .overlay(Image(systemName: "star.fill").foregroundStyle(.yellow))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(bundleId)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(favourites.count) starred")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            if favourites.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No starred menu items yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("In the context dock, right-click any menu pill and choose \"Add to Favourites\"")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Starred items list
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Starred Menu Items")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(favourites, id: \.self) { name in
                                HStack(spacing: 10) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.yellow)
                                        .frame(width: 20)
                                    Text(name)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        settings.toggleFavouriteMenuPill(name, for: bundleId)
                                    } label: {
                                        Image(systemName: "star.slash")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove from Favourites")
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
