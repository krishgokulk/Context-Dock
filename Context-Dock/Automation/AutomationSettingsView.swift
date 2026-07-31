// AutomationSettingsView.swift
// Context-Dock
//
// Unified Automation panel — one place to create and manage
// user-owned scripts, prompts, CLI tools, triggers, and app actions.

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ApplicationServices

// MARK: - Category

enum AutomationCategory: String, CaseIterable, Identifiable {
    case scripts         = "Scripts"
    case aiPrompts       = "AI Prompts"
    case cliTools        = "CLI Tools"
    case contextTriggers = "Context Triggers"
    case appActions      = "FrontmostApp Actions"
    case clipboardActions = "Clipboard Actions"
    case menuCache       = "Menu Cache"
    case systemCommands  = "Global Actions"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .scripts:         return "scroll.fill"
        case .aiPrompts:       return "brain.head.profile"
        case .cliTools:        return "terminal.fill"
        case .contextTriggers: return "scope"
        case .appActions:      return "app.connected.to.app.below.fill"
        case .clipboardActions: return "doc.on.clipboard.fill"
        case .menuCache:       return "menubar.rectangle"
        case .systemCommands:  return "slider.horizontal.3"
        }
    }

    var color: Color {
        switch self {
        case .scripts:         return .orange
        case .aiPrompts:       return .purple
        case .cliTools:        return .green
        case .contextTriggers: return .red
        case .appActions:      return .teal
        case .clipboardActions: return .blue
        case .menuCache:       return .cyan
        case .systemCommands:  return .indigo
        }
    }

    var subtitle: String {
        switch self {
        case .scripts:         return "Bash, Python, AppleScript, JXA scripts"
        case .aiPrompts:       return "AI prompt templates with context variables"
        case .cliTools:        return "CLI binaries callable by the AI terminal"
        case .contextTriggers: return "Rules that fire based on screen context"
        case .appActions:      return "Actions bound to the current frontmost app"
        case .clipboardActions: return "Paste, transform, share, and route clipboard content"
        case .menuCache:       return "Cached app menu snapshots for Global Context"
        case .systemCommands:  return "CLI tool scopes and global commands"
        }
    }
}

private struct AppMenuCacheRowModel: Identifiable {
    let bundleId: String
    let appName: String
    let appURL: URL?
    let icon: NSImage?
    let summary: AppMenuCapabilitySummary?

    var id: String { bundleId }
    var recordCount: Int { summary?.recordCount ?? 0 }
    var isCached: Bool { recordCount > 0 }
}

// MARK: - Main View

struct AutomationSettingsView: View {
    private let settingsPage: SettingsPage?
    @ObservedObject private var settings        = AppSettings.shared
    @ObservedObject private var pkgMgr          = TerminalPackageManager.shared
    @ObservedObject private var l2Mgr           = L2ExtensionManager.shared
    @ObservedObject private var adapterMgr      = AppAdapterManager.shared

    @State private var selectedCategory: AutomationCategory = .appActions
    @State private var searchText = ""
    @State private var selectedExtensionID: UUID?
    @State private var selectedRuleID: UUID?
    @State private var selectedPackageID: UUID?
    @State private var selectedAdapterID: String?
    @State private var selectedAdapterActionID: String?
    @State private var selectedMenuCacheBundleID: String?
    @State private var selectedSystemCommandID: UUID?
    @StateObject private var sysRegistry = SystemCommandsRegistryObservable.shared
    @State private var installedAppsByBundleId: [String: InstalledApplicationEntry] = [:]
    @State private var menuCacheSummaries: [String: AppMenuCapabilitySummary] = [:]
    @State private var refreshingMenuCacheBundleID: String?
    @State private var menuCacheStatusMessage: String?
    @State private var showExtensionSheet = false
    @State private var showPackageSheet = false
    @State private var showRuleSheet = false
    @State private var showAdapterSheet = false
    @State private var showGlobalCLIPicker = false
    @State private var showSystemCommandSheet = false
    @State private var showAIImportSheet = false
    @State private var importPreview: AdapterPackPreview?
    @State private var importError: String?

    private func importAdapterPack() {
        guard let url = AdapterPackImporter.shared.pickPack() else { return }
        do {
            importPreview = try AdapterPackImporter.shared.loadPreview(from: url)
        } catch {
            importError = error.localizedDescription
        }
    }
    @State private var extensionSheetMode: AddAppExtensionSheet.Mode = .script
    @State private var showingImportPanel = false

    init(settingsPage: SettingsPage? = nil) {
        self.settingsPage = settingsPage
        let initialCategory = settingsPage?.automationCategory ?? .appActions
        _selectedCategory = State(initialValue: initialCategory)
    }

