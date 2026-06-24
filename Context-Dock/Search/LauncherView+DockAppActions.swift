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

            if let window = AppDelegate.shared?.launcherWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
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
            "Opening", subject: urlAppName, icon: "arrow.up.right.circle.fill", tint: .accentColor)

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
                DockActionFeedback.complete(launchId, label: "\(name) opened")
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
        // Dismiss the "Switching to" toast once the app has had time to become frontmost
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            DockActionFeedback.complete(switchId)
        }
        // Un-minimize the app's windows and centre once restored. Minimized windows
        // animate back in asynchronously, so this polls until a real window appears
        // instead of firing one premature attempt that finds only a minimized frame
        // (which used to surface a spurious "No window found" toast and skip centring).
        WindowManagementService.shared.centerAfterActivate(app)
        // Don't steal focus back — the activated app should remain frontmost
    }

    /// Called when an app is launched/activated from global context.
    /// Hides launcher immediately, then updates Context Dock state after activation.
    func scheduleContextDockTransition(bundleId: String?, appName: String) {
        hideLauncherAfterResultExecution()
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
        hideLauncherAfterResultExecution()
    }

    func terminateRunningAppFromDock(_ app: NSRunningApplication) {
        let name = app.localizedName ?? "App"
        let bundleID = app.bundleIdentifier ?? ""
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

    func appQuitFeedbackPhase(bundleID: String?) -> DockInlineFeedback.Phase? {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty
        else { return nil }
        return launcherViewModel.appQuitFeedbackPhases[bundleID]
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
            self.requestWindowSizeUpdate(reason: .contentSettled)
        }
    }

    func shouldRequireFullAppNameMatch(
        appName: String,
        bundleIdentifier: String?
    ) -> Bool {
        let normalizedName = normalizedDockPillText(appName)
        if normalizedName == "news" { return true }
        return bundleIdentifier == "com.apple.news"
    }

    func shouldAllowShortAppPrefixMatch(
        prefix: String,
        appName: String,
        bundleIdentifier: String?
    ) -> Bool {
        guard
            !shouldRequireFullAppNameMatch(
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
        else {
            return prefix.count >= 4
        }
        return true
    }

    func shouldAllowLocalAppPartialCompletion(
        fullQuery: String,
        firstToken: String,
        actionQuery: String
    ) -> Bool {
        guard !actionQuery.isEmpty else { return true }
        if isQuestionLikeAppPartialQuery(fullQuery) { return false }
        if isCommonLanguageAppPartialStart(firstToken)
            && !looksLikeAppCommandRemainder(actionQuery)
        {
            return false
        }
        return true
    }

    func isQuestionLikeAppPartialQuery(_ query: String) -> Bool {
        let tokens = query.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return false }
        let questionStarts: Set<String> = [
            "what", "whats", "who", "when", "where", "why", "how",
            "is", "are", "do", "does", "did", "can", "could", "should",
            "tell", "explain", "describe", "summarize", "analyse", "analyze",
        ]
        if questionStarts.contains(first) { return true }
        if tokens.count >= 2 {
            let firstTwo = tokens.prefix(2).joined(separator: " ")
            if ["what is", "what are", "how do", "how can", "tell me"].contains(firstTwo) {
                return true
            }
        }
        return false
    }

    func isCommonLanguageAppPartialStart(_ token: String) -> Bool {
        let commonStarts: Set<String> = [
            "a", "an", "the", "this", "that", "these", "those",
            "what", "whats", "who", "when", "where", "why", "how",
            "is", "are", "do", "does", "did", "can", "could", "should",
            "i", "me", "my", "we", "you", "it", "its",
            "tell", "explain", "describe", "summarize", "analyse", "analyze",
        ]
        return commonStarts.contains(token)
    }

    func looksLikeAppCommandRemainder(_ actionQuery: String) -> Bool {
        guard let first = actionQuery.split(separator: " ").map(String.init).first else {
            return false
        }
        let commandStarts: Set<String> = [
            "open", "new", "close", "send", "message", "call", "search", "find",
            "show", "list", "compose", "create", "add", "play", "pause", "stop",
            "next", "previous", "download", "share", "copy", "paste", "reply",
        ]
        return commandStarts.contains(first)
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

        requestWindowSizeUpdate(reason: .modeChanged)

        if shouldStayInContextDockAfterQuit,
            let fallback,
            fallback.bundleIdentifier != nil
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                AppDelegate.shared?.activateContextDock()
            }
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

    func executeDockMenuAction(
        sourcePID: pid_t,
        path: [String],
        shortcutChar: String?,
        shortcutModifiers: Int
    ) {
        MenuExecutionCoordinator.shared.executeDockMenuAction(
            request: .init(
                sourcePID: sourcePID,
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
        if let bundleURL = app.bundleURL {
            return preparedDockIcon(NSWorkspace.shared.icon(forFile: bundleURL.path))
        }
        return preparedDockIcon(app.icon)
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
        let pid = AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
        return (SafariBrowserBridge.shared.isFresh ? SafariBrowserBridge.shared.latestContext?.url : nil)
            ?? AXWebReader.shared.cachedSnapshot(for: pid)?.url
            ?? axContext.currentURL
            ?? AXContextReader.shared.current.currentURL
            ?? SafariTabManager.shared.lastSelectedTab()?.url
    }

    func currentBrowserPageIcon() -> NSImage? {
        guard let url = currentBrowserPageURL() else { return nil }
        if let favicon = FaviconStore.shared.icon(for: url) {
            return preparedDockIcon(favicon)
        }
        FaviconStore.shared.fetchIfNeeded(for: url)
        let symbol = SafariTab(title: "", url: url.absoluteString, windowIndex: 0, tabIndex: 0).icon
        return preparedDockIcon(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
    }

    var currentBrowserPageIconIdentity: String? {
        currentBrowserPageURL()?.absoluteString
    }

    var shouldShowGlobalRunningAppStrip: Bool {
        showContextInDock
            && !aiMode.isActive
            && !showMediaLayer
            && !isCompactSmartScope
            && searchState.contextApp == nil
            && searchState.selectedIndex == nil
            && !isContextDockChatConnected
            && (isGlobalContextActive ? activeSelectionLabel == nil : l2.targetApp == nil)
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

    var globalRunningAppStripApps: [NSRunningApplication] {
        guard shouldShowGlobalRunningAppStrip else { return [] }
        let frontmostBundle = frontmost.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedBundle = currentGlobalScopedBundleID
        let source = runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps
        let others =
            source
            .filter { app in
                guard !app.isTerminated else { return false }
                guard app.bundleURL != nil || app.executableURL != nil else { return false }
                guard let bundleID = app.bundleIdentifier else { return true }
                return bundleID != "com.apple.finder"
                    && bundleID != frontmostBundle
                    && bundleID != scopedBundle
            }
        // Finder always leads the strip in Global Context.
        let finder = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.finder" && !$0.isTerminated
        }
        return (Array([finder].compactMap { $0 }) + others)
            .prefix(5)
            .map { $0 }
    }

    var globalScopeCycleApps: [NSRunningApplication] {
        guard isGlobalContextActive,
            showContextInDock,
            !aiMode.isActive,
            !showMediaLayer,
            !isCompactSmartScope,
            searchState.contextApp == nil,
            activeSelectionLabel == nil
        else { return [] }

        let frontmostBundle = frontmost.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedBundle = currentGlobalScopedBundleID
        var seen = Set<String>()
        let others = (runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps)
            .filter { app in
                guard !app.isTerminated else { return false }
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return false }
                guard seen.insert(bundleID).inserted else { return false }
                if bundleID == Bundle.main.bundleIdentifier { return false }
                if bundleID == "com.apple.finder" { return false }
                if bundleID == scopedBundle { return true }
                return bundleID != frontmostBundle
            }
        // Finder leads the cycle so the first right-arrow scopes Finder (matches the strip),
        // entering desktop file-search mode.
        let finder = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.finder" && !$0.isTerminated
        }
        return Array([finder].compactMap { $0 }) + others
    }

    @discardableResult
    func switchGlobalContextScope(to app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier,
            let appName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty,
            !appName.isEmpty
        else { return false }
        // Scoping Finder in Global Context is pure desktop/home file search — it must NOT
        // inherit a folder attachment left over from an earlier Context Dock session
        // (otherwise the desktop mode "locks" to e.g. Downloads).
        if bundleID == "com.apple.finder" {
            detachFinderFolderSearch()
        }
        let activated = activateInlineDockAppScope(
            bundleIdentifier: bundleID,
            appName: appName,
            queryOverride: searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : nil,
            preserveGlobalContext: true
        )
        if activated {
            // Run AFTER activateInlineDockAppScope's own focus toggle settles, so this is
            // the authoritative last focus claim — otherwise the racing toggles leave the
            // field unfocused (no caret, can't type) after a right-arrow scope.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.reclaimSearchInputFocus()
            }
        }
        return activated
    }

    @discardableResult
    func cycleGlobalContextAppScope(direction: Int) -> Bool {
        let apps = globalScopeCycleApps
        guard !apps.isEmpty else { return false }

        let nextApp: NSRunningApplication
        if let scopedBundle = currentGlobalScopedBundleID,
            let currentIndex = apps.firstIndex(where: { $0.bundleIdentifier == scopedBundle })
        {
            let count = apps.count
            let offset = direction >= 0 ? 1 : -1
            let nextIndex = (currentIndex + offset + count) % count
            nextApp = apps[nextIndex]
        } else {
            nextApp = direction >= 0 ? apps[0] : apps[apps.count - 1]
        }

        return switchGlobalContextScope(to: nextApp)
    }

    @ViewBuilder
    var globalRunningAppStrip: some View {
        let apps = globalRunningAppStripApps
        if !apps.isEmpty {
            HStack(spacing: 5) {
                ForEach(apps, id: \.processIdentifier) { app in
                    Button {
                        // Running-app pills are app switchers — activate, unminimize, front,
                        // and centre the window. They do NOT scope to the app's menus.
                        activateRunningAppFromDock(app)
                    } label: {
                        if let icon = resolvedRunningAppIcon(for: app) {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 17, height: 17)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        } else {
                            Image(systemName: "app")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary.opacity(0.75))
                                .frame(width: 17, height: 17)
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Switch to \(app.localizedName ?? "app")")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(systemColorScheme == .dark ? 0.16 : 0.22),
                        lineWidth: 0.7)
            )
            .transition(.scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
        }
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

    var visibleSafariTabStripTabs: [SafariTab] {
        let tabs = safariTabPickerTabs.isEmpty
            ? SafariTabManager.shared.cachedTabs(maxAge: 45)
            : safariTabPickerTabs
        guard !tabs.isEmpty else { return [] }
        let currentURLKey = normalizedBrowserTabURLKey(currentBrowserPageURL()?.absoluteString)
        let ordered = tabs.sorted { lhs, rhs in
            if let currentURLKey {
                let lhsIsCurrent = normalizedBrowserTabURLKey(lhs.url) == currentURLKey
                let rhsIsCurrent = normalizedBrowserTabURLKey(rhs.url) == currentURLKey
                if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            }
            if lhs.windowIndex != rhs.windowIndex { return lhs.windowIndex < rhs.windowIndex }
            return lhs.tabIndex < rhs.tabIndex
        }
        let visible = ordered.filter { tab in
            guard isContextDockChatConnected else { return true }
            guard let currentURLKey else { return true }
            return normalizedBrowserTabURLKey(tab.url) != currentURLKey
        }
        return Array(visible.prefix(5))
    }

    func normalizedBrowserTabURLKey(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw)
        else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var key = (components?.url ?? url).absoluteString.lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    var connectedBrowserPageGhostTitle: String? {
        guard showContextInDock,
            isContextDockChatConnected
        else { return nil }
        guard let page = webResearch.pages.last else { return nil }
        let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return URL(string: page.url)?.host ?? currentBrowserPageURL()?.host
    }

    func syncSafariTabStrip(force: Bool = false) {
        let cached = SafariTabManager.shared.cachedTabs(maxAge: 45)
        if !cached.isEmpty,
            cached.map(\.id) != safariTabPickerTabs.map(\.id)
        {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                safariTabPickerTabs = cached
            }
        }
        SafariTabManager.shared.refreshCachedTabsIfNeeded(force: force) { tabs in
            guard tabs.map(\.id) != safariTabPickerTabs.map(\.id) else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                safariTabPickerTabs = tabs
            }
        }
    }

    func syncCurrentSafariTabForStrip() {
        guard shouldShowSafariTabStrip else { return }
        Task {
            guard let tab = await SafariTabManager.shared.currentTab() else { return }
            await MainActor.run {
                let currentKey = normalizedBrowserTabURLKey(tab.url)
                let oldKey = normalizedBrowserTabURLKey(currentBrowserPageURL()?.absoluteString)
                guard currentKey != nil, currentKey != oldKey else { return }
                SafariTabManager.shared.rememberSelectedTab(tab)

                var tabs = safariTabPickerTabs.isEmpty
                    ? SafariTabManager.shared.cachedTabs(maxAge: 45)
                    : safariTabPickerTabs
                if let idx = tabs.firstIndex(where: {
                    normalizedBrowserTabURLKey($0.url) == currentKey
                }) {
                    tabs[idx] = tab
                } else {
                    tabs.insert(tab, at: 0)
                }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                    safariTabPickerTabs = tabs
                    if isContextDockChatConnected {
                        attachBrowserPageSnapshotToCurrentChat(
                            PageSnapshot(
                                url: tab.url, text: "", title: tab.title,
                                timestamp: Date()))
                    } else {
                        searchState.revision += 1
                    }
                }
                if let url = URL(string: tab.url) {
                    FaviconStore.shared.fetchIfNeeded(for: url)
                }
            }
        }
    }

    func safariTabStripIcon(for tab: SafariTab) -> NSImage? {
        guard let url = URL(string: tab.url) else { return nil }
        if let favicon = FaviconStore.shared.icon(for: url) {
            return preparedDockIcon(favicon)
        }
        FaviconStore.shared.fetchIfNeeded(for: url)
        return nil
    }

    func selectSafariTabFromStrip(_ tab: SafariTab) {
        SafariTabManager.shared.switchTo(tab)
        if isContextDockChatConnected {
            attachSafariTabToCurrentChat(tab)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            syncSafariTabStrip(force: true)
            searchState.revision += 1
        }
    }

    func attachSafariTabToCurrentChat(_ tab: SafariTab) {
        attachBrowserPageSnapshotToCurrentChat(
            PageSnapshot(url: tab.url, text: "", title: tab.title, timestamp: Date()))

        let capturedTab = tab
        Task { @MainActor in
            let js = """
                (function(){
                    var el = document.querySelector('article')
                             || document.querySelector('main')
                             || document.body;
                    return el ? el.innerText.trim().substring(0, 8000) : '';
                })()
                """
            let text = await SafariTabManager.shared.executeJS(
                js,
                windowIndex: capturedTab.windowIndex,
                tabIndex: capturedTab.tabIndex
            ) ?? ""
            if !text.isEmpty {
                WebResearchSession.shared.updateText(url: capturedTab.url, text: text)
            }
        }
    }

    func attachBrowserPageSnapshotToCurrentChat(_ snapshot: PageSnapshot) {
        let snapshotKey = normalizedBrowserTabURLKey(snapshot.url)
        if let idx = webResearch.pages.firstIndex(where: {
            normalizedBrowserTabURLKey($0.url) == snapshotKey
        }) {
            WebResearchSession.shared.remove(at: idx)
        }
        WebResearchSession.shared.addPage(snapshot)
        searchState.revision += 1
    }

    @ViewBuilder
    var safariTabStrip: some View {
        let tabs = visibleSafariTabStripTabs
        if !tabs.isEmpty {
            HStack(spacing: 5) {
                ForEach(tabs) { tab in
                    Button {
                        selectSafariTabFromStrip(tab)
                    } label: {
                        if let icon = safariTabStripIcon(for: tab) {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 17, height: 17)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        } else {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.blue.opacity(0.86))
                                .frame(width: 17, height: 17)
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(tab.title.isEmpty ? tab.domain : tab.title)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(systemColorScheme == .dark ? 0.16 : 0.22),
                        lineWidth: 0.7)
            )
            .onAppear { syncSafariTabStrip() }
            .onReceive(Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()) { _ in
                syncCurrentSafariTabForStrip()
            }
            .transition(.scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear { syncSafariTabStrip(force: true) }
        }
    }

}
