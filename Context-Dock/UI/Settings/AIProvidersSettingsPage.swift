import SwiftUI

struct AIProvidersSettingsPage: View {
    /// Off by default. Continuing the editor's session puts quick questions into the
    /// middle of a long coding conversation, and points two live clients at one session
    /// file — worth having, not worth assuming.
    @AppStorage(ClaudeCodeBridge.continueEditorSessionKey) private var continueEditorSession = false

    /// Also off by default. This one answers questions about the user's screen to anything
    /// that can reach loopback with the token — it is switched on deliberately or not at all.
    @AppStorage(DoraXMCPServer.enabledKey) private var mcpEnabled = false
    @ObservedObject private var server = DoraXMCPServer.shared
    @ObservedObject private var computerUse = ComputerUseConsentStore.shared

    @State private var copiedCommand = false
    @State private var copiedSnippet = false
    @State private var copiedToken = false

    /// Names the apps rather than counting them: "2 apps" is a number, and what the user needs
    /// to decide anything is which two.
    private var grantedAppsTitle: String {
        let granted = computerUse.grantedBundleIDs()
        guard !granted.isEmpty else { return "No App Is Granted Yet" }
        let names = granted.map { bundleID -> String in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .flatMap { FileManager.default.displayName(atPath: $0.path) }
                ?? bundleID
        }
        return "Granted: " + names.sorted().joined(separator: ", ")
    }

    private static func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }?
            .replacingOccurrences(of: ".app", with: "") ?? bundleID
    }

    var body: some View {
        VStack(spacing: 16) {
            AIProviderSettingsView()

            if ClaudeCodeBridge.isAvailable {
                CardSection(title: "Claude Code", systemImage: "terminal") {
                    SettingsPageRow(
                        icon: "arrow.triangle.merge",
                        iconColor: .purple,
                        title: "Continue My Editor's Session",
                        subtitle:
                            "Ask Claude in a chat and it picks up the Claude Code conversation already "
                            + "open for that project, instead of keeping its own. Off means this chat "
                            + "keeps a separate thread."
                    ) {
                        Toggle("", isOn: $continueEditorSession)
                            .labelsHidden()
                    }
                }
            }

            CardSection(title: "Computer Use", systemImage: "hand.tap") {
                VStack(spacing: 0) {
                    SettingsPageRow(
                        icon: "cursorarrow.click.2",
                        iconColor: .orange,
                        title: "Let DoraX Operate Apps",
                        subtitle:
                            "When no capability, CLI, MCP tool or published menu command can do "
                            + "what you asked, DoraX may press the app's own menu the way you "
                            + "would. Off by default, and off here means off everywhere — no app "
                            + "is operated whatever its own setting says."
                    ) {
                        Toggle("", isOn: $computerUse.isMasterEnabled)
                            .labelsHidden()
                    }
                    Divider()
                    SettingsPageRow(
                        icon: "checklist",
                        iconColor: .gray,
                        title: grantedAppsTitle,
                        subtitle:
                            "Each app is granted separately, on its own page in Integrations → "
                            + "Access. Sending, replying, forwarding and deleting are never "
                            + "pressed this way, whatever you ask for."
                    ) {
                        if !computerUse.grantedBundleIDs().isEmpty {
                            Button("Turn All Off") {
                                for bundleID in computerUse.grantedBundleIDs() {
                                    computerUse.revoke(for: bundleID)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    // Each standing grant — including "Always for …" chosen in the corner's
                    // Selection card — with its own Remove. After removing, the next action that
                    // needs the app asks again.
                    ForEach(computerUse.grantedBundleIDs(), id: \.self) { bundleID in
                        Divider()
                        SettingsPageRow(
                            icon: "hand.tap",
                            iconColor: .orange,
                            title: Self.appName(bundleID),
                            subtitle: computerUse.mode(for: bundleID).title
                        ) {
                            Button("Remove") { computerUse.revoke(for: bundleID) }
                                .controlSize(.small)
                        }
                    }
                }
            }

            CardSection(title: "Context-Dock MCP Server", systemImage: "antenna.radiowaves.left.and.right") {
                VStack(spacing: 0) {
                    SettingsPageRow(
                        icon: "eye.fill",
                        iconColor: .teal,
                        title: "Enable Native MCP Server",
                        subtitle:
                            "Expose Context-Dock's 5 universal tools (look, do, script, read_data, ask) "
                            + "to Claude Code, Claude Desktop, Cursor, Codex, and external AI providers. "
                            + "Local-only on 127.0.0.1, protected by Bearer token authentication."
                    ) {
                        Toggle("", isOn: $mcpEnabled)
                            .labelsHidden()
                            .onChange(of: mcpEnabled) { _, on in
                                on ? DoraXMCPServer.shared.start() : DoraXMCPServer.shared.stop()
                            }
                    }
                    if mcpEnabled {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(server.isRunning ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                Text(server.isRunning ? "Running on http://127.0.0.1:\(DoraXMCPServer.port)/mcp" : "Starting server…")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(server.isRunning ? .primary : .secondary)
                                Spacer()
                            }

                            HStack(spacing: 8) {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        DoraXMCPServer.registrationCommand, forType: .string)
                                    copiedCommand = true
                                    Task {
                                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                                        copiedCommand = false
                                    }
                                } label: {
                                    Label(copiedCommand ? "Copied Command!" : "Copy CLI Command",
                                          systemImage: copiedCommand ? "checkmark" : "terminal")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(!server.isRunning)

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        DoraXMCPServer.jsonConfigurationSnippet, forType: .string)
                                    copiedSnippet = true
                                    Task {
                                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                                        copiedSnippet = false
                                    }
                                } label: {
                                    Label(copiedSnippet ? "Copied JSON!" : "Copy JSON Config",
                                          systemImage: copiedSnippet ? "checkmark" : "curlybraces")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!server.isRunning)

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        DoraXMCPServer.token, forType: .string)
                                    copiedToken = true
                                    Task {
                                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                                        copiedToken = false
                                    }
                                } label: {
                                    Label(copiedToken ? "Copied Token!" : "Copy Token",
                                          systemImage: copiedToken ? "checkmark" : "key")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!server.isRunning)
                            }

                            DisclosureGroup("View MCP Config Snippet") {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Add to claude_desktop_config.json, Cursor, or your AI client settings:")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    ScrollView(.horizontal) {
                                        Text(DoraXMCPServer.jsonConfigurationSnippet)
                                            .font(.system(size: 10, design: .monospaced))
                                            .padding(8)
                                    }
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                }
                                .padding(.top, 4)
                            }
                            .font(.system(size: 11))
                        }
                        .padding(14)
                    }
                }
            }
        }
    }
}
