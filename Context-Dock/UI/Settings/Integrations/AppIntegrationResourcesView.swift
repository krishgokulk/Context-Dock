import SwiftUI

/// A collapsible group of one resource kind, with its count on the header so the shape of an
/// integration is readable without opening anything. Empty groups start closed.
struct IntegrationResourceSection<Item: Identifiable, Row: View>: View {
    let title: String
    let icon: String
    let count: Int
    let emptyMessage: String
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    @State private var isExpanded: Bool?

    private var expanded: Bool { isExpanded ?? !items.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded = !expanded
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(items.isEmpty ? .tertiary : .secondary)
                        .frame(width: 16)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue("\(count)")

            if expanded {
                if items.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)
                        .padding(.top, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            row(item)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor)))
                    .padding(.top, 8)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Everything an integration can draw on: what steers the model, what it can call, and what
/// it can read. Rows manage what already exists; creation arrives with the Add menu.
struct AppIntegrationResourcesView: View {
    let summary: AppIntegrationSummary

    @ObservedObject private var skillStore = SkillStore.shared
    @ObservedObject private var apiStore = APIConnectionStore.shared
    @ObservedObject private var mcpManager = MCPServerManager.shared
    @ObservedObject private var packageManager = TerminalPackageManager.shared
    @ObservedObject private var adapterManager = AppAdapterManager.shared

    @State private var editingSkill: AdapterSkill?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                skillsSection
                cliSection
                mcpSection
                apiSection
                shortcutsSection
                readersSection
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
    }

    // MARK: - Sections

    private var skillsSection: some View {
        IntegrationResourceSection(
            title: "Skills",
            icon: "brain.head.profile",
            count: summary.skills.count,
            emptyMessage: "No skills yet. Skills steer scoped chat; they never grant execution.",
            items: summary.skills
        ) { skill in
            resourceRow(
                title: skill.name,
                subtitle: "Steers chat · v\(skill.version)",
                icon: "brain.head.profile",
                tint: .purple,
                isOn: Binding(
                    get: { skill.isEnabled },
                    set: { skillStore.setEnabled($0, id: skill.id) }),
                trailing: {
                    AnyView(HStack(spacing: 8) {
                        Button { editingSkill = skill } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit \(skill.name)")
                        Button(role: .destructive) {
                            skillStore.remove(id: skill.id)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(skill.name)")
                    })
                })
        }
    }

    private var cliSection: some View {
        IntegrationResourceSection(
            title: "CLI Tools",
            icon: "terminal",
            count: summary.cliTools.count,
            emptyMessage: "No CLI tools linked to this app.",
            items: summary.cliTools
        ) { package in
            resourceRow(
                title: package.name,
                subtitle: package.isInstalled
                    ? "\(package.command) · installed"
                    : "\(package.command) · not installed",
                icon: "terminal",
                tint: package.isInstalled ? .blue : .orange,
                isOn: nil,
                trailing: {
                    AnyView(Button("Unlink") { unlinkPackage(package) }
                        .controlSize(.small)
                        .accessibilityLabel("Unlink \(package.name) from \(summary.appName)"))
                })
        }
    }

    private var mcpSection: some View {
        IntegrationResourceSection(
            title: "MCP Servers",
            icon: "server.rack",
            count: summary.mcpServers.count,
            emptyMessage: "No MCP servers linked to this app.",
            items: summary.mcpServers
        ) { server in
            resourceRow(
                title: server.name,
                subtitle: "\(server.transport) · \(server.command)",
                icon: "server.rack",
                tint: .orange,
                isOn: nil,
                trailing: {
                    AnyView(Button("Unlink") {
                        mcpManager.unlink(id: server.id, from: summary.bundleID)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Unlink \(server.name) from \(summary.appName)"))
                })
        }
    }

    private var apiSection: some View {
        IntegrationResourceSection(
            title: "API Connections",
            icon: "link",
            count: summary.apiConnections.count,
            emptyMessage: "No API connected. Keys are stored in your Keychain.",
            items: summary.apiConnections
        ) { connection in
            resourceRow(
                title: connection.name,
                subtitle: "\(connection.baseURL) · \(connection.status.rawValue)",
                icon: "link",
                tint: connection.status == .connected ? .green : .orange,
                isOn: nil,
                trailing: {
                    AnyView(Button("Disconnect", role: .destructive) {
                        apiStore.disconnect(id: connection.id)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Disconnect \(connection.name)"))
                })
        }
    }

    private var shortcutsSection: some View {
        IntegrationResourceSection(
            title: "Shortcuts",
            icon: "command",
            count: summary.shortcuts.count,
            emptyMessage: "No macOS Shortcuts linked to this app.",
            items: summary.shortcuts
        ) { shortcut in
            resourceRow(
                title: shortcut.name,
                subtitle: "macOS Shortcut",
                icon: "command",
                tint: .purple,
                isOn: nil,
                trailing: {
                    AnyView(Button(role: .destructive) {
                        Task {
                            await adapterManager.deleteAction(
                                id: shortcut.id,
                                from: summary.bundleID)
                        }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(shortcut.name)"))
                })
        }
    }

    private var readersSection: some View {
        IntegrationResourceSection(
            title: "Context Readers",
            icon: "doc.text.magnifyingglass",
            count: summary.contextReaders.count,
            emptyMessage: "No context readers declared by this integration.",
            items: summary.contextReaders
        ) { reader in
            resourceRow(
                title: reader.name,
                subtitle: reader.type,
                icon: "doc.text.magnifyingglass",
                tint: .teal,
                isOn: nil,
                trailing: { AnyView(EmptyView()) })
        }
    }

    // MARK: - Row

    private func resourceRow(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        isOn: Binding<Bool>?,
        trailing: () -> AnyView
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let isOn {
                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("\(title) enabled")
            }

            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func unlinkPackage(_ package: TerminalPackage) {
        var updated = package
        updated.contextAppBundleIds.removeAll { $0 == summary.bundleID }
        packageManager.updatePackage(updated)
    }
}
