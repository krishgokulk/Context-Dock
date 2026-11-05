// Context-Dock
//
// The Creator's surface: the manifest on the left, what it draws on the right. The preview is
// the real renderer with the real traits, so what an author sees here is what a person gets —
// there is no second drawing of a plugin anywhere in the app.

import SwiftUI

@MainActor
struct PluginCreatorPane: View {
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var chrome = GeneralChatWindowChromeState.shared
    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @StateObject private var model = PluginCreatorModel(text: PluginCreatorPane.starter)
    @State private var saved: String?
    @State private var showOpenAPIInput = false

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
        .onAppear { takeRequestedManifest() }
        .onChange(of: chrome.creatorOpens?.id) { _, _ in takeRequestedManifest() }
    }

    /// Settings asked for a manifest to be opened here (Edit, or an example to try). Taken
    /// once and cleared, so the next visit to this mode starts where the person left it.
    private func takeRequestedManifest() {
        guard let manifest = chrome.creatorOpens else { return }
        chrome.creatorOpens = nil
        open(manifest)
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

            describe

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

    /// Describe it, or describe a change to it, and the configured provider writes the
    /// manifest into the editor. "Copy prompt" is the same ask for any other AI.
    private var describe: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Target App", systemImage: "app.connected.to.app.below.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Target App", selection: $model.selectedTargetBundleID) {
                    Text("Auto-detect / Global").tag("")
                    Divider()
                    ForEach(adapterManager.adapters.filter { !$0.bundleId.isEmpty }, id: \.bundleId) { adapter in
                        Text(adapter.appName.isEmpty ? adapter.bundleId : adapter.appName)
                            .tag(adapter.bundleId)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 190)

                Spacer(minLength: 0)

                Button {
                    showOpenAPIInput.toggle()
                } label: {
                    Label(
                        model.openAPISpecText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "OpenAPI / UTCP Spec"
                            : "OpenAPI / UTCP Attached ✓",
                        systemImage: "link.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if showOpenAPIInput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paste an OpenAPI 3.x or UTCP manual JSON to synthesize direct zero-daemon endpoints:")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.openAPISpecText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 72)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.04)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    model.text == Self.starter
                        ? "Describe the pack — “Create a pack for Safari” or “Linear issue triage”"
                        : "Describe a change — “add a reset button”",
                    text: $model.request)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .disabled(model.isDrafting)
                    .onSubmit { Task { await model.draft() } }
                if model.isDrafting {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.draft() } } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.request.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Draft it with \(settings.selectedAIProvider.displayName)")
                }
                Menu {
                    Button("Copy prompt for another AI") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.promptForAnotherAI(), forType: .string)
                        saved = "Prompt copied. Paste what the AI returns into the editor."
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

            if let introspection = model.lastIntrospection {
                Label("Introspected \(introspection.summaryBadgeText)", systemImage: "magnifyingglass.circle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.teal)
                    .lineLimit(1)
            }
            if let note = model.note {
                Label(note, systemImage: "sparkles")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let error = model.draftError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
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
            HStack(spacing: 8) {
                Label("Preview", systemImage: "eye")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if model.previewManifest?.data != nil {
                    Button {
                        Task { await model.runTest() }
                    } label: {
                        Label(model.isRunning ? "Running…" : "Run test", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isRunning)
                    .help("Run the data script and draw what it returns instead of the sample")
                }
                if let manifest = model.previewManifest, !manifest.declaredPresentations.isEmpty {
                    Button {
                        PluginWindowManager.shared.open(manifest)
                    } label: {
                        Label("Window", systemImage: "macwindow")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("The detached host — the same renderer at window width")
                }
            }
            if let status = model.runStatus {
                Label(status.text, systemImage: status.failed
                    ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(status.failed ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }
            if let manifest = model.previewManifest {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if manifest.targetApp != nil || manifest.hasPackPayload {
                            packBindingPreview(manifest)
                        }
                        if manifest.declaredPresentations.isEmpty {
                            if !manifest.hasPackPayload {
                                oneShotPreview(manifest)
                            }
                        } else {
                            PluginPreviewHarness(manifest: manifest, live: model.live)
                                .id(manifest.id)
                                .padding(.vertical, 4)
                        }
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

    private func packBindingPreview(_ manifest: PluginManifest) -> some View {
        let targetName = manifest.targetApp?.name ?? "Global Context"
        let bundleID = manifest.targetApp?.bundleId ?? "global"
        let caps = manifest.capabilities ?? []
        let endpoints = manifest.utcpEndpoints ?? []
        let skills = manifest.skills ?? []

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: manifest.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.name).font(.system(size: 13, weight: .semibold))
                    Text("Binds to: \(targetName) (\(bundleID))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(bundleID == "global" ? "Global" : "App Pack")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }

            if !caps.isEmpty {
                Divider()
                Text("Capabilities (\(caps.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(caps) { cap in
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cap.name).font(.system(size: 11.5, weight: .medium))
                            if !cap.intent.isEmpty {
                                Text(cap.intent).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(cap.safety.capitalized)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(cap.safety == "read" ? .green : .orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                (cap.safety == "read" ? Color.green : Color.orange).opacity(0.14),
                                in: Capsule())
                    }
                }
            }

            if !endpoints.isEmpty {
                Divider()
                Text("UTCP Direct Endpoints (\(endpoints.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(endpoints) { ep in
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text("\(ep.method) \(ep.baseURL)\(ep.path)")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }

            if !skills.isEmpty {
                Divider()
                Text("Skills (\(skills.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(skills) { skill in
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 10))
                            .foregroundStyle(.purple)
                        Text(skill.name).font(.system(size: 11.5, weight: .medium))
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
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
        model.open(manifest)
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
