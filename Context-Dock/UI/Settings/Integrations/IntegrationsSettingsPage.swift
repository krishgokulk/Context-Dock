import SwiftUI

/// The one Settings destination for capabilities: Apps on one side of the scope switch,
/// Global on the other.
///
/// The page reads the existing managers and composes them into a snapshot once per body
/// evaluation; every display value below comes from that composition. The managers stay the
/// owners of persistence and mutation — this page only presents their editors.
struct IntegrationsSettingsPage: View {
    let destination: IntegrationDestination?

    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @ObservedObject private var skillStore = SkillStore.shared
    @ObservedObject private var packageManager = TerminalPackageManager.shared
    @ObservedObject private var mcpManager = MCPServerManager.shared
    @ObservedObject private var apiStore = APIConnectionStore.shared
    @ObservedObject private var layeredExtensions = LayeredExtensionManager.shared
    @ObservedObject private var userExtensions = UserGlobalExtensionStore.shared
    @ObservedObject private var commandsObserver = SystemCommandsRegistryObserver.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var selection = IntegrationSelectionState()
    @State private var query = ""

    // Creation flows, each presenting the editor that already owns that capability.
    @State private var showAdapterSheet = false
    @State private var showActionEditor = false
    @State private var showSkillEditor: AdapterSkill?
    @State private var showAppCLIPicker = false
    @State private var showGlobalCLIPicker = false
    @State private var showMCPSheet = false
    @State private var showShortcutPicker = false
    @State private var showAPIConnectSheet = false
    @State private var showCommandSheet = false
    @State private var showSelectionActionSheet = false
    @State private var importPreview: AdapterPackPreview?
    @State private var importError: String?

