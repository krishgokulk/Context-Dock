import AppKit
import Combine
import SwiftUI
import Vision

extension LauncherView {
    var contentWithModifiers: some View {
        mainContent
            .frame(width: calculatedWidth)
            // In dock mode anchor content to bottom so dock bar stays fixed while results grow upward.
            // In normal mode anchor to top so results grow downward.
            .frame(
                height: calculatedHeight, alignment: settings.effectiveDockAtBottom ? .bottom : .top
            )
            .background(
                backgroundView
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.8), value: shouldShowBackground)
            )
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isVisible)
            .onChange(of: searchState.results.isEmpty) { _, isEmpty in
                if isEmpty {
                    l1ResultsReservedHeight = 0
                }
                requestWindowSizeUpdate(
                    reason: .resultsChanged,
                    animated: false,
                    debounceNanoseconds: 110_000_000
                )
            }
            .onChange(of: searchState.results.count) { _, newCount in
                guard !showContextInDock, !showMediaLayer, !aiMode.isActive else { return }
                // Pre-commit to max height on first result — window stable while typing (Raycast pattern)
                if newCount > 0 && l1ResultsReservedHeight < 450 {
                    l1ResultsReservedHeight = 450
                    requestWindowSizeUpdate(
                        reason: .resultsChanged,
                        animated: false,
                        debounceNanoseconds: 110_000_000
                    )
                }
            }
            .onChange(of: listViewResizeToken) { _, _ in
                requestWindowSizeUpdate(
                    reason: .rowLayoutChanged,
                    animated: false,
                    debounceNanoseconds: 110_000_000
                )
            }
            .onReceive(FaviconStore.shared.$revision.dropFirst()) { _ in
                // A page favicon finished loading — repaint Safari link rows.
                refreshVisibleGlobalContextAfterMenuCacheUpdate(
                    bundleIdentifier: "com.apple.Safari")
            }
            .onChange(of: aiMode.messages.count) { _, _ in
                requestWindowSizeUpdate(reason: .chatChanged)
            }
            .onChange(of: aiMode.isActive) { _, newValue in
                suppressHoverExpand = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.suppressHoverExpand = false
                }
                if newValue {
                    cancelBrowserContextWarmup()
                    menuLoadTask?.cancel()
                    liveMenuRefreshTask?.cancel()
                    liveMenuItems = []
                    crossAppMenuItems = []
                    contextMenuPills = []
                    cachedDockPills = []
                    l2.focusedPillIndex = nil
                    focusedAppPillIndex = nil
                    l2.appCompletion = nil
                } else {
                    scheduleBrowserContextWarmup(reason: "AI mode toggled")
                }
                // Delay resize so it runs after the animation starts (prevents background flash)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    requestWindowSizeUpdate(reason: .modeChanged)
                }
            }
            .onChange(of: frontmost.isSectionExpanded) { _, _ in
                requestWindowSizeUpdate(reason: .panelChanged)
            }
            .onChange(of: isSearchBarExpanded) { _, _ in
                requestWindowSizeUpdate(reason: .rowLayoutChanged)
            }
            .onChange(of: usesVerticalListDockLayout) { _, active in
                if active {
                    collapseTimer?.cancel()
                    isSearchBarExpanded = true
                    // reclaimSearchInputFocus() intentionally removed: it was only needed to
                    // recover focus after the old structural identity switch (dockBaseView ↔
                    // unifiedListDockCard). The NSTextField now always lives in the same view
                    // hierarchy, so calling it here would select-all the already-typed text.
                }
                requestWindowSizeUpdate(reason: .rowLayoutChanged)
            }
            .onChange(of: l2.chatMessages.count) { _, _ in
                requestWindowSizeUpdate(reason: .chatChanged)
            }
            .onChange(of: showContextInDock) { _, newValue in
                // Block expand during layer transition (icon swap fires phantom hover)
                suppressHoverExpand = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.suppressHoverExpand = false
                }
                if newValue {
                    guard !aiMode.isActive else {
                        liveMenuItems = []
                        crossAppMenuItems = []
                        contextMenuPills = []
                        cachedDockPills = []
                        return
                    }
                    let activeApp = contextTargetApp()
                    // First paint path: title/role only. Selection, URL, Finder files stay off open path.
                    if let app = activeApp {
                        AXContextReader.shared.refreshLightweight(from: app)
                        axContext = AXContextReader.shared.current
                    }
                    scheduleBrowserContextWarmup(reason: "context dock opened")
                    // Reload dock tool extensions so newly installed ones show immediately
                    Task { await L2ExtensionManager.shared.loadExtensions() }
                    updateL2ContextExtensions()
                    l2.focusedPillIndex = nil  // don't auto-focus; user must arrow-key to a pill

                    // Load live menu items from frontmost app only (primary context).
                    // Global Context stays cache-only; Apple Menu uses static fallback pills.
                    menuLoadTask?.cancel()
                    let useCacheOnly = isGlobalContextActive
                    if let app = activeApp {
                        let cachedItems = MenuWarmCacheService.shared.cachedMenuItems(
                            for: app, maxResults: 120)
                        if !cachedItems.isEmpty {
                            liveMenuItems = menuItemsVisibleInActiveDockMode(cachedItems)
                            menuDebugText =
                                "\(app.localizedName ?? ""): \(liveMenuItems.count) cached menus"
                            lastLiveMenuSignature = menuSignature(for: liveMenuItems)
                            previousEnabledIDs = Set(liveMenuItems.filter(\.isEnabled).map(\.id))
                            syncRecentAppsFromAppleMenu(cachedItems)
                        }
                    }
                    menuLoadTask = Task.detached(priority: .userInitiated) {
                        let app = await MainActor.run { self.contextTargetApp() }
                        guard let app, !app.isTerminated else { return }
                        let pid = app.processIdentifier
                        let name = app.localizedName ?? ""
                        var items: [AXMenuItem] = []
                        if useCacheOnly {
                            items = GlobalContextEngine.shared.cachedMenuItems(
                                for: app, maxResults: 120)
                        } else {
                            await MenuWarmCacheService.shared.warm(app: app, force: false)
                            items = await AXMenuReader.shared.peekCachedAllMenuItems(for: pid)
                            if items.isEmpty {
                                items = ContextDockEngine.shared.cachedMenuItems(
                                    for: app, maxResults: 120)
                            }
                        }
                        let debug =
                            await AXMenuReader.shared.lastDebug(for: pid) ?? "no reader detail"
                        let resolvedItems = items
                        await MainActor.run {
                            guard self.contextTargetApp()?.processIdentifier == pid else { return }
                            guard !resolvedItems.isEmpty else { return }
                            let visibleItems = self.menuItemsVisibleInActiveDockMode(resolvedItems)
                            self.liveMenuItems = visibleItems
                            self.menuDebugText = "\(name): \(visibleItems.count) menus, \(debug)"
                            self.lastLiveMenuSignature = self.menuSignature(for: visibleItems)
                            // Seed the enabled-ID baseline so first delta is meaningful
                            self.previousEnabledIDs = Set(
                                visibleItems.filter(\.isEnabled).map(\.id))
                            // Sync recentApps from Apple menu "Recent Items > Applications"
                            // — more authoritative than activation-order tracking
                            self.syncRecentAppsFromAppleMenu(resolvedItems)
                            self.refreshVisibleGlobalContextAfterMenuCacheUpdate(
                                bundleIdentifier: app.bundleIdentifier)
                        }
                    }
                    // Auto-generate a synthetic adapter for unknown frontmost apps
                    if let app = activeApp {
                        Task { await adapterManager.autoGenerateAdapterIfNeeded(for: app) }
                    }

                    // Run contextReaders for the frontmost app's adapter (current file, git branch, etc.)
                    if let frontmostBundleId = activeApp?.bundleIdentifier {
                        let capturedCtx = axContext
                        Task {
                            let data = await adapterManager.runContextReaders(
                                for: frontmostBundleId, axContext: capturedCtx)
                            await MainActor.run { adapterContextData = data }
                        }
                    }

                    // Start AX selection observer for the frontmost app
                    if let pid = activeApp?.processIdentifier {
                        selectionModel.start(for: pid)
                    }
                    suppressCurrentFinderSelectionBaseline()
                    // Refresh running apps list (for Layer 1 bar) — off main thread
                    runningRegularApps = currentRegularRunningApps()
                    rebuildGlobalSearchIndex()
                    // Refresh AX context periodically while dock is open so pills update as user interacts
                    axContextRefreshTimer?.invalidate()
                    axContextRefreshTimer = Timer.scheduledTimer(
                        withTimeInterval: 0.75, repeats: true
                    ) { [self] _ in
                        guard self.showContextInDock else { return }
                        self.refreshLiveContextDockState()
                    }
                    axContextRefreshTimer?.tolerance = 0.15
                } else {
                    if !aiMode.isActive { cancelBrowserContextWarmup() }
                    axContextRefreshTimer?.invalidate()
                    axContextRefreshTimer = nil
                    selectionModel.stop()
                    l2.extensionResults = []
                    l2.chatMessages = []
                    l2.isLoading = false
                    l2.activeRequestID = nil
                    l2.currentTask?.cancel()
                    l2.currentTask = nil
                    liveMenuRefreshTask?.cancel()
                    liveMenuRefreshTask = nil
                    menuAvailabilityRefreshTask?.cancel()
                    menuAvailabilityRefreshTask = nil
                    menuAvailabilityRefreshGeneration &+= 1
                    lastLiveMenuStructureRefresh = .distantPast
                    lastLiveMenuSignature = ""
                    searchState.results = []
                    searchState.selectedIndex = nil
                    liveMenuItems = []
                    crossAppMenuItems = []
                    crossAppMenuTargetPID = 0
                    contextMenuPills = []
                    previousEnabledIDs = []
                    l2.focusedPillIndex = nil
                    focusedAppPillIndex = nil
                    adapterContextData = [:]
                    l2.appCompletion = nil
                    l2.targetApp = nil
                    menuLoadTask?.cancel()
                    crossAppMenuTask?.cancel()
                }
                requestWindowSizeUpdate(reason: .modeChanged)
            }
            .onChange(of: showMediaLayer) { _, newValue in
                if newValue {
                    l2.extensionResults = []
                    l2.chatMessages = []
                    l2.isLoading = false
                    l2.activeRequestID = nil
                    l2.currentTask?.cancel()
                    l2.currentTask = nil
                    searchState.results = []
                    searchState.selectedIndex = nil
                    // Block expand during layer transition (globe ↔ magnifying glass icon swap)
                    suppressHoverExpand = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.suppressHoverExpand = false
                    }
                }
                requestWindowSizeUpdate(reason: .modeChanged)
            }
            // AX selection observer fired — diff enabled states and surface context pills
            .onChange(of: selectionModel.changeCount) { _, _ in
                handleSelectionChange()
            }
    }

    var contentLifecycleView: some View {
        contentWithModifiers
            .onAppear {
                // Load running apps immediately so the dock bar shows them on first launch
                runningRegularApps = currentRegularRunningApps()

                loadApplicationsInBackground()
                activateSearchField()
                setupQuickLookEventMonitor()
                setupSwipeGestureMonitor()  // swipe up/down for layer switching
                setupDockPillKeyMonitor()  // Left/Right/Enter for dock pill navigation
                setupCmdHoldMonitor()  // Cmd held 1.5s → shortcut sheet
                loadPersistedClipboardHistory()
                lastCheckedPasteboardCount = NSPasteboard.general.changeCount
                startClipboardExpiryTimer()

                // Start observing app switches if enabled (frontmost app already detected in ILauncherApp)
                if settings.enableFrontmostDetection {
                    startObservingAppSwitches()
                }

                // Detect initial context
                detectAndUpdateContext()

                // Reset chat visibility flag on launch
                hasUserSentMessageInCurrentSession = false

                // Update smart positioning on launch (with slight delay to ensure window is positioned)
                DispatchQueue.main.async {
                    updateResultsPosition()
                }

                // Also update after a short delay to catch final window position
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    updateResultsPosition()
                    // Mark initial launch complete after position is set
                    searchState.isInitialLaunch = false
                }
            }
            .onDisappear {
                removeQuickLookEventMonitor()
                removeSwipeGestureMonitor()  // Cleanup swipe gesture monitor
                stopObservingAppSwitches()
                // Cancel collapse timer when window closes
                collapseTimer?.cancel()
                clipboardExpiryTimer?.invalidate()
                clipboardExpiryTimer = nil
                queryChangeTask?.cancel()
                queryChangeTask = nil
                globalAppMatchTask?.cancel()
                globalAppMatchTask = nil
                globalGroupedTask?.cancel()
                globalGroupedTask = nil
                pendingGlobalAppQuery = nil
                pendingGlobalGroupedQuery = nil
                menuLoadTask?.cancel()
                liveMenuRefreshTask?.cancel()
                menuAvailabilityRefreshTask?.cancel()
            }
    }

    var contentSettingsHandlersView: some View {
        contentLifecycleView
            .onChange(of: settings.enableFrontmostDetection) { oldValue, newValue in
                if newValue {
                    // Start observing when enabled
                    startObservingAppSwitches()
                } else {
                    // Clear frontmost app data when disabled
                    frontmost.name = ""
                    frontmost.icon = nil
                    frontmost.bundleID = ""
                    stopObservingAppSwitches()
                }
            }
            .onChange(of: settings.enableContextAIExtensions) { oldValue, newValue in
                // Smooth transition when context awareness is toggled
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isContextExpanded = newValue

                    if newValue {
                        // When enabled, detect context immediately
                        detectAndUpdateContext()
                    } else {
                        // When disabled, clear context
                        currentContext = .none
                        l2.contextExtensions = []
                    }
                }
            }
            .onChange(of: settings.clipboardHistoryRetentionHours) { _, _ in
                pruneExpiredClipboardEntries()
                if searchState.activeSmartQueryKey == "clipboard" {
                    refreshCompactScopeResults(resetSelection: false)
                }
            }
            .onChange(of: settings.clipboardHistoryLimit) { _, _ in
                trimClipboardHistoryToLimits()
                if searchState.activeSmartQueryKey == "clipboard" {
                    refreshCompactScopeResults(resetSelection: false)
                }
            }
            .onReceive(notificationManager.$notifications) { _ in
                if searchState.activeSmartQueryKey == "notifications" {
                    refreshCompactScopeResults(resetSelection: false)
                }
            }
            .onChange(of: settings.enableL1DocumentSearch) { _, _ in
                indexedFileResults = indexedFileResults.filter(includeIndexedSearchResult)
                if !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    performSearch()
                }
            }
            .onChange(of: settings.enableL1FileSearch) { _, _ in
                indexedFileResults = indexedFileResults.filter(includeIndexedSearchResult)
                if !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    performSearch()
                }
            }
            .onChange(of: settings.effectiveDockAtBottom) { oldValue, newValue in
                // Update positioning immediately when setting changes
                updateResultsPosition()

                // Reposition window based on new setting
                guard
                    let window = (NSApp.keyWindow as? KeyableWindow)
                        ?? (NSApp.windows.first(where: {
                            ($0 as? KeyableWindow) != nil && $0.isVisible
                        }) as? KeyableWindow),
                    let screen = window.screen ?? NSScreen.main
                else { return }

                let screenFrame = screen.visibleFrame
                let currentFrame = window.frame

                let newY: CGFloat
                if newValue {
                    // Move to bottom and enable bottom anchoring
                    newY = screenFrame.minY + 10
                    window.anchorAtBottom = true
                } else {
                    // Move to upper third and disable bottom anchoring
                    newY = screenFrame.maxY - screenFrame.height / 3
                    window.anchorAtBottom = false
                }

                let newFrame = NSRect(
                    x: currentFrame.origin.x, y: newY, width: currentFrame.width,
                    height: currentFrame.height)
                window.setFrame(newFrame, display: true, animate: true)
            }
    }

    var contentCoreLifecycleHandlersView: some View {
        contentSettingsHandlersView
            .onReceive(NotificationCenter.default.publisher(for: .launcherWindowOpened)) { _ in
                handleLauncherWindowOpened()
            }

            .onChange(of: searchState.results.count) { oldValue, newValue in
                handleSearchResultsCountChanged(newValue)
            }
            .onChange(of: l2.chatMessages.count) { _, _ in
                persistActiveL2DockSession()
            }
            .onChange(of: isGlobalContextActive) { _, isActive in
                if isActive, globalContextActivation?.autoActivated == false {
                    suppressCurrentFinderSelectionBaseline()
                }
                if isActive, lockedFindToken != nil {
                    clearFindToken(preserveQuery: true)
                }
                if !isGlobalContextActive {
                    liveMenuItems = menuItemsVisibleInActiveDockMode(liveMenuItems)
                    if let lockedSubmenuParent, isAppleMenuItem(lockedSubmenuParent) {
                        self.lockedSubmenuParent = nil
                    }
                    cachedDockPills = []
                    contextDockViewModel.resetPillRenderingState(cancelBuild: true)
                    globalInlineAppScope = nil
                    additionalGlobalInlineAppScopes = []
                    suppressGlobalInlineAppScopeDetection = false
                    dismissedGlobalInlineAppScopes = [:]
                    pendingGlobalAppQuery = nil
                    focusedAppPillIndex = nil
                    if showContextInDock {
                        searchState.results = []
                        searchState.selectedIndex = nil
                        indexedFileResults = []
                    }
                }
                syncL2DockSession(force: true)
                updateL2ContextExtensions()
                scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
            }
            // Rebuild pills immediately when AX selection changes (file picked, text highlighted)
            .onChange(of: axContext.selectedFilePaths) { _, paths in
                scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 100_000_000)
                autoReturnFromGlobalContextIfNeeded()
                if !paths.isEmpty { l2.appCompletion = nil }
            }
            .onChange(of: axContext.selectedText) { _, text in
                scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 100_000_000)
                autoReturnFromGlobalContextIfNeeded()
                if !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    l2.appCompletion = nil
                }
            }
            // When Safari tab popover dismisses, reclaim key window so vibrancy stays active
            .onChange(of: showSafariTabPicker) { _, isShowing in
                if !isShowing {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NSApp.keyWindow?.makeKey()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
    }

    var contentLifecycleHandlersView: some View {
        contentCoreLifecycleHandlersView
            .onChange(of: l2.targetApp?.bundleId) { _, newBundleId in
                syncL2DockSession(force: true)
                scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
                // Keep search field focused while in scope so .onKeyPress(.escape) always fires
                if newBundleId != nil {
                    DispatchQueue.main.async { isSearchFieldFocused = true }
                }
            }
            .onChange(of: showContextInDock) { _, newValue in
                if newValue {
                    syncL2DockSession(force: true)
                    scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
                }
            }
            // Rebuild pills whenever the live menu content changes — catches both count changes
            // (new app) and title/enabled-state-only changes (e.g. Show→Hide Tab Bar, message
            // selected/deselected). The signature encodes titles + enabled flags so it fires on
            // any menu mutation, not just when the item count differs.
            .onChange(of: lastLiveMenuSignature) { _, _ in
                scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
            }
            // Global context always shows a fully expanded input — same size as context dock
            .onChange(of: isGlobalContextActive) { _, active in
                if active { isSearchBarExpanded = true }
            }
    }

    var contentNotificationHandlersViewA: some View {
        contentLifecycleHandlersView
            // AppKit-level Escape fallback — fires only when SwiftUI doesn't capture it
            .onReceive(NotificationCenter.default.publisher(for: .escapePressed)) { _ in
                if showFolderPreview {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFolderPreview = false
                        folderPreviewPath = nil
                        folderPreviewSelectedFile = nil
                        searchState.isInSmartMode = false
                        searchState.lastSmartQuery = ""
                        searchState.results = []
                        searchState.selectedIndex = nil
                    }
                    return
                }
                if l2.targetApp != nil || searchState.activeSmartQueryKey != nil
                    || searchState.contextApp != nil
                {
                    clearSearchContext()
                    remPanelIsProcessing = false
                    remIsInstalled = nil
                    systemDataResults = []
                    searchState.lastSmartQuery = ""
                    isSearchFieldFocused = true
                    return
                }
                if l2.focusedPillIndex != nil || focusedAppPillIndex != nil
                    || searchState.selectedIndex != nil
                {
                    l2.focusedPillIndex = nil
                    focusedAppPillIndex = nil
                    l2.pillNavViaKeyboard = false
                    searchState.selectedIndex = nil
                    isSearchFieldFocused = true
                    return
                }
                AppDelegate.shared?.hideLauncher()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    AppDelegate.shared?.previousFrontmostApp?.activate(options: [
                        .activateIgnoringOtherApps
                    ])
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .launcherBackspacePressed)) { _ in
                guard allGlobalInlineAppScopes.isEmpty else {
                    return
                }
                guard searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    return
                }
                if lockedSubmenuParent != nil {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                        lockedSubmenuParent = nil
                    }
                    isSearchFieldFocused = true
                    return
                }
                if shouldShowContextDockChatSheet || l2.showChatPopover || l2.chatArmed {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                        exitContextDockChatAndScope()
                    }
                    isSearchFieldFocused = true
                    return
                }
                if l2.targetApp != nil || searchState.contextApp != nil
                    || searchState.activeSmartQueryKey != nil
                {
                    clearSearchContext()
                    remPanelIsProcessing = false
                    remIsInstalled = nil
                    systemDataResults = []
                    searchState.lastSmartQuery = ""
                    isSearchFieldFocused = true
                    return
                }
                if detachFinderFolderQueryModeFromEmptyBackspace() {
                    isSearchFieldFocused = true
                    return
                }
                if hasActiveDockContextSelection {
                    dismissSelectionAndStayInGlobalContext()
                    isSearchFieldFocused = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
                l2.focusedPillIndex = nil
                focusedAppPillIndex = nil
                l2.pillNavViaKeyboard = false
                showMediaLayer = false
                showContextInDock = true
                expandSearchBar()
                DispatchQueue.main.async {
                    // Window must be key before @FocusState will stick
                    if let window = AppDelegate.shared?.launcherWindow {
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    isSearchFieldFocused = true
                }
            }
            .onReceive(contextEnv.userContextUpdates) { context in
                // Receive pre-detected context from AppDelegate (before ILauncher becomes frontmost)
                if isL2ContextActive || AppDelegate.shared?.isDockContextMode == true {
                    // Context Dock remains app-first, but selection is additive. Preserve
                    // selected text/files/URL as the conversation payload without changing
                    // the visible app scope or suppressing its menus and capabilities.
                    switch context {
                    case .filesSelected, .textSelected, .url, .contactSelected:
                        currentContext = context
                        updateL2ContextExtensions()
                    case .appFocused, .none:
                        setFrontmostAppContextOnly(reason: "dock context pre-detection")
                    }
                    return
                }
                currentContext = context
            }
            .onReceive(contextEnv.frontmostAppUpdates) { appInfo in
                let appName = appInfo.name
                let bundleID = appInfo.bundleID

                // Check if app changed (not just re-detection of same app)
                let appChanged =
                    !frontmost.bundleID.isEmpty && frontmost.bundleID != bundleID

                frontmost.name = appName
                frontmost.bundleID = bundleID

                // Get icon from bundle ID
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == bundleID
                }) {
                    MenuWarmCacheService.shared.frontmostAppDidChange(app)
                    frontmost.icon =
                        resolvedApplicationIcon(bundleIdentifier: bundleID, appName: appName)
                        ?? preparedDockIcon(app.icon)
                } else {
                    frontmost.icon = resolvedApplicationIcon(
                        bundleIdentifier: bundleID, appName: appName)
                }

                if let pendingSwitch = pendingGlobalLaunchContextSwitch,
                    pendingSwitch.bundleId == bundleID,
                    isGlobalContextActive
                {
                    switchGlobalLaunchToContextDock(bundleId: bundleID, appName: appName)
                }

                if appChanged {
                    l2.appCompletion = nil
                    l2.focusedPillIndex = nil
                    l2.pillNavViaKeyboard = false
                    // Immediately clear stale pills so the result panel disappears
                    // and rebuilds for the new frontmost app
                    cachedDockPills = []
                    let ownId = Bundle.main.bundleIdentifier ?? ""
                    // Only exit global context when switching to a real other app
                    // (not when our own dock gains focus — that would clear the chip)
                    let isInlineGlobalTargetSwitch =
                        isGlobalContextActive && l2.targetApp?.bundleId == bundleID
                    if bundleID != ownId && !isInlineGlobalTargetSwitch {
                        // Only auto-deactivate global context if it was auto-activated.
                        // Manual global context (swipe-down) survives app switches.
                        if globalContextActivation?.autoActivated == true {
                            globalContextActivation = nil
                        }
                    }
                    // Clear stale AX selection and clipboard pill from the previous app
                    axContext = .empty
                    currentContext = .none
                    showGlobalClipboardPill = false
                    globalClipboardText = ""
                    // Stamp time so autoSwitch won't re-fire from the AX observer debounce
                    frontmost.lastSwitchDate = Date()
                    if bundleID == "com.apple.finder" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            self.suppressCurrentFinderSelectionBaseline()
                        }
                    } else {
                        suppressedAutomaticFinderSelectionSignature = nil
                    }
                }

                // Scope lock: when user explicitly entered an app scope (l2.targetApp set),
                // ignore frontmost app changes — the dock stays on the pinned app until
                // the user presses Escape or clicks "Exit Scope".
                let scopeLocked = l2.targetApp != nil
                if scopeLocked {
                    syncL2DockSession(force: l2.activeDockSessionKey == nil)
                    if !l2.chatMessages.isEmpty || l2.chatArmed || l2.showChatPopover {
                        l2.chatArmed = true
                        l2.showChatPopover = true
                        l2.chatDismissed = false
                    }
                }

                // Reload live menus only for Context Dock. Global Context is cache-first while
                // typing, so app switches should not trigger L2 AX/menu refresh work there.
                if showContextInDock && !isGlobalContextActive && !scopeLocked {
                    // Sync session on app switch. syncL2DockSession saves the previous app's
                    // session and loads the new app's saved session (or empty if none).
                    // We do NOT call activateInlineDockAppScope here because that would pin
                    // l2.targetApp, causing scopeLocked=true on the next app switch.
                    syncL2DockSession(force: appChanged)
                    // Always reload — covers first open (appChanged=false) AND app switches
                    let allApps: [NSRunningApplication] = Array(
                        NSWorkspace.shared.runningApplications)
                    let matchedApp: NSRunningApplication? = allApps.first {
                        $0.bundleIdentifier == bundleID
                    }
                    if let newApp = matchedApp { reloadMenuForApp(newApp) }
                }

                // Re-detect full context (text selection, etc.) from the new frontmost app
                if !scopeLocked {
                    detectAndUpdateContext()
                }

                // Refresh deep per-app context when app switches while L2 is open
                if showContextInDock && appChanged && !scopeLocked {
                    let capturedCtx = axContext
                    Task {
                        let data = await adapterManager.runContextReaders(
                            for: bundleID, axContext: capturedCtx)
                        await MainActor.run {
                            adapterContextData = data
                            let runningApps: [NSRunningApplication] = Array(
                                NSWorkspace.shared.runningApplications)
                            if let app = runningApps.first(where: {
                                $0.bundleIdentifier == bundleID
                            }) {
                                Task { await adapterManager.autoGenerateAdapterIfNeeded(for: app) }
                            }
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .servicesOpenWithFiles)) {
                notification in
                // Receive files shared via Services/Share Sheet
                if let urls = notification.userInfo?["urls"] as? [URL], !urls.isEmpty {
                    currentContext = .filesSelected(urls)
                    updateL2ContextExtensions()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .servicesOpenWithText)) {
                notification in
                // Receive text shared via Services/Share Sheet
                if let text = notification.userInfo?["text"] as? String, !text.isEmpty {
                    currentContext = .textSelected(text)
                    updateL2ContextExtensions()
                }
            }
    }

    var contentNotificationHandlersView: some View {
        contentNotificationHandlersViewA
            .onReceive(NotificationCenter.default.publisher(for: .toggleAIExtensions)) { _ in
                // Toggle AI Extension Suggestions overlay
                detectAndUpdateContext()  // Update context before showing
                withAnimation(.spring(response: 0.3)) {
                    showAIExtensionSuggestions.toggle()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .activateContextDock)) { _ in
                beginMouseDrivenInteractionGrace()
                // Instant switch — no animation so the layer change feels immediate
                showMediaLayer = false
                aiMode.isActive = false
                showContextInDock = true
                globalContextActivation = nil
                setFrontmostAppContextOnly(reason: "activate context dock")
            }
            .onReceive(NotificationCenter.default.publisher(for: .activateGlobalContext)) { notification in
                beginMouseDrivenInteractionGrace()
                showMediaLayer = false
                aiMode.isActive = false
                showContextInDock = true
                globalContextActivation =
                    (notification.object as? GlobalContextActivation)
                    ?? GlobalContextActivation(autoActivated: false)
                l2.targetApp = nil
                l2.focusedPillIndex = nil
                focusedAppPillIndex = nil
                lockedSubmenuParent = nil
                showShortcutSheet = false
                scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
                activateSearchField()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandKeyToggleContextScope)) { _ in
                handleCommandKeyContextScopeToggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .activateClipboardScope)) { _ in
                activateClipboardScope()
            }
            .onChange(of: currentContext.description) { _, _ in
                // Trigger smooth expansion when context is detected
                if settings.enableContextAIExtensions {
                    let hasValidContext: Bool = {
                        switch currentContext {
                        case .filesSelected(let urls): return !urls.isEmpty
                        case .textSelected(let text):
                            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        case .url(let urlString):
                            return !urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        default: return false
                        }
                    }()

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        isContextExpanded = hasValidContext
                    }
                }

                // Clear stale chat when the selected content changes so AI focuses on the new context.
                // App-level changes are already handled by .frontmostAppDetected; this covers file/text/URL switches.
                let newKey = contextIdentityKey(currentContext)
                if l2.activeRequestID == nil && newKey != "none" && !l2.chatContextKey.isEmpty
                    && newKey != l2.chatContextKey
                    && !l2.chatMessages.isEmpty
                {
                    persistActiveL2DockSession()
                    l2.chatMessages = []
                    l2.isLoading = false
                    l2.currentTask?.cancel()
                    l2.currentTask = nil
                    updateL2Results([])
                }
                if newKey != "none" {
                    l2.chatContextKey = newKey
                }
                // Auto-return to Context Dock if context cleared and global context was auto-activated
                autoReturnFromGlobalContextIfNeeded()
            }
    }

    func handleLauncherWindowOpened() {
        beginMouseDrivenInteractionGrace()
        l2.showChatPopover = false
        l2.chatArmed = false
        l2.chatDraftAppName = ""
        l2.chatDraftBundleId = ""
        suppressOpenResize = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [self] in
            suppressOpenResize = false
            requestWindowSizeUpdate(reason: .modeChanged)
        }

        let openingForDockContext = AppDelegate.shared?.isDockContextMode ?? true
        globalContextActivation = nil

        // Reset transient UI state unconditionally on every open
        aiMode.isActive = false
        showMediaLayer = false
        showFolderPreview = false
        searchState.isInSmartMode = false

        if !openingForDockContext {
            searchState.query = ""
            searchState.results = []
            searchState.selectedIndex = nil
            showContextInDock = true
            searchState.activeSmartQueryKey = nil
            searchState.contextApp = nil
            searchState.appPanelAllItems = []
        }

        activateSearchField()
        if openingForDockContext {
            setFrontmostAppContextOnly(reason: "window opened")
        }

        if let app = AppDelegate.shared?.previousFrontmostApp {
            Task.detached(priority: .utility) {
                await AXContextReader.shared.refreshLightweight(from: app)
                let newCtx = await AXContextReader.shared.current
                await MainActor.run {
                    self.axContext = newCtx
                    if !self.contextDockIsFrontmostApplication {
                        self.setFrontmostAppContextOnly(reason: "window opened lightweight")
                    }
                    self.scheduleDockPillRebuild(query: self.lastPillQuery, delayNanoseconds: 0)
                    self.requestWindowSizeUpdate(reason: .contentSettled)
                }
            }
        }
        syncL2DockSession(force: true)
        scheduleBackgroundScanRunningAppMenusAfterOpen()

    }

    func scheduleBackgroundScanRunningAppMenusAfterOpen() {
        Task.detached(priority: .background) { [self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run { [self] in
                guard self.showContextInDock, self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                self.backgroundScanRunningAppMenusIfNeeded()
            }
        }
    }

    /// Warms frontmost app immediately + recent apps with a 2-min threshold so
    /// global context AI and menu pills are never more than 2 min stale on open.
    func backgroundScanRunningAppMenusIfNeeded() {
        guard searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SearchPerformanceLog.shared.record(
                label: "menuWarmSkipped.queryActive",
                elapsedMS: 0,
                query: searchState.query,
                pills: 0
            )
            return
        }
        if let app = AppDelegate.shared?.previousFrontmostApp ?? contextTargetApp() {
            Task { @MainActor in
                await MenuWarmCacheService.shared.warm(app: app, force: false)
                rebuildGlobalSearchIndex()
                refreshVisibleGlobalContextAfterMenuCacheUpdate(bundleIdentifier: app.bundleIdentifier)
            }
        }
        // Proactive warm of recent apps — uses 2-min threshold, runs in background.
        Task.detached(priority: .background) { [self] in
            let runningApps = await MainActor.run { [self] in
                self.currentRegularRunningApps()
            }
            MenuWarmCacheService.shared.warmRunningAppsOnLauncherOpen(runningApps)
            MenuWarmCacheService.shared.warmRecentAppsOnLauncherOpen()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run { [self] in
                self.rebuildGlobalSearchIndex()
            }
        }
    }

    func handleSearchResultsCountChanged(_ newValue: Int) {
        if newValue > 0 && !isL2ContextActive {
            updateResultsPosition()
        }
    }

    func persistActiveL2DockSession() {
        if let key = l2.activeDockSessionKey {
            AppPanelChatStore.shared.save(l2.chatMessages, for: key)
        }
    }
    // MARK: - Context Dock Filter (type to find actions)

    struct L2FilteredItem {
        let id: String
        let icon: String
        let name: String
        let isExtension: Bool
    }

    var l2FilteredContextActions: [L2FilteredItem] {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let appKey = searchState.activeSmartQueryKey ?? settings.autoDetectedAppKey ?? ""
        var results: [L2FilteredItem] = []
        for sc in settings.shortcuts(for: appKey) where sc.name.lowercased().contains(q) {
            results.append(
                L2FilteredItem(
                    id: "sc_\(sc.id)", icon: sc.iconName, name: sc.name, isExtension: false))
        }
        for ext in appPillScriptExtensions(for: appKey, query: q)
        where ext.toolName.lowercased().contains(q) || ext.aiHint.lowercased().contains(q) {
            let icon = ext.iconName.isEmpty ? (ext.scriptLanguage?.systemImage ?? "terminal") : ext.iconName
            results.append(
                L2FilteredItem(
                    id: "usr_ext_\(ext.id.uuidString)",
                    icon: icon,
                    name: ext.toolName.replacingOccurrences(of: "-", with: " ").capitalized,
                    isExtension: false
                )
            )
        }
        for tool in frontmostAppL2Extensions
        where tool.displayName.lowercased().contains(q) || tool.toolName.lowercased().contains(q) {
            results.append(
                L2FilteredItem(
                    id: "ext_\(tool.toolName)", icon: tool.icon, name: tool.displayName,
                    isExtension: true))
        }
        return results
    }

    func executeL2FilteredItem(_ item: L2FilteredItem) {
        if item.isExtension {
            let toolName = String(item.id.dropFirst(4))  // strip "ext_"
            guard let tool = frontmostAppL2Extensions.first(where: { $0.toolName == toolName })
            else { return }
            l2.chatMessages.append(AIChatMessage(role: .user, content: tool.displayName))
            l2.isLoading = true
            Task {
                let (success, output) = await L2ExtensionManager.shared.execute(
                    toolName: tool.toolName, arguments: [:])
                await MainActor.run {
                    let content =
                        success
                        ? (output.isEmpty ? "✅ \(tool.displayName) done." : output)
                        : "❌ \(tool.displayName) failed: \(output)"
                    l2.chatMessages.append(AIChatMessage(role: .assistant, content: content))
                    l2.isLoading = false
                }
            }
        } else {
            let scIdStr = String(item.id.dropFirst(3))  // strip "sc_"
            let appKey = searchState.activeSmartQueryKey ?? settings.autoDetectedAppKey ?? ""
            if item.id.hasPrefix("usr_ext_"),
                let ext = appPillScriptExtensions(for: appKey, query: searchState.query)
                    .first(where: {
                        $0.id.uuidString == String(item.id.dropFirst("usr_ext_".count))
                    })
            {
                executeAppToolExtension(ext, launchQuery: searchState.query)
            } else if let sc = settings.shortcuts(for: appKey).first(where: {
                $0.id.uuidString == scIdStr
            }
            ) {
                executeAppShortcut(sc)
            }
        }
        searchState.query = ""
    }

    // MARK: - Instant menu reload on app switch

    /// Called immediately when the frontmost app changes while the dock is open.
    /// Cancels any in-flight menu load and starts a fresh one for `app`.
    func reloadMenuForApp(_ app: NSRunningApplication) {
        guard showContextInDock, !app.isTerminated else { return }
        let pid = app.processIdentifier
        let name = app.localizedName ?? ""
        let bundleId = app.bundleIdentifier ?? ""
        let useCacheOnly = isGlobalContextActive

        menuLoadTask?.cancel()
        liveMenuRefreshTask?.cancel()
        liveMenuRefreshTask = nil
        lastLiveMenuStructureRefresh = .distantPast
        contextMenuPills = []
        previousEnabledIDs = []

        let cachedItems = ContextDockEngine.shared.cachedMenuItems(for: app, maxResults: 120)
        if useCacheOnly || !cachedItems.isEmpty {
            if !useCacheOnly, !bundleId.isEmpty {
                warmingMenuBundleIds.insert(bundleId)
            }
            liveMenuItems = menuItemsVisibleInActiveDockMode(cachedItems)
            menuDebugText = "\(name): \(liveMenuItems.count) cached menus"
            lastLiveMenuSignature = menuSignature(for: liveMenuItems)
            previousEnabledIDs = Set(liveMenuItems.filter(\.isEnabled).map(\.id))
            syncRecentAppsFromAppleMenu(cachedItems)
            scheduleDockPillRebuild(
                query: lastPillQuery, delayNanoseconds: 0, refreshContext: false)
            if useCacheOnly {
                return
            }
        }

        menuLoadTask = Task.detached(priority: .userInitiated) {
            let fallbackItems = await MainActor.run {
                AXContextReader.shared.current.menuItems.compactMap { info -> AXMenuItem? in
                    let path = info.fullPath
                        .components(separatedBy: " > ")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    guard let title = path.last, !title.isEmpty else { return nil }
                    return AXMenuItem(
                        title: title,
                        path: path,
                        isEnabled: info.enabled,
                        element: AXUIElementCreateApplication(pid),
                        children: [],
                        sourcePID: pid,
                        sourceAppName: name,
                        isAppleMenu: path.first == "Apple",
                        shortcutChar: nil,
                        shortcutModifiers: 0
                    )
                }
            }

                guard
                    let refresh = await ContextDockEngine.shared.refreshMenus(
                        for: app,
                        cachedItems: cachedItems,
                        fallbackItems: fallbackItems,
                        maxResults: 120,
                        force: cachedItems.isEmpty
                    )
            else {
                await MainActor.run {
                    if !bundleId.isEmpty {
                        self.warmingMenuBundleIds.remove(bundleId)
                    }
                    if cachedItems.isEmpty {
                        self.liveMenuItems = []
                        self.menuDebugText = "\(name): no menu cache yet"
                    }
                }
                return
            }

            await MainActor.run {
                guard self.contextTargetApp()?.processIdentifier == pid else { return }
                if !bundleId.isEmpty {
                    self.warmingMenuBundleIds.remove(bundleId)
                }
                let visibleItems = self.menuItemsVisibleInActiveDockMode(refresh.items)
                self.liveMenuItems = visibleItems
                self.menuDebugText = "\(name): \(visibleItems.count) menus, refreshed"
                self.lastLiveMenuSignature = self.menuSignature(for: visibleItems)
                self.previousEnabledIDs = Set(visibleItems.filter(\.isEnabled).map(\.id))
                self.syncRecentAppsFromAppleMenu(refresh.items)
                self.scheduleDockPillRebuild(
                    query: self.lastPillQuery, delayNanoseconds: 0, refreshContext: false)
                self.refreshVisibleGlobalContextAfterMenuCacheUpdate(bundleIdentifier: bundleId)
            }
        }

        // Restart observer for the new app
        selectionModel.start(for: pid)

        // App switch while launcher is visible uses lightweight AX. Full selection/URL reads are lazy.
        Task.detached(priority: .utility) {
            await AXContextReader.shared.refreshLightweight(from: app)
            let newCtx = await AXContextReader.shared.current
            await MainActor.run {
                guard self.contextTargetApp()?.processIdentifier == pid else { return }
                self.axContext = newCtx
                self.setFrontmostAppContextOnly(reason: "app switch lightweight")
            }
        }
    }

     // MARK: - Apple menu recent apps sync

    /// Reads "Recent Items > Applications" from the already-loaded liveMenuItems and
    /// updates AppDelegate.recentApps with running apps that match — giving us the
    /// same list macOS itself tracks, not just apps activated while our dock was open.
    func syncRecentAppsFromAppleMenu(_ items: [AXMenuItem]) {
        // Apple menu items: path[0] == "" (the  symbol), path[1] == "Recent Items"
        let recentNames =
            items
            .filter { $0.path.count >= 2 && $0.path[0].isEmpty && $0.path[1] == "Recent Items" }
            .map { $0.title.replacingOccurrences(of: ".app", with: "") }
            .filter { !$0.isEmpty && $0 != "Clear Menu" }

        guard !recentNames.isEmpty else { return }

        let running = NSWorkspace.shared.runningApplications
        let frontPID = AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0

        // Match names to running processes, preserving Apple menu order, skip frontmost & self
        let matched: [NSRunningApplication] = recentNames.compactMap { name in
            running.first {
                $0.activationPolicy == .regular
                    && !$0.isTerminated
                    && $0.processIdentifier != frontPID
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                    && ($0.localizedName ?? "") == name
            }
        }

        // Deduplicate and update
        var seen = Set<pid_t>()
        let deduped = matched.filter { seen.insert($0.processIdentifier).inserted }
        AppDelegate.shared?.setRecentAppsFromMenu(Array(deduped.prefix(5)))
    }

    func menuSignature(for items: [AXMenuItem]) -> String {
        // Hash-based fingerprint: avoids O(n) string allocation per 750ms tick
        var hasher = Hasher()
        for item in items.prefix(500) {
            hasher.combine(item.id)
            hasher.combine(item.isEnabled)
            hasher.combine(item.shortcutChar)
            hasher.combine(item.shortcutModifiers)
        }
        return "\(hasher.finalize())"
    }

    func refreshFrontmostMenuStructureIfNeeded(
        for app: NSRunningApplication,
        force: Bool = false
    ) {
        guard showContextInDock, !app.isTerminated else { return }
        guard liveMenuRefreshTask == nil else { return }
        if !force,
            !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return
        }

        let now = Date()
        let minInterval: TimeInterval = force ? 0 : 30
        guard force || now.timeIntervalSince(lastLiveMenuStructureRefresh) >= minInterval else {
            return
        }
        lastLiveMenuStructureRefresh = now

        let pid = app.processIdentifier
        let name = app.localizedName ?? ""
        let bundleId = app.bundleIdentifier

        liveMenuRefreshTask = Task.detached(priority: force ? .userInitiated : .utility) {
            await MenuWarmCacheService.shared.warm(app: app, force: force)
            var items = await AXMenuReader.shared.peekCachedAllMenuItems(for: pid)
            if items.isEmpty {
                items = ContextDockEngine.shared.cachedMenuItems(for: app, maxResults: 120)
            }
            guard !Task.isCancelled else { return }
            guard !items.isEmpty else {
                await MainActor.run {
                    if self.liveMenuRefreshTask != nil {
                        self.liveMenuRefreshTask = nil
                    }
                }
                return
            }

            for i in items.indices {
                items[i].sourcePID = pid
                items[i].sourceAppName = name
            }

            let debug = await AXMenuReader.shared.lastDebug(for: pid) ?? "no reader detail"
            let resolvedItems = items
            await MainActor.run {
                self.liveMenuRefreshTask = nil
                guard self.showContextInDock else { return }
                guard self.contextTargetApp()?.processIdentifier == pid else {
                    return
                }
                let baseItems =
                    self.liveMenuItems.isEmpty
                    ? ContextDockEngine.shared.cachedMenuItems(for: app, maxResults: 120)
                    : self.liveMenuItems
                let mergedItems = self.mergeCachedMenusWithLiveAvailability(
                    cached: baseItems,
                    live: resolvedItems
                )
                let visibleItems = self.menuItemsVisibleInActiveDockMode(mergedItems)
                let signature = self.menuSignature(for: visibleItems)
                guard force || signature != self.lastLiveMenuSignature else { return }

                self.liveMenuItems = visibleItems
                self.lastLiveMenuSignature = signature
                self.menuDebugText = "\(name): \(visibleItems.count) menus, \(debug), cache+live"
                self.previousEnabledIDs = Set(visibleItems.filter(\.isEnabled).map(\.id))
                self.contextMenuPills = []
                self.syncRecentAppsFromAppleMenu(mergedItems)
                if self.frontmost.bundleID.isEmpty, let bundleId {
                    self.frontmost.bundleID = bundleId
                }
                self.refreshVisibleGlobalContextAfterMenuCacheUpdate(bundleIdentifier: bundleId)
            }
        }
    }

    // MARK: - Selection-change handler

    /// Called (debounced 200ms) whenever AXObserver detects a selection/focus change
    /// in the frontmost app. Re-reads only `kAXEnabled` for all cached menu items,
    /// computes the delta (newly enabled items), and surfaces them as context pills.
    func handleSelectionChange() {
        guard showContextInDock else { return }

        if !liveMenuItems.isEmpty {
            let items = liveMenuItems
            let previousIDs = previousEnabledIDs
            let appForAvailability = contextTargetApp()
            let targetPID = appForAvailability?.processIdentifier
            menuAvailabilityRefreshGeneration &+= 1
            let generation = menuAvailabilityRefreshGeneration
            menuAvailabilityRefreshTask?.cancel()
            menuAvailabilityRefreshTask = Task.detached(priority: .userInitiated) {
                // Re-read enabled states off the main thread — one attribute call per item,
                // no tree traversal, but still AX IPC and therefore not free.
                let enabledMap = await AXMenuReader.shared.refreshEnabledStates(for: items)
                guard !Task.isCancelled else { return }
                var updated = items
                for i in updated.indices {
                    if let enabled = enabledMap[updated[i].id] {
                        updated[i].isEnabled = enabled
                    }
                }

                let newEnabledIDs = Set(updated.filter(\.isEnabled).map(\.id))
                let deltaIDs = newEnabledIDs.subtracting(previousIDs)
                let delta = updated.filter { deltaIDs.contains($0.id) && !$0.isAppleMenu }
                    .sorted { ($0.shortcutChar != nil ? 0 : 1) < ($1.shortcutChar != nil ? 0 : 1) }
                let resolvedItems = updated
                let resolvedBundleID = appForAvailability?.bundleIdentifier

                if let appForAvailability {
                    AppMenuCapabilityCache.shared.updateAvailability(
                        items: resolvedItems, for: appForAvailability)
                }

                await MainActor.run {
                    guard !Task.isCancelled,
                        self.menuAvailabilityRefreshGeneration == generation,
                        self.showContextInDock,
                        self.contextTargetApp()?.processIdentifier == targetPID
                    else { return }
                    self.previousEnabledIDs = newEnabledIDs
                    self.liveMenuItems = self.menuItemsVisibleInActiveDockMode(resolvedItems)
                    self.contextMenuPills = Array(delta.prefix(6))
                    self.refreshVisibleGlobalContextAfterMenuCacheUpdate(
                        bundleIdentifier: resolvedBundleID)
                    self.menuAvailabilityRefreshTask = nil
                }
            }
        }

        refreshLiveContextDockState()
    }

    func refreshLiveContextDockState() {
        guard showContextInDock, let app = contextTargetApp() else { return }

        refreshFrontmostMenuStructureIfNeeded(for: app)
        refreshCachedFinderCurrentDirectory(for: app.bundleIdentifier ?? "")
        checkClipboardForGlobalContext()
        autoReturnFromGlobalContextIfNeeded()

        let bundleId = app.bundleIdentifier ?? ""
        let pid = app.processIdentifier

        // Poll path stays lightweight while UI active; deep context reads happen on demand.
        Task.detached(priority: .utility) {
            await AXContextReader.shared.refreshLightweight(from: app)
            let newCtx = await AXContextReader.shared.current
            await MainActor.run {
                guard self.showContextInDock,
                      self.contextTargetApp()?.processIdentifier == pid else { return }
                guard !self.contextDockIsFrontmostApplication else { return }

                let contextChanged =
                    newCtx.windowTitle != self.axContext.windowTitle
                    || newCtx.focusedElementRole != self.axContext.focusedElementRole

                if contextChanged {
                    var merged = self.axContext
                    merged.appName = newCtx.appName
                    merged.bundleId = newCtx.bundleId
                    merged.pid = newCtx.pid
                    merged.windowTitle = newCtx.windowTitle
                    merged.focusedElementRole = newCtx.focusedElementRole
                    merged.timestamp = Date()
                    self.axContext = merged
                }
            }
        }
    }

    func refreshFinderSelectionContextFromFinder() {
        guard showContextInDock, !showMediaLayer, !aiMode.isActive else { return }
        guard !contextDockIsFrontmostApplication else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFinderSelectionRefresh) > 0.25 else { return }
        lastFinderSelectionRefresh = now
        guard
            frontmost.bundleID == "com.apple.finder"
                || AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier == "com.apple.finder"
                || contextTargetApp()?.bundleIdentifier == "com.apple.finder"
        else { return }

        let urls = canonicalExistingURLs(ContextDetector.shared.getFinderSelectedFiles())
        guard !urls.isEmpty else { return }
        let paths = urls.map(\.path)
        updateSuppressedAutomaticFinderSelectionAfterSelectionChange(paths)
        if isSuppressedAutomaticFinderSelection(paths) {
            if axContext.bundleId == "com.apple.finder" {
                axContext.selectedFilePaths = []
            }
            if case .filesSelected(let current) = currentContext,
                isSuppressedAutomaticFinderSelection(current)
            {
                currentContext = .none
            }
            return
        }
        updateDismissedFinderSelectionAfterSelectionChange(paths)
        if isDismissedFinderSelection(paths) {
            if axContext.bundleId == "com.apple.finder" {
                axContext.selectedFilePaths = []
            }
            if case .filesSelected(let current) = currentContext,
                isDismissedFinderSelection(current)
            {
                currentContext = .none
            }
            return
        }

        if axContext.bundleId != "com.apple.finder" || axContext.selectedFilePaths != paths {
            axContext.bundleId = "com.apple.finder"
            axContext.selectedFilePaths = paths
        }
        if case .filesSelected(let current) = currentContext, current.map(\.path) == paths {
            return
        }
        currentContext = .filesSelected(urls)
    }

    func checkClipboardForGlobalContext() {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastCheckedPasteboardCount else { return }
        lastCheckedPasteboardCount = currentCount

        pruneExpiredClipboardEntries()

        _ = importCurrentPasteboardToClipboardHistory()
    }

    @discardableResult
    func importCurrentPasteboardToClipboardHistory() -> Bool {
        let pb = NSPasteboard.general

        if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let paths =
                fileURLs
                .filter { $0.isFileURL }
                .map(\.path)
                .filter { !$0.isEmpty }
            if !paths.isEmpty {
                addClipboardEntry(text: paths.joined(separator: "\n"), filePaths: paths)
                return true
            }
        }

        if let image = NSImage(pasteboard: pb),
            let tiffData = image.tiffRepresentation
        {
            addClipboardEntry(text: "Image copied to clipboard", filePaths: [], imageData: tiffData)
            return true
        }

        guard pb.pasteboardItems?.first?.types.contains(.string) == true,
            let text = pb.string(forType: .string)
        else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3 else { return false }

        addClipboardEntry(text: trimmed, filePaths: [])
        return true
    }

    func addClipboardEntry(text: String, filePaths: [String], imageData: Data? = nil) {
        let sourceApp = clipboardSourceApp()
        let entry = ClipboardEntry(
            text: text,
            timestamp: Date(),
            filePaths: filePaths,
            imageData: imageData,
            sourceAppName: sourceApp.name,
            sourceBundleId: sourceApp.bundleId
        )

        let duplicateKey =
            imageData != nil
            ? "image:\(imageData?.count ?? 0)"
            : (filePaths.isEmpty ? text : filePaths.joined(separator: "\n"))
        clipboardHistory.removeAll { old in
            let oldKey =
                old.imageData != nil
                ? "image:\(old.imageData?.count ?? 0)"
                : (old.filePaths.isEmpty ? old.text : old.filePaths.joined(separator: "\n"))
            return oldKey == duplicateKey
        }
        clipboardHistory.insert(entry, at: 0)
        trimClipboardHistoryToLimits()
        savePersistedClipboardHistory()
        if imageData != nil {
            scheduleClipboardOCR(for: entry.id, imageData: imageData)
        }
        if searchState.activeSmartQueryKey == "clipboard" {
            refreshCompactScopeResults(resetSelection: false)
        }

        globalClipboardText = text
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            showGlobalClipboardPill = true
        }
        clipboardHistoryExpanded = false
        scheduleClipboardIndicatorAutoHide()
        // Rebuild clipboard scope rows immediately when scope is open.
        let rebuildQuery =
            searchState.activeSmartQueryKey == "clipboard"
            ? searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : lastPillQuery
        scheduleDockPillRebuild(query: rebuildQuery, delayNanoseconds: 0, refreshContext: false)
    }

    func scheduleClipboardIndicatorAutoHide() {
        clipboardIndicatorHideTask?.cancel()
        clipboardIndicatorHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                showGlobalClipboardPill = false
                clipboardHistoryExpanded = false
            }
            requestWindowSizeUpdate(reason: .panelChanged)
        }
        requestWindowSizeUpdate(reason: .panelChanged)
    }

    func clipboardSourceApp() -> (name: String, bundleId: String) {
        let app =
            AppDelegate.shared?.previousFrontmostApp
            ?? NSWorkspace.shared.frontmostApplication
        return (app?.localizedName ?? "", app?.bundleIdentifier ?? "")
    }

    func clipboardRetentionInterval() -> TimeInterval {
        TimeInterval(max(1, settings.clipboardHistoryRetentionHours)) * 3600
    }

    var clipboardHistoryStoreURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
                "Library/Application Support")
        return
            base
            .appendingPathComponent("Context-Dock", isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
    }

    func loadPersistedClipboardHistory() {
        let url = clipboardHistoryStoreURL
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([ClipboardEntry].self, from: data)
        else {
            syncVisibleClipboardStateAfterPrune()
            return
        }
        clipboardHistory = entries.sorted { $0.timestamp > $1.timestamp }
        trimClipboardHistoryToLimits(save: false)
        syncVisibleClipboardStateAfterPrune()
        savePersistedClipboardHistory()
    }

    func savePersistedClipboardHistory() {
        let entries = clipboardHistory
        let url = clipboardHistoryStoreURL
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(entries)
                try data.write(to: url, options: .atomic)
            } catch {}
        }
    }

    func scheduleClipboardOCR(for entryID: UUID, imageData: Data?) {
        guard let imageData,
            let nsImage = NSImage(data: imageData),
            let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                await MainActor.run {
                    updateClipboardOCR(entryID: entryID, text: text)
                }
            } catch {
                // OCR is best-effort; clipboard row still works without recognized text.
            }
        }
    }

    func updateClipboardOCR(entryID: UUID, text: String) {
        guard let index = clipboardHistory.firstIndex(where: { $0.id == entryID }) else { return }
        clipboardHistory[index].ocrText = text
        savePersistedClipboardHistory()
        if searchState.activeSmartQueryKey == "clipboard" {
            let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            scheduleDockPillRebuild(query: q, delayNanoseconds: 0, refreshContext: false)
        }
    }

    func trimClipboardHistoryToLimits(save: Bool = true) {
        let before = clipboardHistory.map(\.id)
        pruneExpiredClipboardEntries(updateVisibleState: false, save: false)
        let limit = settings.clipboardHistoryLimit
        if clipboardHistory.count > limit {
            clipboardHistory = Array(clipboardHistory.prefix(limit))
        }
        syncVisibleClipboardStateAfterPrune()
        if save && before != clipboardHistory.map(\.id) {
            savePersistedClipboardHistory()
        }
    }

    func pruneExpiredClipboardEntries(updateVisibleState: Bool = true, save: Bool = true) {
        let cutoff = Date().addingTimeInterval(-clipboardRetentionInterval())
        let before = clipboardHistory.count
        clipboardHistory.removeAll { $0.timestamp < cutoff }
        if updateVisibleState {
            syncVisibleClipboardStateAfterPrune()
        }
        if save && clipboardHistory.count != before {
            savePersistedClipboardHistory()
        }
    }

    func syncVisibleClipboardStateAfterPrune() {
        if let first = clipboardHistory.first {
            globalClipboardText = first.text
        } else {
            globalClipboardText = ""
            showGlobalClipboardPill = false
            showClipboardHistory = false
            clipboardHistoryExpanded = false
        }
    }

    func startClipboardExpiryTimer() {
        clipboardExpiryTimer?.invalidate()
        clipboardExpiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
            [self] _ in
            self.pruneExpiredClipboardEntries()
        }
    }

    /// Auto-returns to Context Dock when the selection that triggered global context is gone.
    /// Only fires if global context was auto-activated (not manually swiped by user).
    func autoReturnFromGlobalContextIfNeeded() {
        guard isGlobalContextActive, isGlobalContextAutoActivated, !aiMode.isActive else { return }

        // If we have a frozen selection, only allow auto-return when the AX update comes from the
        // same source app that originally provided the selection — not from our own dock gaining focus.
        if let sourceId = frozenSelectionSourceBundleId {
            let currentContextApp = axContext.bundleId ?? ""
            let ownBundleId = Bundle.main.bundleIdentifier ?? ""
            // Ignore AX updates from our own app — user is typing in our dock
            guard currentContextApp != ownBundleId else { return }
            // Ignore updates from unrelated apps — only the source app can invalidate the frozen selection
            guard currentContextApp == sourceId || currentContextApp.isEmpty else { return }
        }

        let hasFileSelection =
            !axContext.selectedFilePaths.isEmpty
            && !isDismissedFinderSelection(axContext.selectedFilePaths)
        let axText = (axContext.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTextSelection = axText.count > 15
        let hasCtxSel: Bool = {
            switch currentContext {
            case .filesSelected(let u): return !u.isEmpty && !isDismissedFinderSelection(u)
            case .textSelected(let t):
                return t.trimmingCharacters(in: .whitespacesAndNewlines).count > 15
            case .url(let s): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }()
        let hasClipboard = showGlobalClipboardPill && !globalClipboardText.isEmpty
        if !hasFileSelection && !hasTextSelection && !hasCtxSel && !hasClipboard {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                globalContextActivation = nil
            }
            scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
        }
    }
}