    var body: some View {
        HSplitView {
            if settingsPage == nil {
                // ── Column 1: Category sidebar ───────────────────────────
                sidebar
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 240)
            }

            if showingImportPanel {
                // ── Import panel (full width, replaces col 2+3) ──────
                AutomationImportPanel(onClose: {
                    showingImportPanel = false
                    selectedCategory = .contextTriggers
                })
                .frame(minWidth: 600)
            } else {
                // ── Column 2: Item list ──────────────────────────────
                itemList
                    .frame(minWidth: 340, idealWidth: 390, maxWidth: 480)

                // ── Column 3: Detail / Editor ────────────────────────
                detailPane
                    .frame(minWidth: 360)
            }
        }
        .sheet(isPresented: $showExtensionSheet) {
            AddAppExtensionSheet(appKey: "global", initialMode: extensionSheetMode) { ext in
                settings.addToolExtension(ext)
                focusOnExtension(ext)
            }
        }
        .sheet(isPresented: $showPackageSheet) {
            AddPackageSheet(packageManager: pkgMgr) { package in
                focusOnPackage(package.id)
            }
        }
        .sheet(isPresented: $showRuleSheet) {
            AXRuleEditSheet(rule: nil, isSelectionScope: settingsPage == .shortcutSheetWorkflows) { rule in
                settings.addAXRule(rule)
                focusOnRule(rule.id)
            }
        }
        .sheet(isPresented: $showAdapterSheet) {
            NewAdapterSheet { appName, bundleId, icon in
                Task {
                    await adapterMgr.createAdapter(appName: appName, bundleId: bundleId, icon: icon)
                    await MainActor.run {
                        focusOnAdapter(bundleId)
                        showAdapterSheet = false
                    }
                }
            }
        }
        .sheet(isPresented: $showGlobalCLIPicker) {
            GlobalCLIToolPickerSheet { package in
                settings.pinCLITool(package.command)
                focusOnGlobalCLIScope(package.id)
                showGlobalCLIPicker = false
            }
        }
        .sheet(isPresented: $showSystemCommandSheet) {
            SystemCommandCreateSheet { command in
                sysRegistry.add(command)
                clearSelection()
                selectedCategory = .systemCommands
                selectedSystemCommandID = command.id
                showSystemCommandSheet = false
            }
        }
        .sheet(isPresented: $showAIImportSheet) {
            AIExtensionImportSheet { importedExtension in
                LayeredExtensionManager.shared.addExtension(importedExtension.makeILExtension())
                if let legacy = importedExtension.makeLegacyToolExtension() {
                    settings.addToolExtension(legacy)
                    focusOnExtension(legacy)
                } else {
                    clearSelection()
                    selectedCategory = importedExtension.preferredAutomationCategory
                }
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
                            if !ok { importError = "Couldn't install the adapter pack." }
                        }
                    }
                })
        }
        .alert(
            "Import Failed", isPresented: .constant(importError != nil),
            actions: { Button("OK") { importError = nil } },
            message: { Text(importError ?? "") })
        .onAppear {
            applySettingsPage(settingsPage)
            seedSelectionScopeBuiltInsIfNeeded()
            pkgMgr.loadPackages()
            Task { await l2Mgr.loadExtensions() }
        }
        .onChange(of: settingsPage) { _, newValue in
            applySettingsPage(newValue)
            seedSelectionScopeBuiltInsIfNeeded()
        }
        .task {
            guard shouldLoadAppCatalog else { return }
            await loadInstalledAppsCatalogIfNeeded()
            reloadMenuCacheSummaries()
        }
        .onChange(of: selectedExtensionID) { _, newValue in
            guard newValue != nil else { return }
            selectedPackageID = nil
            selectedSystemCommandID = nil
            selectedAdapterID = nil
            selectedAdapterActionID = nil
            selectedRuleID = nil
            selectedMenuCacheBundleID = nil
        }
        .onChange(of: selectedPackageID) { _, newValue in
            guard newValue != nil else { return }
            selectedExtensionID = nil
            selectedSystemCommandID = nil
            selectedAdapterID = nil
            selectedAdapterActionID = nil
            selectedRuleID = nil
            selectedMenuCacheBundleID = nil
        }
        .onChange(of: selectedSystemCommandID) { _, newValue in
            guard newValue != nil else { return }
            selectedPackageID = nil
            selectedExtensionID = nil
            selectedAdapterID = nil
            selectedAdapterActionID = nil
            selectedRuleID = nil
            selectedMenuCacheBundleID = nil
        }
        .onChange(of: selectedAdapterID) { _, newValue in
            guard newValue != nil else { return }
            selectedPackageID = nil
            selectedSystemCommandID = nil
            selectedExtensionID = nil
            selectedRuleID = nil
            selectedMenuCacheBundleID = nil
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.badge.automatic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .purple],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    )
                Text("Automation")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(AutomationCategory.allCases) { cat in
                        SidebarRow(
                            category: cat,
                            count: count(for: cat),
                            isSelected: !showingImportPanel && selectedCategory == cat
                        )
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedCategory = cat
                                showingImportPanel = false
                                clearSelection()
                            }
                        }
                    }

                    // Divider before Import
                    Divider().padding(.horizontal, 8).padding(.vertical, 4)

                    // Import row
                    AutomationImportSidebarRow(isSelected: showingImportPanel)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showingImportPanel = true
                                clearSelection()
                            }
                        }
                }
                .padding(8)
            }

            Divider()

            // Total count footer
            HStack {
                Text("Total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(totalCount)")
                    .font(.caption.bold())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Item List

    @ViewBuilder
    private var itemList: some View {
        VStack(spacing: 0) {
            itemListHeader

            // Search bar
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                TextField("Search \(searchPlaceholder)…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            switch selectedCategory {
            case .scripts:         scriptList
            case .aiPrompts:       promptList
            case .cliTools:        cliList
            case .contextTriggers: triggerList
            case .appActions:      adapterList
            case .clipboardActions: clipboardActionsList
            case .menuCache:       menuCacheList
            case .systemCommands:  systemCommandList
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        switch selectedCategory {
        case .scripts:
            if let id = selectedExtensionID,
               let ext = scriptExtensions.first(where: { $0.id == id }) {
                ScriptDetailView(extension: ext)
            } else {
                emptyDetail(icon: "scroll.fill", label: "Select a script")
            }

        case .aiPrompts:
            if let id = selectedExtensionID,
               let ext = promptExtensions.first(where: { $0.id == id }) {
                PromptDetailView(extension: ext)
            } else {
                emptyDetail(icon: "brain.head.profile", label: "Select a prompt")
            }

        case .cliTools:
            if let id = selectedPackageID,
               let pkg = pkgMgr.packages.first(where: { $0.id == id }) {
                CLIDetailView(package: pkg)
            } else {
                emptyDetail(icon: "terminal.fill", label: "Select a CLI tool")
            }

        case .contextTriggers:
            if let id = selectedRuleID,
               let idx = settings.axTriggerRules.firstIndex(where: { $0.id == id }) {
                AXRuleDetailView(rule: $settings.axTriggerRules[idx])
            } else {
                contextTriggerEmptyDetail
            }

        case .appActions:
            if let adapterID = selectedAdapterID,
               let adapter = filteredAdapters.first(where: { $0.id == adapterID }) {
                AutomationAdapterDetailView(adapter: adapter, selectedActionID: $selectedAdapterActionID)
            } else {
                appActionsEmptyDetail
            }

        case .clipboardActions:
            clipboardActionsEmptyDetail

        case .menuCache:
            if let bundleID = selectedMenuCacheBundleID,
               let row = menuCacheRows.first(where: { $0.bundleId == bundleID }) {
                MenuCacheDetailView(
                    row: row,
                    isRefreshing: refreshingMenuCacheBundleID == bundleID,
                    statusMessage: menuCacheStatusMessage,
                    openApp: { openAppForMenuCaching(row) },
                    refreshCache: { refreshMenuCache(for: row) }
                )
            } else {
                menuCacheEmptyDetail
            }

        case .systemCommands:
            if settingsPage == .extensionsCLIToolScope,
               let id = selectedPackageID,
               let pkg = pkgMgr.packages.first(where: { $0.id == id }) {
                GlobalCLIScopeDetailView(package: pkg) {
                    settings.unpinCLITool(pkg.command)
                    selectedPackageID = filteredGlobalCLIToolScopes.first?.id
                    selectedSystemCommandID = nil
                }
            } else if settingsPage == .extensionsCLIToolScope {
                emptyDetail(icon: "terminal.fill", label: "Select a CLI tool")
            } else if settingsPage == .extensionsGlobalWithoutSelection {
                SystemCommandDetailView(selectedID: $selectedSystemCommandID)
            } else if let id = selectedPackageID,
                let pkg = pkgMgr.packages.first(where: { $0.id == id })
            {
                GlobalCLIScopeDetailView(package: pkg) {
                    settings.unpinCLITool(pkg.command)
                    selectedPackageID = filteredGlobalCLIToolScopes.first?.id
                    selectedSystemCommandID = nil
                }
            } else {
                SystemCommandDetailView(selectedID: $selectedSystemCommandID)
            }
        }
    }

    // MARK: List Views per Category

    private var scriptList: some View {
        Group {
            if filteredScripts.isEmpty {
                listEmpty(icon: "scroll.fill", label: "No scripts", action: { presentCreateFlow() })
            } else {
                List(selection: $selectedExtensionID) {
                    ForEach(filteredScripts) { ext in
                        AutomationRow(
                            icon: "scroll.fill",
                            color: .orange,
                            title: ext.toolName,
                            subtitle: ext.scriptLanguage?.rawValue ?? "Script",
                            isEnabled: true
                        )
                        .tag(ext.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var promptList: some View {
        Group {
            if filteredPrompts.isEmpty {
                listEmpty(icon: "brain.head.profile", label: "No AI prompts", action: { presentCreateFlow() })
            } else {
                List(selection: $selectedExtensionID) {
                    ForEach(filteredPrompts) { ext in
                        AutomationRow(
                            icon: "brain.head.profile",
                            color: .purple,
                            title: ext.toolName,
                            subtitle: ext.appKey.isEmpty ? "Global" : ext.appKey.capitalized,
                            isEnabled: true
                        )
                        .tag(ext.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var cliList: some View {
        Group {
            if filteredCLI.isEmpty {
                listEmpty(icon: "terminal.fill", label: "No CLI tools", action: { presentCreateFlow() })
            } else {
                List(selection: $selectedPackageID) {
                    ForEach(filteredCLI) { pkg in
                        AutomationRow(
                            icon: "terminal.fill",
                            color: .green,
                            title: pkg.name,
                            subtitle: cliSubtitle(for: pkg),
                            isEnabled: pkg.isEnabled
                        )
                        .tag(pkg.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var triggerList: some View {
        Group {
            if filteredTriggers.isEmpty {
                listEmpty(icon: "scope", label: "No trigger rules", action: { presentCreateFlow() })
            } else {
                List(selection: $selectedRuleID) {
                    Section(settingsPage == .shortcutSheetWorkflows ? "Selection Scope Extensions" : "Triggers") {
                        ForEach(filteredTriggers) { rule in
                            let displayPill = rule.pills.first
                            AutomationRow(
                                icon: displayPill?.icon ?? "scope",
                                color: colorForAccentName(displayPill?.accentColor) ?? .red,
                                title: rule.name,
                                subtitle: "\(rule.conditions.count) condition\(rule.conditions.count == 1 ? "" : "s") · \(rule.pills.count) pill\(rule.pills.count == 1 ? "" : "s")",
                                isEnabled: rule.isEnabled
                            )
                            .tag(rule.id)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // Adapters with at least one non-cliTool action → shown under "Apps"
    private var filteredAppAdapters: [AppAdapter] {
        filteredAdapters.filter { adapter in
            !adapter.bundleId.lowercased().hasPrefix("cli://")
                && (adapter.actions.isEmpty || adapter.actions.contains { $0.type != .cliTool })
        }
    }

    // Adapters where every action is a cliTool → shown under "CLI Tools"
    private var filteredCLIAdapters: [AppAdapter] { [] }

    private var adapterList: some View {
        Group {
            if filteredAdapters.isEmpty {
                listEmpty(icon: "app.connected.to.app.below.fill", label: "No app actions yet", action: { presentCreateFlow() })
            } else {
                List(selection: $selectedAdapterID) {
                    if !filteredAppAdapters.isEmpty {
                        Section("Apps") {
                            ForEach(filteredAppAdapters) { adapter in
                                AutomationAppRow(adapter: adapter)
                                    .tag(adapter.id)
                            }
                        }
                    }
                    if !filteredCLIAdapters.isEmpty {
                        Section("CLI Tools") {
                            ForEach(filteredCLIAdapters) { adapter in
                                AutomationAppRow(adapter: adapter)
                                    .tag(adapter.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var clipboardActionsList: some View {
        listEmpty(icon: "doc.on.clipboard.fill", label: "Clipboard actions coming next", action: nil)
    }

    private var menuCacheList: some View {
        VStack(spacing: 0) {
            // Menu caching is AUTOMATIC — every app is scanned as it becomes frontmost —
            // but the scan needs Accessibility. Without it every app reads "Not cached",
            // which looks broken. Surface the real reason + a one-click grant.
            if !AXIsProcessTrusted() {
                menuCacheAccessibilityBanner
            }
            if filteredMenuCacheRows.isEmpty {
                listEmpty(icon: "menubar.rectangle", label: "No installed apps found", action: nil)
            } else {
                List(selection: $selectedMenuCacheBundleID) {
                    Section("Cached") {
                        ForEach(filteredMenuCacheRows.filter(\.isCached)) { row in
                            MenuCacheAppRow(row: row)
                                .tag(row.bundleId)
                        }
                    }
                    Section("Not Cached") {
                        ForEach(filteredMenuCacheRows.filter { !$0.isCached }) { row in
                            MenuCacheAppRow(row: row)
                                .tag(row.bundleId)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        // Opening this page auto-warms every running app so the cache fills without the
        // user manually opening each one.
        .onAppear { warmRunningAppsForMenuCache() }
    }

    private var menuCacheAccessibilityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission required")
                    .font(.system(size: 12, weight: .semibold))
                Text("Context Dock caches app menus automatically as you use each app — but only with Accessibility access. Menu caching is off until you grant it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") { openAccessibilitySettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func openAccessibilitySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
    }

    /// Warm every regular running app's menus so opening the Menu Cache page fills the
    /// cache automatically (in addition to the on-activation warming during normal use).
    private func warmRunningAppsForMenuCache() {
        guard AXIsProcessTrusted() else { return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        MenuWarmCacheService.shared.warmRunningAppsOnLauncherOpen(apps, maxApps: 12)
    }

    private var systemCommandList: some View {
        Group {
            let cliScopes = filteredGlobalCLIToolScopes
            let cmds = filteredSystemCommands
            switch settingsPage {
            case .extensionsCLIToolScope:
                if cliScopes.isEmpty {
                    listEmpty(icon: "terminal.fill", label: "No pinned CLI tools", action: { showGlobalCLIPicker = true })
                } else {
                    List(selection: $selectedPackageID) {
                        Section("CLI Tool Scopes") {
                            ForEach(cliScopes) { pkg in
                                AutomationRow(
                                    icon: "terminal.fill",
                                    color: .green,
                                    title: pkg.command,
                                    subtitle: cliSubtitle(for: pkg),
                                    isEnabled: pkg.isEnabled
                                )
                                .tag(pkg.id)
                            }
                            .onDelete { idx in
                                let toRemove = idx.map { cliScopes[$0] }
                                toRemove.forEach { settings.unpinCLITool($0.command) }
                                if let selectedPackageID,
                                    toRemove.contains(where: { $0.id == selectedPackageID })
                                {
                                    self.selectedPackageID = filteredGlobalCLIToolScopes.first?.id
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }

            case .extensionsGlobalWithoutSelection:
                if cmds.isEmpty {
                    listEmpty(icon: "globe", label: "No global commands", action: { showSystemCommandSheet = true })
                } else {
                    List(selection: $selectedSystemCommandID) {
                        globalCommandSection(cmds)
                    }
                    .listStyle(.inset)
                }

            default:
                if sysRegistry.commands.isEmpty && cliScopes.isEmpty {
                    listEmpty(icon: "slider.horizontal.3", label: "No global actions", action: { presentCreateFlow() })
                } else {
                    List(selection: $selectedSystemCommandID) {
                        if !cliScopes.isEmpty {
                            Section("CLI Tool Scopes") {
                                ForEach(cliScopes) { pkg in
                                    Button {
                                        selectedPackageID = pkg.id
                                        selectedSystemCommandID = nil
                                    } label: {
                                        AutomationRow(
                                            icon: "terminal.fill",
                                            color: .green,
                                            title: pkg.command,
                                            subtitle: "Global CLI scope",
                                            isEnabled: pkg.isEnabled
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                                .onDelete { idx in
                                    let toRemove = idx.map { cliScopes[$0] }
                                    toRemove.forEach { settings.unpinCLITool($0.command) }
                                    if let selectedPackageID,
                                        toRemove.contains(where: { $0.id == selectedPackageID })
                                    {
                                        self.selectedPackageID = filteredGlobalCLIToolScopes.first?.id
                                    }
                                }
                            }
                        }
                        globalCommandSection(cmds)
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private var filteredSystemCommands: [SystemCommand] {
        guard !searchText.isEmpty else { return sysRegistry.commands }
        return sysRegistry.commands.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.description.localizedCaseInsensitiveContains(searchText)
                || $0.keywords.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private func globalCommandSection(_ cmds: [SystemCommand]) -> some View {
        Section("Global Commands") {
            ForEach(cmds) { cmd in
                AutomationRow(
                    icon: cmd.icon,
                    color: AutomationCategory.systemCommands.color,
                    title: cmd.name,
                    subtitle: cmd.description,
                    isEnabled: cmd.isEnabled
                )
                .tag(cmd.id)
                // No .onTapGesture here: it competes with List(selection:)'s own tap
                // recognizer and makes selection feel laggy / need a second click.
                // selectedPackageID is already cleared by onChange(of: selectedSystemCommandID).
            }
            .onDelete { idx in
                let toRemove = idx.map { cmds[$0] }
                toRemove.forEach { sysRegistry.remove($0) }
                if let selectedSystemCommandID,
                    toRemove.contains(where: { $0.id == selectedSystemCommandID })
                {
                    self.selectedSystemCommandID = sysRegistry.commands.first?.id
                }
            }
        }
    }

    // MARK: Filtered Data

    private var scriptExtensions: [AppToolExtension] {
        settings.appToolExtensions.filter { $0.kind == .script }
    }

    private var promptExtensions: [AppToolExtension] {
        settings.appToolExtensions.filter { $0.kind == .prompt }
    }

    private var filteredScripts: [AppToolExtension] {
        guard !searchText.isEmpty else { return scriptExtensions }
        return scriptExtensions.filter {
            $0.toolName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredPrompts: [AppToolExtension] {
        guard !searchText.isEmpty else { return promptExtensions }
        return promptExtensions.filter {
            $0.toolName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredCLI: [TerminalPackage] {
        guard !searchText.isEmpty else { return pkgMgr.packages }
        return pkgMgr.packages.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.command.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredGlobalCLIToolScopes: [TerminalPackage] {
        let scopes = pkgMgr.packages.filter(isUserAddedGlobalCLITool)
        guard !searchText.isEmpty else { return scopes }
        return scopes.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.command.localizedCaseInsensitiveContains(searchText)
                || $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Delegates to the shared definition so this list and the global search index can never
    /// disagree about which tools the user actually added.
    private func isUserAddedGlobalCLITool(_ package: TerminalPackage) -> Bool {
        pkgMgr.isUserAddedGlobalScope(package)
    }

    private var filteredTriggers: [AXTriggerRule] {
        let rules: [AXTriggerRule]
        if settingsPage == .shortcutSheetWorkflows {
            let selectionNames = Set(AXTriggerRule.selectionScopeBuiltInExamples.map(\.name))
            let genericExampleNames = Set(AXTriggerRule.builtInExamples.map(\.name))
            rules = settings.axTriggerRules.filter { rule in
                if selectionNames.contains(rule.name) { return true }
                if genericExampleNames.contains(rule.name) { return false }
                if rule.name.localizedCaseInsensitiveContains("selection") { return true }
                return rule.conditions.contains { condition in
                    condition.field == .selectedText
                        || condition.field == .filePath
                        || condition.field == .currentURL
                }
            }
        } else {
            rules = settings.axTriggerRules
        }
        guard !searchText.isEmpty else { return rules }
        return rules.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredAdapters: [AppAdapter] {
        let adapters = appActionAdapters
        guard !searchText.isEmpty else { return adapters }
        return adapters.filter {
            $0.appName.localizedCaseInsensitiveContains(searchText)
                || $0.bundleId.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var menuCacheRows: [AppMenuCacheRowModel] {
        let installedRows = installedAppsByBundleId.values.map { entry in
            AppMenuCacheRowModel(
                bundleId: entry.bundleId,
                appName: entry.name,
                appURL: entry.url,
                icon: entry.icon,
                summary: menuCacheSummaries[entry.bundleId]
            )
        }
        let installedBundleIds = Set(installedAppsByBundleId.keys)
        let cacheOnlyRows = menuCacheSummaries.values
            .filter { !installedBundleIds.contains($0.bundleIdentifier) }
            .map { summary in
                AppMenuCacheRowModel(
                    bundleId: summary.bundleIdentifier,
                    appName: summary.appName,
                    appURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: summary.bundleIdentifier),
                    icon: InstalledApplicationsCatalog.icon(for: summary.bundleIdentifier),
                    summary: summary
                )
            }
        return (installedRows + cacheOnlyRows).sorted { lhs, rhs in
            if lhs.isCached != rhs.isCached { return lhs.isCached && !rhs.isCached }
            let order = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
            if order == .orderedSame { return lhs.bundleId < rhs.bundleId }
            return order == .orderedAscending
        }
    }

    private var filteredMenuCacheRows: [AppMenuCacheRowModel] {
        guard !searchText.isEmpty else { return menuCacheRows }
        return menuCacheRows.filter {
            $0.appName.localizedCaseInsensitiveContains(searchText)
                || $0.bundleId.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: Counts

    private func count(for cat: AutomationCategory) -> Int {
        switch cat {
        case .scripts:         return scriptExtensions.count
        case .aiPrompts:       return promptExtensions.count
        case .cliTools:        return pkgMgr.packages.count
        case .contextTriggers: return settings.axTriggerRules.count
        case .appActions:      return appActionAdapters.filter { !$0.bundleId.lowercased().hasPrefix("cli://") }.count
        case .clipboardActions: return 0
        case .menuCache:       return menuCacheSummaries.count
        case .systemCommands:  return sysRegistry.commands.count + filteredGlobalCLIToolScopes.count
        }
    }

    private var totalCount: Int {
        AutomationCategory.allCases.map { count(for: $0) }.reduce(0, +)
    }

    private func cliSubtitle(for package: TerminalPackage) -> String {
        guard !package.contextAppBundleIds.isEmpty else { return package.command }
        let count = package.contextAppBundleIds.count
        return "\(package.command) · \(count) app\(count == 1 ? "" : "s")"
    }

    private func clearSelection() {
        selectedExtensionID  = nil
        selectedRuleID       = nil
        selectedPackageID    = nil
        selectedAdapterID    = nil
        selectedAdapterActionID = nil
        selectedMenuCacheBundleID = nil
        searchText = ""
    }

    private var appActionAdapters: [AppAdapter] {
        let customAdapters = adapterMgr.adapters.filter { !$0.isBuiltIn }
        let customBundleIds = Set(customAdapters.map(\.bundleId))
        let linkedBundleIds = Set(
            pkgMgr.packages
                .filter { $0.isEnabled }
                .flatMap(\.contextAppBundleIds)
                .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("cli://") }
        )

        let linkedOnlyAdapters = linkedBundleIds.compactMap { bundleId -> AppAdapter? in
            guard !customBundleIds.contains(bundleId) else { return nil }
            return syntheticAppActionAdapter(for: bundleId)
        }

        return (customAdapters + linkedOnlyAdapters)
            .filter { !$0.bundleId.lowercased().hasPrefix("cli://") }
            .sorted { lhs, rhs in
            let appNameOrder = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
            if appNameOrder == .orderedSame {
                return lhs.bundleId.localizedCaseInsensitiveCompare(rhs.bundleId) == .orderedAscending
            }
            return appNameOrder == .orderedAscending
        }
    }

    private func syntheticAppActionAdapter(for bundleId: String) -> AppAdapter {
        let entry = installedAppsByBundleId[bundleId]
        let fallbackName = bundleId
            .split(separator: ".")
            .last
            .map { String($0).replacingOccurrences(of: "-", with: " ").capitalized }
            ?? bundleId
        return AppAdapter(
            id: bundleId,
            appName: entry?.name ?? fallbackName,
            bundleId: bundleId,
            icon: "app.fill",
            isEnabled: true,
            isBuiltIn: false,
            actions: []
        )
    }

    private var createButtonTitle: String {
        if settingsPage == .extensionsCLIToolScope { return "Pin CLI" }
        if selectedCategory == .appActions { return "Choose App" }
        return "New"
    }

    private var shouldLoadAppCatalog: Bool {
        settingsPage == nil || settingsPage == .frontmostAppAdapters || settingsPage == .advanced
    }

    private func applySettingsPage(_ page: SettingsPage?) {
        guard let category = page?.automationCategory else { return }
        selectedCategory = category
        showingImportPanel = false
        clearSelection()
    }

    private func seedSelectionScopeBuiltInsIfNeeded() {
        guard settingsPage == .shortcutSheetWorkflows else { return }
        settings.axTriggerRules.removeAll {
            AXTriggerRule.legacySelectionScopeBuiltInNames.contains($0.name)
        }
        let existingNames = Set(settings.axTriggerRules.map(\.name))
        let missing = AXTriggerRule.selectionScopeBuiltInExamples.filter {
            !existingNames.contains($0.name)
        }
        guard !missing.isEmpty else { return }
        settings.axTriggerRules.append(contentsOf: missing)
    }

    private func colorForAccentName(_ name: String?) -> Color? {
        switch name?.lowercased() {
        case "blue": return .blue
        case "red": return .red
        case "green": return .green
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "indigo": return .indigo
        case "teal": return .teal
        case "pink": return .pink
        case "gray", "grey": return .secondary
        default: return nil
        }
    }

    // MARK: Helpers

    private var itemListHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(itemListTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(itemListSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)
            Spacer(minLength: 8)
            if selectedCategory == .menuCache {
                Button {
                    Task { await loadInstalledAppsCatalogIfNeeded() }
                    reloadMenuCacheSummaries()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if settingsPage == .extensionsGlobalWithoutSelection {
                Button(action: { showSystemCommandSheet = true }) {
                    Label("Add Command", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                if settingsPage != .extensionsGlobalWithoutSelection && settingsPage != .extensionsCLIToolScope {
                    Button(action: { showAIImportSheet = true }) {
                        Label("Paste AI", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .layoutPriority(1)
                    Button(action: importAdapterPack) {
                        Label("Import Adapter…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .layoutPriority(1)
                    .help("Import an App Adapter Pack (.adapterpack, .zip, .json)")
                }
                Button(action: presentCreateFlow) {
                    Label(createButtonTitle, systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var itemListTitle: String {
        switch settingsPage {
        case .extensionsGlobalWithSelection: return "With Selection"
        case .extensionsGlobalWithoutSelection: return "Commands"
        case .extensionsCLIToolScope: return "CLI Tool Scope"
        case .frontmostAppAdapters: return "App Adapters"
        case .workflows: return "Workflows"
        case .shortcutSheetWorkflows: return "Selection Scope"
        case .advanced: return "Menu Cache"
        default: return selectedCategory.rawValue
        }
    }

    private var itemListSubtitle: String {
        switch settingsPage {
        case .extensionsGlobalWithSelection:
            return "Actions that require selected text, files, URLs, images, or media."
        case .extensionsGlobalWithoutSelection:
            return "Always-available system and global commands."
        case .extensionsCLIToolScope:
            return "Pinned command-line tools available everywhere."
        case .frontmostAppAdapters:
            return "App-specific adapters shown for the frontmost app."
        case .workflows:
            return "Context rules and multi-step automation."
        case .shortcutSheetWorkflows:
            return "Selection-aware actions for the long-press Command shortcut sheet."
        case .advanced:
            return "Developer-facing cache and diagnostics."
        default:
            return selectedCategory.subtitle
        }
    }

    private var searchPlaceholder: String {
        switch settingsPage {
        case .extensionsGlobalWithSelection:
            return "with-selection actions"
        case .extensionsGlobalWithoutSelection:
            return "global commands"
        case .extensionsCLIToolScope:
            return "CLI tools"
        case .frontmostAppAdapters:
            return "app adapters"
        case .workflows:
            return "workflows"
        case .shortcutSheetWorkflows:
            return "shortcut sheet actions"
        case .advanced:
            return "menu cache"
        default:
            return selectedCategory.rawValue.lowercased()
        }
    }

    private var appActionsEmptyDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("FrontmostApp Actions", systemImage: "app.connected.to.app.below.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Add custom actions, scripts, and shortcuts for specific apps. They appear when that app is frontmost.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    Text("How to create an action")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    onboardingStep(number: "1", title: "Select an app", detail: "Choose any installed app from the list on the left.")
                    onboardingStep(number: "2", title: "Add an action", detail: "Click + to add a script, deep link, shortcut, or app automation.")
                    onboardingStep(number: "3", title: "Use it in the dock", detail: "Switch to that app; the action appears as a pill instantly.")
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Available variables in scripts")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    variableRow("{{selection}}", "Currently selected text in the active app")
                    variableRow("{{clipboard}}", "Current clipboard content")
                    variableRow("{{file}}", "Path of the selected file in Finder")
                    variableRow("{{app}}", "Name of the frontmost app")
                    variableRow("{{query}}", "Text typed in the Context Dock search field")
                    variableRow("{{url}}", "URL from clipboard or active browser tab")
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Sample recipes — tap a type to expand")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Copy any snippet into the \"script\" field of your adapter action.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    AppActionSamplesSection()
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var menuCacheEmptyDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Menu Cache", systemImage: "menubar.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                Text("Global Context app scopes use cached menu snapshots when an app is not frontmost. Open or refresh apps here to make those scopes reliable.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                onboardingStep(number: "1", title: "Open an app", detail: "Choose an app from the list and open it once.")
                onboardingStep(number: "2", title: "Refresh menus", detail: "If the app is running, click Refresh Cache to read its current menu tree.")
                onboardingStep(number: "3", title: "Use Global Context", detail: "Queries like “photos favourite” can use cached menus later.")
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var contextTriggerEmptyDetail: some View {
        if settingsPage == .shortcutSheetWorkflows {
            selectionScopeBuiltInDetail
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Context Triggers", systemImage: "scope")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Rules that auto-activate the dock with relevant actions when you select text, files, or URLs in any app.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 14) {
                        Text("How to create a trigger")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        onboardingStep(number: "1", title: "Click +", detail: "Add a new rule using the button at the bottom of the list.")
                        onboardingStep(number: "2", title: "Set the condition", detail: "Match on selected text pattern, file extension, URL host, or app.")
                        onboardingStep(number: "3", title: "Attach actions", detail: "Add scripts or shortcuts to run when the trigger fires.")
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Trigger types")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        triggerTypeRow("text.cursor", "Text selection", "Fires when selected text matches a pattern or length threshold")
                        triggerTypeRow("doc.fill", "File selection", "Fires when a file of a given extension is selected in Finder")
                        triggerTypeRow("link", "URL", "Fires when a URL matching a host pattern is on the clipboard")
                        triggerTypeRow("app.fill", "App-specific", "Fires only when a specific app is frontmost")
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Available variables in trigger actions")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        variableRow("{{selection}}", "The text or file path that matched the trigger")
                        variableRow("{{clipboard}}", "Current clipboard content")
                        variableRow("{{url}}", "Matched URL")
                        variableRow("{{app}}", "Name of the frontmost app when trigger fired")
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    private var selectionScopeBuiltInDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Create Selection Scope extensions", systemImage: "command.square")
                        .font(.system(size: 15, weight: .semibold))
                    Text("The built-in extensions are listed on the left as real editable examples. Use this page to create workflows that run only against the user’s current selected text, file, folder, URL, document, image, video, or audio.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recommended design")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    onboardingStep(number: "1", title: "Choose the selected input", detail: "Use selected text for writing actions, file path/extension for files and folders, URL host for links, and app name only when the workflow belongs to one app.")
                    onboardingStep(number: "2", title: "Pick the safest engine", detail: "Prefer built-in macOS tools first: MarkItDown for documents, Vision OCR for images, sips for image conversion, ditto/zip for archives, and AI only for reasoning.")
                    onboardingStep(number: "3", title: "Attach one clear action", detail: "Use an AI prompt for answers in-place, a shell command for local transforms, a Shortcut for user automation, or an app adapter when the target app exposes a real capability.")
                    onboardingStep(number: "4", title: "Respect approval and scope", detail: "Read-only actions can run immediately. Anything that writes, deletes, sends, moves, or opens another app should ask first and should only receive the selected content.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Useful starter actions")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    codeExample("Copy selected text", "printf '%s' \"{selectedText}\" | pbcopy")
                    codeExample("Document to Markdown", "markitdown \"{file}\" | pbcopy")
                    codeExample("Zip selected item", "ditto -c -k --keepParent \"{file}\" \"{file}.zip\"")
                    codeExample("Convert image", "sips -s format jpeg \"{file}\" --out \"{file}.jpg\"")
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Useful variables")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    variableRow("{selectedText}", "Text selected through Accessibility")
                    variableRow("{file}", "Selected file or folder path")
                    variableRow("{url}", "Selected or detected URL")
                    variableRow("{appName}", "Frontmost app when Selection Scope opened")
                    variableRow("{bundleId}", "Frontmost app bundle identifier")
                    variableRow("{clipboard}", "Current clipboard content")
                    variableRow("{encodedText}", "URL-encoded selected text")
                    variableRow("{encodedURL}", "URL-encoded detected URL")
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func codeExample(_ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(command)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(NSColor.textBackgroundColor).opacity(0.65),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
    }

    private func selectionBuiltInGroup(
        title: String,
        icon: String,
        color: Color,
        items: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.0) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(color)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0)
                                .font(.system(size: 11, weight: .semibold))
                            Text(item.1)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color(NSColor.textBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func onboardingStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var clipboardActionsEmptyDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Clipboard Actions", systemImage: "doc.on.clipboard.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Build actions that transform, paste, share, summarize, or route copied text, images, files, and URLs.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    Text("Planned action types")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    onboardingStep(number: "1", title: "Paste or share", detail: "Send selected clipboard items to the previous frontmost app or native share sheet.")
                    onboardingStep(number: "2", title: "Transform", detail: "Rewrite, summarize, translate, OCR, or format clipboard content through AI.")
                    onboardingStep(number: "3", title: "Route", detail: "Open URLs, reveal files, run app actions, or trigger workflows from clipboard matches.")
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Available variables")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    variableRow("{{clipboard}}", "Current clipboard text, OCR text, file paths, or URL")
                    variableRow("{{clipboard_type}}", "text, image, file, url, or mixed")
                    variableRow("{{source_app}}", "App that copied the item")
                    variableRow("{{query}}", "User text typed after choosing clipboard scope")
                }
            }
            .padding(24)
        }
    }

    private func variableRow(_ variable: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(variable)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func exampleRow(_ name: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 11, weight: .medium))
            Text(command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Samples Section (inserted between exampleRow and triggerTypeRow)

    private func triggerTypeRow(_ icon: String, _ name: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func emptyDetail(icon: String, label: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func listEmpty(icon: String, label: String, action: (() -> Void)?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if let action {
                Button("Create One") { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presentCreateFlow() {
        switch selectedCategory {
        case .scripts:
            extensionSheetMode = .script
            showExtensionSheet = true
        case .aiPrompts:
            extensionSheetMode = .prompt
            showExtensionSheet = true
        case .cliTools:
            showPackageSheet = true
        case .contextTriggers:
            showRuleSheet = true
        case .appActions:
            showAdapterSheet = true
        case .clipboardActions:
            break
        case .menuCache:
            break
        case .systemCommands:
            if settingsPage == .extensionsGlobalWithoutSelection {
                showSystemCommandSheet = true
            } else {
                showGlobalCLIPicker = true
            }
        }
    }

    private func focusOnExtension(_ ext: AppToolExtension) {
        clearSelection()
        selectedCategory = ext.kind == .prompt ? .aiPrompts : .scripts
        selectedExtensionID = ext.id
    }

    private func focusOnPackage(_ id: UUID) {
        clearSelection()
        selectedCategory = .cliTools
        selectedPackageID = id
    }

    private func focusOnGlobalCLIScope(_ id: UUID) {
        clearSelection()
        selectedCategory = .systemCommands
        selectedPackageID = id
    }

    private func focusOnRule(_ id: UUID) {
        clearSelection()
        selectedCategory = .contextTriggers
        selectedRuleID = id
    }

    private func focusOnAdapter(_ id: String) {
        clearSelection()
        selectedCategory = .appActions
        selectedAdapterID = id
    }

    private func removeAppActionAdapter(_ bundleId: String) async {
        await adapterMgr.deleteAdapter(bundleId: bundleId)
        await MainActor.run {
            settings.customAppEntries.removeAll {
                $0.key == bundleId || $0.appPath == bundleId
            }
            settings.appToolExtensions.removeAll { $0.appKey == bundleId }
            for package in pkgMgr.packages where package.contextAppBundleIds.contains(bundleId) {
                var updated = package
                updated.contextAppBundleIds.removeAll { $0 == bundleId }
                pkgMgr.updatePackage(updated)
            }
            if bundleId.hasPrefix("cli://") {
                let command = String(bundleId.dropFirst("cli://".count))
                settings.unpinCLITool(command)
                settings.customAppEntries.removeAll {
                    $0.key == "cli_\(command)" || $0.appPath == "cli://\(command)"
                }
                if let package = pkgMgr.packages.first(where: { $0.command == command }) {
                    var updated = package
                    updated.contextAppBundleIds.removeAll {
                        $0 == bundleId || $0 == "cli_\(command)"
                    }
                    pkgMgr.updatePackage(updated)
                }
            }
            selectedAdapterID = nil
            selectedAdapterActionID = nil
        }
    }

    private func reloadMenuCacheSummaries() {
        menuCacheSummaries = Dictionary(
            uniqueKeysWithValues: AppMenuCapabilityCache.shared.summaries().map {
                ($0.bundleIdentifier, $0)
            }
        )
    }

    private func openAppForMenuCaching(_ row: AppMenuCacheRowModel) {
        guard let appURL = row.appURL else {
            menuCacheStatusMessage = "Could not find \(row.appName) on disk."
            return
        }

        menuCacheStatusMessage = "Opening \(row.appName)…"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    menuCacheStatusMessage = "Could not open \(row.appName): \(error.localizedDescription)"
                    return
                }
                menuCacheStatusMessage = "\(row.appName) opened. Reading menus…"
                refreshMenuCache(for: row)
            }
        }
    }

    private func refreshMenuCache(for row: AppMenuCacheRowModel) {
        let bundleId = row.bundleId
        let appName = row.appName
        refreshingMenuCacheBundleID = bundleId
        menuCacheStatusMessage = "Reading \(appName) menus…"

        Task.detached(priority: .userInitiated) {
            var runningApp: NSRunningApplication?
            for _ in 0..<20 {
                runningApp = await MainActor.run {
                    NSWorkspace.shared.runningApplications.first {
                        $0.bundleIdentifier == bundleId && !$0.isTerminated
                    }
                }
                if runningApp != nil { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            guard let runningApp else {
                await MainActor.run {
                    refreshingMenuCacheBundleID = nil
                    menuCacheStatusMessage = "\(appName) is not running. Open it once to cache menus."
                }
                return
            }

            var items = await AXMenuReader.shared.refreshAllMenuItems(for: runningApp.processIdentifier, maxDepth: 7)
            if items.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                items = await AXMenuReader.shared.refreshAllMenuItems(for: runningApp.processIdentifier, maxDepth: 7)
            }

            if !items.isEmpty {
                AppMenuCapabilityCache.shared.store(items: items, for: runningApp)
            }
            let cachedCount = AppMenuCapabilityCache.shared.summary(bundleIdentifier: bundleId)?.recordCount ?? 0

            await MainActor.run {
                refreshingMenuCacheBundleID = nil
                reloadMenuCacheSummaries()
                if cachedCount > 0 {
                    menuCacheStatusMessage = "Cached \(cachedCount) menus for \(appName)."
                } else {
                    menuCacheStatusMessage = "No menus were readable for \(appName). Check Accessibility permission and keep the app frontmost."
                }
            }
        }
    }

    private func loadInstalledAppsCatalogIfNeeded() async {
        guard installedAppsByBundleId.isEmpty else { return }
        let discovered = await Task.detached(priority: .utility) {
            InstalledApplicationsCatalog.discoverInstalledApps()
        }.value
        installedAppsByBundleId = Dictionary(uniqueKeysWithValues: discovered.map { ($0.bundleId, $0) })
    }
}

// MARK: - Sidebar Row

private struct SidebarRow: View {
    let category: AutomationCategory
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                          ? category.color.opacity(0.18)
                          : category.color.opacity(0.09))
                    .frame(width: 30, height: 30)
                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? category.color : category.color.opacity(0.7))
            }
            Text(category.rawValue)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(category.color) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isSelected ? category.color.opacity(0.14) : Color.secondary.opacity(0.1),
                        in: Capsule()
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected ? category.color.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Generic Row

private struct AutomationRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(color.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !isEnabled {
                Text("off")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .opacity(isEnabled ? 1.0 : 0.55)
    }
}

private struct AutomationAppRow: View {
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared
    let adapter: AppAdapter

    private var linkedCLIToolsCount: Int {
        pkgMgr.packages.filter { package in
            package.isEnabled && package.contextAppBundleIds.contains(adapter.bundleId)
        }.count
    }

    private var subtitle: String {
        var parts: [String] = []
        let actionCount = adapter.actions.filter { $0.type != .cliTool }.count
        let cliCount = linkedCLIToolsCount
        if actionCount > 0 { parts.append("\(actionCount) action\(actionCount == 1 ? "" : "s")") }
        if cliCount > 0 { parts.append("\(cliCount) CLI") }
        return parts.isEmpty ? "No actions yet" : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.teal.opacity(0.12))
                    .frame(width: 32, height: 32)
                AppBundleIconView(bundleId: adapter.bundleId, fallbackSymbol: adapter.icon, size: 20, cornerRadius: 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(adapter.appName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !adapter.isEnabled {
                Text("off")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .opacity(adapter.isEnabled ? 1.0 : 0.55)
    }
}

private struct MenuCacheAppRow: View {
    let row: AppMenuCacheRowModel

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(row.isCached ? Color.cyan.opacity(0.14) : Color.secondary.opacity(0.09))
                    .frame(width: 32, height: 32)
                if let icon = row.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 21, height: 21)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    AppBundleIconView(bundleId: row.bundleId, fallbackSymbol: "app.fill", size: 20, cornerRadius: 5)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.appName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if row.isCached {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.cyan)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        row.isCached
            ? "\(row.recordCount) cached menu\(row.recordCount == 1 ? "" : "s")"
            : "Not cached"
    }
}

// MARK: - Detail Views

private struct MenuCacheDetailView: View {
    let row: AppMenuCacheRowModel
    let isRefreshing: Bool
    let statusMessage: String?
    let openApp: () -> Void
    let refreshCache: () -> Void

    private var updatedText: String {
        guard let updatedAt = row.summary?.updatedAt else { return "Never cached" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: updatedAt, relativeTo: Date())
    }

    private var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == row.bundleId && !$0.isTerminated
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                HStack(spacing: 8) {
                    Button(action: openApp) {
                        Label(row.isCached ? "Open App" : "Open and Cache", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(row.appURL == nil || isRefreshing)

                    Button(action: refreshCache) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Refresh Cache", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRefreshing || !isRunning)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                AutomationDetailSection(title: "CACHE STATUS") {
                    AutomationDetailRow(label: "Bundle ID", value: row.bundleId, mono: true)
                    AutomationDetailRow(label: "State", value: row.isCached ? "Cached" : "Not cached")
                    AutomationDetailRow(label: "Menus", value: "\(row.recordCount)")
                    AutomationDetailRow(label: "Updated", value: updatedText)
                }

                if let summary = row.summary, !summary.samplePaths.isEmpty {
                    AutomationDetailSection(title: "SAMPLE MENUS") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(summary.samplePaths, id: \.self) { path in
                                Text(path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                } else {
                    AutomationDetailSection(title: "HOW TO CACHE") {
                        Text("Open the app once, keep it frontmost, then click Refresh Cache. Context Dock stores readable app menus for Global Context app scopes.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cyan.opacity(0.12))
                    .frame(width: 48, height: 48)
                if let icon = row.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    AppBundleIconView(bundleId: row.bundleId, fallbackSymbol: "app.fill", size: 32, cornerRadius: 8)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(row.appName)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(row.isCached ? "\(row.recordCount) cached menus" : "No menu cache yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ShortcutDetailView: View {
    @ObservedObject private var settings = AppSettings.shared
    let shortcut: AppShortcut
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                detailHeader(
                    icon: shortcut.iconName,
                    color: .blue,
                    title: shortcut.name,
                    badge: shortcut.actionType.rawValue
                )

                AutomationDetailSection(title: "TRIGGER") {
                    AutomationDetailRow(label: "App Key", value: shortcut.appKey)
                    AutomationDetailRow(label: "Placement", value: shortcut.placement.rawValue)
                    if !shortcut.triggerKeywords.isEmpty {
                        AutomationDetailRow(label: "Keywords", value: shortcut.triggerKeywords.joined(separator: ", "))
                    }
                    if !shortcut.fileTypes.isEmpty {
                        AutomationDetailRow(label: "File Types", value: shortcut.fileTypes.joined(separator: ", "))
                    }
                }

                AutomationDetailSection(title: "ACTION") {
                    AutomationDetailRow(label: "Type", value: shortcut.actionType.rawValue)
                    AutomationDetailRow(label: "Value", value: shortcut.actionValue, mono: true)
                }

                actionBar(
                    onEdit: { editing = true },
                    onDelete: { settings.removeShortcut(shortcut) }
                )
            }
            .padding(20)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $editing) {
            ShortcutEditorSheet(shortcut: shortcut)
        }
    }
}

struct ScriptDetailView: View {
    @ObservedObject private var settings = AppSettings.shared
    let `extension`: AppToolExtension
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailHeader(
                    icon: "scroll.fill",
                    color: .orange,
                    title: `extension`.toolName,
                    badge: `extension`.scriptLanguage?.rawValue ?? "Script"
                )

                AutomationDetailSection(title: "CONFIGURATION") {
                    AutomationDetailRow(label: "App Key", value: `extension`.appKey.isEmpty ? "Global" : `extension`.appKey)
                    if let lang = `extension`.scriptLanguage {
                        AutomationDetailRow(label: "Language", value: lang.rawValue)
                    }
                    if !`extension`.toolPath.isEmpty {
                        AutomationDetailRow(label: "Path", value: `extension`.toolPath, mono: true)
                    }
                }

                if !`extension`.scriptCode.isEmpty {
                    AutomationDetailSection(title: "SCRIPT") {
                        Text(`extension`.scriptCode)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                actionBar(
                    onEdit: { editing = true },
                    onDelete: { settings.appToolExtensions.removeAll { $0.id == `extension`.id } }
                )
            }
            .padding(20)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $editing) {
            ScriptEditorSheet(extension: `extension`)
        }
    }
}

struct PromptDetailView: View {
    @ObservedObject private var settings = AppSettings.shared
    let `extension`: AppToolExtension
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailHeader(
                    icon: "brain.head.profile",
                    color: .purple,
                    title: `extension`.toolName,
                    badge: "AI Prompt"
                )

                AutomationDetailSection(title: "CONFIGURATION") {
                    AutomationDetailRow(label: "App Key", value: `extension`.appKey.isEmpty ? "Global" : `extension`.appKey)
                    AutomationDetailRow(label: "Cache TTL", value: `extension`.cacheTTLMinutes == 0 ? "No cache" : "\(`extension`.cacheTTLMinutes) min")
                }

                if !`extension`.promptTemplate.isEmpty {
                    AutomationDetailSection(title: "TEMPLATE") {
                        Text(`extension`.promptTemplate)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                AutomationDetailSection(title: "VARIABLES") {
                    Text("{{query}}  {{date}}  {{time}}  {{clipboard}}  {{app}}")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                actionBar(
                    onEdit: { editing = true },
                    onDelete: { settings.appToolExtensions.removeAll { $0.id == `extension`.id } }
                )
            }
            .padding(20)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $editing) {
            PromptEditorSheet(extension: `extension`)
        }
    }
}

struct CLIDetailView: View {
    @ObservedObject private var adapterMgr = AppAdapterManager.shared
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared
    @State private var installedApps: [InstalledApplicationEntry] = []
    let package: TerminalPackage
    @State private var scanning = false
    @State private var showAppPicker = false

    private var associatedApps: [InstalledApplicationEntry] {
        let selectedIds = Set(package.contextAppBundleIds)
        return installedApps.filter { selectedIds.contains($0.bundleId) }
    }

    private var unknownAssociatedBundleIds: [String] {
        let knownBundleIds = Set(installedApps.map(\.bundleId))
        return package.contextAppBundleIds.filter { !knownBundleIds.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with toggle
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(package.name)
                            .font(.system(size: 16, weight: .bold))
                        Text(package.command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { package.isEnabled },
                        set: { val in
                            var p = package; p.isEnabled = val
                            pkgMgr.updatePackage(p)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                AutomationDetailSection(title: "DETAILS") {
                    AutomationDetailRow(label: "Command", value: package.command, mono: true)
                    if let path = package.installedPath {
                        AutomationDetailRow(label: "Path", value: path, mono: true)
                    }
                    if !package.taskCategories.isEmpty {
                        AutomationDetailRow(label: "Categories", value: package.taskCategories.joined(separator: ", "))
                    }
                }

                AutomationDetailSection(title: "APP ASSOCIATIONS") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(package.contextAppBundleIds.isEmpty
                             ? "This CLI is currently global. Associate it with specific apps so scoped dock chat for those apps can use this tool's learned commands."
                             : "Scoped dock chat for these apps will use this CLI's scanned commands and help text.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Button {
                                showAppPicker = true
                            } label: {
                                Label(package.contextAppBundleIds.isEmpty ? "Choose Apps" : "Edit Apps", systemImage: "app.connected.to.app.below.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if !package.contextAppBundleIds.isEmpty {
                                Button("Use for Any App") {
                                    updateAssociatedApps([])
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        if package.contextAppBundleIds.isEmpty {
                            Text("Any app")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.08), in: Capsule())
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(associatedApps) { app in
                                    HStack(spacing: 8) {
                                        if let icon = app.icon {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .interpolation(.high)
                                                .frame(width: 16, height: 16)
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                        } else {
                                            AppBundleIconView(bundleId: app.bundleId, fallbackSymbol: "app.fill", size: 16, cornerRadius: 4)
                                        }
                                        Text(app.name)
                                            .font(.system(size: 11, weight: .medium))
                                        Spacer()
                                        Text(app.bundleId)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }

                                ForEach(unknownAssociatedBundleIds, id: \.self) { bundleId in
                                    HStack(spacing: 8) {
                                        Image(systemName: "app.dashed")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(bundleId)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(10)
                            .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if !package.usageExamples.isEmpty {
                    AutomationDetailSection(title: "EXAMPLES") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(package.usageExamples, id: \.self) { ex in
                                Text(ex)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }

                if let help = package.helpText, !help.isEmpty {
                    AutomationDetailSection(title: "HELP TEXT") {
                        Text(String(help.prefix(600)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        scanning = true
                        Task {
                            await pkgMgr.refreshHelpTextByCommand(package.command)
                            scanning = false
                        }
                    } label: {
                        Label(scanning ? "Scanning…" : "Scan Help", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(scanning)

                    Spacer()

                    Button("Remove") {
                        pkgMgr.removePackage(package)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .task {
            if installedApps.isEmpty {
                installedApps = InstalledApplicationsCatalog.discoverInstalledApps()
            }
        }
        .sheet(isPresented: $showAppPicker) {
            CLIContextAppPickerSheet(
                title: "Associate Apps with \(package.name)",
                selectedBundleIds: package.contextAppBundleIds
            ) { bundleIds in
                updateAssociatedApps(bundleIds)
            }
        }
    }

    private func updateAssociatedApps(_ bundleIds: [String]) {
        let normalizedBundleIds = Array(Set(bundleIds.filter { !$0.isEmpty })).sorted()
        var updated = package
        updated.contextAppBundleIds = normalizedBundleIds
        pkgMgr.updatePackage(updated)

        let selectedApps = installedApps.filter { normalizedBundleIds.contains($0.bundleId) }
        guard !selectedApps.isEmpty else { return }

        Task {
            for app in selectedApps {
                await adapterMgr.createAdapter(appName: app.name, bundleId: app.bundleId, icon: "app.fill")
            }
        }
    }
}

struct CLIContextAppPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSave: ([String]) -> Void

    @State private var searchText = ""
    @State private var installedApps: [InstalledApplicationEntry] = []
    @State private var selectedBundleIds: Set<String>

    init(title: String, selectedBundleIds: [String], onSave: @escaping ([String]) -> Void) {
        self.title = title
        self.onSave = onSave
        _selectedBundleIds = State(initialValue: Set(selectedBundleIds))
    }

    private var filteredApps: [InstalledApplicationEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return installedApps }
        let lowercasedQuery = query.lowercased()
        return installedApps.filter { app in
            app.name.lowercased().contains(lowercasedQuery)
                || app.bundleId.lowercased().contains(lowercasedQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Pick which app scopes should use this CLI.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(Array(selectedBundleIds).sorted())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            Button {
                selectedBundleIds.removeAll()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedBundleIds.isEmpty ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedBundleIds.isEmpty ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Any app")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("Leave this empty if the CLI should stay globally available.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Divider()

            if filteredApps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "app.badge")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(installedApps.isEmpty ? "No installed apps found" : "No apps match your search")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredApps) { app in
                    Button {
                        toggle(bundleId: app.bundleId)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedBundleIds.contains(app.bundleId) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedBundleIds.contains(app.bundleId) ? Color.accentColor : .secondary)
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 20, height: 20)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            } else {
                                AppBundleIconView(bundleId: app.bundleId, fallbackSymbol: "app.fill", size: 20, cornerRadius: 5)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(app.bundleId)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 520, height: 560)
        .task {
            if installedApps.isEmpty {
                installedApps = InstalledApplicationsCatalog.discoverInstalledApps()
            }
        }
    }

    private func toggle(bundleId: String) {
        if selectedBundleIds.contains(bundleId) {
            selectedBundleIds.remove(bundleId)
        } else {
            selectedBundleIds.insert(bundleId)
        }
    }
}

struct AppCLIToolPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared
    let appName: String
    let bundleId: String
    let alreadyLinked: Set<UUID>
    @State private var searchText = ""

    private var availableTools: [TerminalPackage] {
        let tools = pkgMgr.packages.filter { !alreadyLinked.contains($0.id) }
        guard !searchText.isEmpty else { return tools }
        let q = searchText.lowercased()
        return tools.filter { $0.name.lowercased().contains(q) || $0.command.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Link CLI Tools to \(appName)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Tap a tool to link it. Scoped dock chat for \(appName) will use its `--help` knowledge.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search CLI tools…", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            if availableTools.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(pkgMgr.packages.isEmpty ? "No CLI tools yet. Add tools in the CLI Tools section." : "All tools are already linked.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List {
                    ForEach(availableTools, id: \.id) { pkg in
                        Button {
                            var updated = pkg
                            if !updated.contextAppBundleIds.contains(bundleId) {
                                updated.contextAppBundleIds.append(bundleId)
                                pkgMgr.updatePackage(updated)
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.green.opacity(0.12))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: "terminal.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.green)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pkg.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(pkg.command).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.accentColor)
                                    .font(.system(size: 14))
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 420, height: 480)
    }
}

// MARK: - App Shortcut Picker Sheet

/// Lets the user link macOS Shortcuts to an App Adapter. Each picked shortcut is
/// stored as a `.shortcut` adapter action, so it surfaces in the dock (filtered
/// alongside menus / actions) only when that app is frontmost.
struct AppShortcutPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = ShortcutsCatalog.shared
    let appName: String
    let bundleId: String
    let alreadyLinked: Set<String>   // lowercased shortcut names already linked
    let onPick: (MacShortcut) -> Void
    @State private var searchText = ""

    private var availableShortcuts: [MacShortcut] {
        let items = catalog.shortcuts.filter {
            !alreadyLinked.contains($0.name.lowercased())
        }
        guard !searchText.isEmpty else { return items }
        let q = searchText.localizedLowercase
        return items.filter { $0.name.localizedLowercase.contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Link Shortcuts to \(appName)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Tap a shortcut to link it. It appears in the dock when \(appName) is frontmost.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    catalog.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reload shortcuts")
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search shortcuts…", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            if catalog.isLoading && catalog.shortcuts.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading shortcuts…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else if availableShortcuts.isEmpty {
                VStack(spacing: 8) {
                    ShortcutTileIcon(size: 36, corner: 9)
                    Text(catalog.shortcuts.isEmpty
                        ? "No shortcuts found. Create some in the Shortcuts app."
                        : "All shortcuts are already linked.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List {
                    ForEach(availableShortcuts) { shortcut in
                        Button {
                            onPick(shortcut)
                        } label: {
                            HStack(spacing: 10) {
                                ShortcutTileIcon(shortcut: shortcut)
                                Text(shortcut.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.accentColor)
                                    .font(.system(size: 14))
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 430, height: 500)
        // Always re-enumerate on open so shortcuts created since launch appear
        // (loadIfNeeded is a no-op once loaded → stale list).
        .onAppear { catalog.refresh() }
    }
}

struct GlobalCLIToolPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared

    let onPick: (TerminalPackage) -> Void
    @State private var searchText = ""

    private var availableTools: [TerminalPackage] {
        let tools = pkgMgr.packages.filter { package in
            package.isEnabled && !settings.isCLIToolPinned(package.command)
        }
        guard !searchText.isEmpty else { return tools }
        let q = searchText.localizedLowercase
        return tools.filter {
            $0.name.localizedLowercase.contains(q)
                || $0.command.localizedLowercase.contains(q)
                || $0.description.localizedLowercase.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Select CLI Tool")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Add a CLI tool scope to Global Actions.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search CLI tools...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            if availableTools.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(pkgMgr.packages.isEmpty ? "No CLI tools yet. Add tools in the CLI Tools section." : "All CLI tools are already in Global Actions.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List {
                    ForEach(availableTools, id: \.id) { pkg in
                        Button {
                            onPick(pkg)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.green.opacity(0.12))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: "terminal.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.green)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pkg.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(pkg.command)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.accentColor)
                                    .font(.system(size: 14))
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 430, height: 500)
    }
}

struct GlobalCLIScopeDetailView: View {
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared
    let package: TerminalPackage
    let onRemove: () -> Void
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(package.name)
                            .font(.system(size: 16, weight: .bold))
                        Text("Global Actions · CLI tool scope")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }

                Divider()

                AutomationDetailSection(title: "COMMAND") {
                    AutomationDetailRow(label: "Command", value: package.command, mono: true)
                    if let path = package.installedPath, !path.isEmpty {
                        AutomationDetailRow(label: "Path", value: path, mono: true)
                    }
                    if !package.description.isEmpty {
                        AutomationDetailRow(label: "Description", value: package.description)
                    }
                }

                AutomationDetailSection(title: "HELP SCAN") {
                    HStack(spacing: 10) {
                        Text((package.helpText?.isEmpty == false)
                             ? "\(package.subcommands.count) subcommand\(package.subcommands.count == 1 ? "" : "s") scanned"
                             : "Help not scanned")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            scanning = true
                            Task {
                                await pkgMgr.refreshHelpText(for: package.id)
                                await MainActor.run { scanning = false }
                            }
                        } label: {
                            Label(scanning ? "Scanning..." : "Scan --help", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(scanning)
                    }

                    if !package.subcommands.isEmpty {
                        Text(package.subcommands.prefix(20).joined(separator: "  "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(20)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

/// Generic capability groups an adapter can expose under the Tools tab. New
/// integration types (API, Skills) plug in here without per-app hardcoding.
enum AdapterToolGroupKind: String, CaseIterable, Identifiable {
    case shortcuts, cli, mcp, api, skills
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shortcuts: return "Shortcuts"
        case .cli: return "CLI Tools"
        case .mcp: return "MCP Servers"
        case .api: return "API Connections"
        case .skills: return "Skills"
        }
    }
    var icon: String {
        switch self {
        case .shortcuts: return "command"
        case .cli: return "terminal.fill"
        case .mcp: return "server.rack"
        case .api: return "link"
        case .skills: return "brain.head.profile"
        }
    }
    /// All capability groups are implemented.
    var isComingSoon: Bool { false }
}

struct SkillEditorSheet: View {
    let skill: AdapterSkill
    let onDone: (AdapterSkill?) -> Void

    @State private var name: String
    @State private var summary: String
    @State private var instructions: String
    @State private var version: String

    init(skill: AdapterSkill, onDone: @escaping (AdapterSkill?) -> Void) {
        self.skill = skill
        self.onDone = onDone
        _name = State(initialValue: skill.name)
        _summary = State(initialValue: skill.summary)
        _instructions = State(initialValue: skill.instructions)
        _version = State(initialValue: skill.version)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(skill.name.isEmpty ? "New Skill" : "Edit Skill")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var s = skill
                    s.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    s.summary = summary
                    s.instructions = instructions
                    s.version = version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "1.0" : version
                    onDone(s)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                    || instructions.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledField("Name") {
                        TextField("e.g. Code Review", text: $name).textFieldStyle(.roundedBorder)
                    }
                    LabeledField("Summary (optional)") {
                        TextField("One line shown in the list", text: $summary)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledField("Version") {
                        TextField("1.0", text: $version).textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    LabeledField("Instructions") {
                        TextEditor(text: $instructions)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 200)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                    Label("Skills guide scoped chat to the right linked tool. They can request a CLI command, but never grant execution permission.",
                        systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 480)
    }
}

enum AdapterDetailTab: String, CaseIterable, Identifiable {
    case overview, actions, tools, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .actions: return "Actions"
        case .tools: return "Tools"
        case .advanced: return "Advanced"
        }
    }
}

struct AutomationAdapterDetailView: View {
    let adapter: AppAdapter
    @Binding var selectedActionID: String?
    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared
    @ObservedObject private var mcpManager = MCPServerManager.shared
    @ObservedObject private var apiStore = APIConnectionStore.shared
    @ObservedObject private var skillStore = SkillStore.shared
    @ObservedObject private var consentStore = AdapterActionConsentStore.shared
    @ObservedObject private var safariBridge = SafariBrowserBridge.shared
    @State private var showAPIConnectSheet = false
    @State private var apiName = ""
    @State private var apiBaseURL = ""
    @State private var apiKey = ""
    @State private var editingSkill: AdapterSkill?
    @State private var showAddActionSheet = false
    @State private var editingAction: AdapterAction? = nil
    @State private var showCLIToolPicker = false
    @State private var showShortcutPicker = false
    @State private var showMCPSheet = false
    @State private var showDeleteConfirm = false
    @State private var isScanningHelp = false
    @State private var importPreview: AdapterPackPreview?
    @State private var importError: String?
    @State private var showSkillURLPrompt = false
    @State private var skillURLInput = ""
    @State private var isFetchingSkillURL = false
    @State private var expandedActionGroups: Set<String> = []
    @State private var detailTab: AdapterDetailTab = .overview
    @AppStorage("noteMCPEnabled") private var noteMCPEnabled: Bool = true
    @AppStorage("calendarMCPEnabled") private var calendarMCPEnabled: Bool = true
    @AppStorage("contactsMCPEnabled") private var contactsMCPEnabled: Bool = true
    @AppStorage("remindersMCPEnabled") private var remindersMCPEnabled: Bool = true
    @AppStorage("photosMCPEnabled") private var photosMCPEnabled: Bool = true
    @AppStorage("mailMCPEnabled") private var mailMCPEnabled: Bool = true
    @AppStorage("musicMCPEnabled") private var musicMCPEnabled: Bool = true
    @AppStorage("messagesMCPEnabled") private var messagesMCPEnabled: Bool = true
    @AppStorage("githubMCPEnabled") private var githubMCPEnabled: Bool = false

    private var packActionItems: [String] {
        currentAdapter.visibleActions.map { action in
            let kind = action.type == .pageJS ? "Browser extension" : action.type.displayName
            return "\(action.name) · \(kind)"
        }
    }

    private var packToolItems: [String] {
        var items = linkedCLITools.map {
            "\($0.name) · \($0.command) · \($0.isInstalled ? "installed" : "not installed")"
        }
        items += skillStore.skills(for: currentAdapter.bundleId).map {
            "\($0.name) · Skill v\($0.version)\($0.isEnabled ? "" : " · disabled")"
        }
        items += linkedShortcuts.map { "\($0.name) · Shortcut" }
        items += apiStore.connections(for: currentAdapter.bundleId).map { "\($0.name) · API" }
        items += linkedMCPServers.map { "\($0.name) · MCP (\($0.transport))" }
        if hasBuiltInIntegration {
            items.append("Context Dock native data tools · built in\(hasEnabledBuiltInIntegration ? " · enabled" : " · available")")
        }
        items += currentAdapter.contextReaders.map { "\($0.name) · Context reader (\($0.type))" }
        return items
    }

    @ViewBuilder
    private func packInventorySection(
        _ title: String, icon: String, items: [String], emptyText: String
    ) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                if items.isEmpty {
                    Text(emptyText).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Label(item, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 10))
            .padding(.top, 8)
        } label: {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var adapterPackInventory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("COMPLETE ADAPTER PACK")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Everything scoped chat can inspect, select, or request for this app.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(currentAdapter.isBuiltIn ? "Built in" : "Installed")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.teal.opacity(0.12), in: Capsule())
                    .foregroundStyle(.teal)
            }
            packInventorySection(
                "Actions and extensions", icon: "bolt.fill", items: packActionItems,
                emptyText: "No actions or browser extensions in this pack."
            )
            Divider()
            packInventorySection(
                "Tools, skills and readers", icon: "shippingbox.fill", items: packToolItems,
                emptyText: "No executable tools are linked; the app-aware skill still uses live context."
            )
            Divider()
            Label(
                "Read-only tools can be requested directly. Commands that write, delete, install, send, publish, or change remote state require approval.",
                systemImage: "checkmark.shield"
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("View Actions") { detailTab = .actions }
                Button("View Tools & Skills") { detailTab = .tools }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Plugin-style summary for the Overview tab — feels alive even with no actions.
    @ViewBuilder
    private var adapterOverview: some View {
        let a = currentAdapter
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                overviewCard("Status", a.isEnabled ? "Enabled" : "Disabled",
                    icon: a.isEnabled ? "checkmark.circle.fill" : "pause.circle.fill",
                    tint: a.isEnabled ? .green : .secondary)
                overviewCard("Actions", "\(appOnlyActions.count)", icon: "bolt.fill", tint: .teal)
                overviewCard("Shortcuts", "\(linkedShortcuts.count)", icon: "command", tint: .purple)
                overviewCard("CLI Tools", "\(linkedCLITools.count)", icon: "terminal.fill", tint: .blue)
                overviewCard("MCP Servers", "\(linkedMCPServerCount)", icon: "server.rack", tint: .orange)
            }
            if !a.bundleId.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BUNDLE ID").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text(a.bundleId).font(.system(size: 12, design: .monospaced))
                }
            }
            adapterPackInventory
            HStack(spacing: 8) {
                Button(action: importAdapterPack) {
                    Label("Import Adapter…", systemImage: "square.and.arrow.down")
                }
                Menu {
                    Button { Task { await adapterManager.duplicateAdapter(bundleId: a.bundleId) } }
                        label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { showDeleteConfirm = true }
                        label: { Label("Delete", systemImage: "trash") }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .controlSize(.small)
        }
        .padding(16)
    }

    private func overviewCard(_ title: String, _ value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text(value).font(.system(size: 22, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func importAdapterPack() {
        guard let url = AdapterPackImporter.shared.pickPack() else { return }
        do {
            importPreview = try AdapterPackImporter.shared.loadPreview(from: url)
        } catch {
            importError = error.localizedDescription
        }
    }

    // Import a web SKILL.md (Claude / Osaurus style) into the current adapter. Opens the
    // editor prefilled so the user can review/edit before saving — no silent install.
    private func importSkillFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText, .text, .data]
        for ext in ["md", "markdown"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        panel.prompt = "Import Skill"
        panel.message = "Choose a SKILL.md file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importError = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let fallback = url.deletingPathExtension().lastPathComponent
        loadSkillMarkdownIntoEditor(text, fallbackName: fallback)
    }

    private func importSkillFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            importError = "Clipboard is empty. Copy a SKILL.md first."
            return
        }
        loadSkillMarkdownIntoEditor(text, fallbackName: "Imported Skill")
    }

    /// Download a SKILL.md from a pasted link (GitHub blob URLs are auto-rewritten to raw)
    /// and open the editor prefilled.
    private func importSkillFromURL() {
        let raw = skillURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedSkillURL(raw) else {
            importError = "Enter a valid http(s) URL to a SKILL.md file."
            return
        }
        showSkillURLPrompt = false
        isFetchingSkillURL = true
        Task {
            defer { isFetchingSkillURL = false }
            do {
                var request = URLRequest(url: url)
                request.setValue("text/plain", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    importError = "Download failed (HTTP \(http.statusCode))."
                    return
                }
                guard let text = String(data: data, encoding: .utf8),
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    importError = "The file at that URL was empty or not text."
                    return
                }
                let fallback = url.deletingPathExtension().lastPathComponent
                loadSkillMarkdownIntoEditor(text, fallbackName: fallback)
            } catch {
                importError = "Couldn't download: \(error.localizedDescription)"
            }
        }
    }

    /// Accept raw links as-is; rewrite `github.com/owner/repo/blob/ref/path` → the
    /// `raw.githubusercontent.com` equivalent so a normal file URL works.
    private func normalizedSkillURL(_ input: String) -> URL? {
        guard let url = URL(string: input),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host?.lowercased()
        else { return nil }
        if host == "github.com", url.pathComponents.contains("blob") {
            var parts = url.pathComponents.filter { $0 != "/" }
            guard let blobIdx = parts.firstIndex(of: "blob"), blobIdx >= 2 else { return url }
            let owner = parts[0], repo = parts[1]
            parts.remove(at: blobIdx)  // drop "blob"
            let tail = parts.dropFirst(2).joined(separator: "/")  // ref/.../SKILL.md
            return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(tail)")
        }
        return url
    }

    private func loadSkillMarkdownIntoEditor(_ text: String, fallbackName: String) {
        guard let parsed = AdapterSkill.fromSkillMarkdown(
            text, bundleId: currentAdapter.bundleId, fallbackName: fallbackName)
        else {
            importError = "No skill content found. Expected a SKILL.md with a markdown body."
            return
        }
        editingSkill = parsed
    }

    private var currentAdapter: AppAdapter {
        adapterManager.adapters.first(where: { $0.id == adapter.id }) ?? adapter
    }

    @ViewBuilder
    private func actionRow(_ action: AdapterAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .font(.system(size: 13))
                .foregroundStyle(.teal)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.name)
                    .font(.system(size: 12, weight: .medium))
                Text(action.type.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editingAction = action
                showAddActionSheet = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            Button(role: .destructive) {
                Task {
                    await adapterManager.deleteAction(id: action.id, from: currentAdapter.bundleId)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.leading, 8)
    }

    private var visibleActions: [AdapterAction] {
        currentAdapter.visibleActions
    }

    private var appOnlyActions: [AdapterAction] {
        visibleActions.filter { $0.type != .pageJS && $0.type != .shortcut }
    }

    private var browserExtensionActions: [AdapterAction] {
        visibleActions.filter { $0.type == .pageJS }
    }

    // MARK: Safari extension health

    /// Live state of the Safari Web Extension pipeline. Without this a broken bridge is
    /// invisible — every consumer just silently falls back to AppleScript/AX.
    @ViewBuilder
    private var safariBridgeStatusRow: some View {
        let (symbol, tint, label): (String, Color, String) = {
            switch safariBridge.connection {
            case .live(let seen):
                return ("checkmark.circle.fill", .green,
                        "Safari extension connected — last page \(Self.relativeTime(seen))")
            case .idle(let seen):
                return ("pause.circle.fill", .yellow,
                        "Safari extension idle — last page \(Self.relativeTime(seen))")
            case .neverConnected:
                return ("xmark.circle.fill", .red,
                        "Safari extension has never sent a page. Enable “Context Dock” in "
                        + "Safari → Settings → Extensions and grant it site access.")
            }
        }()

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private static func relativeTime(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    /// Standing-grant control. Mirrors the "Always allow" choice from the approval
    /// dialog so a grant can be inspected and revoked without triggering the action.
    @ViewBuilder
    private func trustToggle(for action: AdapterAction) -> some View {
        let bundleId = currentAdapter.bundleId
        let trusted = consentStore.isAllowed(bundleId: bundleId, actionId: action.id)

        Button {
            if trusted {
                consentStore.revoke(bundleId: bundleId, actionId: action.id)
            } else {
                consentStore.allowAlways(bundleId: bundleId, actionId: action.id)
            }
        } label: {
            Image(systemName: trusted ? "checkmark.shield.fill" : "shield")
                .font(.system(size: 11))
                .foregroundStyle(trusted ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(trusted
              ? "Always allowed — runs without asking. Click to revoke."
              : "Asks for approval before each run. Click to always allow.")
    }

    /// macOS Shortcuts linked to this adapter (stored as `.shortcut` actions).
    private var linkedShortcuts: [AdapterAction] {
        visibleActions
            .filter { $0.type == .shortcut }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Linked count per capability group — drives the Tools overview chips.
    private func toolGroupCount(_ kind: AdapterToolGroupKind) -> Int {
        switch kind {
        case .shortcuts: return linkedShortcuts.count
        case .cli: return linkedCLITools.count
        case .mcp: return linkedMCPServerCount
        case .api: return apiStore.connections(for: currentAdapter.bundleId).count
        case .skills: return skillStore.skills(for: currentAdapter.bundleId).count
        }
    }

    @ViewBuilder
    private var toolGroupOverview: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10
        ) {
            ForEach(AdapterToolGroupKind.allCases) { kind in
                let count = toolGroupCount(kind)
                VStack(alignment: .leading, spacing: 4) {
                    Label(kind.title, systemImage: kind.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(kind.isComingSoon ? .secondary : .primary)
                    Text(
                        kind.isComingSoon
                            ? "Coming soon"
                            : (count == 0 ? "None linked" : "\(count) linked")
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .opacity(kind.isComingSoon ? 0.55 : 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// Extracts "yt-dlp" from bundleId "cli://yt-dlp", nil for real app adapters.
    private var cliCommandForAdapter: String? {
        let bid = currentAdapter.bundleId
        guard bid.hasPrefix("cli://") else { return nil }
        let cmd = String(bid.dropFirst("cli://".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cmd.isEmpty ? nil : cmd
    }

    private var linkedCLITools: [TerminalPackage] {
        pkgMgr.packages
            .filter { package in
                package.isEnabled && package.contextAppBundleIds.contains(currentAdapter.bundleId)
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private var linkedMCPServers: [MCPServerConfig] {
        mcpManager.servers(forBundleId: currentAdapter.bundleId)
    }

    private var hasEnabledBuiltInIntegration: Bool {
        switch currentAdapter.bundleId {
        case "com.apple.Notes": return noteMCPEnabled
        case "com.apple.iCal": return calendarMCPEnabled
        case "com.apple.AddressBook": return contactsMCPEnabled
        case "com.apple.reminders": return remindersMCPEnabled
        case "com.apple.Photos": return photosMCPEnabled
        case "com.apple.mail": return mailMCPEnabled
        case "com.apple.Music": return musicMCPEnabled
        case "com.apple.MobileSMS": return messagesMCPEnabled
        case "com.github.GitHubClient": return githubMCPEnabled
        default: return false
        }
    }

    private var linkedMCPServerCount: Int {
        linkedMCPServers.count + (hasEnabledBuiltInIntegration ? 1 : 0)
    }

    /// Expandable list of every tool a built-in Apple MCP exposes (title + inputs +
    /// Ask/Auto), so users can see all its possibilities like a full MCP tool sheet.
    @ViewBuilder
    private func builtInMCPToolsDisclosure(prefix: String, tint: Color) -> some View {
        let tools = CapabilityRegistry.shared.all
            .filter { $0.id.hasPrefix(prefix) }
            .sorted { $0.title < $1.title }
        if !tools.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(tools, id: \.id) { tool in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(tint)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tool.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.primary)
                                if !tool.inputSchema.fields.isEmpty {
                                    Text(
                                        "inputs: "
                                            + tool.inputSchema.fields
                                            .map { $0.name + ($0.required ? "" : "?") }
                                            .joined(separator: ", "))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 6)
                            Text(tool.riskLevel.requiresApproval ? "Ask" : "Auto")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(tool.riskLevel.requiresApproval ? .orange : .green)
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 2)
            } label: {
                Text("All tools · \(tools.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private var notesBuiltInMCPRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "note.text")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("DoraX Apple MCP · Notes")
                            .font(.system(size: 12, weight: .medium))
                        Text("built-in")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Text("search · read · create · append · update · summarize · tasks · link · export · delete")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                Toggle("", isOn: liveRegisteringBinding($noteMCPEnabled) {
                    AppleNotesMCPCapabilities.register(in: CapabilityRegistry.shared)
                })
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .onChange(of: noteMCPEnabled) { enabled in
                        if enabled {
                            CapabilityRegistry.shared.registerAppleNotesMCPIfNeeded()
                        }
                    }
            }
            .padding(.vertical, 6)

            if noteMCPEnabled {
                builtInMCPToolsDisclosure(prefix: "notes.", tint: .orange)
            }

            if !linkedMCPServers.isEmpty {
                Divider()
            }
        }
    }

    /// True when this adapter has a first-party built-in integration (Notes, Calendar,
    /// Contacts, Reminders, GitHub) — used for counts and the empty-state check.
    private var hasBuiltInIntegration: Bool {
        ["com.apple.Notes", "com.apple.iCal", "com.apple.AddressBook", "com.apple.reminders",
         "com.apple.Photos", "com.apple.mail", "com.apple.Music", "com.apple.MobileSMS",
         "com.github.GitHubClient"].contains(currentAdapter.bundleId)
    }

    /// Generic built-in integration row (same look as the Notes MCP row) for
    /// Calendar / Contacts / Reminders / GitHub adapters.
    @ViewBuilder
    private func builtInIntegrationRow(
        title: String, capabilities: String, icon: String, tint: Color, isOn: Binding<Bool>,
        toolPrefix: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                        Text("built-in")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(tint)
                    }
                    Text(capabilities)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.vertical, 6)

            if isOn.wrappedValue, let toolPrefix {
                builtInMCPToolsDisclosure(prefix: toolPrefix, tint: tint)
            }

            if !linkedMCPServers.isEmpty {
                Divider()
            }
        }
    }

    /// Registers the given built-in capability set the moment the toggle flips on, so the
    /// AI can use it without an app restart. (There is no unregister — flipping off relies
    /// on each executor's own settings guard until next launch.)
    private func liveRegisteringBinding(
        _ source: Binding<Bool>, register: @escaping @MainActor () -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue },
            set: { newValue in
                source.wrappedValue = newValue
                if newValue { MainActor.assumeIsolated { register() } }
            }
        )
    }

    /// The built-in integration row for the current adapter, if it has one (non-Notes).
    @ViewBuilder
    private var builtInIntegrationRowForCurrentAdapter: some View {
        switch currentAdapter.bundleId {
        case "com.apple.iCal":
            builtInIntegrationRow(
                title: "DoraX Apple MCP · Calendar",
                capabilities: "today · list upcoming · search · create event",
                icon: "calendar", tint: .red,
                isOn: liveRegisteringBinding($calendarMCPEnabled) {
                    AppleCalendarMCPCapabilities.register(in: CapabilityRegistry.shared)
                },
                toolPrefix: "calendar."
            )
        case "com.apple.AddressBook":
            builtInIntegrationRow(
                title: "DoraX Apple MCP · Contacts",
                capabilities: "search · contact details",
                icon: "person.crop.circle", tint: .brown,
                isOn: liveRegisteringBinding($contactsMCPEnabled) {
                    AppleContactsMCPCapabilities.register(in: CapabilityRegistry.shared)
                },
                toolPrefix: "contacts."
            )
        case "com.apple.reminders":
            builtInIntegrationRow(
                title: "DoraX Apple MCP · Reminders",
                capabilities: "today · list · create reminder",
                icon: "checklist", tint: .orange,
                isOn: liveRegisteringBinding($remindersMCPEnabled) {
                    AppleRemindersMCPCapabilities.register(in: CapabilityRegistry.shared)
                },
                toolPrefix: "reminders."
            )
        case "com.apple.Photos":
            builtInIntegrationRow(
                title: "DoraX Apple MCP · Photos",
                capabilities: "recent photos · search library",
                icon: "photo.on.rectangle", tint: .pink,
                isOn: liveRegisteringBinding($photosMCPEnabled) {
                    ApplePhotosMCPCapabilities.register(in: CapabilityRegistry.shared)
                },
                toolPrefix: "photos."
            )
        case "com.apple.mail":
            builtInIntegrationRow(
                title: "DoraX Apple MCP · Mail",
                capabilities: "recent inbox messages",
                icon: "envelope.fill", tint: .blue,
                isOn: liveRegisteringBinding($mailMCPEnabled) {
                    AppleMailMCPCapabilities.register(in: CapabilityRegistry.shared)
                },
                toolPrefix: "mail."
            )
        case "com.apple.Music":
            builtInIntegrationRow(
                title: "DoraX Apple MCP · Music",
                capabilities: "now playing · volume",
                icon: "music.note", tint: .pink,
                isOn: liveRegisteringBinding($musicMCPEnabled) {
                    AppleMusicMCPCapabilities.register(in: CapabilityRegistry.shared)
                },
                toolPrefix: "music."
            )
        case "com.apple.MobileSMS":
            builtInIntegrationRow(
                title: "DoraX Apple MCP · Messages",
                capabilities: "recent conversations · search · compose for review",
                icon: "message.fill", tint: .green,
                isOn: liveRegisteringBinding($messagesMCPEnabled) {
                    AppleMessagesMCPCapabilities.register(in: CapabilityRegistry.shared)
                },
                toolPrefix: "messages."
            )
        case "com.github.GitHubClient":
            builtInIntegrationRow(
                title: "DoraX GitHub (gh CLI)",
                capabilities: "list issues · list PRs · repo info · create issue",
                icon: "chevron.left.forwardslash.chevron.right", tint: .purple,
                isOn: liveRegisteringBinding($githubMCPEnabled) {
                    GitHubMCPCapabilities.register(in: CapabilityRegistry.shared)
                },
                toolPrefix: "github."
            )
        default:
            EmptyView()
        }
    }

    var body: some View {
        // CLI adapter (cli:// bundleId) gets a dedicated minimal view — no "App Actions" / "Linked CLI Tools".
        if let cliCmd = cliCommandForAdapter {
            cliAdapterBody(command: cliCmd)
        } else {
            appAdapterBody
        }
    }

    // MARK: - CLI adapter detail (cli:// bundleId)

    @ViewBuilder
    private func cliAdapterBody(command: String) -> some View {
        let pkg = pkgMgr.packages.first(where: { $0.command == command })
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentAdapter.appName)
                            .font(.system(size: 16, weight: .bold))
                        Text(command)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.red)
                }
                .padding(16)

                Divider()

                // Scan --help section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("CLI Command")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isScanningHelp {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { scanCLIHelp(command: command) } label: {
                                Label(
                                    pkg?.helpText?.isEmpty == false ? "Re-scan --help" : "Scan --help",
                                    systemImage: "doc.text.magnifyingglass"
                                )
                                .font(.system(size: 10, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }

                    HStack(spacing: 8) {
                        Text(command)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.primary)
                        Spacer()
                        if let p = pkg {
                            let scanned = !(p.helpText?.isEmpty ?? true)
                            Text(scanned
                                 ? "\(p.subcommands.count) subcommand\(p.subcommands.count == 1 ? "" : "s")"
                                 : "Not scanned")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(scanned ? .green : .secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(
                                    (scanned ? Color.green : Color.secondary).opacity(0.12),
                                    in: Capsule()
                                )
                        }
                    }

                    if let p = pkg, !p.subcommands.isEmpty {
                        Text(p.subcommands.prefix(15).joined(separator: "  "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    } else if pkg == nil {
                        Text("Click \"Scan --help\" to discover subcommands and enable AI assistance for \(command).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .alert("Remove \(currentAdapter.appName)?", isPresented: $showDeleteConfirm) {
            Button("Remove", role: .destructive) {
                Task {
                    await removeCurrentAdapterEverywhere()
                    await MainActor.run { selectedActionID = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \(currentAdapter.appName) from FrontmostApp Actions.")
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
                            if !ok { importError = "Couldn't install the adapter pack." }
                        }
                    }
                })
        }
        .alert(
            "Import Failed", isPresented: .constant(importError != nil),
            actions: { Button("OK") { importError = nil } },
            message: { Text(importError ?? "") })
    }

    private func removeCurrentAdapterEverywhere() async {
        await adapterManager.deleteAdapter(bundleId: currentAdapter.bundleId)
        await MainActor.run {
            AppSettings.shared.customAppEntries.removeAll {
                $0.key == currentAdapter.bundleId || $0.appPath == currentAdapter.bundleId
            }
            AppSettings.shared.appToolExtensions.removeAll { $0.appKey == currentAdapter.bundleId }
            for package in pkgMgr.packages where package.contextAppBundleIds.contains(currentAdapter.bundleId) {
                var updated = package
                updated.contextAppBundleIds.removeAll { $0 == currentAdapter.bundleId }
                pkgMgr.updatePackage(updated)
            }
            if let command = cliCommandForAdapter {
                AppSettings.shared.unpinCLITool(command)
                AppSettings.shared.customAppEntries.removeAll {
                    $0.key == "cli_\(command)" || $0.appPath == "cli://\(command)"
                }
                if let package = pkgMgr.packages.first(where: { $0.command == command }) {
                    var updated = package
                    updated.contextAppBundleIds.removeAll {
                        $0 == currentAdapter.bundleId || $0 == "cli_\(command)"
                    }
                    pkgMgr.updatePackage(updated)
                }
            }
        }
    }

    // MARK: - Regular app adapter detail

    private var appAdapterBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.teal.opacity(0.12))
                            .frame(width: 44, height: 44)
                        AppBundleIconView(bundleId: currentAdapter.bundleId, fallbackSymbol: currentAdapter.icon, size: 28, cornerRadius: 7)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentAdapter.appName)
                            .font(.system(size: 16, weight: .bold))
                        Text(currentAdapter.bundleId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    Button(action: importAdapterPack) {
                        Label("Import Adapter…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Install many actions for this app from an Adapter Pack")
                    Button {
                        presentAddActionEditor()
                    } label: {
                        Label("Add Action", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(16)

                Divider()

                Picker("", selection: $detailTab) {
                    ForEach(AdapterDetailTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if detailTab == .overview {
                    adapterOverview
                }

                if detailTab == .actions {
                // MARK: FrontmostApp Actions section (non-pageJS)
                VStack(alignment: .leading, spacing: 12) {
                    Text("FrontmostApp Actions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if appOnlyActions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(linkedCLITools.isEmpty && browserExtensionActions.isEmpty ? "No actions yet" : "No app actions yet")
                                .font(.system(size: 13, weight: .medium))
                            Text("Actions appear in DoraX when this app is frontmost. Add one manually, or import an adapter pack to install many at once.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button("Add First Action") {
                                    presentAddActionEditor()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Button {
                                    importAdapterPack()
                                } label: {
                                    Label("Import Adapter…", systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Install many actions for this app from an Adapter Pack")
                            }
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        // Group actions by category into collapsible packs. Each
                        // category expands via its arrow.
                        let grouped = Dictionary(grouping: appOnlyActions) {
                            ($0.category?.trimmingCharacters(in: .whitespaces)).flatMap {
                                $0.isEmpty ? nil : $0
                            } ?? "Actions"
                        }
                        ForEach(grouped.keys.sorted(), id: \.self) { key in
                            let groupActions = grouped[key] ?? []
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedActionGroups.contains(key) },
                                    set: { open in
                                        if open { expandedActionGroups.insert(key) }
                                        else { expandedActionGroups.remove(key) }
                                    })
                            ) {
                                ForEach(groupActions) { action in
                                    actionRow(action)
                                    if action.id != groupActions.last?.id {
                                        Divider().padding(.leading, 34)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(key)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("\(groupActions.count)")
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(16)

                // MARK: Browser Extensions section (pageJS)
                if !browserExtensionActions.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                            Text("Browser Extensions")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text("Page JS userscripts injected into the active browser tab.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        safariBridgeStatusRow

                        // Safari Web Apps expose no AppleScript interface, so pageJS can't
                        // reach them. Say so up front rather than letting each run fail.
                        if currentAdapter.bundleId.hasPrefix("com.apple.Safari.WebApp.") {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                Text("This is a Safari Web App. Web apps expose no AppleScript "
                                     + "interface, so Browser JavaScript can't run here yet — "
                                     + "open the site in Safari proper to use these actions.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 8))
                        }

                        ForEach(browserExtensionActions) { action in
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.orange.opacity(0.12))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: action.icon)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.orange)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(action.type.displayName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                trustToggle(for: action)
                                Button {
                                    editingAction = action
                                    showAddActionSheet = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) {
                                    Task {
                                        await adapterManager.deleteAction(id: action.id, from: currentAdapter.bundleId)
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 6)
                            if action.id != browserExtensionActions.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(16)
                }
                }  // end: if detailTab == .actions

                if detailTab == .tools {
                toolGroupOverview

                // MARK: API Connections section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("API Connections")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            apiName = ""; apiBaseURL = ""; apiKey = ""
                            showAPIConnectSheet = true
                        } label: {
                            Label("Connect", systemImage: "plus")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    let apiConns = apiStore.connections(for: currentAdapter.bundleId)
                    if apiConns.isEmpty {
                        Text("Connect an API to let scoped chat use this app's service. Keys are stored in your Keychain.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        ForEach(apiConns) { conn in
                            HStack(spacing: 10) {
                                Image(systemName: "link")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conn.name).font(.system(size: 12, weight: .medium))
                                    Text(conn.baseURL.isEmpty ? "Connected" : conn.baseURL)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Label("Connected", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.green)
                                Button(role: .destructive) {
                                    apiStore.disconnect(id: conn.id)
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain)
                            }
                            .padding(.vertical, 6)
                            if conn.id != apiConns.last?.id { Divider() }
                        }
                    }
                }
                .padding(16)

                Divider()

                // MARK: Skills section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Skills")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button {
                                skillURLInput = ""
                                showSkillURLPrompt = true
                            } label: {
                                Label("Import from URL…", systemImage: "link")
                            }
                            Button {
                                importSkillFromFile()
                            } label: {
                                Label("Import SKILL.md File…", systemImage: "doc.badge.plus")
                            }
                            Button {
                                importSkillFromClipboard()
                            } label: {
                                Label("Import from Clipboard", systemImage: "doc.on.clipboard")
                            }
                        } label: {
                            Label("Import Skill", systemImage: "square.and.arrow.down")
                                .font(.system(size: 10, weight: .medium))
                        } primaryAction: {
                            importSkillFromFile()
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .controlSize(.mini)
                        Button {
                            editingSkill = AdapterSkill(
                                adapterBundleId: currentAdapter.bundleId, name: "", instructions: "")
                        } label: {
                            Label("Add Skill", systemImage: "plus")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    let skills = skillStore.skills(for: currentAdapter.bundleId)
                    if skills.isEmpty {
                        Text("Skills guide scoped chat toward linked actions, CLI, MCP, APIs, Shortcuts and extensions. They may request a command, but execution still follows approval policy.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        ForEach(skills) { skill in
                            HStack(spacing: 10) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.purple)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name).font(.system(size: 12, weight: .medium))
                                    Text(skill.summary.isEmpty ? "v\(skill.version)" : "\(skill.summary) · v\(skill.version)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { skill.isEnabled },
                                    set: { skillStore.setEnabled($0, id: skill.id) }))
                                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                Button {
                                    editingSkill = skill
                                } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                                Button(role: .destructive) {
                                    skillStore.remove(id: skill.id)
                                } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                            }
                            .padding(.vertical, 6)
                            if skill.id != skills.last?.id { Divider() }
                        }
                    }
                }
                .padding(16)

                Divider()

                // MARK: Linked Shortcuts section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Linked Shortcuts")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            ShortcutsCatalog.shared.loadIfNeeded()
                            showShortcutPicker = true
                        } label: {
                            Label("Add Shortcut", systemImage: "plus")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    if linkedShortcuts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No linked shortcuts")
                                .font(.system(size: 13, weight: .medium))
                            Text("Link macOS Shortcuts to \(currentAdapter.appName). They appear in the dock — filtered alongside menus and actions — only when \(currentAdapter.appName) is frontmost.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        ForEach(linkedShortcuts) { action in
                            HStack(spacing: 10) {
                                ShortcutTileIcon(name: action.shortcutName ?? action.name)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text("Shortcut")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task {
                                        await adapterManager.deleteAction(id: action.id, from: currentAdapter.bundleId)
                                    }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 6)
                            if action.id != linkedShortcuts.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(16)
                }  // end: Tools (Shortcuts)

                if detailTab == .tools {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Linked CLI Tools")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showCLIToolPicker = true
                        } label: {
                            Label("Add CLI Tool", systemImage: "plus")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    if linkedCLITools.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No linked CLI tools")
                                .font(.system(size: 13, weight: .medium))
                            Text("Associate CLI tools to make scoped dock chat use their scanned `--help` knowledge for this app.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("Scoped dock chat for \(currentAdapter.appName) can use these CLI tools and ask for approval before running generated commands.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        ForEach(linkedCLITools, id: \.id) { package in
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.green.opacity(0.12))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: "terminal.fill")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.green)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(package.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Text(package.command)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    if !package.description.isEmpty {
                                        Text(package.description)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    } else if let path = package.installedPath, !path.isEmpty {
                                        Text(path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                let isScanned = package.helpText?.isEmpty == false
                                Button {
                                    Task { await pkgMgr.refreshHelpText(for: package.id) }
                                } label: {
                                    Text(isScanned ? "Scanned --help" : "Scan --help")
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(
                                            (isScanned ? Color.green : Color.orange).opacity(0.12),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(isScanned ? Color.green : Color.orange)
                                }
                                .buttonStyle(.plain)
                                .help(isScanned ? "Re-scan --help output" : "Scan --help to extract subcommands for AI")

                                Button(role: .destructive) {
                                    unlinkCLITool(package)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 6)
                            if package.id != linkedCLITools.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(16)
                }  // end: Tools (CLI)

                if detailTab == .tools {
                // MARK: Linked MCP section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Linked MCP")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showMCPSheet = true
                        } label: {
                            Label("Add MCP", systemImage: "plus")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    if currentAdapter.bundleId == "com.apple.Notes" {
                        notesBuiltInMCPRow
                    } else {
                        builtInIntegrationRowForCurrentAdapter
                    }

                    if linkedMCPServers.isEmpty && !hasBuiltInIntegration {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No linked MCP servers")
                                .font(.system(size: 13, weight: .medium))
                            Text("Link Model Context Protocol servers so scoped dock chat for \(currentAdapter.appName) can use their tools. Paste the app's mcpServers JSON config, or add a stdio command manually.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if !linkedMCPServers.isEmpty {
                        ForEach(linkedMCPServers) { server in
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.purple.opacity(0.12))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: "cpu")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.purple)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(server.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Text(server.transport)
                                            .font(.system(size: 9, weight: .medium))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.purple.opacity(0.12), in: Capsule())
                                            .foregroundStyle(.purple)
                                    }
                                    Text(([server.command] + server.args).joined(separator: " "))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                Button(role: .destructive) {
                                    mcpManager.unlink(id: server.id, from: currentAdapter.bundleId)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 6)
                            if server.id != linkedMCPServers.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(16)
                }  // end: Tools (MCP)

                if detailTab == .advanced {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Adapter")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BUNDLE ID")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(currentAdapter.bundleId)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        HStack(spacing: 8) {
                            Button(action: importAdapterPack) {
                                Label("Import Adapter…", systemImage: "square.and.arrow.down")
                            }
                            Button {
                                Task { await adapterManager.duplicateAdapter(bundleId: currentAdapter.bundleId) }
                            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            if let src = adapterManager.exportFileURL(for: currentAdapter.bundleId) {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([src])
                                } label: { Label("Show Source", systemImage: "folder") }
                            }
                        }
                        .controlSize(.small)

                        Divider()
                        Text("Danger Zone")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                        Button(role: .destructive) { showDeleteConfirm = true } label: {
                            Label("Delete Adapter", systemImage: "trash")
                        }
                        .controlSize(.small)
                    }
                    .padding(16)
                }

            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $showMCPSheet) {
            AddMCPServerSheet(
                appName: currentAdapter.appName,
                bundleId: currentAdapter.bundleId
            )
        }
        .sheet(isPresented: $showAddActionSheet) {
            AdapterActionEditorSheet(bundleId: currentAdapter.bundleId, existing: editingAction) {
                showAddActionSheet = false
                editingAction = nil
            }
        }
        .sheet(isPresented: $showAPIConnectSheet) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Connect API — \(currentAdapter.appName)")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("Cancel") { showAPIConnectSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Connect") {
                        apiStore.connect(
                            name: apiName, baseURL: apiBaseURL, apiKey: apiKey,
                            bundleId: currentAdapter.bundleId)
                        showAPIConnectSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiName.trimmingCharacters(in: .whitespaces).isEmpty
                        || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    LabeledField("Name") {
                        TextField("e.g. GitHub API", text: $apiName).textFieldStyle(.roundedBorder)
                    }
                    LabeledField("Base URL (optional)") {
                        TextField("https://api.github.com", text: $apiBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    LabeledField("API Key") {
                        SecureField("Stored in your Keychain", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Label("The key is saved to the macOS Keychain — never to disk or the adapter file.",
                        systemImage: "lock.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .frame(width: 460)
        }
        .sheet(item: $editingSkill) { skill in
            SkillEditorSheet(skill: skill) { saved in
                if let saved { skillStore.upsert(saved) }
                editingSkill = nil
            }
        }
        .sheet(isPresented: $showSkillURLPrompt) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import Skill from URL")
                    .font(.system(size: 15, weight: .semibold))
                Text("Paste a link to a SKILL.md. GitHub file (blob) links are converted to raw automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(
                    "https://raw.githubusercontent.com/…/SKILL.md",
                    text: $skillURLInput
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { importSkillFromURL() }
                HStack {
                    Spacer()
                    Button("Cancel") { showSkillURLPrompt = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Import") { importSkillFromURL() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(skillURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
        .sheet(isPresented: $showCLIToolPicker) {
            AppCLIToolPickerSheet(
                appName: currentAdapter.appName,
                bundleId: currentAdapter.bundleId,
                alreadyLinked: Set(linkedCLITools.map(\.id))
            )
        }
        .sheet(isPresented: $showShortcutPicker) {
            AppShortcutPickerSheet(
                appName: currentAdapter.appName,
                bundleId: currentAdapter.bundleId,
                alreadyLinked: Set(linkedShortcuts.map { ($0.shortcutName ?? $0.name).lowercased() }),
                onPick: { shortcut in linkShortcut(shortcut) }
            )
        }
        .alert("Remove \(currentAdapter.appName)?", isPresented: $showDeleteConfirm) {
            Button("Remove", role: .destructive) {
                Task {
                    await removeCurrentAdapterEverywhere()
                    await MainActor.run { selectedActionID = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all actions for \(currentAdapter.appName). This cannot be undone.")
        }
    }

    /// Persist a picked macOS Shortcut as a `.shortcut` adapter action so it
    /// surfaces in the dock when this app is frontmost.
    private func linkShortcut(_ shortcut: MacShortcut) {
        let name = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Skip duplicates (by shortcut name).
        if linkedShortcuts.contains(where: {
            ($0.shortcutName ?? $0.name).caseInsensitiveCompare(name) == .orderedSame
        }) { return }

        let action = AdapterAction(
            id: "shortcut-\(UUID().uuidString.prefix(8))",
            name: name,
            icon: shortcut.iconName,
            description: "Run the “\(name)” shortcut",
            triggers: [name],
            type: .shortcut,
            shortcutName: name,
            accentColor: shortcut.accentColor
        )
        let bid = currentAdapter.bundleId
        Task { await adapterManager.appendAction(action, to: bid) }
    }

    private func unlinkCLITool(_ package: TerminalPackage) {
        var updated = package
        updated.contextAppBundleIds = updated.contextAppBundleIds.filter { $0 != currentAdapter.bundleId }
        pkgMgr.updatePackage(updated)
    }

    private func scanCLIHelp(command: String) {
        isScanningHelp = true
        Task {
            if let existing = pkgMgr.packages.first(where: { $0.command == command }) {
                // Link to this adapter's bundleId if not already linked
                if !existing.contextAppBundleIds.contains(currentAdapter.bundleId) {
                    var updated = existing
                    updated.contextAppBundleIds.append(currentAdapter.bundleId)
                    await MainActor.run { pkgMgr.updatePackage(updated) }
                }
                await pkgMgr.refreshHelpText(for: existing.id)
            } else {
                // Create a new package linked to this adapter
                let newPkg = TerminalPackage(
                    name: command,
                    command: command,
                    description: "\(command) CLI tool",
                    contextAppBundleIds: [currentAdapter.bundleId]
                )
                await MainActor.run { pkgMgr.addPackage(newPkg) }
                await pkgMgr.refreshHelpTextByCommand(command)
            }
            await MainActor.run { isScanningHelp = false }
        }
    }

    private func presentAddActionEditor() {
        Task {
            await adapterManager.createAdapter(
                appName: currentAdapter.appName,
                bundleId: currentAdapter.bundleId,
                icon: currentAdapter.icon
            )
            await MainActor.run {
                editingAction = nil
                showAddActionSheet = true
            }
        }
    }
}

// MARK: - Shared Detail Helpers

private func detailHeader(icon: String, color: Color, title: String, badge: String) -> some View {
    HStack(spacing: 12) {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.12))
                .frame(width: 44, height: 44)
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
            Text(badge)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(color.opacity(0.1), in: Capsule())
        }
        Spacer()
    }
}

private func actionBar(onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
        Button("Edit", action: onEdit)
            .buttonStyle(.bordered)
            .controlSize(.small)
        Spacer()
        Button("Delete", action: onDelete)
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
    }
    .padding(.top, 4)
}

struct AutomationDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

struct AutomationDetailRow: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - New Automation Sheet

struct NewAutomationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var category: AutomationCategory
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared

    @State private var selectedType: AutomationCategory = .appActions

    // Script fields
    @State private var extName = ""
    @State private var extAppKey = ""
    @State private var extLang: AppScriptLanguage = .bash
    @State private var extCode = ""

    // Prompt fields
    @State private var promptName = ""
    @State private var promptAppKey = ""
    @State private var promptTemplate = ""

    // CLI fields
    @State private var cliName = ""
    @State private var cliCommand = ""
    @State private var cliDescription = ""

    // Trigger fields
    @State private var ruleName = "New Rule"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Automation")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Type picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AutomationCategory.allCases) { cat in
                        Button {
                            selectedType = cat
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 12, weight: .medium))
                                Text(cat.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                selectedType == cat
                                    ? cat.color.opacity(0.15)
                                    : Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(selectedType == cat ? cat.color : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            Divider()

            // Dynamic form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedType {
                    case .scripts:         scriptForm
                    case .aiPrompts:       promptForm
                    case .cliTools:        cliForm
                    case .contextTriggers: triggerForm
                    case .appActions:      appActionsInfo
                    case .clipboardActions: appActionsInfo
                    case .menuCache:       appActionsInfo
                    case .systemCommands:  appActionsInfo
                    }
                }
                .padding(24)
            }

            Divider()

            // Buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(24)
        }
        .frame(width: 520, height: 580)
        .onAppear { selectedType = category }
    }

    // MARK: Forms

    private var scriptForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            formField("Name") {
                TextField("e.g. compress_images", text: $extName)
                    .textFieldStyle(.roundedBorder)
            }
            formField("App Key") {
                TextField("e.g. finder (leave empty for global)", text: $extAppKey)
                    .textFieldStyle(.roundedBorder)
            }
            formField("Language") {
                Picker("", selection: $extLang) {
                    ForEach(AppScriptLanguage.allCases) { lang in
                        Text(lang.rawValue).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            formField("Script") {
                TextEditor(text: $extCode)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
                    )
            }
        }
    }

    private var promptForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            formField("Name") {
                TextField("e.g. summarize_page", text: $promptName)
                    .textFieldStyle(.roundedBorder)
            }
            formField("App Key") {
                TextField("e.g. safari (leave empty for global)", text: $promptAppKey)
                    .textFieldStyle(.roundedBorder)
            }
            formField("Template") {
                TextEditor(text: $promptTemplate)
                    .font(.system(size: 12))
                    .frame(height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
                    )
            }
            Text("Variables: {{query}}  {{date}}  {{time}}  {{clipboard}}  {{app}}")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var cliForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            formField("Name") {
                TextField("e.g. ImageMagick", text: $cliName)
                    .textFieldStyle(.roundedBorder)
            }
            formField("Command") {
                TextField("e.g. magick", text: $cliCommand)
                    .textFieldStyle(.roundedBorder)
            }
            formField("Description") {
                TextField("What does this tool do?", text: $cliDescription)
                    .textFieldStyle(.roundedBorder)
            }
            Text("The tool will be auto-scanned for subcommands and help text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var triggerForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            formField("Rule Name") {
                TextField("e.g. GitHub Repo Detected", text: $ruleName)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Conditions and actions can be configured in the detail editor after creation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appActionsInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.teal)
                Text("Create app-specific actions from the FrontmostApp Actions section.")
                    .font(.system(size: 13))
            }
            Text("Use FrontmostApp Actions to bind your own scripts, deep links, file openers, shell commands, AppleScript, and JXA actions to any installed app.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Helpers

    private var canCreate: Bool {
        switch selectedType {
        case .scripts:         return !extName.isEmpty
        case .aiPrompts:       return !promptName.isEmpty && !promptTemplate.isEmpty
        case .cliTools:        return !cliName.isEmpty && !cliCommand.isEmpty
        case .contextTriggers: return !ruleName.isEmpty
        case .appActions:      return false
        case .clipboardActions: return false
        case .menuCache:       return false
        case .systemCommands:  return false
        }
    }

    private func create() {
        switch selectedType {
        case .scripts:
            let path = settings.saveScript(
                appKey: extAppKey.isEmpty ? "global" : extAppKey,
                name: extName, language: extLang, code: extCode
            ) ?? ""
            let ext = AppToolExtension(
                appKey: extAppKey, toolName: extName, toolPath: path,
                kind: .script, scriptLanguage: extLang, scriptCode: extCode
            )
            settings.addToolExtension(ext)

        case .aiPrompts:
            let ext = AppToolExtension(
                appKey: promptAppKey, toolName: promptName,
                kind: .prompt, promptTemplate: promptTemplate
            )
            settings.addToolExtension(ext)

        case .cliTools:
            let pkg = TerminalPackage(
                name: cliName, command: cliCommand, description: cliDescription
            )
            pkgMgr.addPackage(pkg)
            Task { await pkgMgr.refreshHelpTextByCommand(cliCommand) }

        case .contextTriggers:
            let rule = AXTriggerRule(name: ruleName)
            settings.addAXRule(rule)

        case .appActions:
            break
        case .clipboardActions:
            break
        case .menuCache:
            break
        case .systemCommands:
            break
        }

        category = selectedType
        dismiss()
    }

    @ViewBuilder
    private func formField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct AIExtensionImportSheet: View {
    let onImport: (ContextDockAIImportPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rawJSON = ""
    @State private var errorMessage: String?
    @State private var importSummary: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Paste AI Result")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Import a Context-Dock extension JSON payload and save it as a real extension.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Paste from Clipboard") {
                    rawJSON = NSPasteboard.general.string(forType: .string) ?? ""
                    errorMessage = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $rawJSON)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if let importSummary {
                    Text(importSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .padding(18)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Import") {
                    importPayload()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 700, height: 520)
        .onAppear {
            if rawJSON.isEmpty {
                rawJSON = NSPasteboard.general.string(forType: .string) ?? ""
            }
        }
    }

    private func importPayload() {
        // Try new simplified format first, then fall back to legacy ContextDockAIImportPayload
        if let simple = try? SimpleAIExtensionImport.decode(from: rawJSON) {
            let exts = simple.toILExtensions()
            exts.forEach { LayeredExtensionManager.shared.addExtension($0) }
            let layerName = exts.first?.layer.displayName ?? "Extensions"
            importSummary = "Imported \(exts.count) extension\(exts.count == 1 ? "" : "s") into \(layerName)."
            errorMessage = nil
            dismiss()
            return
        }
        do {
            let payload = try ContextDockAIImportPayload.decode(from: rawJSON)
            let layer = payload.makeILExtension().layer.displayName
            importSummary = "Imported \(payload.name) into \(layer)."
            errorMessage = nil
            onImport(payload)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Editor Sheets (thin wrappers around existing editors)

struct ShortcutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    let shortcut: AppShortcut

    @State private var name: String
    @State private var iconName: String
    @State private var actionType: AppShortcut.ActionType
    @State private var actionValue: String
    @State private var appKey: String
    @State private var placement: AppShortcut.Placement

    init(shortcut: AppShortcut) {
        self.shortcut = shortcut
        _name = State(initialValue: shortcut.name)
        _iconName = State(initialValue: shortcut.iconName)
        _actionType = State(initialValue: shortcut.actionType)
        _actionValue = State(initialValue: shortcut.actionValue)
        _appKey = State(initialValue: shortcut.appKey)
        _placement = State(initialValue: shortcut.placement)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Shortcut")
                .font(.system(size: 16, weight: .bold))
                .padding(20)

            Divider()

            Form {
                TextField("Name", text: $name)
                TextField("App Key", text: $appKey)
                Picker("Action Type", selection: $actionType) {
                    ForEach([AppShortcut.ActionType.openURL, .openFile, .shellCommand, .appleScript, .jxa, .scriptFile, .menuItem], id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                TextField("Action Value", text: $actionValue)
                Picker("Placement", selection: $placement) {
                    Text("Quick Actions").tag(AppShortcut.Placement.quickActions)
                    Text("Context Dock").tag(AppShortcut.Placement.contextDock)
                    Text("Both").tag(AppShortcut.Placement.both)
                    Text("File Actions").tag(AppShortcut.Placement.fileActions)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if settings.appShortcuts.isEmpty {
                        settings.appShortcuts = AppShortcut.builtInDefaults
                    }
                    if let idx = settings.appShortcuts.firstIndex(where: { $0.id == shortcut.id }) {
                        settings.appShortcuts[idx].name = name
                        settings.appShortcuts[idx].iconName = iconName
                        settings.appShortcuts[idx].actionType = actionType
                        settings.appShortcuts[idx].actionValue = actionValue
                        settings.appShortcuts[idx].appKey = appKey
                        settings.appShortcuts[idx].placement = placement
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 460, height: 420)
    }
}

struct ScriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    let `extension`: AppToolExtension

    @State private var code: String

    init(extension ext: AppToolExtension) {
        self.extension = ext
        _code = State(initialValue: ext.scriptCode)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Script")
                .font(.system(size: 16, weight: .bold))
                .padding(20)
            Divider()
            TextEditor(text: $code)
                .font(.system(size: 12, design: .monospaced))
                .padding(16)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    var updated = `extension`
                    updated.scriptCode = code
                    if let idx = settings.appToolExtensions.firstIndex(where: { $0.id == `extension`.id }) {
                        settings.appToolExtensions[idx] = updated
                    }
                    _ = settings.saveScript(
                        appKey: `extension`.appKey.isEmpty ? "global" : `extension`.appKey,
                        name: `extension`.toolName,
                        language: `extension`.scriptLanguage ?? .bash,
                        code: code
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 600, height: 500)
    }
}

struct PromptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    let `extension`: AppToolExtension

    @State private var template: String
    @State private var cacheTTL: Int

    init(extension ext: AppToolExtension) {
        self.extension = ext
        _template = State(initialValue: ext.promptTemplate)
        _cacheTTL = State(initialValue: ext.cacheTTLMinutes)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit AI Prompt")
                .font(.system(size: 16, weight: .bold))
                .padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Template")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $template)
                    .font(.system(size: 12))
                    .frame(height: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                Text("Variables: {{query}}  {{date}}  {{time}}  {{clipboard}}  {{app}}")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Cache TTL (minutes, 0 = no cache)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("", value: $cacheTTL, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
            }
            .padding(20)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if let idx = settings.appToolExtensions.firstIndex(where: { $0.id == `extension`.id }) {
                        settings.appToolExtensions[idx].promptTemplate = template
                        settings.appToolExtensions[idx].cacheTTLMinutes = cacheTTL
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - App Action Samples Section

private struct AppActionSamplesSection: View {
    @State private var expanded: String? = nil

    struct Recipe: Identifiable {
        var id: String { type }
        let type: String
        let badge: String
        let icon: String
        let color: Color
        let tagline: String
        let examples: [(title: String, code: String)]
    }

    private let recipes: [Recipe] = [
        Recipe(
            type: "shell", badge: "shell", icon: "terminal.fill", color: .green,
            tagline: "Bash — use {{selection}}, {{file}}, {{url}}, {{query}}, {{clipboard}}",
            examples: [
                ("Copy selection to clipboard",   "echo '{{selection}}' | pbcopy"),
                ("Read selected text aloud",      "say '{{selection}}'"),
                ("Open file in VS Code",          "open -a 'Visual Studio Code' '{{file}}'"),
                ("Word count of selection",       "echo '{{selection}}' | wc -w"),
                ("Weather for typed city",        "curl -s 'https://wttr.in/{{query}}?format=3'"),
                ("Google search in browser",      "open 'https://www.google.com/search?q={{query}}'"),
            ]
        ),
        Recipe(
            type: "pageJS", badge: "pageJS", icon: "safari", color: .cyan,
            tagline: "JavaScript injected into Safari — $PAGE_TEXT, $CURRENT_URL, $PAGE_TITLE available",
            examples: [
                ("Scroll to top",                 "window.scrollTo({top:0,behavior:'smooth'});'Scrolled to top'"),
                ("Scroll to bottom",              "window.scrollTo({top:document.body.scrollHeight,behavior:'smooth'});'Done'"),
                ("Word count on page",            "(function(){return'Words: '+document.body.innerText.split(/\\s+/).length;})()"),
                ("Click element by text",         "(function(){var el=Array.from(document.querySelectorAll('a,button')).find(e=>e.textContent.toLowerCase().includes('{{query}}'.toLowerCase()));if(el){el.scrollIntoView();el.click();return'Clicked: '+el.textContent.trim();}return'Not found';})()"),
                ("Highlight text on page",        "(function(){document.body.innerHTML=document.body.innerHTML.replace(/{{query}}/gi,'<mark style=\"background:#FFD60A;color:#000\">$&</mark>');return'Highlighted';})()"),
                ("Copy all links",                "(function(){var h=[...new Set(Array.from(document.querySelectorAll('a[href]')).map(a=>a.href).filter(h=>h.startsWith('http')))].slice(0,50);navigator.clipboard.writeText(h.join('\\n'));return'Copied '+h.length+' links';})()"),
                ("Toggle dark mode",              "(function(){var el=document.documentElement;var f=el.style.filter||'';el.style.filter=f.includes('invert')?f.replace('invert(1) hue-rotate(180deg)','').trim():(f+' invert(1) hue-rotate(180deg)').trim();return'Toggled';})()"),
                ("Extract prices on page",        "(function(){var p=(document.body.innerText.match(/[$€£¥₹][\\d,]+\\.?\\d{0,2}/g)||[]);return[...new Set(p)].slice(0,20).join('\\n')||'No prices found';})()"),
            ]
        ),
        Recipe(
            type: "applescript", badge: "applescript", icon: "applescript", color: .orange,
            tagline: "Automate macOS apps with AppleScript — variables are plain text replacements",
            examples: [
                ("Save selection to Notes",       "tell application \"Notes\" to make new note with properties {name:\"{{query}}\", body:\"{{selection}}\"}"),
                ("Add to Reminders",              "tell application \"Reminders\" to make new reminder with properties {name:\"{{selection}}\"}"),
                ("Draft email with selection",    "tell application \"Mail\" to make new outgoing message with properties {subject:\"{{selection}}\", content:\"\"}"),
                ("Open URL in Safari",            "tell application \"Safari\" to open location \"{{url}}\""),
                ("Speak selected text",           "say \"{{selection}}\""),
                ("Show alert dialog",             "tell application \"System Events\" to display dialog \"{{selection}}\""),
            ]
        ),
        Recipe(
            type: "jxa", badge: "jxa", icon: "curlybraces", color: .yellow,
            tagline: "JavaScript for Automation — reads live app data, return value shows in dock",
            examples: [
                ("Current Safari URL",            "Application('Safari').windows[0].currentTab.url()"),
                ("Current Safari page title",     "Application('Safari').windows[0].currentTab.name()"),
                ("Finder selected file names",    "Application('Finder').selection().map(f=>f.name()).join(', ')"),
                ("Frontmost app name",            "Application('System Events').frontmost.name()"),
                ("Note count in Notes",           "Application('Notes').notes.length+' notes'"),
                ("Volume level",                  "Application('System Events').audioVolume()+'%'"),
            ]
        ),
        Recipe(
            type: "aiPrompt", badge: "aiPrompt", icon: "sparkles", color: .indigo,
            tagline: "Pre-fills the AI chat — {{selection}}, {{url}}, {{query}}, {{clipboard}} available",
            examples: [
                ("Summarise selection",           "Summarise this in 3 bullet points:\n{{selection}}"),
                ("Translate to Tamil",            "Translate the following to Tamil:\n{{selection}}"),
                ("Explain code",                  "Explain what this code does step by step:\n{{selection}}"),
                ("Fix grammar",                   "Fix the grammar and spelling of this text:\n{{selection}}"),
                ("Summarise web page",            "Summarise what this page is about: {{url}}"),
                ("Answer about query",            "Answer this question concisely: {{query}}"),
            ]
        ),
        Recipe(
            type: "urlScheme", badge: "urlScheme", icon: "link", color: .teal,
            tagline: "Open apps via URL deep-links — $CURRENT_URL, $AX_SELECTED_TEXT, {{query}} supported",
            examples: [
                ("New Obsidian note",             "obsidian://new?content={{selection}}"),
                ("Google search",                 "https://www.google.com/search?q={{query}}"),
                ("Google Translate selection",    "https://translate.google.com/?sl=auto&tl=en&text={{selection}}"),
                ("Bear note with selection",      "bear://x-callback-url/create?title={{query}}&text={{selection}}"),
                ("Open Privacy prefs",            "x-apple.systempreferences:com.apple.preference.security"),
                ("Open current URL in Chrome",    "googlechrome://$CURRENT_URL"),
            ]
        ),
        Recipe(
            type: "menubar", badge: "menubar", icon: "menubar.rectangle", color: .blue,
            tagline: "Clicks any macOS menu item by path — must match the menu hierarchy exactly",
            examples: [
                ("New tab (Safari)",              "[\"File\", \"New Tab\"]"),
                ("Close tab (Safari)",            "[\"File\", \"Close Tab\"]"),
                ("Reload page (Safari)",          "[\"View\", \"Reload Page\"]"),
                ("Open Find panel (any app)",     "[\"Edit\", \"Find\", \"Find…\"]"),
                ("Export as PDF (Safari)",        "[\"File\", \"Export as PDF…\"]"),
                ("Zoom window (any app)",         "[\"Window\", \"Zoom\"]"),
            ]
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(recipes) { recipe in
                recipeRow(recipe)
                if recipe.type != recipes.last?.type {
                    Divider().padding(.leading, 36)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.09)))
    }

    private func recipeRow(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expanded = expanded == recipe.type ? nil : recipe.type
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: recipe.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(recipe.color)
                        .frame(width: 18)
                    Text(recipe.badge)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(recipe.color)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(recipe.tagline)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: expanded == recipe.type ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(expanded == recipe.type ? recipe.color.opacity(0.05) : Color.clear)

            if expanded == recipe.type {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(recipe.examples, id: \.title) { ex in
                        codeBlock(title: ex.title, code: ex.code, color: recipe.color)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .background(recipe.color.opacity(0.04))
            }
        }
    }

    private func codeBlock(title: String, code: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
            HStack(alignment: .center, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize()
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(color.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.textBackgroundColor).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

#Preview {
    AutomationSettingsView()
        .frame(width: 960, height: 680)
}

// MARK: - Import Destination

enum ImportDestination: String, CaseIterable {
    case globalContext = "Global Context"
    case contextDock   = "Context Dock"
    case shortcutSheet = "Selection Scope"

    var icon: String {
        switch self {
        case .globalContext: return "globe"
        case .contextDock:   return "dock.rectangle"
        case .shortcutSheet: return "command.square"
        }
    }

    var color: Color {
        switch self {
        case .globalContext: return .purple
        case .contextDock:   return .blue
        case .shortcutSheet: return .red
        }
    }

    var subtitle: String {
        switch self {
        case .globalContext: return "Always-available command from global search"
        case .contextDock:   return "Auto-shows dock pill when URL, app, or file matches"
        case .shortcutSheet: return "Appears in the Selection Scope for selected text or files"
        }
    }

    var savesAs: String {
        switch self {
        case .globalContext: return "→ saved as Script"
        case .contextDock:   return "→ saved as Context Trigger"
        case .shortcutSheet: return "→ saved as Selection Scope Action"
        }
    }
}

// MARK: - Sidebar Import Row

struct AutomationImportSidebarRow: View {
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(colors: [.purple.opacity(0.12), .blue.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 28, height: 28)
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .purple)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Import")
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text("Paste AI-generated JSON")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            isSelected
            ? AnyView(LinearGradient(colors: [.purple.opacity(0.1), .blue.opacity(0.1)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                      .clipShape(RoundedRectangle(cornerRadius: 8)))
            : AnyView(Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Automation Import Panel

struct AutomationImportPanel: View {
    var onClose: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var jsonText = ""
    @State private var parsed: SimpleAIExtensionImport? = nil
    @State private var parsedSystemCommands: [SystemCommand] = []
    @State private var parsedAppAdapter: AppAdapter? = nil
    @State private var parseError: String? = nil
    @State private var destination: ImportDestination = .contextDock
    @State private var didImport = false
    @State private var importedName = ""
    @State private var importedDest: ImportDestination = .contextDock
    @State private var showCreateExtensionSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [.purple.opacity(0.15), .blue.opacity(0.15)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.purple, .blue],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Extension")
                        .font(.system(size: 14, weight: .bold))
                    Text("Paste AI-generated JSON — auto-detected and saved to Global Context, Context Dock, or Selection Scope")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !jsonText.isEmpty && !didImport {
                    Button("Clear") { resetPanel() }
                        .buttonStyle(.bordered).controlSize(.small).tint(.red)
                }
                Button(action: { showCreateExtensionSheet = true }) {
                    Label("Create Extension", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(action: pasteFromClipboard) {
                    Label("Paste", systemImage: "doc.on.clipboard").font(.system(size: 11))
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if didImport {
                successView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {

                        // Destination picker
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SAVE TO")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)

                            HStack(spacing: 10) {
                                ForEach(ImportDestination.allCases, id: \.self) { dest in
                                    destinationCard(dest)
                                        .onTapGesture { destination = dest }
                                }
                            }

                            if parsed != nil || !parsedSystemCommands.isEmpty || parsedAppAdapter != nil {
                                HStack(spacing: 4) {
                                    Image(systemName: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
                                    Text("Auto-detected from triggers")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }

                        // JSON editor
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("JSON PAYLOAD")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                Spacer()
                                if parsed != nil || !parsedSystemCommands.isEmpty || parsedAppAdapter != nil {
                                    Label("Valid", systemImage: "checkmark.circle.fill")
                                        .font(.caption).foregroundStyle(.green)
                                } else if parseError != nil && !jsonText.isEmpty {
                                    Label("Check format", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            ZStack(alignment: .topLeading) {
                                if jsonText.isEmpty {
                                    Text("Paste JSON here…")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.quaternary)
                                        .padding(10).allowsHitTesting(false)
                                }
                                TextEditor(text: $jsonText)
                                    .font(.system(size: 12, design: .monospaced))
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .frame(minHeight: 180, maxHeight: 300)
                                    .onChange(of: jsonText) { _, new in parseAndDetect(new) }
                            }
                            .background(Color(NSColor.textBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                (parsed != nil || !parsedSystemCommands.isEmpty || parsedAppAdapter != nil) ? .green.opacity(0.5) :
                                (parseError != nil && !jsonText.isEmpty) ? .orange.opacity(0.4) :
                                    .secondary.opacity(0.18), lineWidth: 1))
                        }

                        // Preview cards
                        if let adapter = parsedAppAdapter {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("App adapter ready",
                                      systemImage: "checkmark.seal.fill")
                                    .font(.caption.bold()).foregroundStyle(.green)
                                appAdapterImportPreviewCard(adapter)
                            }
                        } else if !parsedSystemCommands.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("\(parsedSystemCommands.count) system command\(parsedSystemCommands.count == 1 ? "" : "s") ready",
                                      systemImage: "checkmark.seal.fill")
                                    .font(.caption.bold()).foregroundStyle(.green)

                                ForEach(parsedSystemCommands) { command in
                                    systemCommandImportPreviewCard(command)
                                }
                            }
                        } else if let payload = parsed {
                            let exts = payload.toILExtensions()
                            VStack(alignment: .leading, spacing: 10) {
                                Label("\(exts.count) extension\(exts.count == 1 ? "" : "s") ready",
                                      systemImage: "checkmark.seal.fill")
                                    .font(.caption.bold()).foregroundStyle(.green)

                                ForEach(exts) { ext in
                                    importPreviewCard(ext)
                                }
                            }
                        }

                        // Empty state tip
                        if jsonText.isEmpty {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "lightbulb.fill").foregroundStyle(.orange).font(.caption)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("How to get extensions").font(.caption.bold())
                                    Text("Pick a template below, copy it, and paste it into any AI (Claude, ChatGPT, Gemini). Paste the JSON it returns above — it's imported and live immediately.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }

                        Divider()

                        // Prompt templates — copy one, paste into an AI to author
                        // a Global Context / Context Dock / Shortcut Sheet extension.
                        PromptTemplatesSection()
                    }
                    .padding(20)
                }

                Divider()

                // Footer
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: destination.icon).font(.caption).foregroundStyle(destination.color)
                        Text(destination.savesAs).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import & Save") { commitImport() }
                        .buttonStyle(.borderedProminent)
                        .tint(LinearGradient(colors: [.purple, .blue],
                                             startPoint: .leading, endPoint: .trailing))
                        .disabled(parsed == nil && parsedSystemCommands.isEmpty && parsedAppAdapter == nil)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { pasteFromClipboard() }
        .sheet(isPresented: $showCreateExtensionSheet) {
            CreateExtensionSheet(defaultDestination: destination) { draft in
                commitCreatedExtension(draft)
                showCreateExtensionSheet = false
            }
        }
    }

    // MARK: Sub-views

    @ViewBuilder
    private func destinationCard(_ dest: ImportDestination) -> some View {
        let isSelected = destination == dest
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: dest.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? dest.color : .secondary)
                Text(dest.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(dest.color)
                }
            }
            Text(dest.subtitle)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            Text(dest.savesAs)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(dest.color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? dest.color.opacity(0.08) : Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? dest.color.opacity(0.4) : .secondary.opacity(0.15), lineWidth: 1))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func importPreviewCard(_ ext: ILExtension) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(destination.color.opacity(0.1))
                    .frame(width: 38, height: 38)
                Image(systemName: ext.icon)
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(destination.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ext.name).font(.system(size: 13, weight: .semibold))
                    Text(ext.scriptType.rawValue.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.secondary.opacity(0.1), in: Capsule())
                }
                Text(ext.description)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(Array(ext.triggers.prefix(3).enumerated()), id: \.offset) { _, t in
                        Text(triggerLabel(t))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.secondary.opacity(0.08), in: Capsule())
                    }
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.green.opacity(0.2), lineWidth: 1))
    }

    @ViewBuilder
    private func systemCommandImportPreviewCard(_ command: SystemCommand) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.indigo.opacity(0.1))
                    .frame(width: 38, height: 38)
                Image(systemName: command.icon)
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(Color.indigo)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(command.name).font(.system(size: 13, weight: .semibold))
                    Text(command.actionTypeLabel.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.secondary.opacity(0.1), in: Capsule())
                }
                Text(command.description)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if let preset = command.keywords.first(where: { $0.lowercased().hasPrefix("presets:") }) {
                    Text(preset)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "slider.horizontal.3").foregroundStyle(.indigo)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.indigo.opacity(0.2), lineWidth: 1))
    }

    @ViewBuilder
    private func appAdapterImportPreviewCard(_ adapter: AppAdapter) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 38, height: 38)
                Image(systemName: adapter.icon.isEmpty ? "app.connected.to.app.below.fill" : adapter.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(adapter.appName).font(.system(size: 13, weight: .semibold))
                    Text("\(adapter.actions.count) ACTION\(adapter.actions.count == 1 ? "" : "S")")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.secondary.opacity(0.1), in: Capsule())
                }
                Text(adapter.bundleId)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(adapter.actions.prefix(3)) { action in
                        Text(action.name)
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.secondary.opacity(0.08), in: Capsule())
                    }
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.2), lineWidth: 1))
    }

    private var successView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.purple.opacity(0.12), .blue.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(LinearGradient(colors: [.purple, .blue],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            VStack(spacing: 6) {
                Text("**\(importedName)** imported")
                    .font(.title3)
                Text("Saved to \(importedDest.rawValue) · active immediately")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Import Another") { resetPanel() }
                    .buttonStyle(.bordered)
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(LinearGradient(colors: [.purple, .blue],
                                         startPoint: .leading, endPoint: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Logic

    /// AI chat UIs (and macOS "smart quotes") turn straight quotes into curly ones, which
    /// is invalid JSON — the #1 reason a pasted pack fails "Check format". Normalize them
    /// back before parsing so a copy-paste from any chat just works.
    static func normalizeSmartQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{201C}", with: "\"")   // " left double
            .replacingOccurrences(of: "\u{201D}", with: "\"")   // " right double
            .replacingOccurrences(of: "\u{201E}", with: "\"")   // „ low double
            .replacingOccurrences(of: "\u{2033}", with: "\"")   // ″ double prime
            .replacingOccurrences(of: "\u{FF02}", with: "\"")   // ＂ fullwidth double
            .replacingOccurrences(of: "\u{2018}", with: "'")    // ' left single
            .replacingOccurrences(of: "\u{2019}", with: "'")    // ' right single
            .replacingOccurrences(of: "\u{FF07}", with: "'")    // ＇ fullwidth single
    }

    private func parseAndDetect(_ text: String) {
        let t = Self.normalizeSmartQuotes(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            parsed = nil
            parsedSystemCommands = []
            parsedAppAdapter = nil
            parseError = nil
            return
        }
        if let commandPayload = try? SystemCommandAIImport.decode(from: t) {
            parsed = nil
            parsedSystemCommands = commandPayload.toSystemCommands()
            parsedAppAdapter = nil
            destination = .globalContext
            parseError = parsedSystemCommands.isEmpty ? "No system commands found in the payload." : nil
            return
        }
        if let adapter = try? AppAdapterAIImport.decode(from: t) {
            parsed = nil
            parsedSystemCommands = []
            parsedAppAdapter = adapter
            destination = .contextDock
            parseError = adapter.actions.isEmpty ? "No adapter actions found in the payload." : nil
            return
        }
        do {
            let payload = try SimpleAIExtensionImport.decode(from: t)
            parsed = payload
            parsedSystemCommands = []
            parsedAppAdapter = nil
            parseError = nil
            // Auto-detect destination from first extension's triggers
            if let spec = payload.extensions.first {
                destination = autoDetect(spec)
            }
        } catch {
            parsed = nil
            parsedSystemCommands = []
            parsedAppAdapter = nil
            parseError = error.localizedDescription
        }
    }

    private func autoDetect(_ spec: SimpleAIExtensionImport.ExtensionSpec) -> ImportDestination {
        let hasSelectionTrigger = spec.triggers.contains { $0.type == "selection" }
        if hasSelectionTrigger {
            return .shortcutSheet
        }

        let hasContextTrigger = spec.triggers.contains {
            ["urlPattern", "appContext", "fileType"].contains($0.type)
        }
        return hasContextTrigger ? .contextDock : .globalContext
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let t = Self.normalizeSmartQuotes(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("```") else { return }
        jsonText = t
        parseAndDetect(t)
    }

    private func commitImport() {
        if let adapter = parsedAppAdapter {
            Task {
                await AppAdapterManager.shared.importAdapter(adapter)
                let mirroredCommandCount = await AppAdapterManager.shared
                    .mirrorVirtualScopeAdapterIntoGlobalCommands(adapter)
                await MainActor.run {
                    importedName = adapter.appName
                    importedDest = mirroredCommandCount > 0 ? .globalContext : .contextDock
                    withAnimation(.spring(duration: 0.35)) { didImport = true }
                }
            }
            return
        }

        if !parsedSystemCommands.isEmpty {
            for command in parsedSystemCommands {
                SystemCommandsRegistry.shared.add(command)
            }
            SystemCommandsRegistryObservable.shared.reload()
            importedName = parsedSystemCommands.first?.name ?? "System Command"
            importedDest = .globalContext
            withAnimation(.spring(duration: 0.35)) { didImport = true }
            return
        }

        guard let payload = parsed else { return }
        let exts = payload.toILExtensions()
        guard let first = exts.first, let spec = payload.extensions.first else { return }

        for ext in exts {
            LayeredExtensionManager.shared.addExtension(normalizedLayeredExtension(ext, for: destination))
        }

        switch destination {
        case .globalContext:
            // Save as AppToolExtension (global script)
            let lang = mapScriptLanguage(spec.scriptType)
            let savedPath = settings.saveScript(
                appKey: "global", name: first.name, language: lang, code: spec.script
            ) ?? ""
            let toolExt = AppToolExtension(
                appKey: "global",
                toolName: first.name,
                toolPath: savedPath,
                aiHint: first.description,
                profile: AppToolProfile(capabilities: [], exampleCommands: [],
                                        fileTypes: [], isDestructive: false),
                kind: .script,
                scriptLanguage: lang,
                scriptCode: spec.script,
                iconName: first.icon
            )
            settings.addToolExtension(toolExt)

        case .contextDock:
            // Save script file + create AXTriggerRule
            let lang = mapScriptLanguage(spec.scriptType)
            let savedPath = settings.saveScript(
                appKey: "context-dock", name: first.name, language: lang, code: spec.script
            ) ?? ""
            let conditions = spec.triggers.compactMap { triggerToCondition($0) }
            let pill = AXRulePill(
                label: first.name,
                icon: first.icon,
                accentColor: "blue",
                actionType: .scriptFile,
                actionValue: savedPath
            )
            // Extract app scope if appContext trigger present
            let appBundleId = spec.triggers.first(where: { $0.type == "appContext" })?.value
            let rule = AXTriggerRule(
                name: first.name,
                isEnabled: true,
                conditions: conditions,
                conditionLogic: conditions.count == 1 ? .all : .any,
                pills: [pill],
                priority: 10,
                bundleId: appBundleId
            )
            settings.addAXRule(rule)

        case .shortcutSheet:
            _ = settings.saveScript(
                appKey: "shortcut-sheet",
                name: first.name,
                language: mapScriptLanguage(spec.scriptType),
                code: spec.script
            )
        }

        importedName = exts.first?.name ?? "Extension"
        importedDest = destination
        withAnimation(.spring(duration: 0.35)) { didImport = true }
    }

    private func commitCreatedExtension(_ draft: CreatedExtensionDraft) {
        let ext = draft.makeILExtension()
        LayeredExtensionManager.shared.addExtension(ext)

        switch draft.destination {
        case .globalContext:
            let lang = draft.appScriptLanguage
            let savedPath = settings.saveScript(
                appKey: "global",
                name: draft.name,
                language: lang,
                code: draft.script
            ) ?? ""
            let toolExt = AppToolExtension(
                appKey: "global",
                toolName: draft.name,
                toolPath: savedPath,
                aiHint: draft.description,
                profile: AppToolProfile(
                    capabilities: draft.keywords,
                    exampleCommands: [],
                    fileTypes: [],
                    isDestructive: false
                ),
                kind: .script,
                scriptLanguage: lang,
                scriptCode: draft.script,
                iconName: draft.icon
            )
            settings.addToolExtension(toolExt)

        case .contextDock:
            let lang = draft.appScriptLanguage
            let savedPath = settings.saveScript(
                appKey: "context-dock",
                name: draft.name,
                language: lang,
                code: draft.script
            ) ?? ""
            let conditions = draft.axConditions
            let pill = AXRulePill(
                label: draft.name,
                icon: draft.icon,
                accentColor: "blue",
                actionType: .scriptFile,
                actionValue: savedPath
            )
            let rule = AXTriggerRule(
                name: draft.name,
                isEnabled: true,
                conditions: conditions,
                conditionLogic: conditions.count == 1 ? .all : .any,
                pills: [pill],
                priority: 10,
                bundleId: draft.appContext.isEmpty ? nil : draft.appContext
            )
            settings.addAXRule(rule)

        case .shortcutSheet:
            _ = settings.saveScript(
                appKey: "shortcut-sheet",
                name: draft.name,
                language: draft.appScriptLanguage,
                code: draft.script
            )
        }

        importedName = draft.name
        importedDest = draft.destination
        destination = draft.destination
        withAnimation(.spring(duration: 0.35)) { didImport = true }
    }

    private func normalizedLayeredExtension(_ ext: ILExtension, for destination: ImportDestination) -> ILExtension {
        var normalized = ext
        switch destination {
        case .globalContext:
            normalized.layer = .l1_search
            normalized.category = normalized.category.isEmpty ? "custom" : normalized.category
            if normalized.triggers.isEmpty {
                normalized.triggers = [.keyword(keywords(from: normalized.name))]
            }
        case .contextDock:
            normalized.layer = .l2_context
            normalized.category = normalized.category.isEmpty || normalized.category == "custom" ? "context" : normalized.category
            if normalized.triggers.isEmpty {
                normalized.triggers = [.selection]
            }
        case .shortcutSheet:
            normalized.layer = .l2_context
            normalized.category = "shortcutSheet"
            if !normalized.triggers.contains(where: { trigger in
                if case .selection = trigger { return true }
                return false
            }) {
                normalized.triggers.append(.selection)
            }
        }
        return normalized
    }

    private func resetPanel() {
        jsonText = ""
        parsed = nil
        parsedSystemCommands = []
        parsedAppAdapter = nil
        parseError = nil
        didImport = false
    }

    private func mapScriptLanguage(_ s: String) -> AppScriptLanguage {
        switch s.lowercased() {
        case "python", "python3": return .python
        case "applescript":       return .applescript
        case "javascript", "jxa": return .jxa
        default:                  return .bash
        }
    }

    private func triggerToCondition(_ spec: SimpleAIExtensionImport.TriggerSpec) -> AXTriggerCondition? {
        switch spec.type {
        case "urlPattern":
            return AXTriggerCondition(field: .currentURL, op: .contains, value: spec.value ?? "")
        case "appContext":
            return AXTriggerCondition(field: .appName, op: .contains, value: spec.value ?? "")
        case "fileType":
            return AXTriggerCondition(field: .filePath, op: .endsWith, value: ".\(spec.value ?? "")")
        case "keyword":
            return AXTriggerCondition(field: .selectedText, op: .contains, value: spec.value ?? "")
        case "selection":
            return AXTriggerCondition(field: .selectedText, op: .isNotEmpty, value: "")
        default:
            return nil
        }
    }

    private func keywords(from name: String) -> [String] {
        let words = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        return words.isEmpty ? [name.lowercased()] : Array(Set(words)).sorted()
    }

    private func triggerLabel(_ trigger: ExtensionTrigger) -> String {
        switch trigger {
        case .keyword(let kws):    return "keyword: \(kws.first ?? "")"
        case .fileType(let types): return ".\(types.first ?? "")"
        case .appContext(let app): return app
        case .urlPattern(let p):   return "url: \(p)"
        case .selection:           return "on select"
        case .always:              return "always"
        }
    }
}

// MARK: - Manual Extension Creator

private struct CreatedExtensionDraft {
    var destination: ImportDestination
    var name: String
    var description: String
    var icon: String
    var scriptType: ILExtension.ScriptType
    var script: String
    var keywords: [String]
    var appContext: String
    var fileType: String
    var urlPattern: String
    var requiresSelection: Bool

    var appScriptLanguage: AppScriptLanguage {
        switch scriptType {
        case .python: return .python
        case .applescript: return .applescript
        case .javascript: return .jxa
        case .bash, .swift: return .bash
        }
    }

    var axConditions: [AXTriggerCondition] {
        var conditions: [AXTriggerCondition] = []
        if !appContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conditions.append(AXTriggerCondition(field: .appName, op: .contains, value: appContext))
        }
        if !fileType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let suffix = fileType.hasPrefix(".") ? fileType : ".\(fileType)"
            conditions.append(AXTriggerCondition(field: .filePath, op: .endsWith, value: suffix))
        }
        if !urlPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conditions.append(AXTriggerCondition(field: .currentURL, op: .contains, value: urlPattern))
        }
        if requiresSelection {
            conditions.append(AXTriggerCondition(field: .selectedText, op: .isNotEmpty, value: ""))
        }
        return conditions
    }

    func makeILExtension() -> ILExtension {
        var triggers: [ExtensionTrigger] = []
        if !keywords.isEmpty {
            triggers.append(.keyword(keywords))
        }
        if !appContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            triggers.append(.appContext(appContext))
        }
        if !fileType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            triggers.append(.fileType([fileType.replacingOccurrences(of: ".", with: "")]))
        }
        if !urlPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            triggers.append(.urlPattern(urlPattern))
        }
        if requiresSelection {
            triggers.append(.selection)
        }
        if triggers.isEmpty {
            triggers.append(destination == .globalContext ? .keyword(keywordsFromName(name)) : .selection)
        }

        return ILExtension(
            name: name,
            description: description.isEmpty ? "User-created extension" : description,
            icon: SFSymbolResolver.validSymbol(icon, fallback: "sparkles"),
            layer: destination == .globalContext ? .l1_search : .l2_context,
            tags: [.automation],
            category: destination == .shortcutSheet ? "shortcutSheet" : (destination == .globalContext ? "custom" : "context"),
            triggers: triggers,
            enabled: true,
            scriptPath: "script.\(scriptType.fileExtension)",
            scriptContent: script,
            scriptType: scriptType,
            requiresPermissions: scriptType == .applescript ? ["automation"] : [],
            author: NSUserName().isEmpty ? "User" : NSUserName(),
            version: "1.0",
            isBuiltIn: false
        )
    }

    private func keywordsFromName(_ value: String) -> [String] {
        let words = value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        return words.isEmpty ? [value.lowercased()] : Array(Set(words)).sorted()
    }
}

private struct CreateExtensionSheet: View {
    let defaultDestination: ImportDestination
    let onCreate: (CreatedExtensionDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var destination: ImportDestination
    @State private var name = ""
    @State private var description = ""
    @State private var icon = "sparkles"
    @State private var scriptType: ILExtension.ScriptType = .bash
    @State private var script = "echo \"Hello from Context Dock\""
    @State private var keywordsText = ""
    @State private var appContext = ""
    @State private var fileType = ""
    @State private var urlPattern = ""
    @State private var requiresSelection = true

    init(defaultDestination: ImportDestination, onCreate: @escaping (CreatedExtensionDraft) -> Void) {
        self.defaultDestination = defaultDestination
        self.onCreate = onCreate
        _destination = State(initialValue: defaultDestination)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "plus.app.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Extension")
                        .font(.system(size: 15, weight: .bold))
                    Text("Create a live Global Context action or Context Dock trigger.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Save To", selection: $destination) {
                        ForEach(ImportDestination.allCases, id: \.self) { dest in
                            Label(dest.rawValue, systemImage: dest.icon).tag(dest)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        TextField("Extension name", text: $name)
                        SFSymbolPickerButton(selected: $icon)
                            .frame(width: 200)
                    }
                    .textFieldStyle(.roundedBorder)

                    TextField("Description", text: $description)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Triggers")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField("Keywords, comma separated", text: $keywordsText)
                            .textFieldStyle(.roundedBorder)
                        if destination != .globalContext {
                            HStack(spacing: 10) {
                                TextField("App name or bundle id", text: $appContext)
                                TextField("File type, e.g. pdf", text: $fileType)
                                TextField("URL contains", text: $urlPattern)
                            }
                            .textFieldStyle(.roundedBorder)
                            Toggle("Requires selected text or file", isOn: $requiresSelection)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Runner", selection: $scriptType) {
                            Text("Bash").tag(ILExtension.ScriptType.bash)
                            Text("Python").tag(ILExtension.ScriptType.python)
                            Text("AppleScript").tag(ILExtension.ScriptType.applescript)
                            Text("JXA").tag(ILExtension.ScriptType.javascript)
                        }
                        .pickerStyle(.segmented)

                        ZStack(alignment: .topLeading) {
                            if script.isEmpty {
                                Text("Script body")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.quaternary)
                                    .padding(10)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $script)
                                .font(.system(size: 12, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .frame(minHeight: 170)
                        }
                        .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.18)))
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(makeDraft())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 620)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func makeDraft() -> CreatedExtensionDraft {
        CreatedExtensionDraft(
            destination: destination,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: SFSymbolResolver.validSymbol(icon, fallback: "sparkles"),
            scriptType: scriptType,
            script: script,
            keywords: keywordsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty },
            appContext: appContext.trimmingCharacters(in: .whitespacesAndNewlines),
            fileType: fileType.trimmingCharacters(in: .whitespacesAndNewlines),
            urlPattern: urlPattern.trimmingCharacters(in: .whitespacesAndNewlines),
            requiresSelection: destination != .globalContext && requiresSelection
        )
    }
}

// MARK: - App Adapter AI Import

struct AppAdapterAIImport {
    static func decode(from text: String) throws -> AppAdapter {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            let lines = json.components(separatedBy: .newlines)
            json = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = json.data(using: .utf8) else { throw SimpleAIImportError.emptyPayload }

        let camelDecoder = JSONDecoder()
        let snakeDecoder = JSONDecoder()
        snakeDecoder.keyDecodingStrategy = .convertFromSnakeCase

        let adapter: AppAdapter
        if let decoded = try? camelDecoder.decode(AppAdapter.self, from: data) {
            adapter = decoded
        } else {
            adapter = try snakeDecoder.decode(AppAdapter.self, from: data)
        }

        let hasIdentity =
            !adapter.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !adapter.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !adapter.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasIdentity, !adapter.actions.isEmpty else {
            throw SimpleAIImportError.invalidJSON("Expected app adapter with actions")
        }
        return adapter
    }
}

// MARK: - System Command AI Import

struct SystemCommandAIImport: Codable {
    struct CommandSpec: Codable {
        var name: String
        var description: String?
        var icon: String?
        var keywords: [String]?
        var presets: [String]?
        var provider: String?
        var scriptType: String
        var script: String
        // Live-scope row action (Return on a row): the script and its interpreter.
        var undoScript: String?
        var undoScriptType: String?
    }

    var version: String?
    var type: String
    var systemCommands: [CommandSpec]

    static func decode(from text: String) throws -> SystemCommandAIImport {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            let lines = json.components(separatedBy: .newlines)
            json = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = json.data(using: .utf8) else { throw SimpleAIImportError.emptyPayload }
        let payload = try JSONDecoder().decode(SystemCommandAIImport.self, from: data)
        guard payload.type.lowercased() == "system_commands" else {
            throw SimpleAIImportError.invalidJSON("Expected type system_commands")
        }
        return payload
    }

    func toSystemCommands() -> [SystemCommand] {
        systemCommands.compactMap { spec in
            let name = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let script = spec.script.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !script.isEmpty else { return nil }

            var keywords = (spec.keywords ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let presets = spec.presets?
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .filter({ !$0.isEmpty }),
                !presets.isEmpty,
                !keywords.contains(where: { $0.lowercased().hasPrefix("presets:") })
            {
                keywords.append("presets:\(presets.joined(separator: "|"))")
            }
            if !keywords.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                keywords.insert(name, at: 0)
            }
            if let provider = spec.provider?.trimmingCharacters(in: .whitespacesAndNewlines),
                !provider.isEmpty,
                !keywords.contains(where: { $0.lowercased() == "provider:\(provider.lowercased())" })
            {
                keywords.append("provider:\(provider.lowercased())")
            }

            let icon = SFSymbolResolver.validSymbol(spec.icon, fallback: "command")
            let undoScript = spec.undoScript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let undoScriptType = spec.undoScriptType?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SystemCommand(
                name: name,
                icon: icon,
                keywords: keywords,
                scriptType: spec.scriptType.trimmingCharacters(in: .whitespacesAndNewlines),
                script: script,
                description: spec.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name,
                undoScriptType: (undoScriptType?.isEmpty == false) ? undoScriptType! : spec.scriptType.trimmingCharacters(in: .whitespacesAndNewlines),
                undoScript: undoScript
            )
        }
    }
}

// MARK: - SystemCommandsRegistryObservable

/// ObservableObject wrapper so SwiftUI views react to registry changes.
final class SystemCommandsRegistryObservable: ObservableObject {
    static let shared = SystemCommandsRegistryObservable()
    @Published private(set) var commands: [SystemCommand] = []
    private init() { reload() }
    func reload() { commands = SystemCommandsRegistry.shared.commands }
    func remove(_ cmd: SystemCommand) {
        SystemCommandsRegistry.shared.remove(cmd)
        reload()
    }
    func update(_ cmd: SystemCommand) {
        SystemCommandsRegistry.shared.update(cmd)
        reload()
    }
    func add(_ cmd: SystemCommand) {
        SystemCommandsRegistry.shared.add(cmd)
        reload()
    }
}

// MARK: - System Command Detail View

struct SystemCommandCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (SystemCommand) -> Void

    @State private var name = "Empty Bin"
    @State private var description = "Empty Bin"
    @State private var icon = "trash"
    @State private var keywords = "empty bin, empty trash, trash, bin, clear trash"
    @State private var scriptType = "applescript"
    @State private var successTitle = "Empty Bin done"
    @State private var successMessage = ""
    @State private var undoTitle = "Undo"
    @State private var undoScriptType = "applescript"
    @State private var undoScript = ""
    @State private var interaction = SystemCommandInteraction.none.rawValue
    @State private var valueScript = ""
    @State private var scopeProvider = "none"
    @State private var scopeItems = ""
    @State private var script = """
tell application "Finder"
    empty trash
end tell
"""

    private var actionType: SystemCommandActionType {
        SystemCommandActionType.normalize(scriptType)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon.isEmpty ? "command" : icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.indigo)
                    .frame(width: 38, height: 38)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Global Command")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Always available without selection.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeledField("Name") {
                        TextField("Empty Bin", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("Description") {
                        TextField("Empty Bin", text: $description)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("SF Symbol") {
                        SFSymbolPickerButton(selected: $icon)
                    }
                    labeledField("Keywords") {
                        TextField("empty bin, empty trash, trash", text: $keywords)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("Type") {
                        Picker("", selection: $scriptType) {
                            ForEach(SystemCommandActionType.allCases) { type in
                                Text(type.label).tag(type.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 240, alignment: .leading)
                    }
                    labeledField(actionType.valueLabel) {
                        if actionType == .url || actionType == .file || actionType == .scriptFile {
                            TextField(actionType.placeholder, text: $script)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextEditor(text: $script)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: actionType == .aiPrompt ? 120 : 180)
                                .scrollContentBackground(.hidden)
                                .background(Color(NSColor.textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75)
                                )
                        }
                        Text("Variables: $CD_QUERY, $CD_URL, $CD_TEXT, $CD_APP or {CD_QUERY}.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    labeledField("Scoped Experience") {
                        Picker("Control", selection: $interaction) {
                            ForEach(SystemCommandInteraction.allCases) { kind in
                                Text(kind.label).tag(kind.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        Picker("Dynamic list", selection: $scopeProvider) {
                            Text("None").tag("none")
                            Text("Bluetooth devices").tag("bluetooth")
                            Text("Wi-Fi networks").tag("wifi")
                            Text("Window layouts").tag("windows")
                            Text("Quick notes").tag("notepad")
                            Text("List Extension (custom rows)").tag("custom")
                        }
                        .pickerStyle(.menu)
                        if scopeProvider == "custom" {
                            Text("Script above = JSON rows source. Undo field = per-row action ($CD_ROW_ID). Add keyword refresh:N for auto-refresh.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        TextField("Optional rows: Home, Work, Settings", text: $scopeItems)
                            .textFieldStyle(.roundedBorder)
                        if interaction != SystemCommandInteraction.none.rawValue {
                            TextEditor(text: $valueScript)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 70)
                                .scrollContentBackground(.hidden)
                                .background(Color(NSColor.textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Value script prints the current number or on/off state. Dynamic lists and custom rows appear below the control while scoped.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    labeledField("Dock Completion") {
                        TextField("Empty Bin done", text: $successTitle)
                            .textFieldStyle(.roundedBorder)
                        TextField("Optional message shown after success", text: $successMessage)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("Undo") {
                        HStack(spacing: 10) {
                            TextField("Undo", text: $undoTitle)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 120)
                            Picker("", selection: $undoScriptType) {
                                ForEach(SystemCommandActionType.allCases) { type in
                                    Text(type.label).tag(type.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 220, alignment: .leading)
                        }
                        TextEditor(text: $undoScript)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75)
                            )
                        Text("Leave blank for no Undo button. Only add undo for reversible actions.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(18)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add Command") {
                    var commandKeywords = keywords.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if scopeProvider != "none" { commandKeywords.append("provider:\(scopeProvider)") }
                    let customItems = scopeItems.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !customItems.isEmpty { commandKeywords.append("presets:\(customItems.joined(separator: "|"))") }
                    let command = SystemCommand(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        icon: icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "command"
                            : icon.trimmingCharacters(in: .whitespacesAndNewlines),
                        keywords: commandKeywords,
                        scriptType: scriptType,
                        script: script,
                        description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                        successTitle: successTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                        successMessage: successMessage.trimmingCharacters(in: .whitespacesAndNewlines),
                        undoTitle: undoTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                        undoScriptType: undoScriptType,
                        undoScript: undoScript.trimmingCharacters(in: .whitespacesAndNewlines),
                        interaction: interaction,
                        valueScript: valueScript.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    onCreate(command)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
            .padding(18)
        }
        .frame(width: 560, height: 760)
        .onChange(of: scriptType) { oldValue, newValue in
            let oldPlaceholder = SystemCommandActionType.normalize(oldValue).placeholder
            let newPlaceholder = SystemCommandActionType.normalize(newValue).placeholder
            if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || script.trimmingCharacters(in: .whitespacesAndNewlines)
                    == oldPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines)
            {
                script = newPlaceholder
            }
        }
    }

    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct SystemCommandDetailView: View {
    @Binding var selectedID: UUID?
    @StateObject private var registry = SystemCommandsRegistryObservable.shared

    private var selected: SystemCommand? {
        guard let id = selectedID else { return nil }
        return registry.commands.first { $0.id == id }
    }

    var body: some View {
        if let cmd = selected {
            SystemCommandEditorView(command: cmd, registry: registry) {
                registry.remove(cmd)
                selectedID = registry.commands.first?.id
            }
                .id(cmd.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select a command")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Global Actions are always available globally.\nType their name in the dock to run them instantly.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SystemCommandEditorView: View {
    let command: SystemCommand
    @ObservedObject var registry: SystemCommandsRegistryObservable
    let onDelete: () -> Void

    @State private var name: String
    @State private var description: String
    @State private var icon: String
    @State private var keywords: String
    @State private var scriptType: String
    @State private var script: String
    @State private var successTitle: String
    @State private var successMessage: String
    @State private var undoTitle: String
    @State private var undoScriptType: String
    @State private var undoScript: String
    @State private var isEnabled: Bool
    @State private var interaction: String
    @State private var sliderMin: String
    @State private var sliderMax: String
    @State private var sliderStep: String
    @State private var valueScript: String
    @State private var scopeProvider: String
    @State private var scopeItems: String
    @State private var refreshSeconds: String
    @State private var liveQuery: Bool

    private static func parseRefreshSeconds(_ keywords: [String]) -> String {
        keywords.first(where: { $0.lowercased().hasPrefix("refresh:") })?
            .split(separator: ":", maxSplits: 1).last.map(String.init) ?? "3"
    }

    private static func parseLiveQuery(_ keywords: [String]) -> Bool {
        keywords.contains { $0.lowercased() == "query:live" }
    }

    init(command: SystemCommand, registry: SystemCommandsRegistryObservable, onDelete: @escaping () -> Void) {
        self.command  = command
        self.registry = registry
        self.onDelete = onDelete
        _name        = State(initialValue: command.name)
        _description = State(initialValue: command.description)
        _icon        = State(initialValue: command.icon)
        _keywords    = State(initialValue: command.keywords.joined(separator: ", "))
        _scriptType  = State(initialValue: command.scriptType)
        _script      = State(initialValue: command.script)
        _successTitle = State(initialValue: command.successTitle)
        _successMessage = State(initialValue: command.successMessage)
        _undoTitle = State(initialValue: command.undoTitle)
        _undoScriptType = State(initialValue: command.undoScriptType)
        _undoScript = State(initialValue: command.undoScript)
        _isEnabled   = State(initialValue: command.isEnabled)
        _interaction = State(initialValue: command.interaction)
        _sliderMin   = State(initialValue: String(Int(command.sliderMin)))
        _sliderMax   = State(initialValue: String(Int(command.sliderMax)))
        _sliderStep  = State(initialValue: String(Int(command.sliderStep)))
        _valueScript = State(initialValue: command.valueScript)
        _scopeProvider = State(initialValue: command.keywords.first(where: { $0.lowercased().hasPrefix("provider:") })?.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "none")
        _scopeItems = State(initialValue: command.keywords.first(where: { $0.lowercased().hasPrefix("presets:") || $0.lowercased().hasPrefix("preset:") })?.split(separator: ":", maxSplits: 1).last.map { String($0).replacingOccurrences(of: "|", with: ", ") } ?? "")
        _refreshSeconds = State(initialValue: Self.parseRefreshSeconds(command.keywords))
        _liveQuery = State(initialValue: Self.parseLiveQuery(command.keywords))
    }

    private var hasChanges: Bool {
        name != command.name || description != command.description
            || icon != command.icon || keywords != command.keywords.joined(separator: ", ")
            || scriptType != command.scriptType || script != command.script
            || successTitle != command.successTitle || successMessage != command.successMessage
            || undoTitle != command.undoTitle || undoScriptType != command.undoScriptType
            || undoScript != command.undoScript
            || isEnabled != command.isEnabled
            || interaction != command.interaction
            || sliderMin != String(Int(command.sliderMin))
            || sliderMax != String(Int(command.sliderMax))
            || sliderStep != String(Int(command.sliderStep))
            || valueScript != command.valueScript
            || scopeProvider != (command.keywords.first(where: { $0.lowercased().hasPrefix("provider:") })?.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "none")
            || scopeItems != (command.keywords.first(where: { $0.lowercased().hasPrefix("presets:") || $0.lowercased().hasPrefix("preset:") })?.split(separator: ":", maxSplits: 1).last.map { String($0).replacingOccurrences(of: "|", with: ", ") } ?? "")
            || refreshSeconds != Self.parseRefreshSeconds(command.keywords)
            || liveQuery != Self.parseLiveQuery(command.keywords)
    }

    private var actionType: SystemCommandActionType {
        SystemCommandActionType.normalize(scriptType)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: icon.isEmpty ? "command" : icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.indigo)
                        .frame(width: 40, height: 40)
                        .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.isEmpty ? "System Command" : name)
                            .font(.system(size: 16, weight: .semibold))
                        Text("Global · \(actionType.label) · Natural language")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                Divider()

                // Fields
                Group {
                    labeledField("Name") {
                        TextField("Command name", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("Description") {
                        TextField("Short description", text: $description)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("SF Symbol") {
                        SFSymbolPickerButton(selected: $icon)
                    }
                    labeledField("Keywords") {
                        TextField("mute, audio, sound (comma-separated)", text: $keywords)
                            .textFieldStyle(.roundedBorder)
                        Text("Used for natural language matching in the dock")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    labeledField("Type") {
                        Picker("", selection: $scriptType) {
                            ForEach(SystemCommandActionType.allCases) { type in
                                Text(type.label).tag(type.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 240, alignment: .leading)
                    }
                }

                labeledField(actionType.valueLabel) {
                    if actionType == .url || actionType == .file || actionType == .scriptFile {
                        TextField(actionType.placeholder, text: $script)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextEditor(text: $script)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: actionType == .aiPrompt ? 120 : 180)
                            .scrollContentBackground(.hidden)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75)
                            )
                    }
                    Text("Variables: $CD_QUERY, $CD_URL, $CD_TEXT, $CD_APP or {CD_QUERY}.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                labeledField("Interaction") {
                    Picker("", selection: $interaction) {
                        ForEach(SystemCommandInteraction.allCases) { kind in
                            Text(kind.label).tag(kind.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 240, alignment: .leading)
                    Text("Slider/Toggle render a live control on the result row. The control's value runs the script as CD_QUERY (slider → number, toggle → on/off).")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    if interaction == SystemCommandInteraction.slider.rawValue {
                        HStack(spacing: 10) {
                            TextField("Min", text: $sliderMin)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 70)
                            TextField("Max", text: $sliderMax)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 70)
                            TextField("Step", text: $sliderStep)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 70)
                            Text("Min · Max · Step")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if interaction != SystemCommandInteraction.none.rawValue {
                        TextEditor(text: $valueScript)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75)
                            )
                        Text("Value script (same type as above): prints the current value — a number for sliders, on/off for toggles — so the control opens at the real system state.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                labeledField("Scoped Results") {
                    Picker("Dynamic list", selection: $scopeProvider) {
                        Text("None").tag("none")
                        Text("Bluetooth devices").tag("bluetooth")
                        Text("Wi-Fi networks").tag("wifi")
                        Text("List Extension (custom rows)").tag("custom")
                    }
                    .pickerStyle(.menu)
                    TextField("Optional rows: Home, Work, Settings", text: $scopeItems)
                        .textFieldStyle(.roundedBorder)
                    Text("When this command is scoped, its control stays at the top and these dynamic or custom rows remain searchable below it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if scopeProvider == "custom" {
                    labeledField("List Extension") {
                        Text(
                            """
                            Build a live list scope like the built-in Process Monitor. The Script \
                            above is the ROWS source: print one JSON object per line. The Undo field \
                            below is the ROW ACTION, run on Enter with the row exposed as \
                            $CD_ROW_ID / $CD_ROW_TITLE.
                            """
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        Text(
                            #"{"id":"1","title":"Dia","subtitle":"47 proc","badge":"6.68 GB","icon":"cpu"}"#
                        )
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        Text("Only title (or id) is required. icon = an SF Symbol name or a file/app path. Non-JSON lines become title-only rows.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 8) {
                            Text("Auto-refresh every")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            TextField("3", text: $refreshSeconds)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                            Text("seconds")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Toggle(isOn: $liveQuery) {
                            Text("Live query — re-run the rows script on every keystroke ($CD_QUERY)")
                                .font(.system(size: 11))
                        }
                        Text("Turn on for capture-style scopes (type + Enter to save, live search). The script decides what rows to show for the current query — no client-side filtering.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                labeledField("Dock Completion") {
                    TextField("Shown after success", text: $successTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("Optional success message", text: $successMessage)
                        .textFieldStyle(.roundedBorder)
                }

                labeledField("Undo") {
                    HStack(spacing: 10) {
                        TextField("Undo", text: $undoTitle)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                        Picker("", selection: $undoScriptType) {
                            ForEach(SystemCommandActionType.allCases) { type in
                                Text(type.label).tag(type.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 240, alignment: .leading)
                    }
                    TextEditor(text: $undoScript)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75)
                        )
                    Text("Leave blank for no Undo button. Only add undo for reversible actions.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                // Save button
                if hasChanges {
                    HStack {
                        Spacer()
                        Button("Save Changes") {
                            var updated = command
                            updated.name        = name.trimmingCharacters(in: .whitespaces)
                            updated.description = description.trimmingCharacters(in: .whitespaces)
                            updated.icon        = icon.trimmingCharacters(in: .whitespaces)
                            updated.keywords = keywords.components(separatedBy: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("provider:") && !$0.lowercased().hasPrefix("preset:") && !$0.lowercased().hasPrefix("presets:") && !$0.lowercased().hasPrefix("refresh:") && !$0.lowercased().hasPrefix("query:") }
                            if scopeProvider != "none" { updated.keywords.append("provider:\(scopeProvider)") }
                            if scopeProvider == "custom" {
                                let secs = Int(refreshSeconds.trimmingCharacters(in: .whitespaces)) ?? 3
                                updated.keywords.append("refresh:\(max(1, secs))")
                                if liveQuery { updated.keywords.append("query:live") }
                            }
                            let customItems = scopeItems.components(separatedBy: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            if !customItems.isEmpty { updated.keywords.append("presets:\(customItems.joined(separator: "|"))") }
                            updated.scriptType  = scriptType
                            updated.script      = script
                            updated.successTitle = successTitle.trimmingCharacters(in: .whitespaces)
                            updated.successMessage = successMessage.trimmingCharacters(in: .whitespaces)
                            updated.undoTitle = undoTitle.trimmingCharacters(in: .whitespaces)
                            updated.undoScriptType = undoScriptType
                            updated.undoScript = undoScript.trimmingCharacters(in: .whitespacesAndNewlines)
                            updated.isEnabled   = isEnabled
                            updated.interaction = interaction
                            updated.sliderMin   = Double(sliderMin.trimmingCharacters(in: .whitespaces)) ?? 0
                            updated.sliderMax   = Double(sliderMax.trimmingCharacters(in: .whitespaces)) ?? 100
                            updated.sliderStep  = max(Double(sliderStep.trimmingCharacters(in: .whitespaces)) ?? 1, 0.0001)
                            updated.valueScript = valueScript.trimmingCharacters(in: .whitespacesAndNewlines)
                            registry.update(updated)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Add MCP Server Sheet

struct AddMCPServerSheet: View {
    let appName: String
    let bundleId: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mcpManager = MCPServerManager.shared

    private enum Mode: String, CaseIterable { case json = "Paste JSON", manual = "Manual" }
    @State private var mode: Mode = .json
    @State private var jsonText: String = ""
    @State private var name: String = ""
    @State private var command: String = ""
    @State private var argsText: String = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add MCP Server")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Linked to \(appName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if isSafariBundle, let safariDriver = safariMCPDriverPath {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        mode = .manual
                        name = "safari"
                        command = safariDriver
                        argsText = "--mcp"
                    } label: {
                        Label("Use Safari Technology Preview MCP", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    Text("Requires Safari Technology Preview 247+. Enable Safari → Settings → Developer → “Enable remote automation and external agents”, then Add.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .json {
                Text("Paste the app's mcpServers config (the JSON block from its MCP settings).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextEditor(text: $jsonText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 180)
                    .padding(8)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.15)))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    mcpField("Name", "my-server", $name)
                    mcpField("Command", "/path/to/server-cli", $command)
                    mcpField("Arguments (space-separated)", "--mcp", $argsText)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { addServer() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var canAdd: Bool {
        mode == .json
            ? !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !name.trimmingCharacters(in: .whitespaces).isEmpty
                && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isSafariBundle: Bool {
        bundleId == "com.apple.Safari" || bundleId == "com.apple.SafariTechnologyPreview"
    }

    /// Path to Safari Technology Preview's bundled safaridriver (which serves the MCP), or
    /// nil when STP isn't installed.
    private var safariMCPDriverPath: String? {
        let stp = "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver"
        return FileManager.default.isExecutableFile(atPath: stp) ? stp : nil
    }

    private func addServer() {
        if mode == .json {
            let count = mcpManager.addFromJSON(jsonText, linkedTo: bundleId)
            if count == 0 {
                errorText = "No MCP servers found. Expected a { \"mcpServers\": { … } } object."
                return
            }
        } else {
            let args = argsText.split(separator: " ").map(String.init)
            mcpManager.add(
                MCPServerConfig(
                    name: name.trimmingCharacters(in: .whitespaces),
                    command: command.trimmingCharacters(in: .whitespaces),
                    args: args),
                linkedTo: bundleId)
        }
        dismiss()
    }

    @ViewBuilder
    private func mcpField(_ label: String, _ placeholder: String, _ text: Binding<String>)
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
