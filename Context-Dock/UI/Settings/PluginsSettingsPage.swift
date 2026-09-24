// Context-Dock
//
// Plugins are Global Context's one extension system (decision 16822896), so they get their own
// page rather than a corner of the AI provider settings. It manages: what is installed (edit,
// open as a window, remove), the shipped examples to try, and what the two systems Plugins
// replaces would become. Looking at a plugin is the Creator's job — it draws every host from
// the same renderer and can run the data script — so nothing is previewed here twice.

import SwiftUI

@MainActor
struct PluginsSettingsPage: View {
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var globalExtensions = UserGlobalExtensionStore.shared
    @ObservedObject private var pins = DockPinStore.shared
    @State private var showsMigrated = true
    @State private var installMessage: String?
    @State private var removeMessage: String?

    /// Everything previewable, in one list: the shipped examples, anything actually installed,
    /// and every Global Command and Global Extension as it would arrive after migration.
    private var migrated: [MigratedPlugin] {
        PluginMigration.migrateAll(
            commands: SystemCommandsRegistry.shared.commands,
            extensions: globalExtensions.extensions)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                installed
                Divider()
                examples
                Divider()
                legacy
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Installed

    private var installed: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Installed", systemImage: "shippingbox")
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    GeneralChatWindowController.shared.showCreator()
                } label: {
                    Label("Create…", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Describe a plugin and draft it with AI")
            }

            if registry.plugins.isEmpty {
                Text("Nothing installed yet. Create one, or open an example below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(registry.plugins) { plugin in
                    row(
                        icon: plugin.manifest.icon, name: plugin.manifest.name,
                        detail: plugin.manifest.description,
                        badge: plugin.hasErrors ? "Has errors" : nil,
                        enabled: plugin.isEnabled
                    ) {
                        // Where a plugin appears: the strip, when pinned; search always.
                        if isPinned(plugin.id) {
                            Image(systemName: "pin.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("In the corner dock")
                        }
                        if editedShipped.contains(plugin.id) {
                            // Edited built-ins are never overwritten by a new build, so this
                            // is the only way the newer shipped version ever arrives — by
                            // being asked for.
                            Image(systemName: "pencil.circle")
                                .font(.caption2).foregroundStyle(.orange)
                                .help("You edited this built-in — a newer version ships with "
                                    + "the app. Reset from the ••• menu to take it.")
                        }
                        Toggle("", isOn: Binding(
                            get: { plugin.isEnabled },
                            set: { registry.setEnabled($0, pluginID: plugin.id) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        Menu {
                            Button("Edit in Creator") {
                                GeneralChatWindowController.shared.showCreator(editing: plugin.manifest)
                            }
                            if !plugin.manifest.declaredPresentations.isEmpty {
                                Button("Open as Window") {
                                    PluginWindowManager.shared.open(plugin.manifest)
                                }
                            }
                            if isPinned(plugin.id) {
                                Button("Unpin from Dock") { setPinned(plugin, false) }
                            } else {
                                Button("Pin to Dock") { setPinned(plugin, true) }
                            }
                            if editedShipped.contains(plugin.id) {
                                Divider()
                                Button("Reset to the built-in version") { reset(plugin) }
                            }
                            Divider()
                            Button("Remove…", role: .destructive) { remove(plugin) }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
            }

            if let removeMessage {
                Text(removeMessage).font(.caption).foregroundStyle(.secondary)
            }

            ForEach(registry.rootErrors, id: \.self) { error in
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    // MARK: What migration would produce

    private var legacy: some View {
        let items = migrated
        let broken = items.filter { !PluginSchema.validate($0.manifest)
            .filter { $0.severity == .error }.isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Your existing extensions", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                Button("Install all that convert") { installAll(items) }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(items.isEmpty)
                Button(showsMigrated ? "Hide" : "Show") {
                    withAnimation(.smooth(duration: 0.2)) { showsMigrated.toggle() }
                }
                .buttonStyle(.borderless).font(.caption)
            }

            Text("Every Global Command and Global Extension, converted to a plugin manifest. "
                + "Nothing is replaced yet — this is what the cut-over would produce; open "
                + "one in the Creator to see what it would draw."
                + (broken.isEmpty
                    ? ""
                    : " \(broken.count) do not convert cleanly and are marked."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let installMessage {
                Text(installMessage).font(.caption).foregroundStyle(.secondary)
            }

            if showsMigrated {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        let errors = PluginSchema.validate(item.manifest)
                            .filter { $0.severity == .error }
                        row(
                            icon: item.manifest.icon, name: item.manifest.name,
                            detail: item.source.rawValue,
                            badge: errors.isEmpty ? nil : errors[0].message,
                            enabled: item.isEnabled
                        ) {
                            Button("Open in Creator") {
                                GeneralChatWindowController.shared.showCreator(editing: item.manifest)
                            }
                            .buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Examples

    /// The shipped examples are the only plugins with a live icon and a hover panel until a
    /// person writes one. Opening one in the Creator, saving it and pinning it is how those
    /// hosts get seen; it also happens to be the fastest way to learn the format.
    private var examples: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Examples", systemImage: "lightbulb")
                .font(.headline)
            Text("Open one in the Creator, change what you like, save it — it is installed "
                + "and searchable, and it can be pinned to the corner dock.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(PluginExamples.all + PluginEssentials.all, id: \.id) { manifest in
                row(
                    icon: manifest.icon, name: manifest.name,
                    detail: shape(of: manifest), badge: nil, enabled: nil
                ) {
                    Button("Open in Creator") {
                        GeneralChatWindowController.shared.showCreator(editing: manifest)
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    /// One line on what hosts a manifest declares — enough to pick the one to try.
    private func shape(of manifest: PluginManifest) -> String {
        let hosts = manifest.declaredPresentations.map { presentation -> String in
            if presentation == .widget, manifest.views.widget?.family == .bar {
                return "bar tile"
            }
            return presentation.rawValue
        }
        return hosts.isEmpty ? "one-shot" : hosts.joined(separator: " · ")
    }

    private func isPinned(_ pluginID: String) -> Bool {
        pins.pins.contains { $0.kind.pluginID == pluginID }
    }

    private func setPinned(_ plugin: InstalledPlugin, _ pinned: Bool) {
        if pinned {
            _ = pins.pin(
                .globalCommand(id: "plugin:\(plugin.id)"), title: plugin.manifest.name,
                documentID: "plugin:\(plugin.id)")
        } else {
            for pin in pins.pins where pin.kind.pluginID == plugin.id { pins.unpin(pin.id) }
        }
    }

    /// Built-in plugins the person has edited. Seeding leaves these alone, so the badge and
    /// the reset are how a newer shipped version ever reaches them.
    private var editedShipped: [String] {
        PluginShipped.editedShippedPlugins(installedIn: PluginInstaller.userRoot)
    }

    private func reset(_ plugin: InstalledPlugin) {
        do {
            try PluginEssentials.reset(pluginID: plugin.id, in: PluginInstaller.userRoot)
            registry.reload()
            removeMessage = "\(plugin.manifest.name) is back to the version that ships with the app."
        } catch {
            removeMessage = "Could not reset \(plugin.manifest.name): \(error)"
        }
    }

    private func remove(_ plugin: InstalledPlugin) {
        let alert = NSAlert()
        alert.messageText = "Remove \"\(plugin.manifest.name)\"?"
        alert.informativeText = "Its folder is deleted and it leaves the dock and search. "
            + "What it remembered is kept for a reinstall."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try registry.uninstall(pluginID: plugin.id)
            removeMessage = "Removed \(plugin.manifest.name)."
        } catch {
            removeMessage = "Could not remove: \(error.localizedDescription)"
        }
    }

    /// Writes every cleanly-converting item into the user's plugin folder, where the registry
    /// reads it. This is the cut-over made real for the ones that are ready, and it refuses
    /// the rest by name rather than installing something that cannot work.
    private func installAll(_ items: [MigratedPlugin]) {
        // Each installed plugin remembers the legacy item it stands in for, so the launcher
        // can hide that original for exactly as long as the plugin is installed.
        let clean = items.compactMap { item -> PluginManifest? in
            var manifest = item.manifest
            guard PluginSchema.validate(manifest).filter({ $0.severity == .error }).isEmpty
            else { return nil }
            manifest.keywords.append(PluginSupersession.keyword(forLegacyID: item.legacyID))
            return manifest
        }
        guard !clean.isEmpty else {
            installMessage = "None of them convert cleanly yet, so nothing was installed."
            return
        }
        do {
            _ = try PluginInstaller.install(
                clean, into: PluginInstaller.userRoot,
                packID: "migrated", packName: "Migrated from Global Context")
            registry.reload()
            let skipped = items.count - clean.count
            installMessage = "Installed \(clean.count)"
                + (skipped > 0 ? ", skipped \(skipped) that do not convert cleanly." : ".")
        } catch {
            installMessage = "Could not install: \(error)"
        }
    }

    private func row<Trailing: View>(
        icon: String, name: String, detail: String, badge: String?, enabled: Bool?,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(badge == nil ? Color.accentColor : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let badge {
                Text(badge).font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
            if let enabled {
                Text(enabled ? "On" : "Off").font(.caption2).foregroundStyle(.secondary)
            }
            trailing()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}
