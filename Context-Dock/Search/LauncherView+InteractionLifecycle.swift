import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import OSLog
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

extension LauncherView {
    // MARK: - Swipe Gesture Monitor Functions












    // MARK: - Search Bar Collapse/Expand Functions

    func expandSearchBar() {
        // Blocked during layer transitions to prevent phantom expand on icon change
        guard !suppressHoverExpand else { return }

        collapseTimer?.cancel()

        withAnimation(.dockSheet) {
            isSearchBarExpanded = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isSearchFieldFocused = true
        }

        startCollapseTimer()
    }

    func startCollapseTimer() {
        // Auto-collapse disabled — bar only collapses when user clicks the search icon
        collapseTimer?.cancel()
    }


    func updateL2ContextExtensions() {
        guard settings.enableContextAIExtensions else {
            l2.contextExtensions = []
            return
        }

        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Frontmost app — from context or stored name
        let frontmostName: String? = {
            switch currentContext {
            case .appFocused(let name, _): return name
            default: return frontmost.name.isEmpty ? nil : frontmost.name
            }
        }()

        // Global Context always includes the live selection so file-type extensions fire.
        // Normal L2 app scope stays app-scoped (no reshuffle on every selection change).
        let includeSelectionContext =
            isGlobalContextActive
            || !isL2ContextActive

        // Selected files — from context + Finder
        var contextFiles: [URL] = {
            guard includeSelectionContext else { return [] }
            switch currentContext {
            case .filesSelected(let urls): return urls
            default: return []
            }
        }()
        // Also pull live Finder selection
        if includeSelectionContext {
            let finderFiles = axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
            if !finderFiles.isEmpty { contextFiles = finderFiles }
        }

        // Selected text
        let selectedText: String? = {
            guard includeSelectionContext else { return nil }
            switch currentContext {
            case .textSelected(let t): return t.isEmpty ? nil : t
            default: return nil
            }
        }()

        // Show extensions whenever there's any meaningful context
        let hasAnyContext =
            frontmostName != nil
            || !contextFiles.isEmpty
            || selectedText != nil

        if !hasAnyContext {
            l2.contextExtensions = []
            return
        }

        // Discover with full context
        let results = LayeredExtensionManager.shared.discoverExtensions(
            for: query,
            selectedFiles: contextFiles,
            selectedText: selectedText,
            frontmostApp: frontmostName,
            layer: .l2_context
        )

        l2.contextExtensions = Array(results.prefix(6))
    }

    func updateContextSuggestions() {
        updateL2ContextExtensions()
    }

    var shouldWarmFrontmostBrowserContext: Bool {
        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Global Context typing is cache-first: do not warm/read live browser context
        // from the keystroke path. Browser warmup belongs to Chat/Context Dock work.
        return currentDockSurfaceMode == .generalChat || aiMode.isLoading || l2.isLoading
            || (showContextInDock && !isGlobalContextActive && !query.isEmpty)
    }

    func cancelBrowserContextWarmup() {
        browserWarmupTask?.cancel()
        browserWarmupTask = nil
    }

