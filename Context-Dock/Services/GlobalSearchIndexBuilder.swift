// GlobalSearchIndexBuilder.swift
// Context-Dock
//
// Builds Global Context's search index: the running apps and their menus, the installed
// apps, the CLI scopes, App Adapter actions, Global Commands, plugins, cached menus, browser
// history and the user's own extensions — everything Global search can find, in the
// Corner and anywhere else that asks `GlobalSearchService`.
//
// It lived in the old launcher view (issue #247, step 4b). That view is built at startup and
// never shown, so the Corner's Global search was only as fresh as a hidden view's lifecycle.
// Moved here unchanged; it now loads its own app list and rebuilds itself when apps launch
// or quit, when Settings asks, and when the browser history refreshes.

import AppKit
import Combine

@MainActor
final class GlobalSearchIndexBuilder {
    static let shared = GlobalSearchIndexBuilder()

    /// Every installed app, from the launch-prewarmed catalog.
    private(set) var allApplications: [SearchResult] = []
    private var observers: [NSObjectProtocol] = []
    private var sinks = Set<AnyCancellable>()
    private var isStarted = false

    private init() {}

    /// Load the app list, build the index, and keep it fresh. Once, at launch.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        loadApplications()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { GlobalSearchIndexBuilder.shared.rebuild() }
                })
        }
        NotificationCenter.default.publisher(for: .globalSearchIndexRebuildRequested)
            .sink { _ in GlobalSearchIndexBuilder.shared.rebuild() }
            .store(in: &sinks)
    }

    /// Reads the catalog off the main thread, then builds. `then` hands the list to a caller
    /// that shows apps itself.
    func loadApplications(then: (@MainActor ([SearchResult]) -> Void)? = nil) {
        Task.detached(priority: .userInitiated) {
            let apps = AppCatalogService.shared.appsNow()
            await MainActor.run {
                let builder = GlobalSearchIndexBuilder.shared
                builder.allApplications = apps
                AppScopeMatchCache.shared.prewarm(
                    appPaths: apps.filter { $0.type == .application }.map(\.subtitle))
                builder.rebuild()
                then?(apps)
            }
        }
    }

    // MARK: - Helpers the index and the old launcher share

    static func currentRegularRunningApps() -> [NSRunningApplication] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                app.bundleIdentifier != Bundle.main.bundleIdentifier,
                !app.isTerminated
            else { return false }

            let key =
                app.bundleIdentifier
                ?? app.bundleURL?.standardizedFileURL.path
                ?? (app.localizedName ?? "").lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }

    static func preparedIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon else { return nil }
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: 64, height: 64)
        return copy
    }

    static func runningAppIcon(_ app: NSRunningApplication) -> NSImage? {
        if let bundleURL = app.bundleURL {
            return preparedIcon(NSWorkspace.shared.icon(forFile: bundleURL.path))
        }
        return preparedIcon(app.icon)
    }

    /// An app's icon by bundle id — running copy first, then the installed one — or, failing
    /// that, by name in the app list or the usual folders.
    static func applicationIcon(
        running: [NSRunningApplication], apps: [SearchResult],
        bundleIdentifier: String?, appName: String? = nil
    ) -> NSImage? {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            if let runningURL = running.first(where: {
                $0.bundleIdentifier == bundleIdentifier
            })?.bundleURL {
                return preparedIcon(NSWorkspace.shared.icon(forFile: runningURL.path))
            }
            if let appURL = GlobalApplicationMetadataCache.shared.applicationURL(
                bundleIdentifier: bundleIdentifier)
            {
                return preparedIcon(NSWorkspace.shared.icon(forFile: appURL.path))
            }
        }

        guard let appName, !appName.isEmpty else { return nil }
        if let result = apps.first(where: {
            $0.title.compare(appName, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }) {
            return preparedIcon(result.icon)
        }

        let appDirectories = [
            "/Applications",
            "/System/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "\(NSHomeDirectory())/Applications",
        ]
        let fileManager = FileManager.default
        for directory in appDirectories {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(appName)
                .appendingPathExtension("app")
            if fileManager.fileExists(atPath: url.path) {
                return preparedIcon(NSWorkspace.shared.icon(forFile: url.path))
            }
        }

        return nil
    }

    /// News is never offered as an app to search.
    nonisolated static func shouldIgnoreApplicationFromAppSearch(
        appName: String,
        bundleIdentifier: String?,
        path: String?
    ) -> Bool {
        let normalizedName = DockTextMatch.normalized(appName)
        if normalizedName == "news" { return true }
        if bundleIdentifier == "com.apple.news" { return true }
        if let path {
            let url = URL(fileURLWithPath: path)
            if Bundle(url: url)?.bundleIdentifier == "com.apple.news" { return true }
            if DockTextMatch.normalized(url.deletingPathExtension().lastPathComponent) == "news" {
                return true
            }
        }
        return false
    }

    /// The action's own SF Symbol, tinted with its accent colour, as a row icon. Nil when
    /// the symbol is empty or unknown, so the caller falls back to the app icon.
    static func adapterActionSymbolImage(_ action: AdapterAction) -> NSImage? {
        let name = action.icon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
            let image = NSImage(systemSymbolName: name, accessibilityDescription: action.name)
        else { return nil }
        let tint: NSColor
        switch (action.accentColor ?? "blue").lowercased() {
        case "red": tint = .systemRed
        case "green": tint = .systemGreen
        case "orange": tint = .systemOrange
        case "yellow": tint = .systemYellow
        case "purple": tint = .systemPurple
        case "indigo": tint = .systemIndigo
        case "teal": tint = .systemTeal
        case "pink": tint = .systemPink
        case "gray", "grey": tint = .secondaryLabelColor
        default: tint = .systemBlue
        }
        let configured = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [tint]))
        return configured ?? image
    }

    // MARK: - The index

    func rebuild() {
        let started = Date()
        let runningRegularApps = Self.currentRegularRunningApps()
        guard !allApplications.isEmpty || !runningRegularApps.isEmpty else { return }
        // Rebuilding walks every cached menu snapshot and re-grams it on the main thread —
        // spin reports caught it holding the main queue for ~0.5s. The open path alone asks for
        // two rebuilds (frontmost warm, then the recent-app warm a second later), and every
        // reopen asks again. Coalesce: at most one rebuild per 8s.
        guard Date().timeIntervalSince(GlobalSearchIndexThrottle.lastRebuild) > 8 else { return }
        GlobalSearchIndexThrottle.lastRebuild = Date()
        GlobalSearchIndexStatus.shared.begin(message: "Building Global Context index...")

        var docs: [GlobalSearchService.SearchDocument] = []
        var seenIds = Set<String>()
        let indexedMenuSnapshotLimit = 360

        func addIfNew(_ doc: GlobalSearchService.SearchDocument) {
            guard seenIds.insert(doc.id).inserted else { return }
            docs.append(doc)
        }

        func addCachedMenuDocs(
            bundleId: String,
            appName: String,
            processIdentifier: pid_t = 0,
            icon: NSImage?,
            maxResults: Int = 24,
            sourceKind: GlobalSearchService.SourceKind = .runningMenu
        ) {
            guard !bundleId.isEmpty,
                GlobalContextEngine.shared.hasMenuSnapshot(bundleIdentifier: bundleId)
            else { return }
            let cachedMenus = GlobalContextEngine.shared.cachedMenuItems(
                bundleIdentifier: bundleId,
                appName: appName,
                processIdentifier: processIdentifier,
                query: "",
                maxResults: maxResults
            )
            for item in cachedMenus {
                if let menuDoc = GlobalSearchService.SearchDocument(
                    menuItem: item,
                    appName: appName,
                    bundleId: bundleId,
                    processIdentifier: processIdentifier,
                    icon: icon,
                    sourceKind: sourceKind
                ) {
                    addIfNew(menuDoc)
                }
            }
        }

        // 1. Running apps (highest priority)
        for app in runningRegularApps {
            guard let name = app.localizedName, !name.isEmpty,
                let bundleId = app.bundleIdentifier,
                bundleId != "com.apple.finder",
                bundleId != Bundle.main.bundleIdentifier
            else { continue }
            guard
                !Self.shouldIgnoreApplicationFromAppSearch(
                    appName: name, bundleIdentifier: bundleId, path: app.bundleURL?.path)
            else { continue }
            let icon = Self.runningAppIcon(app)
            let usageScore =
                AppUsageLearner.shared.score(forBundleID: bundleId)
                + (UsageTracker.shared.getScore(for: "app:\(app.bundleURL?.path ?? bundleId)")
                    / 100.0)
            addIfNew(.init(runningApp: app, icon: icon, usageScore: usageScore))
            addCachedMenuDocs(
                bundleId: bundleId,
                appName: name,
                processIdentifier: app.processIdentifier,
                icon: icon,
                maxResults: indexedMenuSnapshotLimit,
                sourceKind: .runningMenu
            )
        }

        // 2. Built-in Apple apps (always available, high-value targets)
        let builtIns: [(name: String, bundleId: String, path: String)] = [
            ("Safari", "com.apple.Safari", "/Applications/Safari.app"),
            ("Notes", "com.apple.Notes", "/System/Applications/Notes.app"),
            ("Messages", "com.apple.MobileSMS", "/System/Applications/Messages.app"),
            ("Mail", "com.apple.mail", "/System/Applications/Mail.app"),
            ("Calendar", "com.apple.iCal", "/System/Applications/Calendar.app"),
            ("Reminders", "com.apple.reminders", "/System/Applications/Reminders.app"),
            ("Photos", "com.apple.Photos", "/System/Applications/Photos.app"),
            ("Contacts", "com.apple.AddressBook", "/System/Applications/Contacts.app"),
            (
                "System Settings", "com.apple.systempreferences",
                "/System/Applications/System Settings.app"
            ),
            ("FaceTime", "com.apple.FaceTime", "/System/Applications/FaceTime.app"),
            ("Music", "com.apple.Music", "/System/Applications/Music.app"),
        ]
        for app in builtIns {
            guard
                !Self.shouldIgnoreApplicationFromAppSearch(
                    appName: app.name, bundleIdentifier: app.bundleId, path: app.path)
            else { continue }
            let path = GlobalApplicationMetadataCache.shared.applicationURL(bundleIdentifier: app.bundleId)?.path ?? app.path
            let icon = Self.applicationIcon(running: runningRegularApps, apps: allApplications, bundleIdentifier: app.bundleId, appName: app.name)
            let usageScore =
                AppUsageLearner.shared.score(forBundleID: app.bundleId)
                + (UsageTracker.shared.getScore(for: "app:\(path)") / 100.0)
            let result = SearchResult(
                title: app.name, subtitle: path, icon: icon,
                action: {}, type: .application, filePath: path, contactData: nil,
                stableID: "bundle:\(app.bundleId)")
            addIfNew(
                .init(
                    installedApp: result, bundleId: app.bundleId, sourceKind: .builtIn,
                    usageScore: usageScore))
        }

        // 4. All installed apps
        for result in allApplications where result.type == .application {
            let path = result.filePath ?? result.subtitle
            let bundleId = GlobalApplicationMetadataCache.shared.bundleIdentifier(forPath: path) ?? ""
            guard
                !Self.shouldIgnoreApplicationFromAppSearch(
                    appName: result.title, bundleIdentifier: bundleId.isEmpty ? nil : bundleId,
                    path: path)
            else { continue }
            let usageScore =
                AppUsageLearner.shared.score(forBundleID: bundleId)
                + (UsageTracker.shared.getScore(for: "app:\(path)") / 100.0)
            addIfNew(.init(installedApp: result, bundleId: bundleId, usageScore: usageScore))
        }
        GlobalSearchIndexStatus.shared.update(
            progress: 0.35,
            message: "Indexed apps and running app menus..."
        )

        // 5. CLI tools the user deliberately made a scope — pinned, or wired into an App
        // Adapter. `packages` also holds every executable BinaryWatcherService found on PATH,
        // and indexing those made "tac" ghost-complete as a scope the user never added and
        // Settings could neither list nor remove. Same predicate Settings uses.
        let cliIcon = NSWorkspace.shared.icon(forFileType: "public.unix-executable")
        for pkg in TerminalPackageManager.shared.packages
        where pkg.isEnabled && TerminalPackageManager.shared.isUserAddedGlobalScope(pkg) {
            addIfNew(.init(cliPackage: pkg, icon: cliIcon))
        }

        // 5b. Actions the user authored in App Adapters. Menu-bar actions are excluded
        // because AXMenuReader owns menus and section 7 already indexes them; CLI-tool
        // actions are excluded because they attach a terminal to a dock scope, which is not
        // something a global search row can do.
        for adapter in AppAdapterManager.shared.adapters where adapter.isEnabled {
            let appName = adapter.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleId = adapter.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleId.isEmpty, !bundleId.hasPrefix("cli://") else { continue }
            // The app icon is only a fallback. Each action carries its own SF Symbol and
            // accent colour — the glyphs shown in Settings — and rows were rendering blank
            // because a Safari Web App has no bundle URL to take an app icon from, leaving
            // nil. The action's own symbol is both more available and more informative.
            let appIcon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            for action in adapter.visibleActions
            where action.type != .menubar && action.type != .cliTool {
                addIfNew(
                    .init(
                        adapterAction: action,
                        appName: appName.isEmpty ? bundleId : appName,
                        bundleId: bundleId,
                        icon: Self.adapterActionSymbolImage(action) ?? appIcon))
            }
        }

        // 6. Global system commands — minus any whose plugin is installed. Installing a
        // migrated plugin does not delete the original (the Phase 8 cut-over does), so
        // without this both answer to the same name and one of the two rows is quietly the
        // old implementation. Uninstall the plugin and the command is back.
        let enabledManifests = PluginRegistry.shared.enabledPlugins.map(\.manifest)
        let supersededLegacyIDs = PluginSupersession.legacyIDs(in: enabledManifests)
        let replacedNames = PluginSupersession.replacedNames(in: enabledManifests)
        for command in SystemCommandsRegistry.shared.commands where command.isEnabled {
            guard !PluginSupersession.supersedes(
                legacyID: command.id.uuidString, covered: supersededLegacyIDs),
                !PluginSupersession.supersedes(legacyName: command.name, replaced: replacedNames)
            else { continue }
            let icon = NSImage(systemSymbolName: command.icon, accessibilityDescription: command.name)
            addIfNew(.init(systemCommand: command, icon: icon))
        }

        // 6b. Installed plugins, which answer to their own name wherever search reaches.
        for installed in PluginRegistry.shared.enabledPlugins {
            let manifest = installed.manifest
            addIfNew(
                .init(
                    plugin: manifest,
                    icon: NSImage(
                        systemSymbolName: manifest.icon, accessibilityDescription: manifest.name)))
        }
        GlobalSearchIndexStatus.shared.update(
            progress: 0.55,
            message: "Indexed commands and CLI scopes..."
        )

        // 7. Cached menus from all known app snapshots. Running apps above win by ID.
        let runningBundleIds = Set(
            runningRegularApps
                .compactMap(\.bundleIdentifier)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        for summary in AppMenuCapabilityCache.shared.summaries() {
            let bundleId = summary.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleId.isEmpty, !runningBundleIds.contains(bundleId.lowercased()) else {
                continue
            }
            let icon = Self.applicationIcon(running: runningRegularApps, apps: allApplications, 
                bundleIdentifier: bundleId,
                appName: summary.appName
            )
            addCachedMenuDocs(
                bundleId: bundleId,
                appName: summary.appName,
                icon: icon,
                maxResults: indexedMenuSnapshotLimit,
                sourceKind: .cachedMenu
            )
        }
        BrowserURLLibraryService.shared.refreshIfNeeded {
            GlobalSearchIndexBuilder.shared.rebuild()
        }
        for entry in BrowserURLLibraryService.shared.entries(matching: "", limit: 800) {
            let icon = Self.applicationIcon(running: runningRegularApps, apps: allApplications, 
                bundleIdentifier: entry.browserBundleId,
                appName: entry.browserName
            )
            addIfNew(.init(browserURL: entry, icon: icon))
        }
        // Global Extensions the user built. They reached the launcher's own list and no
        // further, so Global Context and the corner could not find one by any name (#15).
        for ext in UserGlobalExtensionStore.shared.enabledExtensions {
            guard !PluginSupersession.supersedes(
                legacyID: ext.id.uuidString, covered: supersededLegacyIDs)
            else { continue }
            addIfNew(
                .init(
                    userExtension: ext,
                    icon: NSImage(
                        systemSymbolName: ext.icon, accessibilityDescription: ext.name)))
        }

        GlobalSearchIndexStatus.shared.update(
            progress: 0.9,
            message: "Publishing search index..."
        )

        GlobalSearchService.shared.rebuild(with: docs)
        GlobalContextResultSource.shared.refresh()
        GlobalSearchIndexStatus.shared.finish(documentCount: docs.count)
        let elapsedMS = Date().timeIntervalSince(started) * 1_000
        if elapsedMS >= 8 {
            SearchPerformanceLog.shared.record(
                label: "rebuildGlobalSearchIndex docs=\(docs.count)",
                elapsedMS: elapsedMS,
                query: "",
                pills: docs.count
            )
        }
    }
}
