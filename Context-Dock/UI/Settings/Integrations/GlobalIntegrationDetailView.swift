import Combine
import SwiftUI

/// Capabilities that belong to no single app.
///
/// Global uses the same section grammar as an app integration, but its contents are only
/// what the user deliberately granted: commands they wrote, selection actions they created,
/// and CLI tools they pinned. Nothing discovered on PATH appears here on its own.
struct GlobalIntegrationDetailView: View {
    let summary: GlobalIntegrationSummary
    @Binding var selectedTab: IntegrationDetailTab

    @ObservedObject private var commandsRegistry = SystemCommandsRegistryObserver.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Section", selection: $selectedTab) {
                ForEach(IntegrationDetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityLabel("Global section")

            Divider()
            tabContent
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.indigo.gradient)
                    .frame(width: 38, height: 38)
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Global")
                    .font(.system(size: 18, weight: .semibold))
                Text("Available everywhere, regardless of which app is in front.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            overview
        case .actions:
            actions
        case .resources:
            resources
        case .access:
            access
        }
    }

    // MARK: - Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Only capabilities you granted globally appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    countTile("Commands", summary.commands.count, "globe")
                    countTile("Selection actions", summary.selectionExtensions.count, "selection.pin.in.out")
                    countTile("Legacy selection rules", summary.selectionRules.count, "scope")
                    countTile("CLI tools", summary.cliTools.count, "terminal")
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func countTile(_ title: String, _ value: Int, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(value == 0 ? .tertiary : .secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12))
            Spacer(minLength: 6)
            Text("\(value)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
    }

    // MARK: - Actions

    private var actions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                IntegrationResourceSection(
                    title: "Commands",
                    icon: "globe",
                    count: summary.commands.count,
                    emptyMessage: "No global commands yet.",
                    items: summary.commands
                ) { command in
                    row(
                        title: command.name,
                        subtitle: command.description.isEmpty
                            ? command.scriptType
                            : command.description,
                        icon: command.icon,
                        tint: .indigo,
                        isOn: Binding(
                            get: { command.isEnabled },
                            set: { newValue in
                                var updated = command
                                updated.isEnabled = newValue
                                SystemCommandsRegistry.shared.update(updated)
                                commandsRegistry.reload()
                            }),
                        trailing: {
                            AnyView(Button(role: .destructive) {
                                SystemCommandsRegistry.shared.remove(command)
                                commandsRegistry.reload()
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(command.name)"))
                        })
                }

                IntegrationResourceSection(
                    title: "Selection Actions",
                    icon: "selection.pin.in.out",
                    count: summary.selectionExtensions.count,
                    emptyMessage: "No selection actions yet.",
                    items: summary.selectionExtensions
                ) { item in
                    row(
                        title: item.name,
                        subtitle: item.description.isEmpty
                            ? "Selection Scope extension"
                            : item.description,
                        icon: item.icon,
                        tint: .teal,
                        isOn: nil,
                        trailing: { AnyView(EmptyView()) })
                }

                // Kept as its own group: legacy rules are a different model with different
                // execution semantics, and merging them would blur which engine runs what.
                IntegrationResourceSection(
                    title: "Legacy Selection Rules",
                    icon: "scope",
                    count: summary.selectionRules.count,
                    emptyMessage: "No legacy selection rules.",
                    items: summary.selectionRules
                ) { rule in
                    row(
                        title: rule.name,
                        subtitle: "\(rule.conditions.count) condition\(rule.conditions.count == 1 ? "" : "s") · \(rule.pills.count) pill\(rule.pills.count == 1 ? "" : "s")",
                        icon: rule.pills.first?.icon ?? "scope",
                        tint: .red,
                        isOn: Binding(
                            get: { rule.isEnabled },
                            set: { newValue in
                                guard let index = settings.axTriggerRules
                                    .firstIndex(where: { $0.id == rule.id }) else { return }
                                settings.axTriggerRules[index].isEnabled = newValue
                            }),
                        trailing: { AnyView(EmptyView()) })
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Resources

    private var resources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                IntegrationResourceSection(
                    title: "CLI Tools",
                    icon: "terminal",
                    count: summary.cliTools.count,
                    emptyMessage: "No CLI tools pinned for global use.",
                    items: summary.cliTools
                ) { package in
                    row(
                        title: package.name,
                        subtitle: globalCLISubtitle(package),
                        icon: "terminal",
                        tint: package.isInstalled ? .blue : .orange,
                        isOn: nil,
                        trailing: {
                            AnyView(Group {
                                // Only a pin can be undone here. Global scope earned through
                                // an adapter link is unpinned where that link lives.
                                if settings.isCLIToolPinned(package.command) {
                                    Button("Unpin") {
                                        settings.unpinCLITool(package.command)
                                    }
                                    .controlSize(.small)
                                    .accessibilityLabel("Unpin \(package.name)")
                                }
                            })
                        })
                }

                mcpNote
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func globalCLISubtitle(_ package: TerminalPackage) -> String {
        let state = package.isInstalled ? "installed" : "not installed"
        let reason = settings.isCLIToolPinned(package.command) ? "pinned" : "linked by an app"
        return "\(package.command) · \(state) · \(reason)"
    }

    private var mcpNote: some View {
        IntegrationResourceSection(
            title: "MCP Servers",
            icon: "server.rack",
            count: summary.mcpServers.count,
            emptyMessage: "MCP servers are linked to an app, not to Global. Add one from an app's Resources.",
            items: summary.mcpServers
        ) { server in
            row(
                title: server.name,
                subtitle: "\(server.transport) · \(server.command)",
                icon: "server.rack",
                tint: .orange,
                isOn: nil,
                trailing: { AnyView(EmptyView()) })
        }
    }

    // MARK: - Access

    private var access: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Global capabilities run with the permissions you granted Context Dock itself.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(
                    "Commands and selection actions run shell, AppleScript, or JavaScript you wrote.",
                    systemImage: "terminal")
                    .font(.system(size: 12))
                Label(
                    "Pinned CLI tools can be called in any scope, including chat.",
                    systemImage: "terminal.fill")
                    .font(.system(size: 12))

                Button("Open Permissions…") {
                    NotificationCenter.default.post(
                        name: .openSettingsPage,
                        object: nil,
                        userInfo: ["page": SettingsPage.permissions.rawValue])
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Row

    private func row(
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
}

/// `SystemCommandsRegistry` is not observable, so this publishes its changes to SwiftUI
/// without changing how the registry itself stores commands.
final class SystemCommandsRegistryObserver: ObservableObject {
    static let shared = SystemCommandsRegistryObserver()

    @Published private(set) var revision = 0

    private init() {}

    func reload() {
        revision &+= 1
    }
}
