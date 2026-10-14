import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension LauncherView {
    func launchApplication(bundleIdentifier: String?, appName: String?, path: String? = nil)
        -> Bool
    {
        // Track launch for usage-based completion ranking
        if let bid = bundleIdentifier, !bid.isEmpty {
            AppLaunchTracker.shared.record(bundleId: bid)
        }

        if let path, !path.isEmpty {
            openApplicationKeepingDockFocus(
                URL(fileURLWithPath: path),
                bundleIdentifier: bundleIdentifier
            )
            return true
        }

        if let bundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        {
            openApplicationKeepingDockFocus(url, bundleIdentifier: bundleIdentifier)
            return true
        }

        guard let appName, !appName.isEmpty else { return false }
        let appDirectories = [
            "/Applications",
            "/System/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "\(NSHomeDirectory())/Applications",
        ]
        for directory in appDirectories {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(appName)
                .appendingPathExtension("app")
            if FileManager.default.fileExists(atPath: url.path) {
                openApplicationKeepingDockFocus(url, bundleIdentifier: bundleIdentifier)
                return true
            }
        }

        return false
    }

    func runningApp(for pinnedApp: PinnedApp) -> NSRunningApplication? {
        if let bundleId = pinnedApp.bundleIdentifier, !bundleId.isEmpty {
            return runningRegularApps.first {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            }
        }
        let itemPath = URL(fileURLWithPath: pinnedApp.path).path
        return runningRegularApps.first {
            guard let runningPath = $0.bundleURL?.path else { return false }
            return runningPath == itemPath && !$0.isTerminated
        }
    }

    func bundleIdentifier(for pinnedApp: PinnedApp) -> String? {
        if let bundleId = pinnedApp.bundleIdentifier, !bundleId.isEmpty {
            return bundleId
        }
        if let running = runningApp(for: pinnedApp)?.bundleIdentifier, !running.isEmpty {
            return running
        }
        guard pinnedApp.type == .application else { return nil }
        return Bundle(path: pinnedApp.path)?.bundleIdentifier
    }

    func resetDockStateAfterAppAction() {
        searchState.query = ""
        searchState.results = []
        searchState.selectedIndex = nil
        l2.focusedPillIndex = nil
        hoveredDockAppKey = nil
        lockedSubmenuParent = nil
    }

    func refocusLauncherWindowAfterAppAction(delay: TimeInterval = 0.12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.isVisible = true
            self.expandSearchBar()
            self.isSearchFieldFocused = true

            if let window = NSApp.windows.first(where: { $0.isVisible })
            {
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }

            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func openApplicationKeepingDockFocus(_ url: URL, bundleIdentifier: String? = nil) {
        let resolvedBundleId = bundleIdentifier ?? Bundle(url: url)?.bundleIdentifier
        let urlAppName = url.deletingPathExtension().lastPathComponent
        resetDockStateAfterAppAction()
        hideLauncherAfterResultExecution()

        if let resolvedBundleId,
            let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == resolvedBundleId && !$0.isTerminated
            })
        {
            activateRunningAppFromDock(runningApp)
            return
        }

        let launchId = DockActionFeedback.start(
            "Opening",
            subject: urlAppName,
            icon: "arrow.up.right.circle.fill",
            tint: .accentColor,
            bundleID: resolvedBundleId)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        Task {
            var launchedApp: NSRunningApplication?
            do {
                launchedApp = try await NSWorkspace.shared.openApplication(
                    at: url, configuration: configuration)
            } catch {
                NSWorkspace.shared.open(url)
            }

            await MainActor.run {
                let name = launchedApp?.localizedName ?? urlAppName
                DockActionFeedback.complete(
                    launchId,
                    label: "\(name) opened",
                    subject: name,
                    bundleID: launchedApp?.bundleIdentifier ?? resolvedBundleId)
            }
        }
    }

    func activateRunningAppFromDock(_ app: NSRunningApplication, forceHideLauncher: Bool = false) {
        resetDockStateAfterAppAction()
        if forceHideLauncher {
            forceHideLauncherAfterResultExecution()
        } else {
            hideLauncherAfterResultExecution()
        }
        let name = app.localizedName ?? "App"
        let switchId = DockActionFeedback.start(
            "Switching to", subject: name, icon: "arrow.up.right.circle", tint: .white.opacity(0.8))
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateIgnoringOtherApps])
        // Electron/Catalyst apps (VS Code, Slack…) frequently ignore
        // NSRunningApplication.activate on modern macOS and stay behind the dock.
        // Re-opening via NSWorkspace reliably raises them and does NOT relaunch a
        // running app — it just activates it.
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
        // Dismiss the "Switching to" toast once the app has had time to become frontmost
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            DockActionFeedback.complete(switchId)
        }
        // Un-minimize the app's windows and raise them — never move or resize. Minimized
        // windows animate back in asynchronously, so this polls until a real window
        // appears instead of firing one premature attempt that finds only a minimized
        // frame.
        WindowManagementService.shared.restoreAfterActivate(app)
        // Don't steal focus back — the activated app should remain frontmost
    }

    func activateRunningAppFromGlobalContext(
        _ app: NSRunningApplication,
        forceHideLauncher: Bool = false
    ) {
        let appName = app.localizedName ?? "App"
        AppDelegate.shared?.holdDockThroughAppLaunch()
        activateRunningAppFromDock(app, forceHideLauncher: forceHideLauncher)
        scheduleContextDockTransition(bundleId: app.bundleIdentifier, appName: appName)
    }

    /// Called when an app is launched/activated from global context.
    /// Hides launcher immediately, then updates Context Dock state after activation.
    func scheduleContextDockTransition(bundleId: String?, appName: String) {
        // Don't hide the dock while the app launches — keep it visible and let it morph
        // into the launched app's Context Dock (premium launch, no hide+relaunch flicker).
        AppDelegate.shared?.holdDockThroughAppLaunch()
        let normalizedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBundleId = NSWorkspace.shared.runningApplications.first { app in
            guard !app.isTerminated else { return false }
            return app.localizedName?.compare(
                normalizedAppName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }?.bundleIdentifier

        guard
            let bundleId = [resolvedBundleId, fallbackBundleId].compactMap({ $0 }).first(where: {
                !$0.isEmpty
            })
        else {
            return
        }
        pendingGlobalLaunchContextSwitch = (bundleId: bundleId, appName: appName)
        globalInlineAppScope = nil
        additionalGlobalInlineAppScopes = []
        dismissedGlobalInlineAppScopes = [:]
        l2.targetApp = nil
        searchState.query = ""
        focusedAppPillIndex = nil
        hoveredAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        scheduleGlobalGroupedListRebuild(query: "", delayNanoseconds: 0)

        // If the user picks the already-frontmost running app, macOS may not emit a
        // didActivateApplication notification. Switch immediately instead of waiting.
        let activeBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmost.bundleID == bundleId || activeBundleId == bundleId {
            switchGlobalLaunchToContextDock(bundleId: bundleId, appName: appName)
            return
        }

        // Fallback for apps that activate before the observer publishes its event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            guard self.pendingGlobalLaunchContextSwitch?.bundleId == bundleId else { return }
            let activeBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard self.frontmost.bundleID == bundleId || activeBundleId == bundleId else { return }
            self.switchGlobalLaunchToContextDock(bundleId: bundleId, appName: appName)
        }
    }

    func switchGlobalLaunchToContextDock(bundleId: String, appName: String) {
        pendingGlobalLaunchContextSwitch = nil
        globalContextActivation = nil
        globalInlineAppScope = nil
        additionalGlobalInlineAppScopes = []
        suppressGlobalInlineAppScopeDetection = false
        dismissedGlobalInlineAppScopes = [:]
        l2.targetApp = nil
        searchState.query = ""
        focusedAppPillIndex = nil
        hoveredAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        showMediaLayer = false
        aiMode.isActive = false
        showContextInDock = true
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) {
            frontmost.bundleID = bundleId
            frontmost.name = app.localizedName ?? appName
            frontmost.icon =
                resolvedApplicationIcon(bundleIdentifier: bundleId, appName: frontmost.name)
                ?? preparedDockIcon(app.icon)
        } else {
            frontmost.bundleID = bundleId
            frontmost.name = appName
            frontmost.icon = resolvedApplicationIcon(bundleIdentifier: bundleId, appName: appName)
        }
        setFrontmostAppContextOnly(reason: "global launch became frontmost")
        syncL2DockSession(force: true)
        scheduleDockPillRebuild(query: "", delayNanoseconds: 0, refreshContext: false)
        // Stay visible on the launched app's Context Dock instead of hiding. The app keeps
        // focus (we don't steal it); the dock floats above showing its context actions.
        suppressAutomaticGlobalContextUntil = Date().addingTimeInterval(1.6)
        AppDelegate.shared?.holdDockThroughAppLaunch()
    }

    func terminateRunningAppFromDock(_ app: NSRunningApplication) {
        let name = app.localizedName ?? "App"
        let bundleID = app.bundleIdentifier ?? ""
        beginGlobalQuitBatchPresentation()
        hoveredDockAppKey = nil
        if !bundleID.isEmpty {
            launcherViewModel.appQuitFeedbackPhases[bundleID] = .progress
        }
        let feedbackID = DockActionFeedback.start(
            "Quitting",
            subject: name,
            icon: "xmark.circle.fill",
            tint: .red.opacity(0.85),
            bundleID: bundleID.isEmpty ? nil : bundleID
        )
        app.terminate()
        refocusLauncherWindowAfterAppAction(delay: 0.06)
        scheduleDockRefreshAfterTerminationAttempt(for: app, feedbackID: feedbackID)
        refreshGlobalSearchAfterRunningAppMutation()
    }

    /// Spotlight-style multi-quit: retain the filtered Global Context result list while
    /// the app exit changes focus, refresh rows inline, then dismiss only after the
    /// user leaves it idle. This owns one sleeping task, never a repeating timer.
    func beginGlobalQuitBatchPresentation() {
        guard isGlobalContextActive else { return }
        globalQuitIdleDismissTask?.cancel()
        globalQuitIdleDismissGeneration &+= 1
        let generation = globalQuitIdleDismissGeneration
        let queryAtLastQuit = searchState.query

        AppDelegate.shared?.holdDockForGlobalQuitBatch(seconds: 10)
        DispatchQueue.main.async { self.reclaimSearchInputFocus() }

        globalQuitIdleDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled,
                generation == globalQuitIdleDismissGeneration,
                isGlobalContextActive,
                searchState.query == queryAtLastQuit
            else { return }
            isSearchFieldFocused = false
        }
    }


    func refreshGlobalSearchAfterRunningAppMutation() {
        guard isGlobalContextActive else { return }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuildGlobalSearchIndex()
        focusedAppPillIndex = nil
        hoveredAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        scheduleGlobalAppMatchRebuild(query: q, delayNanoseconds: 0)
        scheduleGlobalGroupedListRebuild(query: q, delayNanoseconds: 0)
        DispatchQueue.main.async {
            self.reclaimSearchInputFocus()
        }
    }







    func fallbackRunningAppAfterTermination(
        excludingProcessIdentifier processIdentifier: pid_t,
        excludingBundleIdentifier bundleIdentifier: String?
    ) -> NSRunningApplication? {
        let candidates = currentRegularRunningApps().filter { app in
            guard app.processIdentifier != processIdentifier else { return false }
            if let bundleIdentifier, !bundleIdentifier.isEmpty {
                return app.bundleIdentifier != bundleIdentifier
            }
            return true
        }

        return candidates.first(where: { $0.bundleIdentifier != "com.apple.finder" })
            ?? candidates.first
    }

    func actualFrontmostAppAfterTermination(
        excludingProcessIdentifier processIdentifier: pid_t,
        excludingBundleIdentifier bundleIdentifier: String?
    ) -> NSRunningApplication? {
        let ownBundleID = Bundle.main.bundleIdentifier ?? ""

        func isValid(_ app: NSRunningApplication?) -> Bool {
            guard let app, !app.isTerminated else { return false }
            guard app.processIdentifier != processIdentifier else { return false }
            let appBundleID = app.bundleIdentifier ?? ""
            guard appBundleID != ownBundleID else { return false }
            if let bundleIdentifier, !bundleIdentifier.isEmpty {
                guard appBundleID != bundleIdentifier else { return false }
            }
            return app.activationPolicy == .regular
        }

        if isValid(NSWorkspace.shared.frontmostApplication) {
            return NSWorkspace.shared.frontmostApplication
        }

        if let recent = AppDelegate.shared?.recentApps.first(where: { isValid($0) }) {
            return recent
        }

        return currentRegularRunningApps().first(where: { isValid($0) })
    }

    /// After a non-scope app quits, re-point the dock at the app that is actually frontmost now.
    /// Deferred one tick because macOS hasn't promoted the next app to frontmost at the instant
    /// `didTerminateApplicationNotification` fires — reading it synchronously would still return
    /// the dying app (and fall back to recents, surfacing a wrong app like the previous editor).
    func resyncFrontmostToActualAfterTermination(excluding terminated: NSRunningApplication) {
        let terminatedPID = terminated.processIdentifier
        let terminatedBundleID = terminated.bundleIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            guard let actual = actualFrontmostAppAfterTermination(
                excludingProcessIdentifier: terminatedPID,
                excludingBundleIdentifier: terminatedBundleID
            ),
            let bundleID = actual.bundleIdentifier,
            let name = actual.localizedName,
            frontmost.bundleID != bundleID
            else { return }

            AppDelegate.shared?.recordFrontmostApp(actual)
            ContextDockEnvironment.shared.frontmostAppDidChange(name: name, bundleID: bundleID)
            frontmost.name = name
            frontmost.bundleID = bundleID
            frontmost.icon =
                resolvedRunningAppIcon(for: actual) ?? preparedDockIcon(actual.icon)
            if showContextInDock {
                reloadMenuForApp(actual)
            }
        }
    }

    func clearLiveDockMenuState() {
        liveMenuItems = []
        crossAppMenuItems = []
        crossAppMenuTargetPID = 0
        contextMenuPills = []
        previousEnabledIDs = []
        menuDebugText = "menu debug unavailable"
    }

    func reconcileDockAfterTermination(of app: NSRunningApplication) {
        runningRegularApps = currentRegularRunningApps()
        AppDelegate.shared?.removeRecentApp(app)
        let terminatedBundleID = app.bundleIdentifier ?? ""
        let shouldStayInContextDockAfterQuit = showContextInDock && !isGlobalContextActive
        let terminatedScope =
            (!terminatedBundleID.isEmpty && l2.targetApp?.bundleId == terminatedBundleID)
            || (!terminatedBundleID.isEmpty
                && globalInlineAppScope?.bundleId == terminatedBundleID)
        let fallback =
            shouldStayInContextDockAfterQuit
            ? actualFrontmostAppAfterTermination(
                excludingProcessIdentifier: app.processIdentifier,
                excludingBundleIdentifier: app.bundleIdentifier
            )
            : fallbackRunningAppAfterTermination(
                excludingProcessIdentifier: app.processIdentifier,
                excludingBundleIdentifier: app.bundleIdentifier
            )

        if let delegate = AppDelegate.shared,
            delegate.previousFrontmostApp?.processIdentifier == app.processIdentifier
                || (!(app.bundleIdentifier ?? "").isEmpty
                    && delegate.previousFrontmostApp?.bundleIdentifier == app.bundleIdentifier)
        {
            delegate.previousFrontmostApp = fallback
        }

        if frontmost.bundleID == app.bundleIdentifier
            || frontmost.name == (app.localizedName ?? "")
        {
            frontmost.bundleID = ""
            frontmost.name = ""
            frontmost.icon = nil
        }

        if terminatedScope {
            l2.targetApp = nil
            globalInlineAppScope = nil
            clearLiveDockMenuState()
            if let fallback,
                let bundleID = fallback.bundleIdentifier,
                let name = fallback.localizedName
            {
                if shouldStayInContextDockAfterQuit {
                    AppDelegate.shared?.recordFrontmostApp(fallback)
                    ContextDockEnvironment.shared.frontmostAppDidChange(name: name, bundleID: bundleID)
                    frontmost.name = name
                    frontmost.bundleID = bundleID
                    frontmost.icon =
                        resolvedRunningAppIcon(for: fallback)
                        ?? preparedDockIcon(fallback.icon)
                } else {
                    _ = activateInlineDockAppScope(
                        bundleIdentifier: bundleID,
                        appName: name,
                        queryOverride: "",
                        preserveGlobalContext: isGlobalContextActive
                    )
                }
            }
        }

        // Non-scope termination: the displayed `frontmost` can be stale here. A pass-through app
        // (ChatGPT is skipped by the activation observer) means `frontmost` still points at the
        // app from before it, and quitting it doesn't match the terminated-app checks above. Since
        // contextTargetApp() prioritizes frontmost.bundleID, the dock would keep showing that stale
        // app instead of the one the user lands on. Re-resolve to the real current frontmost.
        if shouldStayInContextDockAfterQuit, !terminatedScope {
            resyncFrontmostToActualAfterTermination(excluding: app)
        }

        detectAndUpdateContext()

        if showContextInDock, let targetApp = contextTargetApp() {
            reloadMenuForApp(targetApp)
        } else {
            clearLiveDockMenuState()
        }

    }

    func scheduleDockRefreshAfterTerminationAttempt(
        for app: NSRunningApplication,
        feedbackID: String? = nil
    ) {
        let targetPID = app.processIdentifier
        let targetBundleId = app.bundleIdentifier
        runningRegularApps.removeAll { running in
            running.processIdentifier == targetPID
                || (!(targetBundleId ?? "").isEmpty && running.bundleIdentifier == targetBundleId)
        }
        AppDelegate.shared?.removeRecentApp(app)

        Task {
            for _ in 0..<18 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                let apps = currentRegularRunningApps()
                runningRegularApps = apps

                let stillRunning = apps.contains { running in
                    if running.processIdentifier == targetPID { return true }
                    if let targetBundleId, !targetBundleId.isEmpty {
                        return running.bundleIdentifier == targetBundleId
                    }
                    return false
                }

                guard !stillRunning else { continue }
                if let feedbackID {
                    let appName = app.localizedName ?? "App"
                    DockActionFeedback.complete(
                        feedbackID,
                        label: "\(appName) quit",
                        subject: appName,
                        bundleID: targetBundleId
                    )
                }
                if let targetBundleId, !targetBundleId.isEmpty {
                    launcherViewModel.appQuitFeedbackPhases[targetBundleId] = .success
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        if self.launcherViewModel.appQuitFeedbackPhases[targetBundleId] == .success {
                            self.launcherViewModel.appQuitFeedbackPhases[targetBundleId] = nil
                        }
                    }
                }
                reconcileDockAfterTermination(of: app)
                return
            }

            runningRegularApps = currentRegularRunningApps()
            if let feedbackID {
                DockActionFeedback.dismiss(feedbackID)
            }
            if let targetBundleId, !targetBundleId.isEmpty {
                launcherViewModel.appQuitFeedbackPhases[targetBundleId] = nil
            }
        }
    }

    /// - Parameter launchBundleId: pass alongside `sourcePID: 0` to click a menu path that
    ///   came from a cached snapshot — the app is launched and its menus prepared first.
    func executeDockMenuAction(
        sourcePID: pid_t,
        launchBundleId: String? = nil,
        path: [String],
        shortcutChar: String?,
        shortcutModifiers: Int
    ) {
        MenuExecutionCoordinator.shared.executeDockMenuAction(
            request: .init(
                sourcePID: sourcePID,
                launchBundleId: launchBundleId,
                path: path,
                shortcutChar: shortcutChar,
                shortcutModifiers: shortcutModifiers,
                knownMenuItems: liveMenuItems + crossAppMenuItems,
                isGlobalContextActive: isGlobalContextActive,
                hasActiveDockContextSelection: hasActiveDockContextSelection,
                keepsDockFloating: settings.alwaysFloatDock
                    || (settings.effectiveDockAtBottom && showContextInDock)
            ),
            callbacks: .init(
                hideBeforeExecution: {
                    if settings.alwaysFloatDock
                        || (settings.effectiveDockAtBottom && showContextInDock)
                    {
                        searchState.query = ""
                        focusedAppPillIndex = nil
                        l2.focusedPillIndex = nil
                        l2.pillNavViaKeyboard = false
                        reclaimSearchInputFocus()
                    } else {
                        hideLauncherAfterResultExecution()
                    }
                },
                refreshRunningApps: {
                    runningRegularApps = currentRegularRunningApps()
                },
                scheduleTerminationRefresh: { app in
                    scheduleDockRefreshAfterTerminationAttempt(for: app)
                },
                reloadMenu: { app in
                    reloadMenuForApp(app)
                },
                clearLiveDockMenuState: {
                    clearLiveDockMenuState()
                },
                refocusDockInput: {
                    refocusLauncherWindowAfterAppAction(delay: 0.06)
                }
            )
        )
    }

    func resolvedRunningAppIcon(for app: NSRunningApplication) -> NSImage? {
        GlobalSearchIndexBuilder.runningAppIcon(app)
    }

    func currentBrowserPageURL() -> URL? {
        guard showContextInDock,
            !isGlobalContextActive
        else { return nil }

        let liveRaw = liveBrowserPageURLString()
        let attachedRaw = isContextDockChatConnected ? webResearch.pages.last?.url : nil
        guard attachedRaw != nil || AXWebReader.shared.isBrowser(bundleId: frontmost.bundleID) else {
            return nil
        }
        let raw = isContextDockChatConnected ? (attachedRaw ?? liveRaw) : liveRaw
        guard let raw,
            let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.host != nil
        else { return nil }
        return url
    }

    func liveBrowserPageURLString() -> String? {
        let previousApp = AppDelegate.shared?.previousFrontmostApp
        let pid = previousApp?.processIdentifier ?? 0
        let bundleId = previousApp?.bundleIdentifier ?? ""
        // Fresh on-demand AX read — the only source that works for Safari Web Apps
        // (no extension, no address bar, cached context may point at the dock).
        let liveAXRead: String? = {
            guard previousApp != nil, !bundleId.isEmpty else { return nil }
            return AXContextReader.shared.liveCurrentURL(pid: pid, bundleId: bundleId)
        }()

        // Safari Web Apps (YouTube, YT Music, Spotify…) have no extension bridge and no
        // address bar, and the cached sources can still hold a stale value or the web
        // app's bundle id — which leaked into the prompt as the "page URL". For those,
        // the live AXWebArea read must win.
        let isSafariWebApp = bundleId.hasPrefix("com.apple.Safari.WebApp")
        let ordered: [String?] =
            isSafariWebApp
            ? [
                liveAXRead,
                AXWebReader.shared.cachedSnapshot(for: pid)?.url,
                axContext.currentURL,
            ]
            : [
                SafariBrowserBridge.shared.isFresh ? SafariBrowserBridge.shared.latestContext?.url : nil,
                AXWebReader.shared.cachedSnapshot(for: pid)?.url,
                axContext.currentURL,
                AXContextReader.shared.current.currentURL,
                liveAXRead,
                SafariTabManager.shared.lastSelectedTab()?.url,
            ]

        // Only accept real web URLs — never a bundle id or an app name.
        return ordered.compactMap { $0 }.first { raw in
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                url.host?.isEmpty == false
            else { return false }
            return true
        }
    }




    var currentGlobalScopedBundleID: String? {
        if let target = l2.targetApp?.bundleId,
            !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return target
        }
        if let target = globalInlineAppScope?.bundleId,
            !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return target
        }
        return nil
    }





    @ViewBuilder
    /// Apps matched from the query's word tokens ("mail recent notes" → Mail, Notes).
    /// Fallback feedback for when no app/command/menu row matches the full query.
    func tokenMatchedAppResults(for query: String) -> [SearchResult] {
        let tokens = query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
        guard !tokens.isEmpty else { return [] }
        var out: [SearchResult] = []
        var seen = Set<String>()
        for token in tokens {
            for match in instantGlobalApplicationMatches(for: token, limit: 1) {
                guard seen.insert(match.title.lowercased()).inserted else { continue }
                out.append(match)
            }
            if out.count >= 5 { break }
        }
        return out
    }



    var shouldShowSafariTabStrip: Bool {
        showContextInDock
            && !isGlobalContextActive
            && !aiMode.isActive
            && !showMediaLayer
            && !isCompactSmartScope
            && searchState.contextApp == nil
            && searchState.selectedIndex == nil
            && l2.targetApp == nil
            && currentDockSurfaceMode != .generalChat
            && AXWebReader.shared.isBrowser(bundleId: frontmost.bundleID)
    }





    func syncSafariTabStrip(force: Bool = false) {
        let cached = SafariTabManager.shared.cachedTabs(maxAge: 45)
        if !cached.isEmpty,
            cached.map(\.id) != safariTabPickerTabs.map(\.id)
        {
            withAnimation(.dockSoft) {
                safariTabPickerTabs = cached
            }
        }
        SafariTabManager.shared.refreshCachedTabsIfNeeded(force: force) { tabs in
            guard tabs.map(\.id) != safariTabPickerTabs.map(\.id) else { return }
            withAnimation(.dockSoft) {
                safariTabPickerTabs = tabs
            }
        }
    }






}
