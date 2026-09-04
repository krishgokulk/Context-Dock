import SwiftUI

/// What this integration is allowed to do, and how to take it back.
///
/// Permission, standing consent, and stored credentials are read from the stores that own
/// them; this page only shows their state and offers the revoke each one already supports.
struct AppIntegrationAccessView: View {
    let summary: AppIntegrationSummary

    @ObservedObject private var consentStore = AdapterActionConsentStore.shared
    @ObservedObject private var apiStore = APIConnectionStore.shared
    @State private var showRemoveConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                automationPermission
                standingConsent
                credentials
                declaredScope
                removal
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Remove \(summary.appName)?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Integration", role: .destructive) {
                Task {
                    await IntegrationRemovalService.removeAppIntegration(
                        bundleId: summary.bundleID)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }

    private var preview: IntegrationRemovalPreview {
        IntegrationInventoryBuilder.removalPreview(for: summary)
    }

    // MARK: - Sections

    private var automationPermission: some View {
        let authorized = contextDockAutomationAuthorized(bundleID: summary.bundleID)
        return section(
            title: "Automation Permission",
            caption: "Granted in System Settings → Privacy & Security → Automation."
        ) {
            HStack(spacing: 8) {
                Image(systemName: authorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(authorized ? .green : .orange)
                Text(authorized
                    ? "Context Dock can control \(summary.appName)."
                    : "Not granted — AppleScript actions for this app will fail.")
                    .font(.system(size: 12))
                Spacer()
                if !authorized {
                    Button("Open System Settings") {
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Automation permission")
            .accessibilityValue(authorized ? "Granted" : "Not granted")
        }
    }

    private var grants: [AdapterAction] {
        // The store keys grants case-insensitively, so match how it writes them.
        let allowedIDs = Set(
            consentStore.allGrants()
                .filter { $0.bundleId == summary.bundleID.lowercased() }
                .map(\.actionId))
        return summary.actions.filter { allowedIDs.contains($0.id.lowercased()) }
    }

    private var standingConsent: some View {
        let granted = grants
        return section(
            title: "Always-Allow Actions",
            caption: "Actions that run without asking. Revoking restores the prompt."
        ) {
            if granted.isEmpty {
                Text("No action runs without asking.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(granted.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: action.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(.teal)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.name)
                                    .font(.system(size: 12, weight: .medium))
                                Text(action.type.displayName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                consentStore.revoke(
                                    bundleId: summary.bundleID,
                                    actionId: action.id)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Revoke always-allow for \(action.name)")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor)))
            }
        }
    }

    private var credentials: some View {
        let connections = apiStore.connections(for: summary.bundleID)
        return section(
            title: "Stored Credentials",
            caption: "API keys live in your Keychain, not in Context Dock's settings files."
        ) {
            if connections.isEmpty {
                Text("No stored credentials for this integration.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(connections.enumerated()), id: \.element.id) { index, connection in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.yellow)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.name)
                                    .font(.system(size: 12, weight: .medium))
                                Text(connection.permissions.isEmpty
                                    ? connection.baseURL
                                    : connection.permissions)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Disconnect", role: .destructive) {
                                apiStore.disconnect(id: connection.id)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Disconnect \(connection.name)")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor)))
            }
        }
    }

    private var declaredScope: some View {
        section(
            title: "Declared Scope",
            caption: "What this integration can reach when it runs."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                scopeLine(
                    "Runs \(summary.counts.actions) action\(summary.counts.actions == 1 ? "" : "s") against \(summary.appName)",
                    icon: "bolt")
                if summary.counts.cliTools > 0 {
                    scopeLine(
                        "Can call \(summary.counts.cliTools) linked CLI tool\(summary.counts.cliTools == 1 ? "" : "s") in your shell",
                        icon: "terminal")
                }
                if summary.counts.mcpServers > 0 {
                    scopeLine(
                        "Can reach \(summary.counts.mcpServers) MCP server\(summary.counts.mcpServers == 1 ? "" : "s")",
                        icon: "server.rack")
                }
                if summary.counts.contextReaders > 0 {
                    scopeLine(
                        "Reads \(summary.counts.contextReaders) context source\(summary.counts.contextReaders == 1 ? "" : "s") from the app",
                        icon: "doc.text.magnifyingglass")
                }
                if summary.counts.skills > 0 {
                    scopeLine(
                        "\(summary.counts.skills) skill\(summary.counts.skills == 1 ? "" : "s") steer chat only — no execution",
                        icon: "brain.head.profile")
                }
            }
        }
    }

    private func scopeLine(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
            Spacer()
        }
    }

    private var removal: some View {
        section(
            title: "Remove Integration",
            caption: "Deletes this integration's own records. Shared resources stay."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(removalMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Remove Integration…", role: .destructive) {
                    showRemoveConfirmation = true
                }
                .accessibilityLabel("Remove \(summary.appName) integration")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red.opacity(0.08)))
        }
    }

    private var removalMessage: String {
        let preview = self.preview
        var lines = ["Deletes \(preview.removedActionCount) action\(preview.removedActionCount == 1 ? "" : "s")."]

        if preview.unlinkedCLIToolCount > 0 {
            lines.append(
                "Unlinks \(preview.unlinkedCLIToolCount) CLI tool\(preview.unlinkedCLIToolCount == 1 ? "" : "s") — the tools themselves stay installed.")
        }

        var kept: [String] = []
        if preview.retainedSkillCount > 0 {
            kept.append("\(preview.retainedSkillCount) skill\(preview.retainedSkillCount == 1 ? "" : "s")")
        }
        if preview.retainedMCPCount > 0 {
            kept.append("\(preview.retainedMCPCount) MCP server\(preview.retainedMCPCount == 1 ? "" : "s")")
        }
        if preview.retainedAPIConnectionCount > 0 {
            kept.append(
                "\(preview.retainedAPIConnectionCount) API connection\(preview.retainedAPIConnectionCount == 1 ? "" : "s") (keys stay in your Keychain)")
        }
        if !kept.isEmpty {
            lines.append("Keeps \(kept.joined(separator: ", ")).")
        }
        if !preview.retainedSharedResourceNames.isEmpty {
            lines.append(
                "Still used elsewhere: \(preview.retainedSharedResourceNames.joined(separator: ", ")).")
        }
        return lines.joined(separator: " ")
    }

    private func section<Content: View>(
        title: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }
}
