import SwiftUI

/// The one Settings destination for capabilities: Apps on one side of the scope switch,
/// Global on the other.
///
/// The page reads the existing managers and composes them into a snapshot once per body
/// evaluation; every display value below comes from that composition. The managers stay the
/// owners of persistence and mutation — nothing here writes.
struct IntegrationsSettingsPage: View {
    let destination: IntegrationDestination?

    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @ObservedObject private var skillStore = SkillStore.shared
    @ObservedObject private var packageManager = TerminalPackageManager.shared
    @ObservedObject private var mcpManager = MCPServerManager.shared
    @ObservedObject private var apiStore = APIConnectionStore.shared
    @ObservedObject private var layeredExtensions = LayeredExtensionManager.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var selection = IntegrationSelectionState()
    @State private var query = ""

    var body: some View {
        let inventory = inventory
        let apps = IntegrationInventoryBuilder.filter(inventory.apps, query: query)

        return VStack(spacing: 0) {
            SettingsPageHeader(page: .integrations)
            Divider()

            HStack(spacing: 0) {
                IntegrationBrowserView(
                    scope: $selection.scope,
                    query: $query,
                    selectedAppID: $selection.selectedAppID,
                    apps: apps,
                    global: inventory.global
                )
                .frame(width: 250)

                Divider()

                detail(apps: apps, global: inventory.global)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let destination { selection.apply(destination) }
            selection.reconcile(availableAppIDs: apps.map(\.id))
        }
        .onChange(of: destination) { _, newValue in
            guard let newValue else { return }
            selection.apply(newValue)
        }
        .onChange(of: apps.map(\.id)) { _, ids in
            selection.reconcile(availableAppIDs: ids)
        }
    }

    // MARK: - Composition

    /// Global CLI scope is resolved here, by the manager that owns that meaning, so the pure
    /// builder never has to consult a store to tell app scope from global scope.
    private var inventory: IntegrationInventory {
        let packages = packageManager.packages
        let globalPackageIDs = Set(
            packages
                .filter(packageManager.isUserAddedGlobalScope)
                .map(\.id))

        return IntegrationInventoryBuilder.build(from: IntegrationInventorySnapshot(
            adapters: adapterManager.adapters,
            skills: skillStore.skills,
            packages: packages,
            globalPackageIDs: globalPackageIDs,
            mcpServers: mcpManager.servers,
            apiConnections: apiStore.connections,
            extensions: layeredExtensions.allExtensions,
            selectionRules: settings.axTriggerRules,
            commands: SystemCommandsRegistry.shared.commands))
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(
        apps: [AppIntegrationSummary],
        global: GlobalIntegrationSummary
    ) -> some View {
        switch selection.scope {
        case .apps:
            if let id = selection.selectedAppID,
               let app = apps.first(where: { $0.id == id }) {
                AppIntegrationDetailView(summary: app, selectedTab: $selection.tab)
            } else {
                emptyDetail(
                    icon: "app.dashed",
                    title: "No integration selected",
                    message: "Choose an app on the left to see its actions and resources.")
            }
        case .global:
            globalDetail(global)
        }
    }

    private func globalDetail(_ global: GlobalIntegrationSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Global")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Capabilities available everywhere, not tied to one app.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                tabPicker

                countGrid([
                    ("Commands", global.commands.count),
                    ("Selection actions", global.selectionExtensions.count),
                    ("Legacy selection rules", global.selectionRules.count),
                    ("CLI tools", global.cliTools.count),
                    ("MCP servers", global.mcpServers.count)
                ])
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tabPicker: some View {
        Picker("Section", selection: $selection.tab) {
            ForEach(IntegrationDetailTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Integration section")
    }

    private func countGrid(_ entries: [(String, Int)]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(entries, id: \.0) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.1)")
                        .font(.system(size: 18, weight: .semibold))
                    Text(entry.0)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(entry.0)
                .accessibilityValue("\(entry.1)")
            }
        }
    }

    private func emptyDetail(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
