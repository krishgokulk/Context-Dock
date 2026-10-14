import AppKit
import Combine
import CryptoKit
import OSLog
import SwiftUI
import Vision

extension LauncherView {

    func persistActiveL2DockSession() {
        if let key = l2.activeDockSessionKey {
            AppPanelChatStore.shared.saveSession(l2.chatMessages, for: key)
        }
    }
    // MARK: - Context Dock Filter (type to find actions)

    // MARK: - Instant menu reload on app switch

    /// Called immediately when the frontmost app changes while the dock is open.
    /// Cancels any in-flight menu load and starts a fresh one for `app`.
    /// A System Events walk (off the main thread) has read the menus of an app whose AX tree
    /// is empty — VS Code and other Electron apps. If that is the Dock's app, reload so the
    /// list fills in; the Corner does the same through `AppChatPromptModel`.
    func scriptedMenusDidLoad(pid: pid_t?) {
        guard let pid, let app = contextTargetApp(), app.processIdentifier == pid else { return }
        reloadMenuForApp(app)
    }


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

        if !useCacheOnly, !bundleId.isEmpty {
            warmingMenuBundleIds.insert(bundleId)
        }

        let cachedItems = ContextDockEngine.shared.cachedMenuItems(for: app, maxResults: 120)
        if useCacheOnly || !cachedItems.isEmpty {
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
            defer {
                if !bundleId.isEmpty {
                    Task { @MainActor in
                        self.warmingMenuBundleIds.remove(bundleId)
                    }
                }
            }
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
                    if cachedItems.isEmpty {
                        self.liveMenuItems = []
                        self.menuDebugText = "\(name): no menu cache yet"
                    }
                }
                return
            }

            await MainActor.run {
                guard self.contextTargetApp()?.processIdentifier == pid else { return }
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
    /// Reads the frontmost app's live text selection into the PREVIEW field that
    /// drives the trailing selection button. Deliberately does NOT touch axContext:
    /// writing selectedText there flips hasSelectionScopeSurface, which silently
    /// exits pure global app search mid-typing (blank sheet on ↓, dead expansion).
    /// Called from the AX selection observer AND the 0.75s live poll (some apps
    /// don't emit AXSelectedTextChanged for web-area mouse selections).
    /// `minInterval` throttles the poll caller only; event-driven callers pass 0 and stay
    /// instant. Each call spawns an AX selection read, and for Finder that read reaches
    /// `getFinderSelectedFiles()` — an Apple event that executes on the MAIN thread. Firing it
    /// every 0.75 s tick made typing in Context Dock stutter for a Selection Scope feature the
    /// user had not even opened.
    func refreshLiveSelectionIntoDockContext(minInterval: TimeInterval = 0) {
        guard showContextInDock else { return }
        if minInterval > 0 {
            let now = Date()
            guard now.timeIntervalSince(lastLiveSelectionPoll) > minInterval else { return }
            lastLiveSelectionPoll = now
        }
        // Even while OUR dock has key focus, the source app can still change selection by mouse
        // click/drag behind the panel. Keep polling the remembered source app; empty AX reads are
        // ignored below so transient background-read failures do not flicker the icon.
        let ownBundleId = Bundle.main.bundleIdentifier ?? ""
        let previous = AppDelegate.shared?.previousFrontmostApp
        let app =
            previous?.bundleIdentifier == ownBundleId
            ? contextTargetApp()
            : (previous ?? contextTargetApp())
        guard let app, app.bundleIdentifier != ownBundleId else { return }
        let pid = app.processIdentifier
        Task.detached(priority: .userInitiated) {
            await AXContextReader.shared.refreshSelectionOnly(from: app)
            let newCtx = await AXContextReader.shared.current
            await MainActor.run {
                let currentTargetPID =
                    self.contextTargetApp()?.processIdentifier
                    ?? AppDelegate.shared?.previousFrontmostApp?.processIdentifier
                guard self.showContextInDock,
                    currentTargetPID == pid
                else { return }
                let newText = newCtx.selectedText?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Keep the live selection fields current so the selection icon tracks what the
                // user selects in the background while the dock is open (file/folder changes
                // never updated before — only the text preview did). Patch just the selection
                // fields; replacing the whole context would drop menu/window data.
                //
                // Adopt a NON-EMPTY read only. Reading a background app's selection while our
                // panel holds key focus intermittently comes back empty; treating that as
                // "selection cleared" toggled the icon on and off beside the capsule. An empty
                // result means "couldn't read it", not "nothing is selected" — the user clears a
                // selection through the dock (backspace / "−"), not by us guessing from AX.
                if !newCtx.selectedFilePaths.isEmpty,
                    self.axContext.selectedFilePaths != newCtx.selectedFilePaths
                {
                    self.axContext.selectedText = nil
                    self.axContext.selectedFilePaths = newCtx.selectedFilePaths
                    self.currentContext = .filesSelected(
                        newCtx.selectedFilePaths.map { URL(fileURLWithPath: $0) })
                    self.liveDockSelectionPreviewText =
                        newCtx.selectedFilePaths.count == 1
                        ? URL(fileURLWithPath: newCtx.selectedFilePaths[0]).lastPathComponent
                        : "\(newCtx.selectedFilePaths.count) files selected"
                }
                if !newText.isEmpty, self.axContext.selectedText != newCtx.selectedText {
                    self.axContext.selectedFilePaths = []
                    self.axContext.selectedText = newCtx.selectedText
                    self.currentContext = .textSelected(newText)
                    self.liveDockSelectionPreviewText = newText
                }
            }
        }
    }

    func handleSelectionChange() {
        guard showContextInDock else { return }

        // Text selected in the frontmost app WHILE the dock is open must surface the
        // selection button (next to running-app pills / tab pills) live. The menu
        // refresh below never reads the selection, so do it here, event-driven.
        refreshLiveSelectionIntoDockContext()

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
        ClipboardHistoryEngine.shared.checkPasteboard()
        autoReturnFromGlobalContextIfNeeded()
        // A file selected in Finder WHILE the dock is open must surface the trailing
        // selection button live — the lightweight AX poll below never reads selection.
        // Backup cadence only: the AX event path above handles the responsive case.
        refreshFinderSelectionContextFromFinder(minInterval: 2.0)
        // Same for live TEXT selections (browser pages, editors): poll as backup for
        // apps whose web areas don't emit AXSelectedTextChanged.
        refreshLiveSelectionIntoDockContext(minInterval: 2.0)

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

    /// `minInterval` separates the two callers. The AX selection event (AXSelectedRowsChanged,
    /// which Finder does emit) is the real path and stays responsive; the 0.75 s idle poll is
    /// only a backup for apps that miss the event, and reading Finder there every tick meant a
    /// main-thread Apple event 80 times a minute while the user was merely typing in the dock.
    func refreshFinderSelectionContextFromFinder(minInterval: TimeInterval = 0.25) {
        guard showContextInDock, !showMediaLayer, !aiMode.isActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFinderSelectionRefresh) > minInterval else { return }
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

    /// The corner prompt is an entry point, not a chat: it hands the question to the
    /// app-scoped chat that already exists, down the same path the "Chat with <App>" pill
    /// uses, so there is one conversation rather than two.
    func handleAppChatPromptSubmission(_ note: Notification) {
        // The corner's prompt tests post these notifications and check that they were posted.
        // In the test host this dock is live too, and acting on them started real turns on the
        // shared conversation — a model call from an offline suite, and a loading conversation
        // that held later tests' prompts up (GitHub #75). The same guard is on every
        // appChatPrompt* handler below.
        guard !AppDelegate.isHostingTests else { return }
        guard let info = note.userInfo,
            let bundleId = info["bundleId"] as? String,
            let appName = info["appName"] as? String
        else { return }
        let query = (info["query"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The corner posts what the user attached. This handler used to read only the
        // question, so a screenshot attached in the corner was neither shown on the message
        // nor sent with the turn — the answer was about the words alone, and nothing said
        // so. They go where the dock's own composer puts them, which is also what renders
        // them as chips on the message.
        let attached = (info["attachments"] as? [String] ?? [])
            .map(URL.init(fileURLWithPath:))
        // Selection Scope sends the text it was opened on. Without it the turn falls back
        // to `liveSelectionForChat()`, which reads whatever is selected *now* — and by the
        // time a question is submitted the frontmost app is Context Dock, whose own window
        // has no selection at all.
        if let selected = (info["selectedText"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty
        {
            contextDockChatCapturedText = selected
        }
        for url in attached where !aiMode.attachments.contains(url) {
            aiMode.attachments.append(url)
        }

        // Asking in the corner used to open the Context Dock over whatever the user was
        // working in, and then wait 120 ms for it to finish appearing before the question
        // landed. The pipeline never needed that: the launcher view is built once at
        // startup and only ordered out when hidden, so it and its handlers are alive to run
        // the turn whether or not anyone can see them. The corner is a second presentation
        // of this conversation, not a shortcut to the dock.
        retargetCornerAppChat(appName: appName, bundleId: bundleId)

        guard !query.isEmpty else {
            return
        }
        dismissMediaLayer()
        // The Selection card's questions are for the AI, never a command to route.
        handleL2QuerySkippingMenuRouter(
            query, isSelectionQuestion: info["selectionQuestion"] as? Bool ?? false)
    }

    /// The corner picked one of the answer's offered routes.
    ///
    /// The turn ran on the dock's pipeline, so the choice runs there too — the corner is a
    /// second presentation of this conversation, not a second engine for it.
    func handleAppChatPromptPickAction(_ note: Notification) {
        guard !AppDelegate.isHostingTests else { return }
        guard let choiceID = note.userInfo?["choiceID"] as? String, !choiceID.isEmpty else {
            return
        }
        let title = note.userInfo?["title"] as? String ?? choiceID
        runOfferedChoiceFromCorner(id: choiceID, title: title)
    }

    /// The corner asked to stop the running turn. The task is the dock's, so the stop is too.
    func handleAppChatPromptCancel() {
        guard !AppDelegate.isHostingTests else { return }
        guard l2.isLoading || l2.currentTask != nil else { return }
        l2.currentTask?.cancel()
        l2.currentTask = nil
        l2.isLoading = false
        l2.activeRequestID = nil
        AppChatConversation.shared.liveSteps = []
    }

    /// The corner asked to drop clips. It reads the same history this writes, and the image
    /// blobs live beside that file, so removal happens here where both are owned.
    /// The corner asked to start over. It shows the dock's conversation rather than one of
    /// its own, so the dock is what empties it.
    func handleAppChatPromptNewChat() {
        guard !AppDelegate.isHostingTests else { return }
        l2.currentTask?.cancel()
        l2.currentTask = nil
        l2.isLoading = false
        l2.activeRequestID = nil
        l2.handledApprovalIds = []
        l2.chatMessages = []
        AppChatConversation.shared.liveSteps = []
        if let key = l2.activeDockSessionKey {
            AppPanelChatStore.shared.beginSession(for: key)
        }
    }

    func handleAppChatPromptScopeChange(_ note: Notification) {
        guard !AppDelegate.isHostingTests else { return }
        guard let info = note.userInfo,
            let bundleId = info["bundleId"] as? String,
            let appName = info["appName"] as? String
        else { return }
        retargetCornerAppChat(appName: appName, bundleId: bundleId)
    }

    /// The corner and dock are two presentations of this one session. Remove explicit
    /// stale scopes, then let the existing frontmost-app session resolver persist/load
    /// the correct app (including Finder's folder-aware key).
    private func retargetCornerAppChat(appName: String, bundleId: String) {
        showContextInDock = true
        globalContextActivation = nil
        globalInlineAppScope = nil
        additionalGlobalInlineAppScopes = []
        l2.targetApp = nil
        l2.chatDraftAppName = appName
        l2.chatDraftBundleId = bundleId
        l2.chatArmed = true
        l2.chatDismissed = false
        syncL2DockSession()
        // Opening the dock is what used to start context tracking for the target app, so a
        // corner-only session had no live Finder selection to hand its turn: `showContextInDock`
        // was false, and `handleSelectionChange` returns on that guard. Retargeting turns it
        // on above, so read the selection now rather than waiting for the next AX event —
        // otherwise the first question about a folder is asked with nothing selected.
        refreshLiveSelectionIntoDockContext()
    }

    func clipboardImageData(for entry: ClipboardEntry) -> Data? {
        ClipboardHistoryEngine.imageData(for: entry)
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


// Handlers for `contentWithModifiers`. Kept out of the modifier chain on purpose: a multi-statement
// closure is type-checked together with the expression around it, and with these bodies inline
// Xcode 26's type checker gave up on the chain (CI, 2026-09-24).
extension LauncherView {
    /// `.onChange(of: aiMode.isActive)`.
    func handleAIModeActiveChange(_ newValue: Bool) {
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
    }

    /// `.onChange(of: showContextInDock)`.
    func handleShowContextInDockChange(_ newValue: Bool) {
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
            let warmBundleId = activeApp?.bundleIdentifier ?? ""
            if !useCacheOnly, !warmBundleId.isEmpty {
                warmingMenuBundleIds.insert(warmBundleId)
            }
            if let app = activeApp {
                var cachedItems = MenuWarmCacheService.shared.cachedMenuItems(
                    for: app, maxResults: 120)
                if cachedItems.isEmpty {
                    cachedItems = ContextDockEngine.shared.cachedMenuItems(
                        for: app, maxResults: 120)
                }
                if !cachedItems.isEmpty {
                    liveMenuItems = menuItemsVisibleInActiveDockMode(cachedItems)
                    menuDebugText =
                        "\(app.localizedName ?? ""): \(liveMenuItems.count) cached menus"
                    lastLiveMenuSignature = menuSignature(for: liveMenuItems)
                    previousEnabledIDs = Set(liveMenuItems.filter(\.isEnabled).map(\.id))
                    syncRecentAppsFromAppleMenu(cachedItems)
                    scheduleDockPillRebuild(
                        query: lastPillQuery, delayNanoseconds: 0, refreshContext: false)
                }
            }
            menuLoadTask = Task.detached(priority: .userInitiated) {
                defer {
                    if !warmBundleId.isEmpty {
                        Task { @MainActor in
                            self.warmingMenuBundleIds.remove(warmBundleId)
                        }
                    }
                }
                let app = await MainActor.run { self.contextTargetApp() }
                guard let app, !app.isTerminated else { return }
                let pid = app.processIdentifier
                let name = app.localizedName ?? ""
                // Don't warm Finder in desktop-only mode (no window) — its menus aren't
                // shown there (files are), and the open-to-populate scan would flash
                // Finder's menus for nothing.
                let isFinderApp = app.bundleIdentifier == "com.apple.finder"
                let finderDesktopOnly =
                    isFinderApp ? (await MainActor.run { self.isFinderDesktopOnlyMode }) : false
                let skipFinderDesktopWarm = isFinderApp && finderDesktopOnly
                var items: [AXMenuItem] = []
                if useCacheOnly {
                    items = GlobalContextEngine.shared.cachedMenuItems(
                        for: app, maxResults: 120)
                } else if skipFinderDesktopWarm {
                    items = await AXMenuReader.shared.peekCachedAllMenuItems(for: pid)
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
                    guard !resolvedItems.isEmpty else {
                        self.scheduleDockPillRebuild(
                            query: self.lastPillQuery, delayNanoseconds: 0,
                            refreshContext: false)
                        return
                    }
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
            liveDockSelectionPreviewText = nil
            l2.extensionResults = []
            // NEVER destroy an active conversation on dock hide: an approved chat
            // command (`code --status`) can activate its target app, which auto-hides
            // the launcher — wiping messages + scope here killed the chat mid-answer.
            // Menus/pills below still reset; the chat + pinned scope survive so the
            // next open resumes exactly where the user left off.
            let hasActiveChat =
                l2.isLoading || l2.currentTask != nil || !l2.chatMessages.isEmpty
            if !hasActiveChat {
                l2.chatMessages = []
                l2.isLoading = false
                l2.activeRequestID = nil
                l2.currentTask?.cancel()
                l2.currentTask = nil
            }
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
            // Keep the pinned scope alive with an active chat (see hasActiveChat
            // above) so reopening the dock lands back in the same conversation.
            if !hasActiveChat {
                l2.targetApp = nil
            }
            menuLoadTask?.cancel()
            crossAppMenuTask?.cancel()
        }
    }

}
