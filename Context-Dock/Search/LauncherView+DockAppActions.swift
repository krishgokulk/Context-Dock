import AppKit
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
        let pid = app.processIdentifier
        // Dismiss the "Switching to" toast once the app has had time to become frontmost
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            DockActionFeedback.complete(switchId)
        }
        // Un-minimize any minimized windows
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
                == .success,
                let windows = windowsRef as? [AXUIElement]
            {
                for win in windows {
                    var minimized: CFTypeRef?
                    if AXUIElementCopyAttributeValue(
                        win, kAXMinimizedAttribute as CFString, &minimized) == .success,
                        (minimized as? Bool) == true
                    {
                        AXUIElementSetAttributeValue(
                            win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    }
                }
            }
        }
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
        hoveredDockAppKey = nil
        app.terminate()
        let feedbackID = DockActionFeedback.start(
            "Quit", subject: name, icon: "xmark.circle.fill", tint: .red.opacity(0.85))
        refocusLauncherWindowAfterAppAction(delay: 0.06)
        scheduleDockRefreshAfterTerminationAttempt(for: app, feedbackID: feedbackID)
        refreshGlobalSearchAfterRunningAppMutation()
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
                    DockActionFeedback.complete(feedbackID)
                }
                reconcileDockAfterTermination(of: app)
                return
            }

            runningRegularApps = currentRegularRunningApps()
            if let feedbackID {
                DockActionFeedback.dismiss(feedbackID)
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
                hasActiveDockContextSelection: hasActiveDockContextSelection
            ),
            callbacks: .init(
                hideBeforeExecution: { hideLauncherAfterResultExecution() },
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
        return (runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps)
            .filter { app in
                guard !app.isTerminated else { return false }
                guard let bundleID = app.bundleIdentifier else { return true }
                return bundleID != "com.apple.finder"
                    && bundleID != frontmostBundle
                    && bundleID != scopedBundle
            }
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
        return (runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps)
            .filter { app in
                guard !app.isTerminated else { return false }
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return false }
                guard seen.insert(bundleID).inserted else { return false }
                if bundleID == Bundle.main.bundleIdentifier { return false }
                if bundleID == "com.apple.finder" { return false }
                if bundleID == scopedBundle { return true }
                return bundleID != frontmostBundle
            }
    }

    @discardableResult
    func switchGlobalContextScope(to app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier,
            let appName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty,
            !appName.isEmpty
        else { return false }
        let activated = activateInlineDockAppScope(
            bundleIdentifier: bundleID,
            appName: appName,
            queryOverride: searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : nil,
            preserveGlobalContext: true
        )
        if activated {
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    self.reclaimSearchInputFocus()
                }
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
                        if isGlobalContextActive {
                            _ = switchGlobalContextScope(to: app)
                        } else {
                            activateRunningAppFromDock(app)
                        }
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
                    .help(
                        isGlobalContextActive
                            ? "Scope to \(app.localizedName ?? "app")"
                            : "Switch to \(app.localizedName ?? "app")"
                    )
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

}
