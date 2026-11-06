import SwiftUI

/// Unified "Capabilities & Skills" tab for an app integration (Spec 2026-11-05 §2.2).
///
/// Replaces the old 5-tab / 8-bucket developer breakdown with one unified Capabilities list
/// (displaying each tool's intent, trigger, and Read/Write safety classification) and one
/// Skills section for reusable steering instructions.
struct AppIntegrationCapabilitiesView: View {
    let summary: AppIntegrationSummary
    let onAddCapability: () -> Void
    let onEditCapability: (AdapterAction) -> Void
    let onRemoveCapability: (AdapterAction) -> Void

    @ObservedObject private var skillStore = SkillStore.shared
    @ObservedObject private var apiStore = APIConnectionStore.shared
    @ObservedObject private var mcpManager = MCPServerManager.shared
    @ObservedObject private var packageManager = TerminalPackageManager.shared
    @ObservedObject private var adapterManager = AppAdapterManager.shared

    @State private var editingSkill: AdapterSkill?
    @State private var showLiveMenus = false
    @State private var showCLIPicker = false
    @State private var showUTCPConnect = false
    @State private var isEnriching = false
    @State private var enrichmentStatus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusAndHealthHeader
                capabilitiesSection
                discoveredCLIsSection
                liveMenuSection
                skillsSection
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editingSkill) { skill in
            SkillEditorSheet(skill: skill) { saved in
                if let saved { skillStore.upsert(saved) }
                editingSkill = nil
            }
        }
        .sheet(isPresented: $showCLIPicker) {
            AppCLIToolPickerSheet(
                appName: summary.appName,
                bundleId: summary.bundleID,
                alreadyLinked: Set(summary.cliTools.map(\.id)))
        }
        .sheet(isPresented: $showUTCPConnect) {
            IntegrationAPIConnectSheet(
                appName: summary.appName,
                bundleID: summary.bundleID) {
                showUTCPConnect = false
            }
        }
    }

    // MARK: - Status & Health

    private var isEnabled: Bool {
        summary.adapter?.isEnabled ?? true
    }

    private var isBuiltIn: Bool {
        summary.adapter?.isBuiltIn == true || summary.adapter == nil
    }

    private var statusAndHealthHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isEnabled ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(isEnabled ? "Enabled" : "Disabled")
                    .font(.system(size: 12, weight: .medium))
                if isBuiltIn {
                    Text("Built-in")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                if case .healthy = summary.health {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.green)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Integration status")
            .accessibilityValue(isEnabled ? "Enabled" : "Disabled")

            if case .needsAttention(let warnings) = summary.health {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.10)))
            }
        }
    }

    // MARK: - Unified Capabilities

    private struct UnifiedCapabilityRowItem: Identifiable {
        enum Safety: String {
            case read = "Read"
            case write = "Write"
        }

        let id: String
        let icon: String
        let tint: Color
        let title: String
        let intent: String
        let triggerText: String
        let safety: Safety
        let editableAction: AdapterAction?
        let onDelete: (() -> Void)?
    }

    private var unifiedCapabilities: [UnifiedCapabilityRowItem] {
        var rows: [UnifiedCapabilityRowItem] = []

        // 1. App & Browser Actions
        for action in summary.appActions + summary.browserActions {
            let isWrite = action.requiresApproval || action.isDestructive || Self.looksMutating(action.name)
            let triggers = action.triggers.isEmpty ? action.type.displayName : action.triggers.prefix(3).joined(separator: ", ")
            let intent = action.description.isEmpty ? action.type.displayName : action.description
            rows.append(
                UnifiedCapabilityRowItem(
                    id: "action:\(action.id)",
                    icon: action.icon.isEmpty ? "bolt.fill" : action.icon,
                    tint: .teal,
                    title: action.name,
                    intent: intent,
                    triggerText: "Trigger: \(triggers)",
                    safety: isWrite ? .write : .read,
                    editableAction: action,
                    onDelete: { onRemoveCapability(action) }))
        }

        // 2. Direct UTCP / OpenAPI Connections
        for connection in summary.apiConnections {
            let toolLabel = connection.toolCount > 0
                ? "\(connection.toolCount) direct UTCP endpoint\(connection.toolCount == 1 ? "" : "s")"
                : "Direct HTTP endpoint"
            rows.append(
                UnifiedCapabilityRowItem(
                    id: "utcp:\(connection.id)",
                    icon: "link",
                    tint: connection.status == .connected ? .green : .orange,
                    title: connection.name,
                    intent: "\(toolLabel) · \(connection.baseURL)",
                    triggerText: "Trigger: UTCP / OpenAPI",
                    safety: .read,
                    editableAction: nil,
                    onDelete: { apiStore.disconnect(id: connection.id) }))
        }

        // 3. Linked Shortcuts
        for shortcut in summary.shortcuts {
            rows.append(
                UnifiedCapabilityRowItem(
                    id: "shortcut:\(shortcut.id)",
                    icon: "command",
                    tint: .purple,
                    title: shortcut.name,
                    intent: shortcut.description.isEmpty ? "Runs macOS Shortcut" : shortcut.description,
                    triggerText: "Trigger: \(shortcut.shortcutName ?? shortcut.name)",
                    safety: .write,
                    editableAction: nil,
                    onDelete: {
                        Task {
                            await adapterManager.deleteAction(id: shortcut.id, from: summary.bundleID)
                        }
                    }))
        }

        // 4. Linked CLI Tools
        for package in summary.cliTools {
            rows.append(
                UnifiedCapabilityRowItem(
                    id: "cli:\(package.id.uuidString)",
                    icon: "terminal",
                    tint: package.isInstalled ? .blue : .orange,
                    title: package.name,
                    intent: package.description.isEmpty ? "Command-line tool (\(package.command))" : package.description,
                    triggerText: "Trigger: \(package.command)",
                    safety: .read,
                    editableAction: nil,
                    onDelete: {
                        var updated = package
                        updated.contextAppBundleIds.removeAll { $0 == summary.bundleID }
                        packageManager.updatePackage(updated)
                    }))
        }

        // 5. Linked MCP Servers
        for server in summary.mcpServers {
            rows.append(
                UnifiedCapabilityRowItem(
                    id: "mcp:\(server.id.uuidString)",
                    icon: "server.rack",
                    tint: .orange,
                    title: server.name,
                    intent: "Connected tool server (\(server.transport))",
                    triggerText: "Trigger: \(server.command)",
                    safety: .read,
                    editableAction: nil,
                    onDelete: {
                        mcpManager.unlink(id: server.id, from: summary.bundleID)
                    }))
        }

        // 6. Context Readers
        for reader in summary.contextReaders {
            rows.append(
                UnifiedCapabilityRowItem(
                    id: "reader:\(reader.id)",
                    icon: "doc.text.magnifyingglass",
                    tint: .teal,
                    title: reader.name,
                    intent: "Reads live context from \(summary.appName)",
                    triggerText: "Trigger: Automatic context read",
                    safety: .read,
                    editableAction: nil,
                    onDelete: nil))
        }

        return rows
    }

    private static func looksMutating(_ name: String) -> Bool {
        let words = name.lowercased().split { !$0.isLetter }.map(String.init)
        let writeVerbs: Set<String> = [
            "send", "create", "new", "delete", "remove", "archive", "move",
            "rename", "export", "save", "close", "quit", "clear", "post", "update"
        ]
        return words.contains { writeVerbs.contains($0) }
    }

    private var capabilitiesSection: some View {
        let items = unifiedCapabilities
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capabilities · \(items.count)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("What DoraX can do in \(summary.appName) — native tools, direct UTCP endpoints, and actions.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    Task {
                        isEnriching = true
                        enrichmentStatus = nil
                        let result = await AutonomousAppDiscoveryEngine.enrich(
                            bundleId: summary.bundleID,
                            appName: summary.appName)
                        isEnriching = false
                        enrichmentStatus = "Enriched (v\(result.version))"
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        enrichmentStatus = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isEnriching {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "globe")
                        }
                        Text(enrichmentStatus ?? "Enrich Knowledge")
                    }
                }
                .controlSize(.small)
                .disabled(isEnriching)
                .help("Offline enrichment: extracts URL schemes, CLI tools, and documentation once per version into AGENT.md and skills")

                Menu {
                    Button {
                        onAddCapability()
                    } label: {
                        Label("🌟 AI Action / Goal", systemImage: "sparkles")
                    }
                    Button {
                        showCLIPicker = true
                    } label: {
                        Label("💻 Link Installed CLI Tool…", systemImage: "terminal")
                    }
                    Button {
                        showUTCPConnect = true
                    } label: {
                        Label("⚡️ Connect UTCP API…", systemImage: "bolt.horizontal")
                    }
                } label: {
                    Label("Add Capability", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No custom capabilities yet")
                        .font(.system(size: 12, weight: .medium))
                    Text("DoraX can still inspect live menus and AppleScript dictionaries automatically, or you can add a capability or install a pack from Store / Packs.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor)))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        capabilityRow(item)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor)))
            }
        }
    }

    // MARK: - Recommended Discovered CLI Accelerators

    private var unlinkedDiscoveredCLIs: [DiscoveredCLITool] {
        let discovered = AutonomousAppDiscoveryEngine.discoverCLITools(
            bundleId: summary.bundleID,
            appName: summary.appName)
        let linkedCommands = Set(summary.cliTools.map { $0.command.lowercased() })
        return discovered.filter { !linkedCommands.contains($0.command.lowercased()) }
    }

    @ViewBuilder
    private var discoveredCLIsSection: some View {
        let unlinked = unlinkedDiscoveredCLIs
        if !unlinked.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                    Text("Discovered Local CLI Accelerators · \(unlinked.count)")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Detected on PATH for \(summary.appName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(Array(unlinked.enumerated()), id: \.element.id) { index, cli in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.blue)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(cli.command)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    Text("Detected")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.14), in: Capsule())
                                }
                                Text(cli.path)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Button {
                                AutonomousAppDiscoveryEngine.linkCLITool(
                                    cli,
                                    toBundleId: summary.bundleID,
                                    appName: summary.appName)
                            } label: {
                                Label("Link Accelerator", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Link \(cli.command) as an accelerated tool for \(summary.appName)")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor)))
            }
        }
    }

    private func capabilityRow(_ item: UnifiedCapabilityRowItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundStyle(item.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(item.safety.rawValue)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(item.safety == .read ? .green : .orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            (item.safety == .read ? Color.green : Color.orange).opacity(0.14),
                            in: Capsule())
                }
                Text(item.intent)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.triggerText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let editable = item.editableAction {
                Button {
                    onEditCapability(editable)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Edit capability")
                .accessibilityLabel("Edit \(item.title)")
            }

            if let onDelete = item.onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Remove capability")
                .accessibilityLabel("Remove \(item.title)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Live Menu Commands

    @ViewBuilder
    private var liveMenuSection: some View {
        let leaves = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: summary.bundleID,
            appName: summary.appName,
            query: "",
            maxResults: 40)
            .filter { $0.isLeaf && !$0.path.isEmpty }

        if !leaves.isEmpty {
            DisclosureGroup(
                isExpanded: $showLiveMenus,
                content: {
                    VStack(spacing: 0) {
                        ForEach(Array(leaves.prefix(20).enumerated()), id: \.offset) { index, item in
                            if index > 0 { Divider() }
                            let pathText = item.path.joined(separator: " ▸ ")
                            let isWrite = Self.looksMutating(item.title)
                            HStack(spacing: 8) {
                                Image(systemName: "filemenu.and.selection")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(item.title)
                                    .font(.system(size: 11.5, weight: .medium))
                                Text(pathText)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(isWrite ? "Write" : "Read")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(isWrite ? .orange : .green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(
                                        (isWrite ? Color.orange : Color.green).opacity(0.14),
                                        in: Capsule())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor)))
                    .padding(.top, 6)
                },
                label: {
                    HStack(spacing: 6) {
                        Image(systemName: "filemenu.and.selection")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Live Menu Commands · \(leaves.count)")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Discovered automatically from \(summary.appName)'s menu bar")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                })
        }
    }

    // MARK: - Skills

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills · \(summary.skills.count)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Reusable workflows and instructions that steer DoraX in \(summary.appName).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editingSkill = AdapterSkill(
                        adapterBundleId: summary.bundleID,
                        name: "",
                        instructions: "")
                } label: {
                    Label("Add Skill", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if summary.skills.isEmpty {
                Text("No skills for \(summary.appName) yet. Skills steer scoped chat and multi-step workflows.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor)))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(summary.skills.enumerated()), id: \.element.id) { index, skill in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 12))
                                .foregroundStyle(.purple)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                    .font(.system(size: 12, weight: .medium))
                                Text(skill.summary.isEmpty
                                    ? "Steers \(skill.scope.label) · v\(skill.version)"
                                    : skill.summary)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Toggle("", isOn: Binding(
                                get: { skill.isEnabled },
                                set: { skillStore.setEnabled($0, id: skill.id) }))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                                .accessibilityLabel("\(skill.name) enabled")

                            Button {
                                skillStore.setPinned(!skill.isPinned, id: skill.id)
                            } label: {
                                Image(systemName: skill.isPinned ? "pin.fill" : "pin")
                            }
                            .buttonStyle(.plain)
                            .help(skill.isPinned ? "Pinned into every prompt" : "Read on demand")

                            Button {
                                editingSkill = skill
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                skillStore.remove(id: skill.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
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
}
