// AutomationSettingsView.swift
// Context-Dock
//
// Unified Automation panel — one place to create and manage
// user-owned scripts, prompts, CLI tools, triggers, and app actions.

import SwiftUI
import AppKit
import Combine

// MARK: - Category

enum AutomationCategory: String, CaseIterable, Identifiable {
    case scripts         = "Scripts"
    case aiPrompts       = "AI Prompts"
    case cliTools        = "CLI Tools"
    case contextTriggers = "Context Triggers"
    case appActions      = "App Actions"
    case menuCache       = "Menu Cache"
    case systemCommands  = "System Commands"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .scripts:         return "scroll.fill"
        case .aiPrompts:       return "brain.head.profile"
        case .cliTools:        return "terminal.fill"
        case .contextTriggers: return "scope"
        case .appActions:      return "app.connected.to.app.below.fill"
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
        case .appActions:      return "User-owned actions bound to installed apps"
        case .menuCache:       return "Cached app menu snapshots for Global Context"
        case .systemCommands:  return "Global device controls: volume, appearance, display…"
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
    @State private var showAIImportSheet = false
    @State private var extensionSheetMode: AddAppExtensionSheet.Mode = .script
    @State private var showingImportPanel = false

    var body: some View {
        HSplitView {
            // ── Column 1: Category sidebar ───────────────────────────
            sidebar
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 240)

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
                    .frame(minWidth: 260, idealWidth: 300)

                // ── Column 3: Detail / Editor ────────────────────────
                detailPane
                    .frame(minWidth: 340)
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
            AXRuleEditSheet(rule: nil) { rule in
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
        .onAppear {
            pkgMgr.loadPackages()
            Task { await l2Mgr.loadExtensions() }
        }
        .task {
            await loadInstalledAppsCatalogIfNeeded()
            reloadMenuCacheSummaries()
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
                TextField("Search \(selectedCategory.rawValue.lowercased())…", text: $searchText)
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
            SystemCommandDetailView(selectedID: $selectedSystemCommandID)
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
                    ForEach(filteredTriggers) { rule in
                        AutomationRow(
                            icon: "scope",
                            color: .red,
                            title: rule.name,
                            subtitle: "\(rule.conditions.count) condition\(rule.conditions.count == 1 ? "" : "s")",
                            isEnabled: rule.isEnabled
                        )
                        .tag(rule.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // Adapters with at least one non-cliTool action → shown under "Apps"
    private var filteredAppAdapters: [AppAdapter] {
        filteredAdapters.filter { adapter in
            adapter.actions.isEmpty || adapter.actions.contains { $0.type != .cliTool }
        }
    }

    // Adapters where every action is a cliTool → shown under "CLI Tools"
    private var filteredCLIAdapters: [AppAdapter] {
        filteredAdapters.filter { adapter in
            !adapter.actions.isEmpty && adapter.actions.allSatisfy { $0.type == .cliTool }
        }
    }

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

    private var menuCacheList: some View {
        Group {
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
    }

    private var systemCommandList: some View {
        Group {
            if sysRegistry.commands.isEmpty {
                listEmpty(icon: "slider.horizontal.3", label: "No system commands", action: {})
            } else {
                let cmds: [SystemCommand] = searchText.isEmpty
                    ? sysRegistry.commands
                    : sysRegistry.commands.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.keywords.contains { $0.localizedCaseInsensitiveContains(searchText) } }
                List(selection: $selectedSystemCommandID) {
                    ForEach(cmds) { cmd in
                        AutomationRow(
                            icon: cmd.icon,
                            color: AutomationCategory.systemCommands.color,
                            title: cmd.name,
                            subtitle: cmd.description,
                            isEnabled: cmd.isEnabled
                        )
                        .tag(cmd.id)
                    }
                    .onDelete { idx in
                        let toRemove = idx.map { cmds[$0] }
                        toRemove.forEach { sysRegistry.remove($0) }
                    }
                }
                .listStyle(.inset)
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

    private var filteredTriggers: [AXTriggerRule] {
        let rules = settings.axTriggerRules
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
        case .appActions:      return appActionAdapters.count
        case .menuCache:       return menuCacheSummaries.count
        case .systemCommands:  return sysRegistry.commands.count
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
                .filter { !$0.isEmpty }
        )

        let linkedOnlyAdapters = linkedBundleIds.compactMap { bundleId -> AppAdapter? in
            guard !customBundleIds.contains(bundleId) else { return nil }
            return syntheticAppActionAdapter(for: bundleId)
        }

        return (customAdapters + linkedOnlyAdapters).sorted { lhs, rhs in
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
        selectedCategory == .appActions ? "Choose App or CLI Tool" : "New"
    }

    // MARK: Helpers

    private var itemListHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedCategory.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                Text(selectedCategory.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if selectedCategory == .menuCache {
                Button {
                    Task { await loadInstalledAppsCatalogIfNeeded() }
                    reloadMenuCacheSummaries()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button(action: { showAIImportSheet = true }) {
                    Label("Paste AI", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(action: presentCreateFlow) {
                    Label(createButtonTitle, systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var appActionsEmptyDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("App Actions", systemImage: "app.connected.to.app.below.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Add custom actions, scripts, and CLI tools for any app. They appear as dock pills when that app is active.")
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
                    onboardingStep(number: "2", title: "Add an action", detail: "Click + to add a script, CLI command, or shortcut.")
                    onboardingStep(number: "3", title: "Use it in the dock", detail: "Switch to that app — your action appears as a pill instantly.")
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

    private var contextTriggerEmptyDetail: some View {
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
        case .menuCache:
            break
        case .systemCommands:
            break // system commands are edited inline
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
        let actionCount = adapter.visibleActions.count
        let cliCount = linkedCLIToolsCount
        if cliCount == 0 {
            return "\(actionCount) action\(actionCount == 1 ? "" : "s")"
        }
        return "\(actionCount) action\(actionCount == 1 ? "" : "s") · \(cliCount) CLI"
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

struct AutomationAdapterDetailView: View {
    let adapter: AppAdapter
    @Binding var selectedActionID: String?
    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @ObservedObject private var pkgMgr = TerminalPackageManager.shared
    @State private var showAddActionSheet = false
    @State private var editingAction: AdapterAction? = nil
    @State private var showCLIToolPicker = false
    @State private var showDeleteConfirm = false
    @State private var isScanningHelp = false

    private var currentAdapter: AppAdapter {
        adapterManager.adapters.first(where: { $0.id == adapter.id }) ?? adapter
    }

    private var visibleActions: [AdapterAction] {
        currentAdapter.visibleActions
    }

    private var appOnlyActions: [AdapterAction] {
        visibleActions.filter { $0.type != .pageJS }
    }

    private var browserExtensionActions: [AdapterAction] {
        visibleActions.filter { $0.type == .pageJS }
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
                    await adapterManager.deleteAdapter(bundleId: currentAdapter.bundleId)
                    await MainActor.run { selectedActionID = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \(currentAdapter.appName) from App Actions.")
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

                // MARK: App Actions section (non-pageJS)
                VStack(alignment: .leading, spacing: 12) {
                    Text("App Actions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if appOnlyActions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(linkedCLITools.isEmpty && browserExtensionActions.isEmpty ? "No actions yet" : "No app actions yet")
                                .font(.system(size: 13, weight: .medium))
                            Text("Add actions using Open URL / Deep Link, Open File / App, CLI Tool, Shell Command, AppleScript, JXA, Script File, or AI Prompt.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Button("Add First Action") {
                                presentAddActionEditor()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        ForEach(appOnlyActions) { action in
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
                            if action.id != appOnlyActions.last?.id {
                                Divider()
                            }
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

                Divider()

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

            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $showAddActionSheet) {
            AdapterActionEditorSheet(bundleId: currentAdapter.bundleId, existing: editingAction) {
                showAddActionSheet = false
                editingAction = nil
            }
        }
        .sheet(isPresented: $showCLIToolPicker) {
            AppCLIToolPickerSheet(
                appName: currentAdapter.appName,
                bundleId: currentAdapter.bundleId,
                alreadyLinked: Set(linkedCLITools.map(\.id))
            )
        }
        .alert("Remove \(currentAdapter.appName)?", isPresented: $showDeleteConfirm) {
            Button("Remove", role: .destructive) {
                Task {
                    await adapterManager.deleteAdapter(bundleId: currentAdapter.bundleId)
                    await MainActor.run { selectedActionID = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all actions for \(currentAdapter.appName). This cannot be undone.")
        }
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
                Text("Create app-specific actions from the App Actions section.")
                    .font(.system(size: 13))
            }
            Text("Use App Actions to bind your own scripts, deep links, file openers, shell commands, AppleScript, and JXA actions to any installed app.")
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

    var icon: String {
        switch self {
        case .globalContext: return "globe"
        case .contextDock:   return "dock.rectangle"
        }
    }

    var color: Color {
        switch self {
        case .globalContext: return .purple
        case .contextDock:   return .blue
        }
    }

    var subtitle: String {
        switch self {
        case .globalContext: return "Runs on selected text or content in any app"
        case .contextDock:   return "Auto-shows dock pill when URL, app, or file matches"
        }
    }

    var savesAs: String {
        switch self {
        case .globalContext: return "→ saved as Script"
        case .contextDock:   return "→ saved as Context Trigger"
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
    @State private var parseError: String? = nil
    @State private var destination: ImportDestination = .contextDock
    @State private var didImport = false
    @State private var importedName = ""
    @State private var importedDest: ImportDestination = .contextDock

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
                    Text("Paste AI-generated JSON — auto-detected and saved to Global Context or Context Dock")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !jsonText.isEmpty && !didImport {
                    Button("Clear") { resetPanel() }
                        .buttonStyle(.bordered).controlSize(.small).tint(.red)
                }
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

                            if parsed != nil {
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
                                if parsed != nil {
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
                                parsed != nil ? .green.opacity(0.5) :
                                (parseError != nil && !jsonText.isEmpty) ? .orange.opacity(0.4) :
                                    .secondary.opacity(0.18), lineWidth: 1))
                        }

                        // Preview cards
                        if let payload = parsed {
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
                                    Text("Ask any AI (Claude, ChatGPT, Gemini) using the Context Dock extension prompt. Paste the JSON here — it's imported and live immediately.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
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
                        .disabled(parsed == nil)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { pasteFromClipboard() }
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

    private func parseAndDetect(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { parsed = nil; parseError = nil; return }
        do {
            let payload = try SimpleAIExtensionImport.decode(from: t)
            parsed = payload
            parseError = nil
            // Auto-detect destination from first extension's triggers
            if let spec = payload.extensions.first {
                destination = autoDetect(spec)
            }
        } catch {
            parsed = nil
            parseError = error.localizedDescription
        }
    }

    private func autoDetect(_ spec: SimpleAIExtensionImport.ExtensionSpec) -> ImportDestination {
        let hasContextTrigger = spec.triggers.contains {
            ["urlPattern", "appContext", "fileType"].contains($0.type)
        }
        return hasContextTrigger ? .contextDock : .globalContext
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("```") else { return }
        jsonText = t
        parseAndDetect(t)
    }

    private func commitImport() {
        guard let payload = parsed else { return }
        let exts = payload.toILExtensions()
        guard let first = exts.first, let spec = payload.extensions.first else { return }

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
                scriptCode: spec.script
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
        }

        importedName = exts.first?.name ?? "Extension"
        importedDest = destination
        withAnimation(.spring(duration: 0.35)) { didImport = true }
    }

    private func resetPanel() {
        jsonText = ""; parsed = nil; parseError = nil; didImport = false
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

struct SystemCommandDetailView: View {
    @Binding var selectedID: UUID?
    @StateObject private var registry = SystemCommandsRegistryObservable.shared

    private var selected: SystemCommand? {
        guard let id = selectedID else { return nil }
        return registry.commands.first { $0.id == id }
    }

    var body: some View {
        if let cmd = selected {
            SystemCommandEditorView(command: cmd, registry: registry)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select a command")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("System Commands are always available globally.\nType their name in the dock to run them instantly.")
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

    @State private var name: String
    @State private var description: String
    @State private var icon: String
    @State private var keywords: String
    @State private var scriptType: String
    @State private var script: String
    @State private var isEnabled: Bool

    init(command: SystemCommand, registry: SystemCommandsRegistryObservable) {
        self.command  = command
        self.registry = registry
        _name        = State(initialValue: command.name)
        _description = State(initialValue: command.description)
        _icon        = State(initialValue: command.icon)
        _keywords    = State(initialValue: command.keywords.joined(separator: ", "))
        _scriptType  = State(initialValue: command.scriptType)
        _script      = State(initialValue: command.script)
        _isEnabled   = State(initialValue: command.isEnabled)
    }

    private var hasChanges: Bool {
        name != command.name || description != command.description
            || icon != command.icon || keywords != command.keywords.joined(separator: ", ")
            || scriptType != command.scriptType || script != command.script
            || isEnabled != command.isEnabled
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
                        Text("Global · Always available · Natural language")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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
                        TextField("e.g. speaker.wave.3.fill", text: $icon)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("Keywords") {
                        TextField("mute, audio, sound (comma-separated)", text: $keywords)
                            .textFieldStyle(.roundedBorder)
                        Text("Used for natural language matching in the dock")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    labeledField("Script Type") {
                        Picker("", selection: $scriptType) {
                            Text("AppleScript").tag("applescript")
                            Text("bash").tag("bash")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 200)
                    }
                }

                labeledField("Script") {
                    TextEditor(text: $script)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75)
                        )
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
                            updated.keywords    = keywords.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            updated.scriptType  = scriptType
                            updated.script      = script
                            updated.isEnabled   = isEnabled
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