    func scheduleBrowserContextWarmup(reason: String, urlOverride: String? = nil) {
        cancelBrowserContextWarmup()

        guard shouldWarmFrontmostBrowserContext,
            let app = contextTargetApp(),
            !app.isTerminated,
            AXWebReader.shared.isBrowser(bundleId: app.bundleIdentifier ?? "")
        else { return }

        let resolvedURL =
            (urlOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? urlOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil)
            ?? axContext.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? AXContextReader.shared.current.currentURL?.trimmingCharacters(
                in: .whitespacesAndNewlines)

        guard let currentURL = resolvedURL, !currentURL.isEmpty else { return }

        let pid = app.processIdentifier
        let appName = app.localizedName ?? "Browser"

        browserWarmupTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                AXWebReader.shared.refresh(pid: pid, currentURL: currentURL)
            }
        }
    }

    func setFrontmostAppContextOnly(reason: String) {
        guard settings.enableContextAIExtensions else {
            clearFinderFollowUpTargets()
            currentContext = .none
            l2.contextExtensions = []
            return
        }

        guard let frontmostApp = contextTargetApp() else {
            currentContext = .none
            updateContextSuggestions()
            return
        }

        let bundleID = frontmostApp.bundleIdentifier ?? ""
        let appName = frontmostApp.localizedName ?? "Unknown"
        if bundleID != "com.apple.finder" {
            clearFinderFollowUpTargets()
        }
        refreshCachedFinderCurrentDirectory(for: bundleID)
        frontmost.name = appName
        frontmost.bundleID = bundleID
        frontmost.icon =
            resolvedApplicationIcon(bundleIdentifier: bundleID, appName: appName)
            ?? preparedDockIcon(frontmostApp.icon)
        currentContext = .appFocused(name: appName, bundleID: bundleID)
        updateContextSuggestions()
        if AXWebReader.shared.isBrowser(bundleId: bundleID) {
            scheduleBrowserContextWarmup(reason: "frontmost browser context set")
        }
    }

    // MARK: - App Switch Observer

    func startObservingAppSwitches() {
        // ── Instant running-list refresh when any app launches ──
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [self] notification in
            runningRegularApps = currentRegularRunningApps()
            rebuildGlobalSearchIndex()
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                let bid = app.bundleIdentifier, app.activationPolicy == .regular
            {
                AppUsageLearner.shared.recordApp(bundleID: bid, appName: app.localizedName ?? "")
            }
        }

        // ── Instant running-list refresh when any app quits ──
        appTerminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            {
                reconcileDockAfterTermination(of: app)
            } else {
                runningRegularApps = currentRegularRunningApps()
            }
            rebuildGlobalSearchIndex()
        }

        // Observe when other apps become active (user switches windows)
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Only update if frontmost detection is enabled
            guard settings.enableFrontmostDetection else { return }

            // Get the activated app
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            {
                let bundleID = app.bundleIdentifier ?? ""
                let appName = app.localizedName ?? "Unknown"

                // Skip only our own app — ChatGPT is now treated as a normal frontmost app.
                if bundleID == Bundle.main.bundleIdentifier {
                    return
                }

                // A locked frontmost-app chat owns the dock. Do not repoint frontmost
                // metadata, re-detect context or reload the new app's menus underneath a
                // live conversation — the contextEnv path applies the same lock.
                if isContextDockChatLocked {
                    return
                }

                // Update frontmost app info
                frontmost.name = appName
                frontmost.bundleID = bundleID
                frontmost.icon =
                    resolvedApplicationIcon(bundleIdentifier: bundleID, appName: appName)
                    ?? preparedDockIcon(app.icon)

                // Record app activation in on-device learner
                AppUsageLearner.shared.recordApp(bundleID: bundleID, appName: appName)

                // Auto-map to an appKey so the AI knows context without manual panel selection
                settings.autoDetectedAppKey = settings.appKey(
                    forBundleID: bundleID, appName: appName)

                // Re-detect context (selected text/files/browser tab/clipboard) and then refresh suggestions.
                // This ensures suggestions update based on actual user selection, not just the app name.
                if bundleID != "com.apple.finder" {
                    clearFinderFollowUpTargets()
                }

                // When Finder becomes active with no window (desktop mode), skip expensive
                // menu reloads — treat it as a neutral desktop state.
                let isFinderDesktop = bundleID == "com.apple.finder" && !finderHasActiveWindow()
                detectAndUpdateContext()

                // Global Context is cache-first. Do not live-reload L2 menus while the
                // Global Context surface is active; cached/global matching owns that path.
                if showContextInDock && !isGlobalContextActive && !isFinderDesktop {
                    updateL2Results([])
                    reloadMenuForApp(app)
                }
            }
        }
    }

    func stopObservingAppSwitches() {
        for observer in [appSwitchObserver, appLaunchObserver, appTerminateObserver].compactMap({
            $0
        }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        appSwitchObserver = nil
        appLaunchObserver = nil
        appTerminateObserver = nil
    }

}