    var body: some View {
        let inventory = inventory
        let apps = IntegrationInventoryBuilder.filter(inventory.apps, query: query)
        let selectedApp = apps.first { $0.id == selection.selectedAppID }

        return VStack(spacing: 0) {
            headerBar
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

                detail(selectedApp: selectedApp, global: inventory.global)
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
        .modifier(IntegrationCreationSheets(
            bundleID: selectedApp?.bundleID,
            appName: selectedApp?.appName,
            linkedPackageIDs: Set((selectedApp?.cliTools ?? []).map(\.id)),
            linkedShortcutNames: Set((selectedApp?.shortcuts ?? [])
                .map { ($0.shortcutName ?? $0.name).lowercased() }),
            showAdapterSheet: $showAdapterSheet,
            showActionEditor: $showActionEditor,
            showSkillEditor: $showSkillEditor,
            showAppCLIPicker: $showAppCLIPicker,
            showGlobalCLIPicker: $showGlobalCLIPicker,
            showMCPSheet: $showMCPSheet,
            showShortcutPicker: $showShortcutPicker,
            showAPIConnectSheet: $showAPIConnectSheet,
            showCommandSheet: $showCommandSheet,
            showSelectionActionSheet: $showSelectionActionSheet,
            importPreview: $importPreview,
            importError: $importError,
            onAdapterCreated: { bundleID in selection.selectedAppID = bundleID }))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            SettingsPageHeader(page: .integrations)
            Spacer(minLength: 0)
            IntegrationAddMenu(
                actions: IntegrationAddAction.available(
                    scope: selection.scope,
                    tab: selection.tab),
                perform: perform)
                .padding(.trailing, 24)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Composition

    /// Global CLI scope is resolved here, by the manager that owns that meaning, so the pure
    /// builder never has to consult a store to tell app scope from global scope.
    private var inventory: IntegrationInventory {
        // Referenced so SwiftUI re-composes when the non-observable command registry changes.
        _ = commandsObserver.revision

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
        selectedApp: AppIntegrationSummary?,
        global: GlobalIntegrationSummary
    ) -> some View {
        switch selection.scope {
        case .apps:
            if let selectedApp {
                AppIntegrationDetailView(summary: selectedApp, selectedTab: $selection.tab)
            } else {
                emptyDetail(
                    icon: "app.dashed",
                    title: "No integration selected",
                    message: "Choose an app on the left, or add one from the Add menu.")
            }
        case .global:
            GlobalIntegrationDetailView(summary: global, selectedTab: $selection.tab)
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

    // MARK: - Add

    private func perform(_ action: IntegrationAddAction) {
        switch action {
        case .chooseApp:
            showAdapterSheet = true
        case .importIntegration:
            guard let url = AdapterPackImporter.shared.pickPack() else { return }
            do {
                importPreview = try AdapterPackImporter.shared.loadPreview(from: url)
            } catch {
                importError = error.localizedDescription
            }
        case .addAction:
            showActionEditor = true
        case .addSkill:
            guard let bundleID = selection.selectedAppID else { return }
            showSkillEditor = AdapterSkill(
                adapterBundleId: bundleID,
                name: "",
                instructions: "")
        case .addCLITool:
            if selection.scope == .global {
                showGlobalCLIPicker = true
            } else {
                showAppCLIPicker = true
            }
        case .addMCPServer:
            showMCPSheet = true
        case .connectAPI:
            showAPIConnectSheet = true
        case .linkShortcut:
            showShortcutPicker = true
        case .addCommand:
            showCommandSheet = true
        case .addSelectionAction:
            showSelectionActionSheet = true
        }
    }
}

/// Every creation editor the workspace can present, kept out of the page body so the page
/// stays readable. Each case hands off to the sheet that already owns that capability.
private struct IntegrationCreationSheets: ViewModifier {
    let bundleID: String?
    let appName: String?
    let linkedPackageIDs: Set<UUID>
    let linkedShortcutNames: Set<String>

    @Binding var showAdapterSheet: Bool
    @Binding var showActionEditor: Bool
    @Binding var showSkillEditor: AdapterSkill?
    @Binding var showAppCLIPicker: Bool
    @Binding var showGlobalCLIPicker: Bool
    @Binding var showMCPSheet: Bool
    @Binding var showShortcutPicker: Bool
    @Binding var showAPIConnectSheet: Bool
    @Binding var showCommandSheet: Bool
    @Binding var showSelectionActionSheet: Bool
    @Binding var importPreview: AdapterPackPreview?
    @Binding var importError: String?
    let onAdapterCreated: (String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showAdapterSheet) {
                NewAdapterSheet { appName, bundleId, icon in
                    Task {
                        await AppAdapterManager.shared.createAdapter(
                            appName: appName,
                            bundleId: bundleId,
                            icon: icon)
                        await MainActor.run {
                            onAdapterCreated(bundleId)
                            showAdapterSheet = false
                        }
                    }
                }
            }
            .sheet(isPresented: $showActionEditor) {
                if let bundleID {
                    AdapterActionEditorSheet(bundleId: bundleID, existing: nil) {
                        showActionEditor = false
                    }
                }
            }
            .sheet(item: $showSkillEditor) { skill in
                SkillEditorSheet(skill: skill) { saved in
                    if let saved { SkillStore.shared.upsert(saved) }
                    showSkillEditor = nil
                }
            }
            .sheet(isPresented: $showAppCLIPicker) {
                if let bundleID {
                    AppCLIToolPickerSheet(
                        appName: appName ?? bundleID,
                        bundleId: bundleID,
                        alreadyLinked: linkedPackageIDs)
                }
            }
            .sheet(isPresented: $showGlobalCLIPicker) {
                GlobalCLIToolPickerSheet { package in
                    AppSettings.shared.pinCLITool(package.command)
                    showGlobalCLIPicker = false
                }
            }
            .sheet(isPresented: $showMCPSheet) {
                if let bundleID {
                    AddMCPServerSheet(appName: appName ?? bundleID, bundleId: bundleID)
                }
            }
            .sheet(isPresented: $showShortcutPicker) {
                if let bundleID {
                    AppShortcutPickerSheet(
                        appName: appName ?? bundleID,
                        bundleId: bundleID,
                        alreadyLinked: linkedShortcutNames,
                        onPick: { shortcut in linkShortcut(shortcut, to: bundleID) })
                }
            }
            .sheet(isPresented: $showAPIConnectSheet) {
                if let bundleID {
                    IntegrationAPIConnectSheet(
                        appName: appName ?? bundleID,
                        bundleID: bundleID,
                        onDone: { showAPIConnectSheet = false })
                }
            }
            .sheet(isPresented: $showCommandSheet) {
                SystemCommandCreateSheet { command in
                    SystemCommandsRegistry.shared.add(command)
                    SystemCommandsRegistryObserver.shared.reload()
                    showCommandSheet = false
                }
            }
            .sheet(isPresented: $showSelectionActionSheet) {
                UserGlobalExtensionCreateSheet { ext in
                    UserGlobalExtensionStore.shared.add(ext)
                    showSelectionActionSheet = false
                }
            }
            .sheet(item: $importPreview) { preview in
                AdapterPackImportPreviewSheet(
                    preview: preview,
                    onCancel: { importPreview = nil },
                    onImport: {
                        Task {
                            let ok = await AdapterPackImporter.shared.install(preview)
                            await MainActor.run {
                                importPreview = nil
                                if !ok { importError = "Couldn't install the integration." }
                            }
                        }
                    })
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } })
            ) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
    }

    /// Same shape the App Adapters page writes, so a shortcut linked from either place is
    /// the same record.
    private func linkShortcut(_ shortcut: MacShortcut, to bundleID: String) {
        let name = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !linkedShortcutNames.contains(name.lowercased()) else { return }

        let action = AdapterAction(
            id: "shortcut-\(UUID().uuidString.prefix(8))",
            name: name,
            icon: shortcut.iconName,
            description: "Run the “\(name)” shortcut",
            triggers: [name],
            type: .shortcut,
            shortcutName: name,
            accentColor: shortcut.accentColor)
        Task { await AppAdapterManager.shared.appendAction(action, to: bundleID) }
    }
}

/// Connects an API to one app integration. The key never lands in Context Dock's settings
/// files — `APIConnectionStore` writes it to the Keychain.
private struct IntegrationAPIConnectSheet: View {
    let appName: String
    let bundleID: String
    let onDone: () -> Void

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an API to \(appName)")
                .font(.system(size: 15, weight: .semibold))
            Text("Scoped chat can call this service. The key is stored in your Keychain.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Name", text: $name)
            TextField("Base URL", text: $baseURL)
            SecureField("API Key", text: $apiKey)

            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                Button("Connect") {
                    _ = APIConnectionStore.shared.connect(
                        name: name.trimmingCharacters(in: .whitespaces),
                        baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                        apiKey: apiKey,
                        bundleId: bundleID)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty
                        || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                        || apiKey.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 420)
    }
}
