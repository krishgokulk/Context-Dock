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

    func setupSwipeGestureMonitor() {
        removeSwipeGestureMonitor()

        swipeGestureMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Pass scroll events through untouched when the settings window is front —
            // the user is scrolling inside settings, not trying to switch dock layers.
            if let settingsWindow = AppDelegate.shared?.settingsWindow,
                event.window === settingsWindow
            {
                return event
            }

            // Native menus and popovers use their own transient window. A scroll inside
            // the General Chat app picker must scroll that menu, never leak through to
            // the dock-wide layer-switch gesture monitor.
            if let eventWindow = event.window,
                let launcherWindow = AppDelegate.shared?.launcherWindow,
                eventWindow !== launcherWindow
            {
                return event
            }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            // ── Scroll over pill row → navigate pills (no scrolling, just index change) ──
            // Consumes the event so the ScrollView underneath never moves.
            if self.isHoveringPillRow
                && self.showContextInDock
                && self.currentDockSurfaceMode != .generalChat
                && abs(dx) > abs(dy)  // horizontal-dominant gesture
            {
                if event.phase == .began { self.pillScrollAccumulator = 0 }

                if event.phase == .changed || event.phase == .began || event.phase == .none {
                    self.pillScrollAccumulator += dx
                }

                let threshold: CGFloat = 22

                if self.isGlobalContextActive {
                    // Global context: scroll navigates app pills — same wrap behaviour as keyboard nav
                    let appPills = self.currentAppPillActions()
                    while self.pillScrollAccumulator >= threshold {
                        self.pillScrollAccumulator -= threshold
                        let cur = self.focusedAppPillIndex ?? 0
                        if cur <= 0 {
                            self.focusedAppPillIndex = nil
                        } else {
                            self.focusedAppPillIndex = cur - 1
                        }
                    }
                    while self.pillScrollAccumulator <= -threshold {
                        self.pillScrollAccumulator += threshold
                        let cur = self.focusedAppPillIndex ?? -1
                        let next = cur + 1
                        self.focusedAppPillIndex = next < appPills.count ? next : nil
                    }
                } else {
                    // Context dock: scroll navigates action pills (skip separators)
                    let pills = self.cachedDockPills
                    while self.pillScrollAccumulator >= threshold {
                        self.pillScrollAccumulator -= threshold
                        let cur = self.l2.focusedPillIndex ?? 0
                        if cur <= 0 {
                            self.l2.focusedPillIndex = nil
                            self.l2.pillNavViaKeyboard = false
                        } else {
                            var idx = cur - 1
                            while idx > 0 && pills[idx].isSeparator { idx -= 1 }
                            self.l2.pillNavViaKeyboard = true
                            self.l2.focusedPillIndex = idx
                        }
                    }
                    while self.pillScrollAccumulator <= -threshold {
                        self.pillScrollAccumulator += threshold
                        let cur = self.l2.focusedPillIndex ?? -1
                        if cur >= pills.count - 1 {
                            self.l2.focusedPillIndex = nil
                            self.l2.pillNavViaKeyboard = false
                        } else {
                            var idx = cur + 1
                            while idx < pills.count - 1 && pills[idx].isSeparator { idx += 1 }
                            self.l2.pillNavViaKeyboard = true
                            self.l2.focusedPillIndex = idx
                        }
                    }
                }

                if event.phase == .ended || event.phase == .cancelled {
                    self.pillScrollAccumulator = 0
                }
                return nil  // consume — pills stay visually stable
            }

            let deltaX = abs(event.scrollingDeltaX)
            let deltaY = abs(event.scrollingDeltaY)

            // Track both vertical and horizontal movement during the gesture
            if event.phase == .began {
                self.accumulatedSwipeDeltaY = 0
                self.accumulatedSwipeDeltaX = 0
                self.didSwitchLayerInCurrentSwipe = false
            }

            // Accumulate through BOTH the finger-down phase and the momentum phase.
            // A fast flick lands most of its travel in momentum (after lift), so
            // accumulating only .changed missed it and the switch silently no-op'd.
            if event.phase == .changed || event.phase == .began
                || event.momentumPhase == .changed || event.momentumPhase == .began
            {
                self.accumulatedSwipeDeltaY += event.scrollingDeltaY
                self.accumulatedSwipeDeltaX += event.scrollingDeltaX
            }

            // Evaluate on lift AND at momentum-end — the retry lets a fast flick that
            // was under-threshold at lift still switch once its momentum lands. The
            // accumulators reset only after a switch fires (below), so momentum-end
            // never double-switches a gesture that already acted.
            if event.phase == .ended || event.momentumPhase == .ended {
                guard !self.didSwitchLayerInCurrentSwipe else {
                    if event.momentumPhase == .ended {
                        self.accumulatedSwipeDeltaY = 0
                        self.accumulatedSwipeDeltaX = 0
                    }
                    return event
                }
                let totalVertical = abs(self.accumulatedSwipeDeltaY)
                let totalHorizontal = abs(self.accumulatedSwipeDeltaX)
                let attempted =
                    (totalHorizontal > 70 && totalHorizontal > totalVertical * 1.8
                        && (self.isHoveringDockArea || self.isHoveringInputField))
                    || (totalVertical > 55 && totalVertical > totalHorizontal * 1.15
                        && (self.isHoveringDockArea || self.isHoveringInputField))
                defer {
                    if attempted {
                        self.accumulatedSwipeDeltaY = 0
                        self.accumulatedSwipeDeltaX = 0
                    }
                }

                // Horizontal swipe over the input toggles AI Chat from any layer and back.
                if totalHorizontal > 70 && totalHorizontal > totalVertical * 1.8
                    && (self.isHoveringDockArea || self.isHoveringInputField)
                {
                    if self.currentDockSurfaceMode == .generalChat {
                        self.exitGeneralChatRestoringLayer()
                        self.didSwitchLayerInCurrentSwipe = true
                    } else if self.accumulatedSwipeDeltaX > 0 {
                        self.enterGeneralChatPreservingLayer()
                        self.didSwitchLayerInCurrentSwipe = true
                    }
                }
                // Vertical swipe — Context Dock is home: swipe down → Global, swipe up → Media.
                else if totalVertical > 55 && totalVertical > totalHorizontal * 1.15
                    && (self.isHoveringDockArea || self.isHoveringInputField)
                {
                    guard !self.isExplicitAppScopeLocked else { return event }
                    // Swipe UP (negative deltaY): Global → Context → Media
                    if self.accumulatedSwipeDeltaY < 0 {
                        if self.isGlobalContextActive {
                            // Global Context → Context Dock
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                self.dismissContextAndReturnToDock()
                            }
                            self.didSwitchLayerInCurrentSwipe = true
                        } else if !self.showMediaLayer && self.settings.enableLayer3 {
                            self.didSwitchLayerInCurrentSwipe = true
                            // Context Dock → Media Dock
                            Task {
                                await self.mediaObserver.refreshNowPlaying()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    self.showContextInDock = true
                                    self.globalContextActivation = nil
                                    self.showMediaLayer = true
                                }
                                if self.searchState.query.isEmpty && !self.isSearchFieldFocused {
                                    self.startCollapseTimer()
                                }
                            }
                        }
                    }
                    // Swipe DOWN (positive deltaY): Media → Context → Global
                    else {
                        if self.currentDockSurfaceMode == .generalChat {
                            // AI chat → previous layer
                            self.exitGeneralChatRestoringLayer()
                            self.didSwitchLayerInCurrentSwipe = true
                        } else if self.showMediaLayer {
                            // Media Dock → Context Dock
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                self.showMediaLayer = false
                                self.showContextInDock = true
                            }
                            self.didSwitchLayerInCurrentSwipe = true
                            if self.searchState.query.isEmpty && !self.isSearchFieldFocused {
                                self.startCollapseTimer()
                            }
                        } else if !self.isGlobalContextActive {
                            // Context Dock → Global Context (manual)
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                self.showMediaLayer = false
                                self.globalContextActivation = GlobalContextActivation(
                                    autoActivated: false)
                            }
                            self.didSwitchLayerInCurrentSwipe = true
                            self.replaceCachedDockPills(
                                self.buildDockPills(query: self.lastPillQuery),
                                preserveFocus: true
                            )
                        }
                    }
                }
            }

            return event
        }
    }

    func removeSwipeGestureMonitor() {
        if let monitor = swipeGestureMonitor {
            NSEvent.removeMonitor(monitor)
            swipeGestureMonitor = nil
        }
    }

    func toggleAIModeViaSwipe() {
        if currentDockSurfaceMode == .generalChat {
            exitGeneralChatRestoringLayer()
        } else {
            enterGeneralChatPreservingLayer()
        }
    }

    enum DockLayerDirection {
        case up
        case down
    }

    func switchDockLayer(_ direction: DockLayerDirection) {
        guard !isExplicitAppScopeLocked else { return }

        switch direction {
        case .up:
            if currentDockSurfaceMode == .generalChat {
                exitGeneralChatRestoringLayer()
            } else if showMediaLayer {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    showMediaLayer = false
                    showContextInDock = true
                }
                if searchState.query.isEmpty && !isSearchFieldFocused {
                    startCollapseTimer()
                }
            } else if !isGlobalContextActive {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    showMediaLayer = false
                    globalContextActivation = GlobalContextActivation(autoActivated: false)
                }
                scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
            }
        case .down:
            if currentDockSurfaceMode == .generalChat {
                exitGeneralChatRestoringLayer()
            } else if isGlobalContextActive {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    dismissContextAndReturnToDock()
                }
            } else if !showMediaLayer && settings.enableLayer3 {
                Task {
                    await mediaObserver.refreshNowPlaying()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        showContextInDock = true
                        globalContextActivation = nil
                        showMediaLayer = true
                    }
                    if searchState.query.isEmpty && !isSearchFieldFocused {
                        startCollapseTimer()
                    }
                }
            }
        }
    }

    func toggleGlobalContextPreservingQuery() {
        guard !isExplicitAppScopeLocked else { return }
        guard showContextInDock, currentDockSurfaceMode != .generalChat else { return }
        let wasGlobalContextActive = isGlobalContextActive

        withAnimation(.spring(response: 0.25, dampingFraction: 0.80)) {
            showMediaLayer = false
            showContextInDock = true
            globalContextActivation =
                wasGlobalContextActive ? nil : GlobalContextActivation(autoActivated: false)
            l2.targetApp = nil
            globalInlineAppScope = nil
            additionalGlobalInlineAppScopes = []
            l2.chatArmed = false
            l2.chatAutoArmedForNoMenuMatch = false
            l2.chatDismissed = true
            l2.chatDraftAppName = ""
            l2.chatDraftBundleId = ""
            focusedAppPillIndex = nil
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
        }
        scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
        DispatchQueue.main.async {
            self.isSearchBarExpanded = true
            self.isSearchFieldFocused = true
        }
        requestWindowSizeUpdate(reason: .modeChanged)
    }

    func handleCommandKeyContextScopeToggle() {
        guard settings.singleCommandTogglesContextScope else { return }
        guard !isCompactSmartScope else { return }
        guard showContextInDock else { return }
        guard Date() >= suppressCommandScopeToggleUntil else { return }

        // In an app scope ENTERED FROM Global Context with an empty field, Cmd steps back to
        // Global Context (same as Backspace/Escape) — the "global key" the user expects.
        let emptyQuery = searchState.query
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if emptyQuery, l2.targetApp != nil || globalInlineAppScope != nil {
            exitGlobalAppScopeToGlobalContext()
            return
        }

        guard currentDockSurfaceMode != .generalChat else { return }

        // Otherwise Cmd only switches Global Context ↔ Context Dock. Inside an explicit
        // (non-global) app scope it stays inert — leave that scope with Backspace/Escape.
        guard l2.targetApp == nil else { return }

        if !isSearchBarExpanded {
            beginMouseDrivenInteractionGrace(0.55)
            expandSearchBar()
            return
        }

        toggleGlobalContextPreservingQuery()
    }

    /// Step out of an app scope entered from Global Context, back to plain Global Context
    /// (keep globalContextActivation; just drop the app scope). Triggered by Cmd on an empty
    /// field, matching Backspace/Escape.
    func exitGlobalAppScopeToGlobalContext() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
            l2.targetApp = nil
            globalInlineAppScope = nil
            additionalGlobalInlineAppScopes = []
            l2.chatArmed = false
            l2.chatAutoArmedForNoMenuMatch = false
            l2.chatDismissed = true
            l2.chatDraftAppName = ""
            l2.chatDraftBundleId = ""
        }
        focusedAppPillIndex = nil
        l2.focusedPillIndex = nil
        l2.pillNavViaKeyboard = false
        syncL2DockSession(force: true)
        scheduleGlobalGroupedListRebuild(query: "", delayNanoseconds: 0)
        DispatchQueue.main.async { self.reclaimSearchInputFocus() }
    }

    func toggleAIModePreservingLayer() {
        if currentDockSurfaceMode == .generalChat {
            exitGeneralChatRestoringLayer()
        } else {
            enterGeneralChatPreservingLayer()
        }
    }

    func enterGeneralChatPreservingLayer() {
        guard settings.enableAIMode else { return }
        guard currentDockSurfaceMode != .generalChat else { return }

        // Refresh so Global Commands and built-in MCPs the user enabled this session
        // are callable without a relaunch.
        CapabilityRegistry.shared.refreshGlobalCommands()
        CapabilityRegistry.shared.refreshBuiltInMCPs()

        searchState.results = []
        searchState.selectedIndex = nil
        searchState.query = ""
        aiMode.currentTask?.cancel()
        aiMode.isLoading = false
        restoreGeneralAIConversationIfNeeded()

        let previousMode = currentDockSurfaceMode
        chatReturnContextInDock = showContextInDock
        chatReturnBrowserLayer = previousMode == .mediaDock
        chatReturnGlobalContext = previousMode == .globalContext ? globalContextActivation : nil
        // Keep the previous conversation visible on switch-back — only a fresh session
        // (no messages) starts collapsed. Resetting to false hid the retained chat.
        hasUserSentMessageInCurrentSession = !aiMode.messages.isEmpty

        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
            aiMode.isActive = true
            // Media hides the input field, so temporarily leave L3 while chat is active.
            showMediaLayer = false
        }
        // Auto-expand to the retained conversation height (glow + grow), no manual nudge.
        if !aiMode.messages.isEmpty {
            requestWindowSizeUpdate(reason: .modeChanged)
        }

        collapseTimer?.cancel()
    }

    func exitGeneralChatRestoringLayer() {
        guard currentDockSurfaceMode == .generalChat else { return }

        searchState.results = []
        searchState.selectedIndex = nil
        searchState.query = ""
        aiMode.currentTask?.cancel()
        aiMode.isLoading = false

        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
            aiMode.isActive = false
            showContextInDock = chatReturnContextInDock
            showMediaLayer = chatReturnBrowserLayer
            globalContextActivation = chatReturnGlobalContext
        }

        if searchState.query.isEmpty {
            startCollapseTimer()
        }
    }

    // MARK: - Search Bar Collapse/Expand Functions

    func expandSearchBar() {
        // Blocked during layer transitions to prevent phantom expand on icon change
        guard !suppressHoverExpand else { return }

        collapseTimer?.cancel()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            isSearchBarExpanded = true
        }
        requestWindowSizeUpdate(reason: .rowLayoutChanged)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isSearchFieldFocused = true
        }

        startCollapseTimer()
    }

    func startCollapseTimer() {
        // Auto-collapse disabled — bar only collapses when user clicks the search icon
        collapseTimer?.cancel()
    }

    func resetCollapseTimer() {
        // Cancel existing timer
        collapseTimer?.cancel()

        // Collapse timer is an L1 concept — skip entirely in L2 and AI mode
        if currentDockSurfaceMode == .generalChat || isL2ContextActive {
            return
        }

        if !searchState.query.isEmpty {
            // Keep expanded while there's text
            return
        }

        // Restart timer if search is empty
        startCollapseTimer()
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
            || (!isL2ContextActive && AppDelegate.shared?.isDockContextMode != true)

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
