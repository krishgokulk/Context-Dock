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
                                    computerUse.setMode(.off, for: bundleID)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            CardSection(title: "Agent Access (MCP)", systemImage: "antenna.radiowaves.left.and.right") {
                VStack(spacing: 0) {
                    SettingsPageRow(
                        icon: "eye.fill",
                        iconColor: .teal,
                        title: "Let Agents See This Mac",
                        subtitle:
                            "Claude Code, Codex and any other MCP client can ask what app is in "
                            + "front, what you have selected, what Safari has open, and take a "
                            + "screenshot. Local only, and every request needs the token below."
                    ) {
                        Toggle("", isOn: $mcpEnabled)
                            .labelsHidden()
                            .onChange(of: mcpEnabled) { _, on in
                                on ? DoraXMCPServer.shared.start() : DoraXMCPServer.shared.stop()
                            }
                    }
                    if mcpEnabled {
                        Divider()
                        SettingsPageRow(
                            icon: "terminal.fill",
                            iconColor: .gray,
                            title: server.isRunning
                                ? "Connect Your Agent" : "Starting…",
                            subtitle: server.isRunning
                                ? "Run this once in any project. The token is what keeps other "
                                    + "programs on this Mac from using it."
                                : "Waiting for the local port."
                        ) {
                            Button("Copy Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    DoraXMCPServer.registrationCommand, forType: .string)
                            }
                            .disabled(!server.isRunning)
                        }
                    }
                }
            }
        }
    }
}
