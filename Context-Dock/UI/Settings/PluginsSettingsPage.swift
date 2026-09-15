// Context-Dock
//
// Plugins are Global Context's one extension system (decision 16822896), so they get their own
// page rather than a corner of the AI provider settings. Today it shows what is installed and
// what a manifest draws; Phase 3 gives it a runtime, and Phase 7 the Creator.

import SwiftUI

struct PluginsSettingsPage: View {
    @ObservedObject private var registry = PluginRegistry.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                installed
                Divider()
                PluginPreviewPanel()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var installed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Installed", systemImage: "shippingbox")
                .font(.headline)

            if registry.plugins.isEmpty {
                Text("No plugins installed yet. A plugin is a folder with a `plugin.json` "
                    + "manifest; installing and running them is Phase 3. The examples below "
                    + "ship with the app so the kit can be seen before then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(registry.plugins) { plugin in
                    HStack(spacing: 10) {
                        Image(systemName: plugin.manifest.icon)
                            .frame(width: 20)
                            .foregroundStyle(plugin.hasErrors ? Color.orange : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.manifest.name).font(.system(size: 13, weight: .medium))
                            Text(plugin.manifest.description)
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if plugin.hasErrors {
                            Text("Has errors").font(.caption2).foregroundStyle(.orange)
                        }
                        Text(plugin.isEnabled ? "On" : "Off")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            if !registry.rootErrors.isEmpty {
                ForEach(registry.rootErrors, id: \.self) { error in
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }
}
