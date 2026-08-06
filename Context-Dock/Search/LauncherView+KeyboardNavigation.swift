import AppKit
import SwiftUI

extension LauncherView {
    func requestWindowSizeUpdate(
        reason: DockResizeReason,
        animated: Bool = true,
        debounceNanoseconds: UInt64 = 50_000_000
    ) {
        // Keep the dock floating across Spaces while a scope / scoped chat is active,
        // so switching desktops doesn't leave it on the old Space (reads as "hidden").
        // Cleared automatically once the scope is exited.
        syncScopeChatSpaceHold()

        if isGlobalContextActive,
            globalContextViewModel.typingSnapshot.shouldShowOnlyTopMatch,
            reason.isTypingOrContentRefresh,
            !hasMatchingGlobalContextResults
        {
            return
        }
        let preset = currentDockHeightPreset
        let mode = currentDockSurfaceMode
        let presetChanged = lastAppliedDockHeightPreset != preset
        let modeChanged = lastAppliedDockSurfaceMode != mode

        if showContextInDock,
            !isGlobalContextActive,
            mode == .contextDock,
            reason.isTypingOrContentRefresh,
            !presetChanged,
            !modeChanged,
            !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return
        }

        if reason.isTypingOrContentRefresh && preset.stabilizesResize && !presetChanged
            && !modeChanged
        {
            if let window = AppDelegate.shared?.launcherWindow {
                let heightDelta = abs(window.frame.height - calculatedHeight)
                let widthDelta = abs(window.frame.width - calculatedWidth)
                if heightDelta <= 24 && widthDelta <= 1 {
                    return
                }
            } else {
                return
            }
        }

