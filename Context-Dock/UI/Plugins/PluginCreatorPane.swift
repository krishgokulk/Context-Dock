// Context-Dock
//
// The Creator's surface: the manifest on the left, what it draws on the right. The preview is
// the real renderer with the real traits, so what an author sees here is what a person gets —
// there is no second drawing of a plugin anywhere in the app.

import SwiftUI

@MainActor
struct PluginCreatorPane: View {
    @ObservedObject private var registry = PluginRegistry.shared
    @StateObject private var model = PluginCreatorModel(text: PluginCreatorPane.starter)
    @State private var saved: String?

    /// What an empty Creator starts from. A working plugin rather than an empty object: the
    /// fastest way to learn the format is to change something that already runs.
    static let starter = """
    {
      "id": "my-plugin",
      "name": "My Plugin",
      "icon": "sparkles",
      "description": "What this does.",
      "keywords": ["mine"],
      "actions": {
        "go": { "type": "bash", "script": "echo hello", "title": "Say hello", "risk": "low" }
      },
      "primaryAction": "go"
    }
    """

    var body: some View {
        HSplitView {
            editor
                .frame(minWidth: 320, idealWidth: 460)
            preview
                .frame(minWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Manifest", systemImage: "curlybraces")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Menu("Open") {
                    ForEach(registry.plugins) { installed in
                        Button(installed.manifest.name) { open(installed.manifest) }
                    }
                    if registry.plugins.isEmpty {
                        Text("Nothing installed yet").font(.caption)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("New") { open(nil) }
                    .buttonStyle(.borderless)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
                    .help(model.canSave
                        ? "Write this plugin where the app reads it"
                        : "Fix the errors below first")
            }

            TextEditor(text: $model.text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))

            status
        }
        .padding(12)
    }

    @ViewBuilder
    private var status: some View {
        if let saved {
            Label(saved, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.green)
        }
        if !model.errors.isEmpty {
            PluginDiagnosticsView(diagnostics: model.errors)
        } else if !model.warnings.isEmpty {
            // Warnings are advice — shown, never blocking. A plugin is usually half-written
            // while it is being written.
            PluginDiagnosticsView(diagnostics: model.warnings)
        } else {
            Label("Valid", systemImage: "checkmark.seal")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Preview", systemImage: "eye")
                .font(.system(size: 12, weight: .semibold))
            if let manifest = model.previewManifest {
                if manifest.declaredPresentations.isEmpty {
                    oneShotPreview(manifest)
                } else {
                    ScrollView {
                        PluginPreviewHarness(manifest: manifest)
                            .padding(.vertical, 4)
                    }
                }
            } else {
                Text("Nothing has parsed yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A plugin with no views is a one-shot. Drawing an empty host for it would say nothing,
    /// so the preview says what choosing it will do instead.
    private func oneShotPreview(_ manifest: PluginManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: manifest.icon)
                Text(manifest.name).font(.system(size: 13, weight: .semibold))
            }
            switch PluginLaunch.behaviour(for: manifest) {
            case .run(let action):
                let declared = manifest.actions[action]
                Text("A one-shot: choosing it runs \"\(declared?.title ?? action)\".")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let declared, PluginPermissions.needsApproval(declared) {
                    Label("Asks before it runs (risk: \(declared.risk.rawValue))",
                          systemImage: "lock.shield")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .openPanel:
                EmptyView()
            case .nothing:
                Label("No view and no primary action — nothing would happen.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
    }

    // MARK: Actions

    private func open(_ manifest: PluginManifest?) {
        saved = nil
        if let manifest {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            model.text = (try? encoder.encode(manifest))
                .flatMap { String(data: $0, encoding: .utf8) } ?? Self.starter
        } else {
            model.text = Self.starter
        }
    }

    private func save() {
        do {
            if try model.save() {
                saved = "Saved. It is installed and searchable by name."
            }
        } catch {
            saved = nil
        }
    }
}
