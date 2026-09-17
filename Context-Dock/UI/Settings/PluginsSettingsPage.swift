// Context-Dock
//
// Plugins are Global Context's one extension system (decision 16822896), so they get their own
// page rather than a corner of the AI provider settings. Today it shows what is installed, what
// the two systems Plugins replaces would become, and what any of them draws. Phase 3 gives them
// a runtime; Phase 7 the Creator; Phase 8 the actual cut-over.

import SwiftUI

@MainActor
struct PluginsSettingsPage: View {
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var globalExtensions = UserGlobalExtensionStore.shared
    @StateObject private var runtime = PluginRuntime()
    @State private var selection: String = PluginExamples.all.first?.id ?? ""
    @State private var showsMigrated = true
    @State private var running = false
    @State private var installMessage: String?

    /// Everything previewable, in one list: the shipped examples, anything actually installed,
    /// and every Global Command and Global Extension as it would arrive after migration.
    private var migrated: [MigratedPlugin] {
        PluginMigration.migrateAll(
            commands: SystemCommandsRegistry.shared.commands,
            extensions: globalExtensions.extensions)
    }

    private var previewable: [PluginManifest] {
        PluginExamples.all + registry.plugins.map(\.manifest) + migrated.map(\.manifest)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                installed
                Divider()
                legacy
                Divider()
                preview
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Installed

    private var installed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Installed", systemImage: "shippingbox")
                .font(.headline)

            if registry.plugins.isEmpty {
                Text("No plugins installed yet. A plugin is a folder with a `plugin.json` "
                    + "manifest; installing and running them is Phase 3.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(registry.plugins) { plugin in
                    row(
                        icon: plugin.manifest.icon, name: plugin.manifest.name,
                        detail: plugin.manifest.description,
                        badge: plugin.hasErrors ? "Has errors" : nil,
                        enabled: plugin.isEnabled)
                }
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
                + "Nothing is replaced yet — this is what the cut-over would produce, and "
                + "picking one below shows what it would draw."
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
                            enabled: item.isEnabled)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.smooth(duration: 0.2)) { selection = item.id }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selection == item.id
                                        ? Color.accentColor.opacity(0.12) : Color.clear))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Preview", systemImage: "eye")
                    .font(.headline)
                Spacer()
                Picker("", selection: $selection) {
                    ForEach(previewable, id: \.id) { manifest in
                        Text(manifest.name).tag(manifest.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }

            Text("Every host this plugin declares, drawn from its own sample data. Nothing "
                + "runs: scripts, artwork fetches and the AI component are Phase 3.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let manifest = previewable.first(where: { $0.id == selection }) ?? previewable.first {
                runRow(manifest)
                PluginPreviewHarness(manifest: manifest, live: liveBinding(for: manifest))
                    .id(manifest.id)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.22), value: selection)
    }

    /// Runs the plugin's DATA script and draws what it returns instead of the sample.
    ///
    /// Data only. A plugin's actions stay refused here: routing them through the app's
    /// approval centre means deciding whether a plugin action is an AICapability, which is
    /// what the PluginToolset work settles — and inventing a second approval sheet in the
    /// meantime is exactly the thing worth not doing.
    @ViewBuilder
    private func runRow(_ manifest: PluginManifest) -> some View {
        HStack(spacing: 10) {
            Button {
                running = true
                Task {
                    await runtime.refresh(manifest, host: .panel, inputs: PluginInputs())
                    running = false
                }
            } label: {
                Label(running ? "Running…" : "Run data script", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .disabled(manifest.data == nil || running)

            switch runtime.state(for: manifest, host: .panel, inputs: PluginInputs()) {
            case .ready where manifest.data != nil:
                Label("Showing live output", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let diagnostic):
                Label(diagnostic.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            case .ready, .loading:
                if manifest.data == nil {
                    Text("No data script — this plugin is its sample.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Sample data. Press Run to see what the script returns.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)

            Button {
                PluginWindowManager.shared.open(manifest)
            } label: {
                Label("Open window", systemImage: "macwindow")
            }
            .buttonStyle(.bordered)
            .help("The detached host — the same renderer at window width")
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

    private func liveBinding(for manifest: PluginManifest) -> PluginBinding? {
        guard manifest.data != nil,
            case .ready(let binding) = runtime.state(
                for: manifest, host: .panel, inputs: PluginInputs())
        else { return nil }
        return binding
    }

    private func row(icon: String, name: String, detail: String, badge: String?, enabled: Bool)
        -> some View
    {
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
            Text(enabled ? "On" : "Off").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}
