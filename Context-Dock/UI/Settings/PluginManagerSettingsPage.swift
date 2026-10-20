// Context-Dock
//
// The plugin manager (plan §4): one read-only front over every capability registry, per
// app. It shows what each plugin is, what it can read and write, where it came from and
// — once measured — how reliable it is. It writes nothing; enabling, pinning and removing
// are the editable pages' job (Plugins, App Packs, Integrations) and come to this view
// later. Not the Global Context widget "Plugins" page: that is a different layer.

import SwiftUI

@MainActor
struct PluginManagerSettingsPage: View {
    @ObservedObject private var adapters = AppAdapterManager.shared

    /// Rebuilt whenever the adapter set changes (the projection is cheap); grouped by app
    /// so each app is one section, machine-wide capabilities last under "System".
    private var apps: [AppGroup] {
        let manifests = AgentPluginManifestBuilder.manifests()
        var order: [String] = []
        var byApp: [String: [AgentPluginManifest]] = [:]
        for manifest in manifests {
            let key = manifest.app
            if byApp[key] == nil { order.append(key) }
            byApp[key, default: []].append(manifest)
        }
        return order.map { app in
            let group = byApp[app] ?? []
            let bundleID = group.compactMap { $0.bundleIDs.first }.first
            return AppGroup(
                name: app.isEmpty ? "System" : app,
                bundleID: bundleID,
                manifests: group,
                menuCommandCount: bundleID.map {
                    AgentPluginManifestBuilder.menuCommandCount(bundleID: $0)
                } ?? 0)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Every way DoraX can act on an app, in one place. Each capability shows "
                    + "its kind, what it costs to run, and whether it reads or writes. This "
                    + "view is read-only; turn things on or off on the Plugins, App Packs and "
                    + "Integrations pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(apps) { group in
                    appSection(group)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func appSection(_ group: AppGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.name).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if group.menuCommandCount > 0 {
                    Text("\(group.menuCommandCount) menu commands")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Learned menu commands for this app. Used only when no headless "
                            + "route can do the job (plan §2a).")
                }
            }

            ForEach(group.manifests) { manifest in
                manifestBlock(manifest)
            }
        }
        .padding(.vertical, 4)
    }

    private func manifestBlock(_ manifest: AgentPluginManifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(manifest.kindLabel)
                    .font(.system(size: 12, weight: .medium))
                originBadge(manifest.origin)
                Spacer(minLength: 0)
                Text(healthText(manifest.health))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(manifest.capabilities) { capability in
                capabilityRow(capability)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor)))
    }

    private func capabilityRow(_ capability: AgentPluginManifest.Capability) -> some View {
        HStack(spacing: 8) {
            Image(systemName: capability.isWrite ? "pencil" : "eye")
                .font(.caption2)
                .foregroundStyle(capability.isWrite ? Color.orange : Color.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(capability.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(capability.surface.costLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(capability.isWrite ? "Write" : "Read")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(
                        (capability.isWrite ? Color.orange : Color.secondary).opacity(0.15)))
                .foregroundStyle(capability.isWrite ? Color.orange : Color.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(capability.title), "
            + "\(capability.isWrite ? "writes" : "reads"), \(capability.surface.costLabel)")
    }

    private func originBadge(_ origin: AgentPluginManifest.Origin) -> some View {
        Text(origin.rawValue)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
    }

    private func healthText(_ health: AgentPluginManifest.Health?) -> String {
        guard let health, let rate = health.successRate else { return "No health data yet" }
        return "\(Int(rate * 100))% success"
    }

    private struct AppGroup: Identifiable {
        let name: String
        let bundleID: String?
        let manifests: [AgentPluginManifest]
        let menuCommandCount: Int
        var id: String { name }
    }
}
