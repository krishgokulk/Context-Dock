import SwiftUI

/// The app's own AGENT.md: how DoraX works with it, written as a file the user owns.
///
/// Authoring matters more here than anywhere else in Integrations, because the profile is the
/// one part of an app's setup that cannot be discovered — actions, skills, CLI tools and MCP
/// servers are all found, while "prefer the live page read over AppleScript" is something only a
/// person knows. So this page starts from a draft of what is already installed and gets out of
/// the way: a text editor, what the parser could not read, and Save.
struct AppIntegrationAgentView: View {
    let summary: AppIntegrationSummary

    @ObservedObject private var profiles = AppAgentProfileStore.shared
    @ObservedObject private var mcpServers = MCPServerManager.shared

    @State private var text: String = ""
    @State private var loadedText: String = ""
    @State private var problems: [String] = []
    @State private var savedAt: Date?
    @State private var saveError: String?

    private var isDirty: Bool { text != loadedText }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                nativeServers
                editor
                declared
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onChange(of: summary.bundleID) { _, _ in load() }
    }

    // MARK: - Sections

    /// Apple's own MCP servers for this app. Shown whether or not this Mac can run them, with
    /// the requirements stated: "nothing here" reads as DoraX being unable, when the truth is
    /// usually that a version or a setting is missing.
    @ViewBuilder
    private var nativeServers: some View {
        let servers = NativeMCPCatalog.servers(forBundleID: summary.bundleID)
        if !servers.isEmpty {
            section(
                title: "Apple's MCP server",
                caption: "Shipped with macOS, run locally, added to this app's resources."
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Divider() }
                        nativeServerRow(server)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor)))
            }
        }
    }

    private func nativeServerRow(_ server: NativeMCPServer) -> some View {
        let installed = NativeMCPCatalog.isInstalled(server, in: mcpServers)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12))
                    .foregroundStyle(.purple)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.id)
                        .font(.system(size: 12, weight: .medium))
                    Text(server.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if installed {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Add") {
                        mcpServers.add(
                            NativeMCPCatalog.configuration(for: server),
                            linkedTo: server.bundleID)
                    }
                    .controlSize(.small)
                    .disabled(!server.isPresent)
                }
            }
            if !server.isPresent {
                // Absent is not broken: Safari's server arrives with Safari 27 / Technology
                // Preview 247, so an older Mac is a version behind rather than unsupported.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not on this Mac yet. It needs:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                    ForEach(server.requirements, id: \.self) { requirement in
                        Text("• \(requirement)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if !installed {
                Text("Needs, in Safari: Show features for web developers, and Allow remote "
                    + "automation and external agents.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var editor: some View {
        section(
            title: "AGENT.md",
            caption: "How DoraX works with \(summary.appName): which route to prefer, what to "
                + "read first, what it must never do, and how to check its own work."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 280)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(NSColor.textBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12)))

                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lines DoraX could not read — everything else still applies:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                        ForEach(problems, id: \.self) { problem in
                            Text("• \(problem)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isDirty)
                    Button("Revert") { load() }
                        .controlSize(.small)
                        .disabled(!isDirty)
                    Button(loadedText.isEmpty ? "Start From What's Installed" : "Insert Draft") {
                        text = profiles.draft(
                            forBundleID: summary.bundleID, appName: summary.appName
                        ).markdown()
                        revalidate()
                    }
                    .controlSize(.small)
                    Button("Show in Finder") {
                        let url = profiles.fileURL(forBundleID: summary.bundleID)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .controlSize(.small)
                    .disabled(loadedText.isEmpty)
                    Button("Export…") { exportPack() }
                        .controlSize(.small)
                        .disabled(loadedText.isEmpty)
                    Button("Import…") { importPack() }
                        .controlSize(.small)
                    Spacer(minLength: 0)
                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    } else if let savedAt, !isDirty {
                        Text("Saved \(savedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: text) { _, _ in revalidate() }
    }

    /// What the file currently declares, read back from the parser rather than from the text —
    /// so this says what a turn will actually be told, not what the editor appears to say.
    @ViewBuilder
    private var declared: some View {
        let profile = AppAgentProfile.parse(
            text, bundleID: summary.bundleID, appName: summary.appName)
        if !profile.tools.isEmpty || !profile.never.isEmpty {
            section(
                title: "What this declares",
                caption: "Read back from the file, so it is what a chat will be told."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    declaredRow("Capabilities", profile.tools.capabilities, icon: "bolt")
                    declaredRow("MCP servers", profile.tools.mcp, icon: "server.rack")
                    declaredRow("CLI tools", profile.tools.cli, icon: "terminal")
                    declaredRow("Actions", profile.tools.actions, icon: "play.rectangle")
                    declaredRow("Scripts", profile.tools.scripts, icon: "doc.text")
                    if !profile.never.isEmpty {
                        ForEach(profile.never, id: \.self) { line in
                            HStack(spacing: 8) {
                                Image(systemName: "hand.raised")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                                    .frame(width: 16)
                                Text(line).font(.system(size: 11))
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func declaredRow(_ title: String, _ values: [String]?, icon: String) -> some View {
        if let values {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("\(title): ")
                    .font(.system(size: 11, weight: .medium))
                + Text(values.isEmpty ? "none" : values.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Loading and saving

    private func load() {
        let url = profiles.fileURL(forBundleID: summary.bundleID)
        loadedText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = loadedText
        saveError = nil
        revalidate()
    }

    private func revalidate() {
        problems = AppAgentProfile.parse(
            text, bundleID: summary.bundleID, appName: summary.appName
        ).problems
    }

    private func save() {
        do {
            let profile = AppAgentProfile.parse(
                text, bundleID: summary.bundleID, appName: summary.appName)
            // Written verbatim rather than re-serialised: this is the user's file, and a save
            // that reformats what they typed is a save that fights them.
            let url = profiles.fileURL(forBundleID: summary.bundleID)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            profiles.invalidate(bundleID: summary.bundleID)
            loadedText = text
            problems = profile.problems
            savedAt = Date()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Write this app's profile and scripts out as a `.dxagent` folder, so the setup that took
    /// an afternoon to get right can be handed to someone else in one drag.
    private func exportPack() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Where should \(summary.appName)'s agent pack go?"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let url = try AppAgentProfilePack.export(
                forBundleID: summary.bundleID, appName: summary.appName,
                from: profiles.root, to: parent)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Read a pack, say what it carries, and install it only if the user agrees — including
    /// whether its scripts may run, which is a separate decision from importing them.
    private func importPack() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Pack"
        panel.message = "Choose a .\(AppAgentProfilePack.fileExtension) folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let contents = try AppAgentProfilePack.inspect(folder: folder)
            let alert = NSAlert()
            alert.messageText = "Import this agent for \(summary.appName)?"
            var lines = [contents.profile.summary].filter { !$0.isEmpty }
            if !contents.scripts.isEmpty {
                lines.append("Scripts: " + contents.scripts.joined(separator: ", "))
            }
            if !contents.missingScripts.isEmpty {
                lines.append(
                    "Declares but does not carry: "
                    + contents.missingScripts.joined(separator: ", "))
            }
            lines.append("This replaces \(summary.appName)'s current AGENT.md.")
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")

            // Off by default: a pack is someone else's code, and making it runnable is its own
            // decision rather than a consequence of importing.
            let allowScripts = NSButton(
                checkboxWithTitle: "Allow its scripts to run", target: nil, action: nil)
            allowScripts.state = .off
            if !contents.scripts.isEmpty { alert.accessoryView = allowScripts }

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = try AppAgentProfilePack.install(
                folder: folder, forBundleID: summary.bundleID, into: profiles.root,
                makeScriptsExecutable: contents.scripts.isEmpty
                    ? false : allowScripts.state == .on)
            profiles.invalidate(bundleID: summary.bundleID)
            load()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func section<Content: View>(
        title: String, caption: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }
}