        // A preset/mode change IS the expand-collapse transition. Debouncing it let SwiftUI paint
        // the sheet first and grow the shell ~50ms later, which reads as the sheet flickering in
        // before the window catches up. Only steady-state churn (list height settling while
        // typing) keeps the debounce.
        let isSurfaceTransition = presetChanged || modeChanged
        updateWindowSize(
            animated: animated,
            debounceNanoseconds: isSurfaceTransition ? 0 : debounceNanoseconds)
    }

    // MARK: - Dock pill arrow-key navigation

    /// Flat list of app pills currently visible in the pinned/running or global-search row.
    /// Returns (action, destructiveAction, removeAction) per index for keyboard execution.
    func currentAppPillActions() -> [(
        execute: () -> Void, quit: (() -> Void)?, remove: (() -> Void)?
    )] {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Global context app search
        if shouldUsePureGlobalAppSearch && !q.isEmpty {
            let state = visibleGlobalGroupedListNavigationState(for: q)
            let visibleRows =
                state.appResults.isEmpty
                ? currentGlobalAppMatches(for: q)
                : state.appResults
            return visibleRows
                .map {
                    result -> (execute: () -> Void, quit: (() -> Void)?, remove: (() -> Void)?) in
                    let runningApp = runningApplication(forGlobalResult: result)
                    let quitAction: (() -> Void)? = runningApp.map { app in
                        { terminateRunningAppFromDock(app) }
                    }
                    let removeAction: (() -> Void)? = nil
                    return (
                        execute: {
                            executeGlobalAppSearchResult(result)
                        }, quit: quitAction, remove: removeAction
                    )
                }
        }
        // Pinned row
        var items: [(execute: () -> Void, quit: (() -> Void)?, remove: (() -> Void)?)] = []
        for app in settings.pinnedApps {
            let ri = runningApp(for: app)
            let captured = app
            items.append(
                (
                    execute: { launchPinnedApp(captured) },
                    quit: ri.map { r in { terminateRunningAppFromDock(r) } },
                    remove: { settings.unpinApp(captured) }
                ))
        }
        return items
    }

    /// Set up a key monitor that handles Left/Right arrow navigation and
    /// Enter-to-execute for dock pills when the L2 Context Dock is active.
    func searchInputHasHighlightedText() -> Bool {
        guard isSearchFieldFocused,
            let textView = NSApp.keyWindow?.firstResponder as? NSTextView
        else { return false }

        return textView.selectedRanges.contains { value in
            value.rangeValue.length > 0
        }
    }

    func searchInputCursorIsAtEnd() -> Bool {
        guard isSearchFieldFocused,
            let textView = NSApp.keyWindow?.firstResponder as? NSTextView
        else { return false }

        let range = textView.selectedRange()
        return range.length == 0 && range.location >= (textView.string as NSString).length
    }

    /// UTF-16 caret offset in the focused search field (nil when unfocused or
    /// when a selection — not a bare caret — is active).
    func searchInputCursorOffset() -> Int? {
        guard isSearchFieldFocused,
            let textView = NSApp.keyWindow?.firstResponder as? NSTextView
        else { return nil }
        let range = textView.selectedRange()
        guard range.length == 0 else { return nil }
        return min(range.location, (textView.string as NSString).length)
    }

    enum KeyRoutingMode {
        case shareSheet
        case ai
        case compactScope
        case hidden
        case globalContext
        case contextDock
    }

    var keyRoutingMode: KeyRoutingMode {
        if isSharingSheetActive { return .shareSheet }
        if aiMode.isActive { return .ai }
        if isCompactSmartScope { return .compactScope }
        if !showContextInDock { return .hidden }
        if isGlobalContextActive { return .globalContext }
        return .contextDock
    }

    func handleTopLevelKeyRouting(_ event: NSEvent, mode: KeyRoutingMode) -> NSEvent? {
        switch mode {
        case .shareSheet, .ai, .compactScope, .hidden:
            return event
        case .globalContext, .contextDock:
            return nil
        }
    }

    func setupDockPillKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // A pinned panel is its own surface. Hand its keys straight back, or
            // navigating a folder panel also arrows through Global Context behind it.
            if GlassFloatingPanel.ownsEvent(event) { return event }
            // Quick Look is modal to the keyboard while it is up: its arrows page
            // through the preview set. Without this the dock also read them and
            // switched app scope behind the preview.
            if FileQuickLookPanel.shared.ownsEvent(event) { return event }

            // Space = Quick Look, handled before anything else in this monitor can
            // consume it. Sitting further down, an earlier branch swallowed it and
            // Space did nothing in a file scope.
            if event.keyCode == 49,
                !event.modifierFlags.contains(.command),
                let path = self.focusedPillPreviewPath() {
                FileQuickLookPanel.shared.toggle(
                    path: path, siblings: self.visiblePreviewPaths())
                return nil
            }

            // Backspace on an empty compact scope (Clipboard / Notifications) exits it.
            // Handled here because the field editor swallows Backspace before SwiftUI's
            // .onKeyPress ever sees it.
            if event.keyCode == 51,
                self.searchState.activeSmartQueryKey != nil,
                self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                self.clearSearchContext()
                self.isSearchFieldFocused = true
                self.scheduleDockPillRebuild(query: "", delayNanoseconds: 0, refreshContext: false)
                self.requestWindowSizeUpdate(reason: .modeChanged)
                return nil
            }

            // Backspace on an empty field in Selection Scope leaves the scope AND dismisses the
            // dock — the scope IS the surface, so dropping the user into an empty Context Dock
            // is a dead end. Must be handled here for the same reason as the compact scopes
            // above: the field editor eats Backspace before .onKeyPress or the NC route runs.
            if event.keyCode == 51,
                self.hasSelectionScopeSurface,
                self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            {
                self.dismissSelectionAndStayInGlobalContext()
                self.isSearchFieldFocused = false
                AppDelegate.shared?.hideLauncher(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    AppDelegate.shared?.previousFrontmostApp?.activate(options: [
                        .activateIgnoringOtherApps
                    ])
                }
                return nil
            }

            // "/rem" + Return picks the filtered app, wherever Return reaches us from.
            // This sits ahead of every other Return route because the field is not
            // holding a question at that moment — it is holding a filter, and sending
            // it to the model is never what the user meant.
            if event.keyCode == 36, self.handleGeneralChatSlashPickIfNeeded() {
                self.ensureSearchInputFocusReady()
                return nil
            }

            let routingMode = self.keyRoutingMode
            // General Chat's provider picker is an AppKit menu.  After that menu closes,
            // AppKit can leave the panel (rather than the NSTextView) as first responder, so
            // SwiftUI's TextField.onSubmit never receives Return.  Route that *unfocused* path
            // here, before the L2/global-only key guard below.  A focused editor still owns
            // Return and uses its normal .onSubmit route, so this cannot double-send.
            if event.keyCode == 36,
                self.currentDockSurfaceMode == .generalChat,
                !(NSApp.keyWindow?.firstResponder is NSTextView)
            {
                let generalChatQuery = self.searchState.query
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !generalChatQuery.isEmpty {
                    if self.handleGeneralChatSlashPickIfNeeded() {
                        self.ensureSearchInputFocusReady()
                        return nil
                    }
                    if !self.launchTypedAppMatchIfNeeded() {
                        self.submitAIQuery()
                    }
                    self.ensureSearchInputFocusReady()
                    return nil
                }
            }

            if let routedEvent = self.handleTopLevelKeyRouting(event, mode: routingMode) {
                return routedEvent
            }

            // Space = Quick Look, Finder-style. Gated on keyboard pill navigation being
            // active: the search field always holds focus here, so an ungated Space would
            // stop the user typing a space in a query.

            // The Quick Note split editor owns the keyboard: yield every key to the
            // focused TextEditor / list so the user types freely. Escape exits the
            // scope; ⌘N starts a new note.
            if self.activeNotepadScopeCommand != nil {
                if event.keyCode == 53 {  // Escape
                    if let scope = self.globalInlineAppScope {
                        self.removeGlobalInlineAppScope(scope)
                    }
                    self.notepadSelectedNoteID = nil
                    return nil
                }
                if event.keyCode == 45, event.modifierFlags.contains(.command) {  // ⌘N
                    self.notepadSelectedNoteID = QuickNotesStore.shared.create()
                    return nil
                }
                // Up/Down navigate the notes list while the input field is focused;
                // in the editor they stay normal cursor movement.
                if (event.keyCode == 125 || event.keyCode == 126), self.isSearchFieldFocused {
                    self.navigateNotepadSelection(delta: event.keyCode == 125 ? 1 : -1)
                    return nil
                }
                // Return in the top input field = ask the selected AI provider and
                // insert its reply into the open note. Return in the editor (input not
                // focused), or Shift+Return, stays a plain newline.
                if event.keyCode == 36,
                    self.isSearchFieldFocused,
                    !event.modifierFlags.contains(.shift)
                {
                    let q = self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !q.isEmpty || !self.notepadAttachments.isEmpty
                        || self.notepadCapturedText?.isEmpty == false
                    {
                        self.submitNotepadAIPrompt(q)
                        return nil
                    }
                }
                return event
            }

            // Only context/global dock modes can consume dock navigation keys.
            guard routingMode == .contextDock || routingMode == .globalContext else {
                return event
            }

            // A cli:// scope is an agent command workspace, not a Global Context
            // result list. Its text must always reach the scoped chat on Return.  The
            // generic Global Context monitor below can see stale menu/app pills and
            // consume Return first, which made "brew show installed apps" appear to do
            // nothing. Keep vertical arrows inside the workspace too: an empty CLI
            // composer must not cycle the user into Context/Media layers.
            if self.isCLIToolScopeLocked {
                let cliQuery = self.searchState.query
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if event.keyCode == 36,
                    !cliQuery.isEmpty,
                    !self.l2.isLoading,
                    let target = self.currentGlobalScopedChatTarget
                {
                    self.armGlobalScopedChat(appName: target.appName, bundleId: target.bundleId)
                    self.dismissMediaLayer()
                    self.handleL2QuerySkippingMenuRouter(cliQuery)
                    return nil
                }
                if (event.keyCode == 125 || event.keyCode == 126),
                    cliQuery.isEmpty,
                    self.isSearchFieldFocused
                {
                    return nil
                }
            }

            // Pills behave like atomic text: backspace with the caret at a pill's
            // right edge converts that pill back to plain text (any position, not
            // just end-of-query), and arrow keys jump across the pill in one press
            // instead of crawling invisibly through the hidden alias characters.
            if self.isGlobalContextActive,
                !self.allGlobalInlineAppScopes.isEmpty,
                self.focusedAppPillIndex == nil, self.l2.focusedPillIndex == nil,
                event.keyCode == 51 || event.keyCode == 123 || event.keyCode == 124,
                let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                textView.selectedRange().length == 0
            {
                let caret = textView.selectedRange().location
                let spans = self.globalInlineScopeUTF16Spans()
                switch event.keyCode {
                case 51:  // Backspace at a pill's right edge → pill becomes text
                    if let hit = spans.first(where: { $0.span.upperBound == caret }) {
                        self.removeGlobalInlineAppScopeFromBackspace(hit.scope)
                        DispatchQueue.main.async {
                            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                                let limit = (tv.string as NSString).length
                                tv.setSelectedRange(
                                    NSRange(location: min(caret, limit), length: 0))
                            }
                        }
                        return nil
                    }
                case 124:  // Right — jump over the pill
                    if let hit = spans.first(where: { $0.span.lowerBound == caret }) {
                        textView.setSelectedRange(
                            NSRange(location: hit.span.upperBound, length: 0))
                        self.launcherViewModel.searchInputCaretTick &+= 1
                        return nil
                    }
                case 123:  // Left — jump over the pill
                    if let hit = spans.first(where: { $0.span.upperBound == caret }) {
                        textView.setSelectedRange(
                            NSRange(location: hit.span.lowerBound, length: 0))
                        self.launcherViewModel.searchInputCaretTick &+= 1
                        return nil
                    }
                default:
                    break
                }
            }

            // Attached folder search arms the chat — detach it FIRST so backspace
            // can actually leave folder mode (back to Finder menu search).
            if event.keyCode == 51,
                self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                self.detachFinderFolderQueryModeFromEmptyBackspace()
            {
                self.isSearchFieldFocused = true
                return nil
            }

            // Frontmost-app chat open + empty field: backspace saves and hides the chat, then
            // returns to that app's menu search. This MUST run before the inline-scope
            // pops below, which would otherwise dump the user into Global Context.
            if event.keyCode == 51,
                self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                self.shouldShowContextDockChatSheet || self.l2.showChatPopover || self.l2.chatArmed
            {
                withAnimation(.dockStandard) {
                    if let key = self.l2.activeDockSessionKey {
                        AppPanelChatStore.shared.saveSession(self.l2.chatMessages, for: key)
                    }
                    self.l2.isLoading = false
                    self.l2.loadingStatus = nil
                    self.l2.activeRequestID = nil
                    self.l2.currentTask?.cancel()
                    self.l2.currentTask = nil
                    self.exitContextDockChatBackToContext()
                    // Backspace on an empty field fully leaves the frontmost-app chat:
                    // also drop the pin so the launcher returns to normal menu search
                    // (pin + scope both kept the chat open — one key clears both).
                    if self.settings.launcherPinned {
                        self.settings.launcherPinned = false
                        AppDelegate.shared?.applyPersistentDockBehavior()
                    }
                }
                self.isSearchFieldFocused = true
                return nil
            }

            if event.keyCode == 51, self.dismissSelectionScopeFromEmptyBackspaceIfNeeded() {
                return nil
            }

            if event.keyCode == 51, self.isGlobalContextActive,
                self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                self.l2.targetApp != nil
            {
                self.exitGlobalAppScopeToGlobalContext()
                return nil
            }

            if event.keyCode == 51, self.isGlobalContextActive,
                let scope = self.trailingGlobalInlineAppScopeForBackspace()
            {
                self.removeGlobalInlineAppScopeFromBackspace(scope)
                return nil
            }

            if event.keyCode == 51, self.isGlobalContextActive,
                self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let scope = self.allGlobalInlineAppScopes.last
            {
                self.removeGlobalInlineAppScope(scope)
                return nil
            }

            if event.keyCode == 48, self.isL2ContextActive, !self.isGlobalContextActive {
                return nil
            }

            if event.keyCode == 51,
                self.lockedFindToken != nil,
                self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                self.clearFindToken(preserveQuery: false)
                return nil
            }

            if self.isGlobalContextActive,
                self.shouldUsePureGlobalAppSearch,
                !self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                self.globalContextViewModel.typingSnapshot.phase != .expanded
            {
                switch event.keyCode {
                case 125:  // Down
                    if self.expandGlobalContextTypingMatch(selectFirst: true) { return nil }
                case 124, 48:  // Right / Tab — completion/scope only; ↓ owns sheet reveal
                    if event.keyCode == 124,
                        self.acceptTopGlobalAppGhostCompletionIfPossible()
                    {
                        return nil
                    }
                    if event.keyCode == 124,
                        self.activateFocusedGlobalAppScopeIfPossible()
                    {
                        return nil
                    }
                case 36:  // Enter
                    // Execute the top grouped row directly — the SAME row the leading input
                    // icon previews (top app OR top menu command, e.g. "quit music" → Quit
                    // Music ⌘Q). Enter runs it instead of expanding the sheet; ↓ still expands
                    // to browse the other rows.
                    if self.executeFocusedGlobalGroupedListRow() {
                        return nil
                    }
                    // "quit <app>" before the sheet is built: quit the app the leading icon
                    // is previewing. The fast-match fallbacks below only know the index
                    // rows, which for this query are unrelated menu owners — one of them
                    // could be launched instead of the app being quit.
                    if let quitTarget = self.strongGlobalQuitMatch(for: self.searchState.query),
                        let bundleID = quitTarget.bundleID,
                        let app = NSWorkspace.shared.runningApplications.first(where: {
                            $0.bundleIdentifier == bundleID && !$0.isTerminated
                        })
                    {
                        self.terminateRunningAppFromDock(app)
                        return nil
                    }
                    let matchIcons = self.globalContextViewModel.typingSnapshot.matchDockIcons
                    let exactLaunchIcons = matchIcons.filter {
                        $0.isExactAppPrefix && !$0.isExpandable
                    }
                    let expandableRunningIcons = matchIcons.filter {
                        $0.isExpandable && $0.isRunning
                    }
                    if exactLaunchIcons.count == 1, let item = exactLaunchIcons.first {
                        self.executeMatchDockIcon(item)
                        return nil
                    } else if expandableRunningIcons.count == 1,
                        let item = expandableRunningIcons.first
                    {
                        self.executeMatchDockIcon(item)
                        return nil
                    }
                default:
                    break
                }
            }

            // Right arrow: focus visible Global app result, otherwise accept app ghost text.
            if event.keyCode == 124 {
                if self.acceptTopGlobalAppGhostCompletionIfPossible() {
                    return nil
                }
                if self.activateFocusedGlobalAppScopeIfPossible() {
                    return nil
                }
                if !self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    self.focusTopGlobalAppResultIfPossible()
                {
                    return nil
                }
                // Right arrow always drives the "+" actions (attach folder / frontmost
                // chat). Selection Scope opens ONLY from clicking its trailing icon.
                if self.attachCurrentFinderFolderFromEmptyFieldIfNeeded() {
                    return nil
                }
                if self.connectFrontmostAppChatFromEmptyFieldIfNeeded() {
                    return nil
                }
                if let findToken = self.lockedFindToken,
                    findToken.hasChildMenu,
                    self.searchInputCursorIsAtEnd()
                {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.82)) {
                        self.showFindTokenMenu = true
                    }
                    return nil
                }
                if let completion = self.l2.appCompletion,
                    !completion.ghost.isEmpty,
                    self.searchInputCursorIsAtEnd()
                {
                    let full = completion.appName
                    if !full.isEmpty && self.searchState.query.lowercased() != full.lowercased() {
                        self.searchState.query = full
                        return nil
                    }
                }
            }
            // Tab in global context explicitly enters app scope.
            // Typing alone stays global so cross-app suggestions cannot steal the query.
            // Exception: in Finder desktop-only mode the query is a file/folder search —
            // Tab must NOT switch to a same-named app (e.g. "screen" → Screen Sharing),
            // which would hijack the Finder scope and drop the file results.
            if event.keyCode == 48, self.isGlobalContextActive, !self.isFinderDesktopOnlyMode {
                // First Tab accepts the same visible ghost completion as Right Arrow. A second
                // Tab on the completed app name may enter its scope. This prevents a partial
                // query such as "duck" from collapsing immediately into an icon-only scope.
                if self.acceptTopGlobalAppGhostCompletionIfPossible() {
                    return nil
                }
                if self.shouldUsePureGlobalAppSearch,
                    let result = self.focusedOrTopGlobalAppResult(),
                    let bundleId = self.bundleIdentifier(forApplicationResult: result)
                {
                    let activated = self.activateGlobalInlineScope(
                        result: result,
                        bundleID: bundleId
                    )
                    if activated {
                        self.focusedAppPillIndex = nil
                        self.l2.focusedPillIndex = nil
                        return nil
                    }
                }

                // Pure global search mode: use globalInlineAppScope (lightweight, no L2 session switch).
                // Tab on "notes" → Notes scope, query="".
                // Tab on "new note" → Notes scope, query="new".
                // Pure global search: Tab on bare app name (e.g. "not", "notes") → lock into scope.
                // Cross-app queries like "new note" have a non-empty actionQuery → skip, no scope switch.
                if self.shouldUsePureGlobalAppSearch, self.globalInlineAppScope == nil {
                    let raw = self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isBareName =
                        self.installedAppMenuTarget(
                            for: raw,
                            includeAppsWithoutMenuSnapshot: true,
                            allowPrefixAlias: true
                        ).map {
                            $0.actionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        } ?? false
                    if isBareName, self.applyGlobalInlineAppScopeIfNeeded(for: raw + " ") {
                        self.focusedAppPillIndex = nil
                        self.l2.focusedPillIndex = nil
                        return nil
                    }
                }

                if self.activateTypedAppScopeIfPossible() {
                    self.focusedAppPillIndex = nil
                    self.l2.focusedPillIndex = nil
                    return nil
                }

            }
            // Tab: pill ghost completion (prefix match on current pill name)
            if event.keyCode == 48, !self.isGlobalContextActive,
                let ghost = self.ghostPillCompletion
            {
                self.searchState.query = ghost.name
                return nil
            }
            // Tab: app ghost completion (non-global L2 scope sub-scope entry).
            // Never in pure Global Context — there Tab has exactly one meaning, entering the
            // app scope, and letting a leftover completion answer first made it ambiguous.
            if event.keyCode == 48, !self.shouldUsePureGlobalAppSearch,
                let completion = self.l2.appCompletion, !completion.ghost.isEmpty
            {
                self.acceptL2AppCompletion(completion)
                return nil
            }
            // Tab: try scope activation — only in non-global context (global context uses inline scope)
            if event.keyCode == 48, !self.isGlobalContextActive,
                self.activateTypedAppScopeIfPossible()
            {
                return nil
            }

            let q = self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            // Compact (hotkey-opened) Selection Scope: ↓ unfolds the actions sheet, mirroring the
            // ↓ expansion in Global Context. Typing does the same via the query change.
            if event.keyCode == 125, self.hasSelectionScopeSurface,
                self.selectionScopeSheetCollapsed
            {
                self.expandSelectionScopeSheet()
                return nil
            }

            // ↓ opens the compact capsule before it navigates anything. This monitor runs
            // ahead of SwiftUI's .onKeyPress, so the expansion has to live here: downstream
            // the key is consumed by row navigation, which only moved the selection and made
            // ↓ look dead while the ghost text cycled.
            if event.keyCode == 125,
                !self.isDockResultSheetRevealed,
                self.showContextInDock,
                !self.aiMode.isActive,
                self.isActiveGlobalRunningAppMenuScope()
                    || (!self.isGlobalContextActive && !q.isEmpty)
            {
                self.expandScopedCapsuleSheet(selectFirst: true)
                return nil
            }

            if event.keyCode == 36, self.aiMode.isActive {
                if self.handleGeneralChatSlashPickIfNeeded() {
                    return nil
                }
                self.submitAIQuery()
                return nil
            }

            if event.keyCode == 36, self.executeScopedRunningAppIfIdle() {
                return nil
            }

            if event.keyCode == 36,
                self.shouldShowContextDockChatSheet || self.l2.showChatPopover || self.l2.chatArmed,
                q.isEmpty
            {
                self.exitContextDockChatAndScope()
                return nil
            }

            // Right Arrow cycles the running-app scope forward. Left Arrow mirrors it
            // BACKWARD — but only once a running-app scope is active. With no scope the
            // empty-field Left Arrow stays reserved for General Chat (handled by the
            // SwiftUI .onKeyPress(.leftArrow) below), so both start states are distinct:
            // from the bare field Right enters the capsule, Left enters General Chat.
            // An open frontmost-app chat owns the arrow keys — cycling the app scope from
            // inside a conversation swapped it to another app (e.g. Finder) mid-chat.
            let inScopedChat =
                self.shouldShowContextDockChatSheet || self.l2.chatArmed || self.l2.showChatPopover

            if self.isGlobalContextActive || self.l2.targetApp != nil,
                q.isEmpty,
                event.keyCode == 124,
                !inScopedChat,
                self.focusedAppPillIndex == nil,
                self.l2.focusedPillIndex == nil,
                self.currentGlobalScopedBundleID?.hasPrefix("syscmd://") != true,
                self.currentGlobalScopedBundleID?.hasPrefix("cli://") != true
            {
                _ = self.cycleGlobalContextAppScope(direction: 1)
                self.focusedAppPillIndex = nil
                self.l2.focusedPillIndex = nil
                return nil
            }

            if self.isGlobalContextActive || self.l2.targetApp != nil,
                q.isEmpty,
                event.keyCode == 123,
                !inScopedChat,
                self.focusedAppPillIndex == nil,
                self.l2.focusedPillIndex == nil,
                let scopedBundle = self.currentGlobalScopedBundleID,
                !scopedBundle.hasPrefix("syscmd://"),
                !scopedBundle.hasPrefix("cli://")
            {
                _ = self.cycleGlobalContextAppScope(direction: -1)
                self.focusedAppPillIndex = nil
                self.l2.focusedPillIndex = nil
                return nil
            }

            // Block 1: grouped navigation — fires when view shows globalAppSearchListView.
            // That view is shown when: app matches exist, OR frontmost has no matching menus
            // (cross-app or empty). When frontmost HAS menus (preferFrontmostMenuResults=true),
            // view shows dockPillListView instead — Block 3 handles it with full-pills indices.
            if (self.shouldUsePureGlobalAppSearch || self.isActiveGlobalRunningAppMenuScope())
                && !q.isEmpty
            {
                let state = self.visibleGlobalGroupedListNavigationState(for: q)
                if state.totalCount == 0 {
                    // Nothing matched apps/commands/menus — ↓ still goes through the
                    // single expansion entry (its token-word fallback covers this).
                    switch event.keyCode {
                    case 125: // Down
                        if self.expandGlobalContextTypingMatch(selectFirst: true) { return nil }
                        return nil
                    default:
                        return event
                    }
                }

                switch event.keyCode {
                case 125:  // Down — FIRST press expands via the single entry, then navigates
                    if self.expandGlobalContextTypingMatch(selectFirst: true) { return nil }
                    _ = self.moveGlobalGroupedListFocus(
                        direction: self.settings.effectiveDockAtBottom ? -1 : 1
                    )
                    return nil
                case 126:  // Up — move through grouped app/menu rows
                    _ = self.moveGlobalGroupedListFocus(
                        direction: self.settings.effectiveDockAtBottom ? 1 : -1
                    )
                    return nil
                case 36:  // Return — execute focused grouped row, or first row if none focused
                    return self.executeFocusedGlobalGroupedListRow() ? nil : event
                case 123:  // Left — exit result focus, return to input field
                    if self.focusedAppPillIndex != nil || self.l2.focusedPillIndex != nil {
                        self.focusedAppPillIndex = nil
                        self.l2.focusedPillIndex = nil
                        self.l2.pillNavViaKeyboard = false
                        DispatchQueue.main.async { self.reclaimSearchInputFocus() }
                        return nil
                    }
                    return event
                case 53:  // Escape — collapse expanded sheet to compact typing; keep query
                    if self.globalContextViewModel.typingSnapshot.phase == .expanded {
                        // globalMenuResultsRevealed's setter re-derives the pre-expansion
                        // phase from the current match icons — single source of truth.
                        self.globalMenuResultsRevealed = false
                        self.focusedAppPillIndex = nil
                        self.l2.focusedPillIndex = nil
                        self.l2.pillNavViaKeyboard = false
                        // One resize back to the compact bar (mirror of the ↓ expansion).
                        self.requestWindowSizeUpdate(
                            reason: .modeChanged, animated: true, debounceNanoseconds: 0)
                        DispatchQueue.main.async { self.reclaimSearchInputFocus() }
                        return nil
                    }
                    if self.focusedAppPillIndex != nil || self.l2.focusedPillIndex != nil {
                        self.focusedAppPillIndex = nil
                        self.l2.focusedPillIndex = nil
                        self.l2.pillNavViaKeyboard = false
                        DispatchQueue.main.async { self.reclaimSearchInputFocus() }
                        return nil
                    }
                    return event
                case 48:  // Tab is handled above by explicit app-scope activation.
                    return nil
                case 51:  // Delete/Backspace — clear focus only (never quit apps)
                    if self.currentGlobalGroupedFocusIndex(state: state) != nil {
                        self.setGlobalGroupedFocus(nil, state: state)
                        return nil
                    }
                    return event
                default:
                    return event
                }
            }

            // ── App-pill row navigation (pinned/running or global app search) ──────────
            let hasActiveContextSel = self.hasSelectionScopeSurface
            // Use the same cached pill list the List View renders. Do not rebuild here;
            // this key monitor runs on every keyDown.
            let pillQuery = self.shouldUseFinderSearchPopover(for: q) ? "" : q
            // renderedOrderDockPills = the exact order the list renders (clustered),
            // with a fallback build while the debounced pipeline is mid-flight — so
            // ↑/↓ walk the rows in visual order and Enter runs the highlighted row.
            let actionPills: [DockPill] =
                q.isEmpty
                ? self.selectionScopedDockPills(self.cachedDockPills)
                : (pillQuery.isEmpty ? [] : self.renderedOrderDockPills(for: pillQuery))
            let showPinnedRow =
                q.isEmpty
                && self.l2.targetApp == nil
                && (actionPills.isEmpty || (self.isGlobalContextActive && !hasActiveContextSel))
            let globalGroupedRowCount =
                (self.shouldUsePureGlobalAppSearch || self.isActiveGlobalRunningAppMenuScope())
                ? self.visibleGlobalGroupedListNavigationState(for: q).totalCount
                : 0
            let hasGlobalAppMatches =
                self.isGlobalContextActive
                && (!q.isEmpty || self.currentGlobalScopedBundleID != nil)
                && (globalGroupedRowCount > 0
                    || (!self.isActiveGlobalRunningAppMenuScope()
                        && (!self.currentGlobalAppMatches(for: q).isEmpty
                            || self.pendingGlobalAppQuery == q)))
            let showGlobalAppSearch =
                self.shouldUsePureGlobalAppSearch
                && (!q.isEmpty || self.currentGlobalScopedBundleID != nil)
                && hasGlobalAppMatches
            let isAppPillRowActive = showPinnedRow || showGlobalAppSearch

            if isAppPillRowActive {
                let appPills = self.currentAppPillActions()
                guard !appPills.isEmpty || globalGroupedRowCount > 0 else { return event }

                switch event.keyCode {
                case 48:  // Tab — enter/exit app pill navigation; never let macOS Full Keyboard Navigation take over
                    if self.focusedAppPillIndex == nil {
                        self.focusedAppPillIndex = 0
                        self.l2.pillNavViaKeyboard = true
                    } else {
                        self.focusedAppPillIndex = nil
                        self.expandSearchBar()
                    }
                    return nil
                case 123:  // Left — mirror context dock: wrap to input field at start
                    guard self.focusedAppPillIndex != nil else { return event }
                    if self.usesVerticalListDockLayout {
                        self.focusedAppPillIndex = nil
                        self.l2.pillNavViaKeyboard = false
                        DispatchQueue.main.async { self.reclaimSearchInputFocus() }
                        return nil
                    }
                    let curLeft = self.focusedAppPillIndex ?? 0
                    if curLeft <= 0 {
                        self.focusedAppPillIndex = nil
                        self.expandSearchBar()
                        return nil
                    }
                    self.focusedAppPillIndex = curLeft - 1
                    return nil
                case 124:  // Right — vertical list: scope the focused app into a pill.
                    //          Horizontal pill row: move focus right / wrap to input.
                    if self.usesVerticalListDockLayout {
                        guard self.currentGlobalScopedBundleID == nil else { return event }
                        if self.searchInputHasHighlightedText() { return event }
                        let qq = self.searchState.query
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !qq.isEmpty else { return event }
                        let activated = self.scopeFocusedGlobalGroupedListRow()
                        guard activated else { return event }
                        self.focusedAppPillIndex = nil
                        self.l2.focusedPillIndex = nil
                        self.l2.pillNavViaKeyboard = false
                        self.clearSearchFieldEditorText()
                        self.reclaimSearchInputFocus()
                        DispatchQueue.main.async {
                            self.searchState.query = ""
                            self.clearSearchFieldEditorText()
                            self.reclaimSearchInputFocus()
                        }
                        return nil
                    }
                    if self.searchInputHasHighlightedText() {
                        self.focusedAppPillIndex = nil
                        return event
                    }
                    guard self.focusedAppPillIndex != nil else { return event }
                    let curIdx = self.focusedAppPillIndex ?? -1
                    if curIdx >= appPills.count - 1 {
                        self.focusedAppPillIndex = nil
                        self.expandSearchBar()
                        return nil
                    }
                    self.focusedAppPillIndex = curIdx + 1
                    return nil
                case 125:  // Down — navigate app list in List View; otherwise Global → Context → Media
                    if self.usesVerticalListDockLayout {
                        _ = self.moveGlobalAppResultFocus(
                            direction: self.settings.effectiveDockAtBottom ? -1 : 1
                        )
                        return nil
                    }
                    guard q.isEmpty,
                        self.focusedAppPillIndex == nil,
                        self.l2.focusedPillIndex == nil
                    else { return event }
                    self.switchDockLayer(.down)
                    return nil
                case 126:  // Up — navigate app list in List View; otherwise Media → Context → Global
                    if self.usesVerticalListDockLayout {
                        _ = self.moveGlobalAppResultFocus(
                            direction: self.settings.effectiveDockAtBottom ? 1 : -1
                        )
                        return nil
                    }
                    guard q.isEmpty,
                        self.focusedAppPillIndex == nil,
                        self.l2.focusedPillIndex == nil
                    else { return event }
                    self.switchDockLayer(.up)
                    return nil
                case 36:  // Enter — launch/activate
                    if (self.shouldUsePureGlobalAppSearch || self.isActiveGlobalRunningAppMenuScope()),
                        globalGroupedRowCount > 0,
                        self.executeFocusedGlobalGroupedListRow()
                    {
                        self.hideLauncherAfterResultExecution()
                        return nil
                    }
                    if let idx = self.focusedAppPillIndex, idx < appPills.count {
                        appPills[idx].execute()
                        self.searchState.query = ""
                        self.focusedAppPillIndex = nil
                        self.hideLauncherAfterResultExecution()
                        return nil
                    }
                    // Render-default: first row is shown pre-selected (focusedAppPillIndex nil) while
                    // typing — Enter launches it (the ghost top result), matching the highlight.
                    if !self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty,
                        let first = appPills.first
                    {
                        first.execute()
                        self.searchState.query = ""
                        self.focusedAppPillIndex = nil
                        self.hideLauncherAfterResultExecution()
                        return nil
                    }
                    return event
                case 51:  // Delete/Backspace — clear focus, return to input (never quit apps)
                    if self.focusedAppPillIndex != nil {
                        self.focusedAppPillIndex = nil
                        self.l2.pillNavViaKeyboard = false
                        DispatchQueue.main.async { self.reclaimSearchInputFocus() }
                        return nil
                    }
                    return event
                case 53:  // Escape — mirror context dock: clear focus and re-expand input
                    if self.focusedAppPillIndex != nil {
                        self.focusedAppPillIndex = nil
                        self.expandSearchBar()
                        return nil
                    }
                    return event
                default:
                    return event
                }
            }

            let pills = actionPills
            guard !pills.isEmpty else { return event }

            switch event.keyCode {
            case 48:  // Tab — return focus to search field (prevents macOS Full Keyboard Navigation takeover)
                self.l2.focusedPillIndex = nil
                self.l2.pillNavViaKeyboard = false
                DispatchQueue.main.async { self.isSearchFieldFocused = true }
                return nil

            case 123:  // Left arrow — move focus left; wrap to input field at start
                guard self.l2.focusedPillIndex != nil else { return event }
                if self.usesVerticalListDockLayout {
                    self.l2.focusedPillIndex = nil
                    self.l2.pillNavViaKeyboard = false
                    DispatchQueue.main.async { self.reclaimSearchInputFocus() }
                    return nil
                }
                let curLeft = self.l2.focusedPillIndex ?? 0
                if curLeft <= 0 {
                    // Already at first pill — return focus to input field
                    self.l2.focusedPillIndex = nil
                    self.l2.pillNavViaKeyboard = false
                    DispatchQueue.main.async { self.isSearchFieldFocused = true }
                    return nil
                }
                self.l2.pillNavViaKeyboard = true
                var idx = max(0, curLeft - 1)
                while idx > 0 && pills[idx].isSeparator { idx -= 1 }
                self.l2.focusedPillIndex = idx
                return nil

            case 124:  // Right arrow — move focus right (skip separators); wrap to input at end
                if self.searchInputHasHighlightedText() {
                    self.l2.focusedPillIndex = nil
                    self.l2.pillNavViaKeyboard = false
                    return event
                }
                guard self.l2.focusedPillIndex != nil else { return event }
                let curIdx = self.l2.focusedPillIndex ?? -1
                if curIdx >= pills.count - 1 {
                    // Already at last pill — return focus to input field
                    self.l2.focusedPillIndex = nil
                    self.l2.pillNavViaKeyboard = false
                    DispatchQueue.main.async { self.isSearchFieldFocused = true }
                    return nil
                }
                self.l2.pillNavViaKeyboard = true
                var idx = min(pills.count - 1, curIdx + 1)
                while idx < pills.count - 1 && pills[idx].isSeparator { idx += 1 }
                self.l2.focusedPillIndex = idx
                return nil

            case 125:  // Down — navigate pills when focused, else pass through to SwiftUI
                // Never navigate the coordinator's temporary preview array. Its final
                // result can have a different order, which makes an index highlight a
                // different action and causes the visible jump seen during loading.
                if self.usesVerticalListDockLayout,
                    self.pendingDockPillQuery == q,
                    self.dockPillBuildTask != nil
                {
                    self.contextDockViewModel.queuedPillNavigationDelta += 1
                    self.contextDockViewModel.queuedPillNavigationGeneration =
                        self.dockPillBuildGeneration
                    return nil
                }
                if self.usesVerticalListDockLayout, !pills.isEmpty {
                    if self.settings.effectiveDockAtBottom {
                        guard let cur = self.l2.focusedPillIndex else { return event }
                        if cur <= 0 {
                            self.l2.focusedPillIndex = nil
                            self.l2.pillNavViaKeyboard = false
                            DispatchQueue.main.async { self.reclaimSearchInputFocus() }
                            return nil
                        }
                        var downIdx = cur - 1
                        while downIdx > 0 && pills[downIdx].isSeparator { downIdx -= 1 }
                        self.l2.pillNavViaKeyboard = true
                        self.l2.focusedPillIndex = downIdx
                        return nil
                    }
                    // The first selectable pill is shown pre-selected (render default) while typing
                    // even though focusedPillIndex is nil. Treat that as the current position so the
                    // first Down advances to the SECOND result instead of re-selecting the first.
                    let defaultStart =
                        (!q.isEmpty && self.l2.focusedPillIndex == nil)
                        ? (pills.firstIndex(where: { !$0.isSeparator }) ?? -1)
                        : -1
                    let curIdx = self.l2.focusedPillIndex ?? defaultStart
                    var downIdx = curIdx + 1
                    while downIdx < pills.count && pills[downIdx].isSeparator { downIdx += 1 }
                    if downIdx < pills.count {
                        self.l2.pillNavViaKeyboard = true
                        self.l2.focusedPillIndex = downIdx
                        return nil
                    }
                }
                return event  // pass through → SwiftUI navigateResults(direction:1)

            case 126:  // Up — navigate pills when focused, else pass through to SwiftUI
                if q.isEmpty && self.showGlobalClipboardPill && !self.globalClipboardText.isEmpty
                    && !self.isSearchBarExpanded
                {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                        self.clipboardHistoryExpanded.toggle()
                    }
                    return nil
                }
                if self.usesVerticalListDockLayout,
                    self.pendingDockPillQuery == q,
                    self.dockPillBuildTask != nil
                {
                    self.contextDockViewModel.queuedPillNavigationDelta -= 1
                    self.contextDockViewModel.queuedPillNavigationGeneration =
                        self.dockPillBuildGeneration
                    return nil
                }
                if self.usesVerticalListDockLayout, !pills.isEmpty {
                    if self.settings.effectiveDockAtBottom {
                        let curIdx = self.l2.focusedPillIndex ?? -1
                        var upIdx = curIdx + 1
                        while upIdx < pills.count && pills[upIdx].isSeparator { upIdx += 1 }
                        if upIdx < pills.count {
                            self.l2.pillNavViaKeyboard = true
                            self.l2.focusedPillIndex = upIdx
                            return nil
                        }
                        return nil
                    }
                    // Stop at the first selectable pill: Up from there returns to the input with the
                    // query selected (Spotlight-style), since the first pill is the default selection.
                    let firstSelectable = pills.firstIndex(where: { !$0.isSeparator }) ?? 0
                    if let cur = self.l2.focusedPillIndex, cur > firstSelectable {
                        var upIdx = cur - 1
                        while upIdx > firstSelectable && pills[upIdx].isSeparator { upIdx -= 1 }
                        self.l2.pillNavViaKeyboard = true
                        self.l2.focusedPillIndex = upIdx
                    } else {
                        DispatchQueue.main.async { self.reclaimSearchInputFocusSelectingAll() }
                    }
                    return nil
                }
                return event  // pass through → SwiftUI navigateResults(direction:-1)

            case 36:  // Return / Enter
                if let findToken = self.lockedFindToken {
                    let payload = self.searchState.query.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    self.executeFindToken(findToken, userMessage: "find \(payload)")
                    return nil
                }
                // Submenu ghost: Enter executes the first matching child
                if let subCtx = self.submenuGhostContext, let firstChild = subCtx.children.first {
                    let frontPID = AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
                    let pid = firstChild.sourcePID != 0 ? firstChild.sourcePID : frontPID
                    self.searchState.query = ""
                    self.lockedSubmenuParent = nil
                    self.executeDockMenuAction(
                        sourcePID: pid, path: firstChild.path,
                        shortcutChar: firstChild.shortcutChar,
                        shortcutModifiers: firstChild.shortcutModifiers
                    )
                    return nil
                }
                if self.l2.focusedPillIndex != nil, self.executeFocusedOrDirectAppPillIfNeeded() {
                    return nil
                }

                // Finder desktop scope is FILE SEARCH — Enter opens the highlighted file/folder
                // result (Spotlight-like), never launches a typed app match. Falling through to
                // launchTypedAppMatchIfNeeded here would fuzzy-launch e.g. "applica" → App Store.
                if self.isFinderDesktopOnlyMode {
                    if self.executeFirstVisibleFinderDesktopPillIfNeeded() { return nil }
                    return event
                }

                if self.executeFirstMatchingFinderFolderPillIfNeeded() {
                    return nil
                }

                if self.executeFirstAttachedFinderFolderResultIfNeeded() {
                    return nil
                }

                if self.launchTypedAppMatchIfNeeded() {
                    return nil
                }

                if self.executeFocusedOrDirectAppPillIfNeeded() {
                    return nil
                }

                return event

            case 53:  // Escape — clear pill focus and return to input field
                if self.lockedFindToken != nil {
                    self.clearFindToken(preserveQuery: true)
                    return nil
                }
                if self.l2.focusedPillIndex != nil {
                    self.l2.focusedPillIndex = nil
                    self.l2.pillNavViaKeyboard = false
                    DispatchQueue.main.async { self.isSearchFieldFocused = true }
                    return nil
                }
                return event

            case 51:  // Delete/Backspace — deselect focused action pill and return to input field
                if self.l2.focusedPillIndex != nil {
                    self.l2.focusedPillIndex = nil
                    self.l2.pillNavViaKeyboard = false
                    DispatchQueue.main.async { self.isSearchFieldFocused = true }
                    return nil
                }
                return event

            default:
                return event
            }
        }
    }

    // MARK: - Cmd long-press → shortcut sheet

    /// Holds Cmd ≥ 1.5 s without pressing any other key → shows the shortcut sheet.
    func setupCmdHoldMonitor() {
        if let m = cmdHoldMonitor {
            NSEvent.removeMonitor(m)
            cmdHoldMonitor = nil
        }
        if let m = cmdHoldGlobalMonitor {
            NSEvent.removeMonitor(m)
            cmdHoldGlobalMonitor = nil
        }

        cmdHoldMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [self] event in
            if GlassFloatingPanel.ownsEvent(event) { return event }
            if FileQuickLookPanel.shared.ownsEvent(event) { return event }
            if event.type == .keyDown {
                // Any keyDown while Cmd held → cancel the long-press timer
                cmdHoldTask?.cancel()
                cmdHoldTask = nil
                if event.modifierFlags.contains(.command) {
                    cmdChordUsed = true
                }

                // Shortcut passthrough: when L2 context dock is open, forward Cmd+key combos
                // to the frontmost app using liveMenuItems shortcut index — no focus switch needed.
                let routingMode = keyRoutingMode
                if routingMode == .contextDock || routingMode == .globalContext,
                    event.modifierFlags.contains(.command),
                    let ch = event.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty,
                    let targetApp = AppDelegate.shared?.previousFrontmostApp
                {
                    let pid = targetApp.processIdentifier
                    let shift = event.modifierFlags.contains(.shift) ? 1 : 0
                    let option = event.modifierFlags.contains(.option) ? 2 : 0
                    let control = event.modifierFlags.contains(.control) ? 4 : 0
                    let mods = shift | option | control
                    // Look up the matching menu item shortcut in the live cache
                    let match = liveMenuItems.first { item in
                        item.shortcutChar?.lowercased() == ch && item.shortcutModifiers == mods
                    }
                    if let item = match, item.isEnabled {
                        self.executeDockMenuAction(
                            sourcePID: pid,
                            path: item.path,
                            shortcutChar: item.shortcutChar,
                            shortcutModifiers: item.shortcutModifiers
                        )
                        return nil  // consume — don't pass to dock's text field
                    }
                }

                return event
            }

            // flagsChanged
            let cmdDown =
                event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.shift)
                && !event.modifierFlags.contains(.option)
                && !event.modifierFlags.contains(.control)

            if cmdDown {
                // ⌘ long-press (Shortcut Sheet) removed — ⌘ only TAP-toggles scope now. Arm the
                // tap; no hold task is scheduled.
                if !cmdTapArmed {
                    cmdTapArmed = true
                    cmdChordUsed = false
                    cmdHoldTriggered = false
                }
            } else {
                // Cmd released — bare tap toggles Context Dock ↔ Global Context.
                let shouldToggleScope =
                    cmdTapArmed
                    && !cmdChordUsed
                    && !cmdHoldTriggered

                cmdHoldTask?.cancel()
                cmdHoldTask = nil
                cmdTapArmed = false
                cmdChordUsed = false
                cmdHoldTriggered = false

                if shouldToggleScope {
                    handleCommandKeyContextScopeToggle()
                    return nil
                }
            }
            return event
        }

        cmdHoldGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .flagsChanged, .keyDown,
        ]) {
            [self] event in
            guard !NSApp.isActive else { return }

            if event.type == .keyDown {
                cmdHoldTask?.cancel()
                cmdHoldTask = nil
                if event.modifierFlags.contains(.command) {
                    cmdChordUsed = true
                }
                return
            }

            let cmdDown =
                event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.shift)
                && !event.modifierFlags.contains(.option)
                && !event.modifierFlags.contains(.control)

            if cmdDown {
                // ⌘ long-press (Shortcut Sheet) removed — arm tap only, no hold task.
                if !cmdTapArmed {
                    cmdTapArmed = true
                    cmdChordUsed = false
                    cmdHoldTriggered = false
                }
            } else {
                cmdTapArmed = false
                cmdChordUsed = false
                cmdHoldTriggered = false
            }
        }
    }

    func updateWindowSize(
        animated: Bool = true,
        debounceNanoseconds: UInt64 = 50_000_000
    ) {
        // Cancel any previously scheduled resize — coalesce rapid calls (e.g. every result update)
        windowResizeTask?.cancel()
        windowResizeTask = Task { @MainActor in
            // Debounce absorbs burst calls. Result-list churn uses a wider debounce and no frame
            // animation so typing stays visually locked while ranking/list height settles.
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard !self.suppressOpenResize else { return }

            guard let window = AppDelegate.shared?.launcherWindow
            else {
                return
            }
            guard window.isVisible else { return }
            // Bottom dock mode is removed. A stale KeyableWindow.anchorAtBottom flag
            // rewrites setFrame(_:) to keep the bottom edge fixed, which makes the
            // input pill slide down when a short result sheet shrinks. Force top
            // anchoring here so only the result area changes height.
            if let keyableWindow = window as? KeyableWindow {
                keyableWindow.anchorAtBottom = false
            }

            let heightSignpost = SearchPerformanceLog.shared.beginInterval(
                "window.heightUpdate",
                query: searchState.query
            )
            defer {
                SearchPerformanceLog.shared.endInterval(
                    "window.heightUpdate", state: heightSignpost)
            }

            let heightPreset = self.currentDockHeightPreset
            let surfaceMode = self.currentDockSurfaceMode
            let newHeight = self.calculatedHeight
            let newWidth = self.calculatedWidth
            let currentFrame = window.frame
            let screen = window.screen ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

            let presetChanged = self.lastAppliedDockHeightPreset != heightPreset
            let modeChanged = self.lastAppliedDockSurfaceMode != surfaceMode
            // Global Context collapsing and expanding is a surface transition, but neither
            // check above sees it: the preset is already .large (any result count sets it,
            // so it flips on the first keystroke, long before the sheet opens) and the mode
            // stays .globalContext throughout. So the expand took the "typing" branch — a
            // bare yield instead of the content-commit delay — and revealed an empty sheet
            // with the rows popping in after, which is the exact case the delay exists for.
            let globalPhase = self.globalContextViewModel.typingSnapshot.phase
            let globalPhaseChanged = self.lastAppliedGlobalTypingPhase != globalPhase
            // A reveal in flight owns the frame. Row churn (icons resolving, a late menu
            // group) must not interrupt it with a second setFrame — that is the "expands,
            // stops, expands again" stutter. It settles on the next request instead.
            if let keyableWindow = window as? KeyableWindow,
                keyableWindow.isAnimatingDockFrame,
                !presetChanged,
                !modeChanged
            {
                return
            }
            let widthChanged = abs(currentFrame.width - newWidth) > 1
            let heightDelta = abs(currentFrame.height - newHeight)
            if heightPreset.stabilizesResize
                && !presetChanged
                && !modeChanged
                && !widthChanged
                && heightDelta <= 24
            {
                return
            }

            // Only update if size actually changed
            guard heightDelta > 1 || widthChanged
            else {
                self.lastAppliedDockHeightPreset = heightPreset
                self.lastAppliedDockSurfaceMode = surfaceMode
                return
            }

            // Smart vertical positioning — keep anchor point stable so window doesn't jump
            let spaceBelow = currentFrame.minY - visibleFrame.minY
            let spaceAbove = visibleFrame.maxY - currentFrame.maxY

            let resizeAnchorX: CGFloat
            if let keyableWindow = window as? KeyableWindow {
                resizeAnchorX = keyableWindow.horizontalResizeAnchorX ?? currentFrame.midX
                keyableWindow.horizontalResizeAnchorX = resizeAnchorX
            } else {
                resizeAnchorX = currentFrame.midX
            }
            let proposedX = resizeAnchorX - (newWidth / 2)
            let horizontalMargin: CGFloat = 12
            let minX = visibleFrame.minX + horizontalMargin
            let maxX = visibleFrame.maxX - newWidth - horizontalMargin
            let newX = min(max(proposedX, minX), max(minX, maxX))

            _ = spaceBelow
            _ = spaceAbove
            var effectiveHeight = newHeight
            let newY: CGFloat
            if settings.effectiveDockAtBottom {
                // Bottom-anchored: grow upward, keep bottom edge fixed
                newY = currentFrame.minY
            } else {
                // Spotlight model: keep the TOP edge fixed at the window's PINNED top (set once on
                // open/drag), never derived from the live frame. CRUCIAL: cap the height to the
                // space below that top so the window never extends past the screen bottom —
                // otherwise the setFrame chokepoint pins the top off-screen, macOS constrains the
                // panel back onto the screen, and THAT repositioning is the input-bar jump. A
                // longer result list scrolls inside its own panel instead of growing the window.
                let keyableWindow = window as? KeyableWindow
                let topAnchor = keyableWindow?.pinnedTopY ?? currentFrame.maxY
                keyableWindow?.pinnedTopY = topAnchor
                let available = topAnchor - visibleFrame.minY - 8
                effectiveHeight = min(newHeight, max(heightPreset.minimumHeight, available))
                newY = topAnchor - effectiveHeight
            }

            let newFrame = NSRect(x: newX, y: newY, width: newWidth, height: effectiveHeight)

            // Keep the shell and its host in lockstep.  The old implementation grew the
            // transparent NSPanel first and then animated a shorter SwiftUI card inside it. That
            // exposed an empty half-sheet and, while the host was taller than the card, SwiftUI's
            // fallback alignment could momentarily re-centre the input/icon.  Spotlight-style
            // launchers do not animate two independent geometries: they prepare the final surface
            // and commit one anchored panel frame.  A single yield lets SwiftUI accept the new
            // content frame before it can become visible outside the old host; it is one pass per
            // real size change, never on each search result.
            var noAnimation = Transaction()
            noAnimation.animation = nil
            withTransaction(noAnimation) {
                self.renderedDockHeight = effectiveHeight
            }
            // Collapsed capsule ⇄ result sheet is a surface transition: the panel animates
            // it as one motion. Everything else (typing, a row appearing) stays instant so
            // the dock never appears to lag behind the keyboard.
            let isSurfaceTransition =
                animated && (presetChanged || modeChanged || globalPhaseChanged)
            if isSurfaceTransition {
                // The list is a LazyVStack clipped to zero height until it expands, so its
                // rows do not exist in the frame where the transition begins. Give SwiftUI
                // one commit to lay them out at the final height — off-window, invisible —
                // then let the panel reveal finished content. Without this the reveal shows
                // an empty sheet first and the rows pop in afterwards.
                try? await Task.sleep(nanoseconds: KeyableWindow.dockContentCommitDelay)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled, window.isVisible else { return }

            if let keyableWindow = window as? KeyableWindow {
                keyableWindow.applyDockFrame(newFrame, animated: isSurfaceTransition)
            } else {
                window.setFrame(newFrame, display: true)
            }
            // Transparent window: recompute the macOS drop-shadow for the new glass
            // shape, otherwise it lags / keeps the old outline as the dock resizes.
            window.invalidateShadow()

            self.lastAppliedDockHeightPreset = heightPreset
            self.lastAppliedDockSurfaceMode = surfaceMode
            self.lastAppliedGlobalTypingPhase = globalPhase

            // SwiftUI's @FocusState reconciliation fires asynchronously after setFrame and
            // calls becomeFirstResponder → selectAll on the NSTextField.
            // Two DispatchQueue.main.async ticks puts us after that reconciliation pass so
            // we can collapse any unwanted selection to an insertion point at the end.
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    guard let fe = window.fieldEditor(false, for: nil) as? NSTextView else {
                        return
                    }
                    let len = (fe.string as NSString).length
                    if fe.selectedRange().length > 0, len > 0 {
                        fe.setSelectedRange(NSRange(location: len, length: 0))
                    }
                }
            }
        }
    }

    var contentKeyHandlersView: some View {
        contentNotificationHandlersView
            .onExitCommand {
                // Layer overlays close first
                if showMediaLayer {
                    withAnimation(.dockSheet) {
                        showMediaLayer = false
                    }
                    return
                }
                if showAIExtensionSuggestions {
                    withAnimation(.spring(response: 0.3)) {
                        showAIExtensionSuggestions = false
                    }
                    return
                }
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
                // App scope: exit scope, close dock, switch to scoped app
                if let targetInfo = l2.targetApp {
                    let bundleId = targetInfo.bundleId
                    clearSearchContext()
                    AppDelegate.shared?.hideLauncher()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        let app =
                            NSWorkspace.shared.runningApplications.first {
                                $0.bundleIdentifier == bundleId && !$0.isTerminated
                            } ?? AppDelegate.shared?.previousFrontmostApp
                        app?.activate(options: [.activateIgnoringOtherApps])
                    }
                    return
                }
                // Smart panel / search context: exit back to normal search, keep dock open
                if searchState.activeSmartQueryKey != nil || searchState.contextApp != nil {
                    clearSearchContext()
                    remPanelIsProcessing = false
                    remIsInstalled = nil
                    systemDataResults = []
                    searchState.lastSmartQuery = ""
                    return
                }
                // Pills / results highlighted: clear selection, return focus to search field
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
                // Nothing active: close dock and return to previous app
                onClose()
            }
            .onKeyPress(.upArrow) {
                // Quick Note split editor owns arrows (cursor / list); never switch layer.
                if activeNotepadScopeCommand != nil { return .ignored }
                if isGlobalContextActive,
                    shouldUsePureGlobalAppSearch,
                    !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    _ = moveGlobalGroupedListFocus(
                        direction: settings.effectiveDockAtBottom ? 1 : -1
                    )
                    return .handled
                }
                if isGlobalContextActive,
                    isSearchFieldFocused,
                    focusedAppPillIndex == nil,
                    l2.focusedPillIndex == nil,
                    searchState.selectedIndex == nil
                {
                    return .handled
                }
                if searchState.activeSmartQueryKey == "clipboard" {
                    if NSEvent.modifierFlags.contains(.command) {
                        extendClipboardSelection(direction: -1)
                        return .handled
                    }
                    if clipboardSourcePillFocusIndex != nil {
                        clipboardSourcePillFocusIndex = nil
                        isKeyboardNavigation = false
                        isSearchFieldFocused = true
                        return .handled
                    }
                    navigateClipboardScope(direction: -1)
                    return .handled
                }
                if searchState.activeSmartQueryKey == "notifications" {
                    guard searchState.selectedIndex != nil else { return .handled }
                    if searchState.selectedIndex == 0 {
                        withAnimation(.dockStandard) {
                            searchState.selectedIndex = nil
                            isKeyboardNavigation = false
                            isSearchFieldFocused = true
                        }
                        return .handled
                    }
                    navigateResults(direction: -1)
                    return .handled
                }
                if !showFolderPreview {
                    navigateResults(direction: -1)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.downArrow) {
                // Quick Note split editor owns arrows (cursor / list); never switch layer.
                if activeNotepadScopeCommand != nil { return .ignored }
                // ↓ is what opens the result sheet — in an app-scope capsule and in the
                // frontmost Context Dock alike. Until then only the inline ghost shows, so
                // typing never throws the list open.
                if !isDockResultSheetRevealed,
                    showContextInDock,
                    !aiMode.isActive,
                    !isCompactSmartScope,
                    !hasSelectionScopeSurface,
                    !isFinderDesktopOnlyMode,
                    !isInCLIToolScope,
                    !isContextDockChatRoutingLocked,
                    isActiveGlobalRunningAppMenuScope()
                        || (!isGlobalContextActive
                            && !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty)
                {
                    expandScopedCapsuleSheet(selectFirst: true)
                    return .handled
                }
                if isGlobalContextActive,
                    shouldUsePureGlobalAppSearch,
                    !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    if globalContextViewModel.typingSnapshot.phase != .expanded {
                        if expandGlobalContextTypingMatch(selectFirst: true) {
                            return .handled
                        }
                        return .handled
                    }

                    _ = moveGlobalGroupedListFocus(
                        direction: settings.effectiveDockAtBottom ? -1 : 1
                    )
                    return .handled
                }
                if showContextInDock, isGlobalContextActive, !aiMode.isActive {
                    let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    // File/text selection chip is showing: Down arrow moves focus into the action pills
                    // instead of dismissing the context (let the user act on the selected file via keyboard)
                    let hasSelection =
                        frozenSelectionText != nil
                        || !effectiveFinderSelectionURLsForPills().isEmpty
                    if hasSelection && l2.focusedPillIndex == nil {
                        let pills = buildDockPills(query: q)
                        if !pills.isEmpty {
                            l2.pillNavViaKeyboard = true
                            var idx = 0
                            while idx < pills.count - 1 && pills[idx].isSeparator { idx += 1 }
                            l2.focusedPillIndex = idx
                            return .handled
                        }
                    }
                    // Only an empty input field switches layers. Typed global queries keep
                    // the current dock so Down can navigate visible results/menus.
                    if q.isEmpty && l2.focusedPillIndex == nil && focusedAppPillIndex == nil {
                        switchDockLayer(.down)
                        return .handled
                    }
                }
                if searchState.activeSmartQueryKey == "clipboard" {
                    if NSEvent.modifierFlags.contains(.command) {
                        extendClipboardSelection(direction: 1)
                        return .handled
                    }
                    if clipboardSourcePillFocusIndex == nil,
                        focusedClipboardEntryIndex == nil,
                        searchState.selectedIndex == nil
                    {
                        focusFirstClipboardSourcePill()
                        return .handled
                    }
                    if clipboardSourcePillFocusIndex != nil {
                        clipboardSourcePillFocusIndex = nil
                    }
                    navigateClipboardScope(direction: 1)
                    return .handled
                }
                if searchState.activeSmartQueryKey == "notifications" {
                    navigateResults(direction: 1)
                    return .handled
                }
                if !showFolderPreview {
                    navigateResults(direction: 1)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.space) {
                // Quick Note editor: space is text — never steal it back to the input.
                if activeNotepadScopeCommand != nil { return .ignored }
                if !allGlobalInlineAppScopes.isEmpty && !isSearchFieldFocused {
                    searchState.query.append(" ")
                    reclaimSearchInputFocus()
                    resetCollapseTimer()
                    return .handled
                }

                if searchState.activeSmartQueryKey == "clipboard" {
                    guard focusedClipboardEntryIndex != nil || isKeyboardNavigation else {
                        return .ignored
                    }
                    quickLookFocusedClipboardEntry()
                    return .handled
                }

                // Close contact preview if it's showing
                if showContactPreview {
                    withAnimation {
                        showContactPreview = false
                        contactPreviewData = nil
                    }
                    return .handled
                }

                // Only handle space for Quick Look when the search field is NOT focused
                // This allows typing spaces in the search field
                if !showFolderPreview && !isSearchFieldFocused && searchState.selectedIndex != nil
                    && !searchState.results.isEmpty
                {
                    quickLookSelectedItem()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [.init("y")], phases: .down) { keyPress in
                // Cmd+Y for Quick Look (like Finder)
                if keyPress.modifiers.contains(.command) && !showFolderPreview
                    && searchState.selectedIndex != nil && !searchState.results.isEmpty
                {
                    quickLookSelectedItem()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.return) {
                // Quick Note editor: Return / Shift+Return insert a newline.
                if activeNotepadScopeCommand != nil { return .ignored }
                if !showFolderPreview {
                    if executeScopedRunningAppIfIdle() {
                        return .handled
                    }
                    // Submenu ghost: Enter executes the first matching child directly
                    if let subCtx = submenuGhostContext, let firstChild = subCtx.children.first {
                        let frontPID =
                            AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
                        let pid = firstChild.sourcePID != 0 ? firstChild.sourcePID : frontPID
                        searchState.query = ""
                        lockedSubmenuParent = nil
                        executeDockMenuAction(
                            sourcePID: pid, path: firstChild.path,
                            shortcutChar: firstChild.shortcutChar,
                            shortcutModifiers: firstChild.shortcutModifiers
                        )
                        return .handled
                    }
                    // Execute inline pill ghost completion if available
                    if let ghost = ghostPillCompletion {
                        ghost.execute()
                        searchState.query = ""
                        l2.focusedPillIndex = nil
                        return .handled
                    }
                    if isCLIToolScopeLocked {
                        let trimmed = searchState.query.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return .handled }
                        if let target = currentGlobalScopedChatTarget {
                            armGlobalScopedChat(appName: target.appName, bundleId: target.bundleId)
                            dismissMediaLayer()
                            handleL2QuerySkippingMenuRouter(trimmed)
                        }
                        return .handled
                    }
                    if isL2ContextActive,
                        l2.focusedPillIndex != nil,
                        executeFocusedOrDirectAppPillIfNeeded()
                    {
                        return .handled
                    }
                    if isL2ContextActive, executeFirstMatchingFinderFolderPillIfNeeded() {
                        return .handled
                    }
                    // Finder desktop scope never launches a typed app — file search only.
                    if isFinderDesktopOnlyMode {
                        if executeFirstVisibleFinderDesktopPillIfNeeded() { return .handled }
                        return .handled
                    }
                    // Enter runs the row the user is looking at. The highlighted row is what
                    // the leading icon and the ghost are both drawn from, and
                    // executeFocusedGlobalGroupedListRow is the accessor that reads it —
                    // three NSEvent monitors already use it.
                    //
                    // This handler reached launchTypedAppMatchIfNeeded first, which resolves
                    // an app from the *typed text* through L2AppActionRouter: a fourth
                    // resolver, independent of the icon, the ghost and Tab. So "remi" could
                    // show Reminders and launch something else, and which happened depended
                    // on whether this handler or a monitor saw the key first.
                    if isGlobalContextActive, executeFocusedGlobalGroupedListRow() {
                        return .handled
                    }
                    if launchTypedAppMatchIfNeeded() {
                        return .handled
                    }
                    if searchState.activeSmartQueryKey == "clipboard" {
                        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if q.isEmpty {
                            _ = pasteFocusedClipboardEntriesToFrontmost()
                        } else {
                            _ = submitClipboardScopeAIQuery(q)
                        }
                        return .handled
                    }
                    // Only explicit chat mode routes Enter to AI. App panels stay menu-first.
                    let isAIAppPanel =
                        searchState.contextApp != nil || searchState.activeSmartQueryKey != nil
                    if isAIAppPanel
                        && (l2.chatArmed || l2.showChatPopover)
                        && !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    {
                        handleRemPanelQuery()
                        return .handled
                    } else if isL2ContextActive {
                        // NSEvent monitor handles Enter when pills exist (returns nil, consuming the event).
                        // We only reach here when no pills are visible — escalate to AI.
                        let trimmed = searchState.query.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return .handled }
                        if shouldShowSelectionCompactAIAction
                            || shouldShowContextDockAIQueryFallback
                        {
                            runCompactAIActionFromInput()
                            return .handled
                        }
                        // Send when arming the chat (first message, before the sheet opens) AND when a
                        // conversation is already open — otherwise once showChatPopover is true every
                        // follow-up Enter fell through to `.handled` below and was silently dropped.
                        if l2.chatArmed
                            || shouldShowContextDockChatSheet
                            || shouldShowContextDockAIQueryFallback
                        {
                            dismissMediaLayer()
                            handleL2QuerySkippingMenuRouter(trimmed)
                            return .handled
                        }
                        if executeFirstMatchingFinderFolderPillIfNeeded() {
                            return .handled
                        }
                        // Normal Context Dock is menu-first. AI chat only sends after the
                        // user explicitly connects chat with the right-side control.
                        return .handled
                    } else if aiMode.isActive {
                        submitAIQuery()
                    } else {
                        // L1/L2: Execute selected result
                        executeSelectedResult()
                    }
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.tab) {
                if activeNotepadScopeCommand != nil { return .ignored }
                if isL2ContextActive && !isGlobalContextActive {
                    return .handled
                }

                // Tab on submenu ghost — lock parent if not yet locked; execute if already locked
                if let subCtx = submenuGhostContext, !subCtx.children.isEmpty {
                    if lockedSubmenuParent == nil {
                        // First Tab: lock the parent as a chip, clear all app-detection state
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                            lockedSubmenuParent = subCtx.parent
                            searchState.query = ""
                        }
                        l2.appCompletion = nil
                        l2.showResultsPopover = false
                        crossAppMenuItems = []
                        cachedDockPills = []
                        return .handled
                    } else if let firstChild = subCtx.children.first {
                        // Already locked + Tab: execute the highlighted child
                        let frontPID =
                            AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
                        let pid = firstChild.sourcePID != 0 ? firstChild.sourcePID : frontPID
                        let path = firstChild.path
                        let sc = firstChild.shortcutChar
                        let mod = firstChild.shortcutModifiers
                        searchState.query = ""
                        lockedSubmenuParent = nil
                        executeDockMenuAction(
                            sourcePID: pid, path: path, shortcutChar: sc, shortcutModifiers: mod)
                        return .handled
                    }
                }
                // Tab accepts pill ghost completion (prefix match on pill name)
                if let ghost = ghostPillCompletion {
                    searchState.query = ghost.name
                    return .handled
                }

                // L1 mode: Tab fills ghost from selected result when it's a prefix match.
                if !isL2ContextActive, !isGlobalContextActive {
                    let typed = searchState.query.trimmingCharacters(in: .whitespaces)
                    if !typed.isEmpty,
                        let idx = searchState.selectedIndex,
                        idx < searchState.results.count
                    {
                        let result = searchState.results[idx]
                        if result.title.lowercased().hasPrefix(typed.lowercased()) {
                            searchState.query = result.title
                            return .handled
                        }
                    }
                }

                // Global context: Tab fills ghost text from top/focused match.
                // Scope resolves inline from query — no dock switch.
                if isGlobalContextActive {
                    let q = searchState.query.trimmingCharacters(in: .whitespaces)
                    if !q.isEmpty {
                        // Match the event-monitor path: complete the visible app name before
                        // turning it into a scope chip. Tab and Right Arrow now share one
                        // completion transaction.
                        if acceptTopGlobalAppGhostCompletionIfPossible() {
                            return .handled
                        }
                        // Tab completes whatever the input is ghosting, which is the row
                        // under the highlight. That logic already exists and Right Arrow uses
                        // it: it follows the visible selection, enters the scope for a
                        // syscmd:// or cli:// row, and fills the title for an app.
                        //
                        // Tab used to run its own lookup instead — focused-or-top *app*
                        // result — and system commands live in appResults alongside apps. So
                        // with "Screenshots · System Command" highlighted and ghosted, Tab
                        // skipped it and filled the first app in the list: typing "scree"
                        // ghosted "screenshot" and completed to "iPhone Mirroring".
                        //
                        // One implementation for both keys, so they cannot disagree about
                        // what the user is pointing at.
                        if acceptTopGlobalAppGhostCompletionIfPossible() {
                            return .handled
                        }
                        let hit =
                            focusedGlobalAppResultForInputPreview()
                            ?? topGlobalAppResultForInputPreview()
                        if let result = hit {
                            if let bundleId = bundleIdentifier(forApplicationResult: result),
                                activateGlobalInlineScope(result: result, bundleID: bundleId)
                            {
                                return .handled
                            }
                            searchState.query = result.title
                            focusedAppPillIndex = nil
                            return .handled
                        }
                    }
                }

                // Non-global context: Tab may enter explicit app sub-scope
                if !isGlobalContextActive {
                    if activateTypedAppScopeIfPossible() {
                        return .handled
                    }
                }

                if isL2ContextActive && !isGlobalContextActive {
                    if focusFirstDockPillIfAvailable(for: searchState.query) {
                        return .handled
                    }
                    return .handled
                }

                // Tab → always open context panel for selected result (files, folders, apps, etc.)
                if let idx = searchState.selectedIndex, idx < searchState.results.count {
                    let result = searchState.results[idx]
                    activateSearchContext(for: result)
                    return .handled
                }

                toggleAIModePreservingLayer()
                return .handled
            }
            .onKeyPress(.escape) {
                // Folder preview: ESC exits back to normal search
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
                    return .handled
                }
                // Inline Share Sheet: ESC exits back to normal dock
                if inlineShareActive {
                    inlineShareActive = false
                    isSearchFieldFocused = true
                    scheduleDockPillRebuild(
                        query: searchState.query, delayNanoseconds: 0, refreshContext: false)
                    return .handled
                }
                // Clipboard Scope closes the dock outright rather than falling back.
                if exitClipboardScopeClosingLauncher() { return .handled }
                // App scope or app panel: ESC exits scope and returns to L1 (stays open)
                if l2.targetApp != nil || searchState.activeSmartQueryKey != nil
                    || searchState.contextApp != nil
                {
                    let wasAppScope = l2.targetApp != nil
                    clearSearchContext()
                    remPanelIsProcessing = false
                    remIsInstalled = nil
                    systemDataResults = []
                    searchState.lastSmartQuery = ""
                    // Restore global app-search mode so dock shows app search, not empty limbo
                    if wasAppScope {
                        globalContextActivation = GlobalContextActivation(autoActivated: false)
                    }
                    isSearchFieldFocused = true
                    return .handled
                }
                // Pills focused (no scope): ESC returns focus to search field, keeps dock open
                if l2.focusedPillIndex != nil || focusedAppPillIndex != nil
                    || searchState.selectedIndex != nil
                {
                    l2.focusedPillIndex = nil
                    focusedAppPillIndex = nil
                    l2.pillNavViaKeyboard = false
                    searchState.selectedIndex = nil
                    isSearchFieldFocused = true
                    return .handled
                }
                // Dock visible, nothing active: ESC hides dock and returns to previous app
                AppDelegate.shared?.hideLauncher(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    AppDelegate.shared?.previousFrontmostApp?.activate(options: [
                        .activateIgnoringOtherApps
                    ])
                }
                return .handled
            }
            .onKeyPress(.delete) {
                // Quick Note editor: Backspace deletes characters in the note.
                if activeNotepadScopeCommand != nil { return .ignored }
                let text = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    // Backspace on an empty field leaves a compact scope. Clipboard exits
                    // the dock entirely; Notifications still steps out to the surface below.
                    if exitClipboardScopeClosingLauncher() { return .handled }
                    if searchState.activeSmartQueryKey != nil {
                        clearSearchContext()
                        isSearchFieldFocused = true
                        scheduleDockPillRebuild(
                            query: "", delayNanoseconds: 0, refreshContext: false)
                        requestWindowSizeUpdate(reason: .modeChanged)
                        return .handled
                    }
                    // Exit inline Share Sheet first
                    if inlineShareActive {
                        inlineShareActive = false
                        isSearchFieldFocused = true
                        scheduleDockPillRebuild(
                            query: "", delayNanoseconds: 0, refreshContext: false)
                        return .handled
                    }
                    // Unlock locked submenu parent first
                    if lockedSubmenuParent != nil {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                            lockedSubmenuParent = nil
                        }
                        isSearchFieldFocused = true
                        return .handled
                    }
                    // Dismiss file/text selection chip (same as clicking "-")
                    if hasSelectionScopeSurface {
                        dismissSelectionAndStayInGlobalContext()
                        isSearchFieldFocused = true
                        return .handled
                    }
                    if isContextDockChatConnected,
                        AXWebReader.shared.isBrowser(bundleId: frontmost.bundleID)
                    {
                        withAnimation(.dockStandard) {
                            exitContextDockChatSheet()
                            WebResearchSession.shared.clear()
                            searchState.revision += 1
                        }
                        isSearchFieldFocused = true
                        return .handled
                    }
                    if shouldShowContextDockChatSheet || l2.showChatPopover {
                        withAnimation(.dockStandard) {
                            exitContextDockChatBackToContext()
                        }
                        isSearchFieldFocused = true
                        return .handled
                    }
                    if l2.chatArmed {
                        withAnimation(.dockStandard) {
                            exitContextDockChatBackToContext()
                        }
                        isSearchFieldFocused = true
                        return .handled
                    }
                    // Exit app/smart-query scope — same as Esc, restores L1
                    if l2.targetApp != nil || searchState.contextApp != nil
                        || searchState.activeSmartQueryKey != nil
                    {
                        let wasAppScope = l2.targetApp != nil
                        clearSearchContext()
                        remPanelIsProcessing = false
                        remIsInstalled = nil
                        systemDataResults = []
                        searchState.lastSmartQuery = ""
                        if wasAppScope {
                            globalContextActivation = GlobalContextActivation(autoActivated: false)
                        }
                        isSearchFieldFocused = true
                        return .handled
                    }
                }
                // Browsing a Finder folder with an empty field → pop to the parent
                // folder, then back out to the search results.
                if popFinderBrowseFromEmptyBackspaceIfNeeded() { return .handled }
                return detachFinderFolderQueryModeFromEmptyBackspace() ? .handled : .ignored
            }
            // Left Arrow on an empty field (no scope chips) → standalone General AI
            // chat. With text or a scope chip present it stays a normal cursor/scope key.
            .onKeyPress(.leftArrow) {
                if searchState.activeSmartQueryKey == "clipboard",
                    clipboardSourcePillFocusIndex != nil
                {
                    return retreatClipboardSourcePill() ? .handled : .ignored
                }
                guard searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    allGlobalInlineAppScopes.isEmpty,
                    activeNotepadScopeCommand == nil,
                    isGlobalContextActive || showContextInDock,
                    !aiMode.isActive,
                    !showMediaLayer,
                    !isCompactSmartScope,
                    // Never hop out of an open frontmost-app chat — Left Arrow only enters
                    // General Chat from a bare dock, not from an active scoped conversation.
                    !shouldShowContextDockChatSheet,
                    !l2.chatArmed,
                    !l2.showChatPopover,
                    l2.targetApp == nil,
                    settings.enableAIMode
                else { return .ignored }
                enterGeneralChatPreservingLayer()
                return .handled
            }
            // Right Arrow: accept visible ghost text first. If no prefix ghost exists,
            // use Right Arrow for app scope navigation.
            .onKeyPress(.rightArrow) {
                if activeNotepadScopeCommand != nil { return .ignored }
                // Finder desktop: drill into the focused folder, showing its contents.
                // Only when the caret is at the end so it never hijacks cursor movement
                // while editing the query.
                if searchInputCursorIsAtEnd(), drillIntoFocusedFinderFolderIfPossible() {
                    return .handled
                }
                if searchState.activeSmartQueryKey == "clipboard",
                    clipboardSourcePillFocusIndex != nil
                {
                    return advanceClipboardSourcePill() ? .handled : .ignored
                }
                // Right arrow on a focused multi-file clip expands its file stack; then
                // Down arrow walks into the files.
                if let stackEntry = focusedClipboardStackEntry(),
                    !expandedClipboardEntryIDs.contains(stackEntry.id)
                {
                    toggleClipboardStackExpansion(stackEntry)
                    return .handled
                }
                if acceptTopGlobalAppGhostCompletionIfPossible() {
                    return .handled
                }
                // Entering an app scope belongs to Tab alone. Both keys used to do it, and
                // Right Arrow is the one that costs something: inside a text field it means
                // "move the caret", so editing mid-query could change scope instead. Tab has
                // no text-editing meaning and is the launcher convention. Right Arrow keeps
                // its own jobs above and below — accepting ghost text, drilling into a Finder
                // folder, walking clipboard entries.
                if !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    focusTopGlobalAppResultIfPossible()
                {
                    return .handled
                }
                if searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    currentSelectionActivationSnapshot(refresh: true) != nil
                {
                    openSelectionContextFromTrailingButton()
                    return .handled
                }
                if attachCurrentFinderFolderFromEmptyFieldIfNeeded() {
                    return .handled
                }
                // In a browser with an empty field, right-arrow grabs the current
                // page and immediately arms app-scoped chat for that page. Verify against
                // the LIVE frontmost app: a stale cached bundle made this fire while the
                // user was in a non-browser app (VS Code), attaching a browser page to
                // that app's chat.
                let liveFrontmostBundle =
                    AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier
                    ?? frontmost.bundleID
                if isGlobalContextActive || showContextInDock,
                    searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !aiMode.isActive,
                    !showMediaLayer,
                    !isCompactSmartScope,
                    l2.targetApp == nil,
                    AXWebReader.shared.isBrowser(bundleId: liveFrontmostBundle),
                    liveFrontmostBundle == frontmost.bundleID,
                    addCurrentSafariPageToContextFromKeyboard()
                {
                    searchState.revision += 1
                    openInlineAIChatPanel()
                    return .handled
                }
                if isGlobalContextActive || showContextInDock,
                    searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !aiMode.isActive,
                    !showMediaLayer,
                    !isCompactSmartScope,
                    frontmost.bundleID != "com.apple.finder"
                {
                    openInlineAIChatPanel()
                    return .handled
                }
                if let findToken = lockedFindToken,
                    findToken.hasChildMenu,
                    searchInputCursorIsAtEnd()
                {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.82)) {
                        showFindTokenMenu = true
                    }
                    return .handled
                }
                if let completion = l2.appCompletion,
                    !completion.ghost.isEmpty,
                    searchInputCursorIsAtEnd()
                {
                    let full = completion.appName
                    if !full.isEmpty && searchState.query.lowercased() != full.lowercased() {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            searchState.query = full
                        }
                        return .handled
                    }
                }
                return .ignored
            }
    }
}
