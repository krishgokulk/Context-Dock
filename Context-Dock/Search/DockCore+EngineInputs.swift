// DockCore+EngineInputs.swift
// Context-Dock
//
// What the engine does with what reaches it from outside: the context and frontmost app the
// AppDelegate detects, files and text from Services, scripted menus, index rebuild requests,
// and its start-up. These were `.onAppear` / `.onReceive` on the launcher's view, so they ran
// only while that view sat in a window. `DockEngine` calls them now (#257 E2). Bodies moved
// unchanged.

import AppKit
import SwiftUI

extension DockCore {
    /// The engine's start-up: the app list, the Drop Shelf, app-switch observers and the first
    /// context read. Once, from `DockEngine.start()`.
    func startEngine() {
        // Load running apps immediately so the dock bar shows them on first launch
        runningRegularApps = currentRegularRunningApps()
        loadApplicationsInBackground()
        // The Drop Shelf's edge strip does not exist until this runs, so nothing
        // it does can affect the system before the app is up.
        DropShelfController.shared.activate()
        // Start observing app switches if enabled (frontmost app already detected in ILauncherApp)
        if settings.enableFrontmostDetection {
            startObservingAppSwitches()
        }
        // Detect initial context
        detectAndUpdateContext()
        // Reset chat visibility flag on launch
        hasUserSentMessageInCurrentSession = false
        // The Corner's Global results run on this engine's row builders.
        connectGlobalResults()
    }

    func handleUserContextUpdate(_ context: UserContext) {
        // Receive pre-detected context from AppDelegate (before ILauncher becomes frontmost)
        if isL2ContextActive {
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

    func handleFrontmostAppUpdate(_ appInfo: FrontmostAppInfo) {
        let appName = appInfo.name
        let bundleID = appInfo.bundleID

        if bundleID == Bundle.main.bundleIdentifier {
            return
        }

        // Check if app changed (not just re-detection of same app)
        let appChanged =
            !frontmost.bundleID.isEmpty && frontmost.bundleID != bundleID

        // A selection belongs to the app it was made in. When the frontmost app
        // actually changes, drop the previous app's cached selection so its
        // selection button/scope doesn't linger in every other app. A locked chat
        // keeps its selection — that text/file IS the conversation's payload.
        if appChanged, !isContextDockChatLocked {
            liveDockSelectionPreviewText = nil
            axContext.selectedText = nil
            axContext.selectedFilePaths = []
        }

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

        // Clipboard and Notifications own their result sheet independently of the
        // frontmost app. Let the app metadata update above land, then stop before the
        // generic Context Dock switch path clears list measurements and rebuilds app
        // context. That race could collapse a compact scope to only its input bar.
        if isCompactSmartScope {
            AppDelegate.shared?.smartScopeActive = true
            showContextInDock = true
            isSearchBarExpanded = true
            refreshCompactScopeResults(resetSelection: false)
            return
        }

        // A frontmost-app chat is a locked conversation: it belongs to the app it was
        // started for. Switching apps, clicking away or changing Spaces must not wipe
        // its messages, retarget its scope or rebuild the other app's menus underneath
        // it — only an explicit exit (Escape / backspace / the `−` chip) ends it.
        // Menu search (chat not locked) keeps following the frontmost app below.
        if isContextDockChatLocked {
            syncL2DockSession(force: l2.activeDockSessionKey == nil)
            return
        }

        if appChanged {
            l2.appCompletion = nil
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            // Immediately clear stale pills AND cancel any in-flight rebuild.
            // Otherwise an older app's delayed pill build can finish after the
            // frontmost switch and repaint previous-app menu rows.
            contextDockViewModel.resetPillRenderingState(cancelBuild: true)
            menuLoadTask?.cancel()
            menuLoadTask = nil
            liveMenuRefreshTask?.cancel()
            liveMenuRefreshTask = nil
            menuAvailabilityRefreshTask?.cancel()
            menuAvailabilityRefreshTask = nil
            cachedDockPills = []
            liveMenuItems = []
            contextMenuPills = []
            previousEnabledIDs = []
            measuredGlobalListContentHeight = 0
            lastLiveMenuSignature = ""
            lastPillQuery = ""
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
            // Clear stale AX selection only when moving to a different external app.
            // When Context-Dock itself becomes frontmost, preserve the prior app's
            // selection so the trailing selection-scope button can still appear.
            if bundleID != ownId {
                axContext = .empty
                currentContext = .none
                showGlobalClipboardPill = false
                globalClipboardText = ""
            }
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
            if let pinnedApp = contextTargetApp() {
                reloadMenuForApp(pinnedApp)
            }
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

        // Switching the external app rebuilds the scoped row asynchronously. Restore
        // focus after this handler has committed the new app so that rebuild cannot
        // leave the visible dock with no field editor. Explicitly locked app scopes do
        // not follow the external app and therefore need no responder reset here.
    }

    func handleServicesOpenWithFiles(_ notification: Notification) {
        // Receive files shared via Services/Share Sheet
        if let urls = notification.userInfo?["urls"] as? [URL], !urls.isEmpty {
            currentContext = .filesSelected(urls)
            updateL2ContextExtensions()
        }
    }

    func handleServicesOpenWithText(_ notification: Notification) {
        // Receive text shared via Services/Share Sheet
        if let text = notification.userInfo?["text"] as? String, !text.isEmpty {
            currentContext = .textSelected(text)
            updateL2ContextExtensions()
        }
    }

    func handleScriptedMenusDidLoad(_ note: Notification) {
        scriptedMenusDidLoad(pid: note.userInfo?["pid"] as? pid_t)
    }

    func handleGlobalSearchIndexRebuildRequest(_ note: Notification) {
        rebuildGlobalSearchIndex()
        if shouldUsePureGlobalAppSearch {
            let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
            updateGlobalContextTypingSnapshot(query: q)
            scheduleGlobalGroupedListRebuild(query: q, delayNanoseconds: 0)
        }
    }

    // MARK: - Reactions to its own state (#257 E3)
    //
    // `.onChange` hooks on the view that did engine work — saving the chat, keeping its
    // session keyed to the right app, following the selection. `DockEngine` runs them when
    // the value changes, the way `.onChange` did. Bodies moved unchanged.

    func engineFrontmostDetectionChanged(_ newValue: Bool) {
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

    func engineTargetAppChanged() {
        syncL2DockSession(force: true)
        scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
    }

    func engineShowContextInDockChanged(_ newValue: Bool) {
        handleShowContextInDockChange(newValue)
        if newValue {
            syncL2DockSession(force: true)
            if shouldShowSafariTabStrip {
                syncSafariTabStrip(force: true)
            }
            scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
        }
    }

    /// Clear stale chat when the selected content changes so AI focuses on the new context.
    /// App-level changes are handled by the frontmost-app update; this covers file/text/URL.
    func engineContextChanged() {
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
