import AppKit
import SwiftUI

extension LauncherView {
    func requestWindowSizeUpdate(
        reason: DockResizeReason,
        animated: Bool = true,
        debounceNanoseconds: UInt64 = 50_000_000
    ) {
        let preset = currentDockHeightPreset
        let mode = currentDockSurfaceMode
        let presetChanged = lastAppliedDockHeightPreset != preset
        let modeChanged = lastAppliedDockSurfaceMode != mode

        if reason.isTypingOrContentRefresh
            && preset.stabilizesResize
            && !presetChanged
            && !modeChanged
        {
            return
        }

        updateWindowSize(animated: animated, debounceNanoseconds: debounceNanoseconds)
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
            return currentGlobalAppMatches(for: q)
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
        case shortcutSheet
        case shareSheet
        case ai
        case compactScope
        case hidden
        case globalContext
        case contextDock
    }

    var keyRoutingMode: KeyRoutingMode {
        if showShortcutSheet { return .shortcutSheet }
        if isSharingSheetActive { return .shareSheet }
        if aiMode.isActive { return .ai }
        if isCompactSmartScope { return .compactScope }
        if !showContextInDock { return .hidden }
        if isGlobalContextActive { return .globalContext }
        return .contextDock
    }

    func handleTopLevelKeyRouting(_ event: NSEvent, mode: KeyRoutingMode) -> NSEvent? {
        switch mode {
        case .shortcutSheet:
            return handleShortcutSheetKey(event)
        case .shareSheet, .ai, .compactScope, .hidden:
            return event
        case .globalContext, .contextDock:
            return nil
        }
    }

    func handleShortcutSheetKey(_ event: NSEvent) -> NSEvent? {
        guard showShortcutSheet else { return event }

        switch event.keyCode {
        case 53:  // Escape
            closeShortcutSheet()
            return nil
        case 125:  // Down
            if shortcutSheetSelectionSnapshot != nil {
                shortcutSheetSelectionExpanded = true
            }
            let commands = currentShortcutSheetCommandIDs()
            guard !commands.isEmpty else { return nil }
            if let id = shortcutSheetFocusedCommandID,
                let index = commands.firstIndex(of: id)
            {
                shortcutSheetFocusedCommandID = commands[min(commands.count - 1, index + 1)]
            } else {
                shortcutSheetFocusedCommandID = commands[0]
            }
            refreshShortcutSheetPanel()
            return nil
        case 126:  // Up
            if shortcutSheetSelectionSnapshot != nil {
                shortcutSheetSelectionExpanded = true
            }
            let commands = currentShortcutSheetCommandIDs()
            guard !commands.isEmpty else { return nil }
            guard let id = shortcutSheetFocusedCommandID,
                let index = commands.firstIndex(of: id)
            else {
                shortcutSheetFocusedCommandID = commands[commands.count - 1]
                refreshShortcutSheetPanel()
                return nil
            }
            if index <= 0 {
                shortcutSheetFocusedCommandID = commands[0]
            } else {
                shortcutSheetFocusedCommandID = commands[index - 1]
            }
            refreshShortcutSheetPanel()
            return nil
        case 36:  // Return
            guard let id = shortcutSheetFocusedCommandID,
                executeFocusedShortcutSheetCommand(id: id)
            else { return event }
            return nil
        default:
            return event
        }
    }

    func setupDockPillKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let routingMode = self.keyRoutingMode
            if let routedEvent = self.handleTopLevelKeyRouting(event, mode: routingMode) {
                return routedEvent
            }

            // Only context/global dock modes can consume dock navigation keys.
            guard routingMode == .contextDock || routingMode == .globalContext else {
                return event
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
                if self.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    self.currentSelectionActivationSnapshot(refresh: true) != nil
                {
                    self.openSelectionContextFromTrailingButton()
                    return nil
                }
                if self.attachCurrentFinderFolderFromEmptyFieldIfNeeded() {
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
            if event.keyCode == 48, self.isGlobalContextActive {
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
            if let completion = self.l2.appCompletion, !completion.ghost.isEmpty,
                event.keyCode == 48
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

            if event.keyCode == 36,
                (self.shouldShowContextDockChatSheet || self.l2.showChatPopover || self.l2.chatArmed),
                q.isEmpty
            {
                self.exitContextDockChatAndScope()
                return nil
            }

            if event.keyCode == 36, self.executeScopedRunningAppIfIdle() {
                return nil
            }

            if self.isGlobalContextActive,
                q.isEmpty,
                event.keyCode == 123 || event.keyCode == 124,
                self.focusedAppPillIndex == nil,
                self.l2.focusedPillIndex == nil
            {
                _ = self.cycleGlobalContextAppScope(direction: event.keyCode == 124 ? 1 : -1)
                self.focusedAppPillIndex = nil
                self.l2.focusedPillIndex = nil
                return nil
            }

            // Block 1: grouped navigation — fires when view shows globalAppSearchListView.
            // That view is shown when: app matches exist, OR frontmost has no matching menus
            // (cross-app or empty). When frontmost HAS menus (preferFrontmostMenuResults=true),
            // view shows dockPillListView instead — Block 3 handles it with full-pills indices.
            if self.shouldUsePureGlobalAppSearch && !q.isEmpty {
                let groupedState = self.globalGroupedListNavigationState(for: q)
                guard groupedState.totalCount > 0 else { return event }

                switch event.keyCode {
                case 125:  // Down — move through grouped app/menu rows
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
                case 53:  // Escape — leave result focus first; keep query intact
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
                case 51:  // Delete/Backspace — quit focused running app row, else clear focus
                    if self.currentGlobalGroupedFocusIndex(state: groupedState) != nil {
                        if self.quitFocusedGlobalAppResultIfPossible(state: groupedState) {
                            return nil
                        }
                        self.setGlobalGroupedFocus(nil, state: groupedState)
                        return nil
                    }
                    return event
                default:
                    return event
                }
            }

            // ── App-pill row navigation (pinned/running or global app search) ──────────
            let hasActiveContextSel = self.activeSelection != nil
            // Use the same cached pill list the List View renders. Do not rebuild here;
            // this key monitor runs on every keyDown.
            let pillQuery = self.shouldUseFinderSearchPopover(for: q) ? "" : q
            let actionPills =
                q.isEmpty
                ? self.selectionScopedDockPills(self.cachedDockPills)
                : (pillQuery.isEmpty ? [] : self.contextDockViewModel.visiblePills)
            let showPinnedRow =
                q.isEmpty
                && self.l2.targetApp == nil
                && (actionPills.isEmpty || (self.isGlobalContextActive && !hasActiveContextSel))
            let hasGlobalAppMatches =
                self.isGlobalContextActive && !q.isEmpty
                && (!self.currentGlobalAppMatches(for: q).isEmpty
                    || self.pendingGlobalAppQuery == q)
            let showGlobalAppSearch =
                self.shouldUsePureGlobalAppSearch && !q.isEmpty && hasGlobalAppMatches
            let isAppPillRowActive = showPinnedRow || showGlobalAppSearch

            if isAppPillRowActive {
                let appPills = self.currentAppPillActions()
                guard !appPills.isEmpty else { return event }

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
                case 124:  // Right — mirror context dock: wrap to input field at end
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
                    if let idx = self.focusedAppPillIndex, idx < appPills.count {
                        appPills[idx].execute()
                        self.searchState.query = ""
                        self.focusedAppPillIndex = nil
                        self.hideLauncherAfterResultExecution()
                        return nil
                    }
                    return event
                case 51:  // Delete/Backspace — quit focused running app, else clear focus
                    if let idx = self.focusedAppPillIndex {
                        if idx < appPills.count, let quit = appPills[idx].quit {
                            let preservedQuery = self.searchState.query
                            quit()
                            self.searchState.query = preservedQuery
                            self.focusedAppPillIndex = nil
                            self.l2.pillNavViaKeyboard = false
                            self.scheduleGlobalAppMatchRebuild(
                                query: preservedQuery,
                                delayNanoseconds: 0
                            )
                            self.scheduleGlobalGroupedListRebuild(
                                query: preservedQuery,
                                delayNanoseconds: 0
                            )
                            return nil
                        }
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
                    let curIdx = self.l2.focusedPillIndex ?? -1
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
                    if let cur = self.l2.focusedPillIndex, cur > 0 {
                        var upIdx = cur - 1
                        while upIdx > 0 && pills[upIdx].isSeparator { upIdx -= 1 }
                        self.l2.pillNavViaKeyboard = true
                        self.l2.focusedPillIndex = upIdx
                    } else {
                        self.l2.focusedPillIndex = nil
                        self.l2.pillNavViaKeyboard = false
                        DispatchQueue.main.async { self.isSearchFieldFocused = true }
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
                if self.l2.focusedPillIndex != nil,
                    !self.showShortcutSheet,
                    self.executeFocusedOrDirectAppPillIfNeeded()
                {
                    return nil
                }

                if !self.showShortcutSheet,
                    self.executeFirstMatchingFinderFolderPillIfNeeded()
                {
                    return nil
                }

                if !self.showShortcutSheet,
                    self.executeFirstAttachedFinderFolderResultIfNeeded()
                {
                    return nil
                }

                if self.launchTypedAppMatchIfNeeded() {
                    return nil
                }

                if !self.showShortcutSheet, self.executeFocusedOrDirectAppPillIfNeeded() {
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
                if !cmdTapArmed {
                    cmdTapArmed = true
                    cmdChordUsed = false
                    cmdHoldTriggered = false
                }
                guard cmdHoldTask == nil else { return event }  // already counting
                let targetApp =
                    AppDelegate.shared?.previousFrontmostApp
                    ?? NSWorkspace.shared.frontmostApplication
                cmdHoldTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)  // 0.8 s
                    guard !Task.isCancelled else { return }
                    guard !self.aiMode.isActive, !self.isCompactSmartScope else { return }
                    self.cmdHoldTriggered = true
                    self.presentCommandHoldSheet(for: targetApp)
                    self.cmdHoldTask = nil
                }
            } else {
                // Cmd released — bare tap toggles Context Dock ↔ Global Context.
                let shouldToggleScope =
                    cmdTapArmed
                    && !cmdChordUsed
                    && !cmdHoldTriggered
                    && !showShortcutSheet

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
                if !cmdTapArmed {
                    cmdTapArmed = true
                    cmdChordUsed = false
                    cmdHoldTriggered = false
                }
                guard cmdHoldTask == nil else { return }
                let targetApp = NSWorkspace.shared.frontmostApplication
                cmdHoldTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled, !cmdChordUsed else { return }
                    guard !self.aiMode.isActive, !self.isCompactSmartScope else { return }
                    self.cmdHoldTriggered = true
                    self.presentCommandHoldSheet(for: targetApp)
                    self.cmdHoldTask = nil
                }
            } else {
                cmdHoldTask?.cancel()
                cmdHoldTask = nil
                cmdTapArmed = false
                cmdChordUsed = false
                cmdHoldTriggered = false
            }
        }
    }

    func presentCommandHoldSheet(for app: NSRunningApplication?) {
        if let snapshot = currentSelectionSheetSnapshot(refresh: true, app: app) {
            presentSelectionCommandSheet(snapshot: snapshot, app: app)
            return
        }
        // No selection resolved — still open a sheet with the app's menu commands
        // so cmd-hold always surfaces something (never a dead key press).
        presentGlobalShortcutSheet(for: app)
    }

    func isMailLikeApp(_ bundleID: String) -> Bool {
        ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac"]
            .contains(bundleID)
    }

    func currentSelectionSheetSnapshot(
        refresh: Bool,
        app: NSRunningApplication?
    ) -> SelectionContextSnapshot? {
        if refresh, let app, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            AXContextReader.shared.refresh(from: app)
            axContext = AXContextReader.shared.current
        }

        let sourceAppName = app?.localizedName ?? frontmost.name
        let sourceBundleID = app?.bundleIdentifier ?? frontmost.bundleID
        let files: [URL] = {
            let axFiles = isDismissedFinderSelection(axContext.selectedFilePaths)
                ? []
                : axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
            if !axFiles.isEmpty { return axFiles }
            if case .filesSelected(let urls) = currentContext,
                !isDismissedFinderSelection(urls)
            {
                return urls
            }
            // Mail attachments aren't in the AX file-selection path — resolve the
            // focused/selected attachment's cached file URL on demand so it gets
            // real file actions (Open With, Quick Look, Share).
            if isMailLikeApp(sourceBundleID), let pid = app?.processIdentifier {
                let attachments = ContextDetector.shared.getMailAttachmentFiles(pid: pid)
                if !attachments.isEmpty { return attachments }
            }
            return []
        }()

        if !files.isEmpty {
            let title = files.count == 1 ? files[0].lastPathComponent : "\(files.count) items selected"
            let subtitle = files.count == 1
                ? files[0].deletingLastPathComponent().lastPathComponent
                : sourceAppName
            return SelectionContextSnapshot(
                sourceAppName: sourceAppName,
                sourceBundleID: sourceBundleID,
                selectedText: nil,
                selectedFiles: files,
                iconName: files.count == 1
                    ? fileIcon(for: files[0].pathExtension.lowercased())
                    : "doc.on.doc.fill",
                title: title,
                subtitle: subtitle
            )
        }

        let text: String? = {
            if let text = axContext.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                text.count > 2
            {
                return text
            }
            if case .textSelected(let text) = currentContext {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.count > 2 ? trimmed : nil
            }
            return nil
        }()

        if let text {
            return SelectionContextSnapshot(
                sourceAppName: sourceAppName,
                sourceBundleID: sourceBundleID,
                selectedText: text,
                selectedFiles: [],
                iconName: "text.cursor",
                title: String(text.prefix(48)),
                subtitle: sourceAppName
            )
        }

        return nil
    }

    func presentGlobalShortcutSheet(for app: NSRunningApplication?) {
        guard let app,
            !app.isTerminated,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }

        AppDelegate.shared?.recordFrontmostApp(app)
        ContextDockEnvironment.shared.frontmostAppDidChange(
            name: app.localizedName ?? "",
            bundleID: app.bundleIdentifier ?? ""
        )

        globalContextActivation = nil
        aiMode.isActive = false
        shortcutSheetSelectionSnapshot = nil
        shortcutSheetSearchQuery = ""
        shortcutSheetFocusedCommandID = nil
        shortcutSheetSourcePID = app.processIdentifier
        shortcutSheetAppName = app.localizedName ?? "App"

        let cachedItems = MenuWarmCacheService.shared.cachedMenuItems(for: app, maxResults: 180)
        if !cachedItems.isEmpty {
            liveMenuItems = cachedItems
        } else {
            liveMenuItems = []
        }
        showStandaloneShortcutSheetPanel(appName: shortcutSheetAppName)

        Task { @MainActor in
            await MenuWarmCacheService.shared.warm(app: app, force: true)
            let warmedItems = MenuWarmCacheService.shared.cachedMenuItems(for: app, maxResults: 180)
            if !warmedItems.isEmpty {
                self.liveMenuItems = warmedItems
            }
            for _ in 0..<6 {
                if !self.liveMenuItems.isEmpty { break }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard !self.isCompactSmartScope else { return }
            self.shortcutSheetFocusedCommandID = nil
            self.showShortcutSheet = true
            ShortcutSheetPanelPresenter.shared.update(
                rootView: self.shortcutSheetPanelRootView(appName: self.shortcutSheetAppName)
            )
        }
    }

    func presentSelectionCommandSheet(
        snapshot: SelectionContextSnapshot,
        app: NSRunningApplication?
    ) {
        if let app {
            AppDelegate.shared?.recordFrontmostApp(app)
            ContextDockEnvironment.shared.frontmostAppDidChange(
                name: app.localizedName ?? "",
                bundleID: app.bundleIdentifier ?? ""
            )
            shortcutSheetSourcePID = app.processIdentifier
            shortcutSheetAppName = app.localizedName ?? snapshot.sourceAppName
            let cachedItems = MenuWarmCacheService.shared.cachedMenuItems(for: app, maxResults: 180)
            liveMenuItems = cachedItems
        } else {
            shortcutSheetSourcePID = 0
            shortcutSheetAppName = snapshot.sourceAppName
            liveMenuItems = []
        }

        aiMode.isActive = false
        shortcutSheetSelectionSnapshot = snapshot
        shortcutSheetSelectionExpanded = false
        shortcutSheetSearchQuery = ""
        shortcutSheetFocusedCommandID = nil
        primeFinderContextualActionsForSelectionSheet(snapshot)
        showStandaloneShortcutSheetPanel(appName: shortcutSheetAppName, preserveSelection: true)

        guard let app else { return }
        Task { @MainActor in
            await MenuWarmCacheService.shared.warm(app: app, force: true)
            let warmedItems = MenuWarmCacheService.shared.cachedMenuItems(for: app, maxResults: 180)
            if !warmedItems.isEmpty {
                self.liveMenuItems = warmedItems
                ShortcutSheetPanelPresenter.shared.update(
                    rootView: self.shortcutSheetPanelRootView(appName: self.shortcutSheetAppName)
                )
            }
        }
    }

    func primeFinderContextualActionsForSelectionSheet(_ snapshot: SelectionContextSnapshot) {
        guard snapshot.sourceBundleID == "com.apple.finder",
            !snapshot.selectedFiles.isEmpty,
            !FinderContextualMenuActionSource.shared.hasFreshCache(for: snapshot.selectedFiles)
        else { return }

        _ = FinderContextualMenuActionSource.shared.actions(for: snapshot.selectedFiles)
    }

    func showStandaloneShortcutSheetPanel(appName: String, preserveSelection: Bool = false) {
        let preservedSnapshot = preserveSelection ? shortcutSheetSelectionSnapshot : nil
        closeShortcutSheet(resetSearch: false)
        if preserveSelection {
            shortcutSheetSelectionSnapshot = preservedSnapshot
        }
        AppDelegate.shared?.launcherWindow?.orderOut(nil)
        showShortcutSheet = true
        ShortcutSheetPanelPresenter.shared.show(
            rootView: shortcutSheetPanelRootView(appName: appName),
            initialHeight: shortcutSheetSelectionSnapshot != nil ? 132 : 560,
            onKeyDown: handleShortcutSheetPanelKey
        )
    }

    func shortcutSheetPanelRootView(appName: String) -> some View {
        Group {
            if let snapshot = shortcutSheetSelectionSnapshot {
                SelectionCommandSheetView(
                    snapshot: snapshot,
                    commands: selectionSheetAllCommands(for: snapshot),
                    onSelect: executeSelectionSheetCommand,
                    onClose: { closeShortcutSheet() },
                    onExpand: { expandSelectionCommandSheet(snapshot) },
                    onAdd: { addSelectionSheetContextToDock(snapshot) },
                    chatMessages: shortcutSheetChatMessages,
                    isChatLoading: shortcutSheetChatLoading,
                    onAsk: { query in askSelectionSheetAI(query: query, snapshot: snapshot) },
                    focusedCommandID: shortcutSheetFocusedCommandIDBinding,
                    searchQuery: shortcutSheetSearchQueryBinding,
                    isExpanded: shortcutSheetSelectionExpandedBinding
                )
            } else {
                ShortcutSheetView(
                    commands: shortcutSheetAllCommands,
                    appName: appName,
                    onSelect: executeShortcutSheetCommand,
                    focusedCommandID: shortcutSheetFocusedCommandIDBinding,
                    searchQuery: shortcutSheetSearchQueryBinding
                )
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.36), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    func handleShortcutSheetPanelKey(_ event: NSEvent) -> Bool {
        handleShortcutSheetKey(event) == nil
    }

    func closeShortcutSheet(resetSearch: Bool = true) {
        showShortcutSheet = false
        shortcutSheetFocusedCommandID = nil
        shortcutSheetSelectionSnapshot = nil
        shortcutSheetSelectionExpanded = false
        shortcutSheetChatMessages = []
        shortcutSheetChatLoading = false
        if resetSearch {
            shortcutSheetSearchQuery = ""
        }
        ShortcutSheetPanelPresenter.shared.close()
    }

    func refreshShortcutSheetPanel() {
        guard showShortcutSheet else { return }
        ShortcutSheetPanelPresenter.shared.update(
            rootView: shortcutSheetPanelRootView(appName: shortcutSheetAppName)
        )
    }

    /// Send a selection-sheet query directly to the user's selected AI provider
    /// (no L2 chat pipeline) and show the conversation inline in the sheet.
    func askSelectionSheetAI(query: String, snapshot: SelectionContextSnapshot) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let provider = settings.selectedAIProvider
        let rawKey = AppSettings.shared.getAPIKey(for: provider)
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey

        shortcutSheetChatMessages.append(AIChatMessage(role: .user, content: trimmed))
        shortcutSheetSearchQuery = ""
        shortcutSheetSelectionExpanded = true
        shortcutSheetFocusedCommandID = nil

        if provider.requiresAPIKey && apiKey == nil {
            shortcutSheetChatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content:
                        "No API key found for \(provider.shortName). Add it in Settings → AI Provider.",
                    isError: true
                ))
            refreshShortcutSheetPanel()
            return
        }

        shortcutSheetChatLoading = true
        refreshShortcutSheetPanel()

        let history: [ChatMessage] = shortcutSheetChatMessages.dropLast()
            .filter { $0.role != .tool }
            .map { ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.content) }

        Task {
            do {
                let response = try await AIProviderService.shared.sendMessage(
                    trimmed,
                    context: snapshot.userContext,
                    provider: provider,
                    apiKey: apiKey,
                    conversationHistory: history,
                    additionalContextPrompt: selectionSheetAIContextPrompt(snapshot)
                )
                await MainActor.run {
                    shortcutSheetChatMessages.append(
                        AIChatMessage(role: .assistant, content: response))
                    shortcutSheetChatLoading = false
                    refreshShortcutSheetPanel()
                }
            } catch {
                await MainActor.run {
                    shortcutSheetChatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: "\(provider.shortName) error: \(error.localizedDescription)",
                            isError: true
                        ))
                    shortcutSheetChatLoading = false
                    refreshShortcutSheetPanel()
                }
            }
        }
    }

    func selectionSheetAIContextPrompt(_ snapshot: SelectionContextSnapshot) -> String {
        var parts = [
            "The user asked this from a selection sheet over \(snapshot.sourceAppName)."
        ]
        if let text = snapshot.selectedText, !text.isEmpty {
            parts.append("Selected text:\n\(String(text.prefix(4000)))")
        }
        if !snapshot.selectedFiles.isEmpty {
            parts.append(
                "Selected files:\n"
                    + snapshot.selectedFiles.prefix(20).map(\.path).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
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

            let heightSignpost = SearchPerformanceLog.shared.beginInterval(
                "window.heightUpdate",
                query: searchState.query
            )
            defer { SearchPerformanceLog.shared.endInterval("window.heightUpdate", state: heightSignpost) }

            let heightPreset = self.currentDockHeightPreset
            let surfaceMode = self.currentDockSurfaceMode
            let newHeight = self.calculatedHeight
            let newWidth = self.calculatedWidth
            let currentFrame = window.frame
            let screen = window.screen ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

            let presetChanged = self.lastAppliedDockHeightPreset != heightPreset
            let modeChanged = self.lastAppliedDockSurfaceMode != surfaceMode
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

            let newY: CGFloat
            if settings.effectiveDockAtBottom {
                // Bottom-anchored: grow upward, keep bottom edge fixed
                newY = currentFrame.minY
            } else {
                switch surfaceMode {
                case .generalChat, .contextDockChat:
                    // Chat surfaces swap content inside the stable dock frame.
                    newY = max(visibleFrame.minY, currentFrame.maxY - newHeight)
                case .globalContext, .contextDock, .mediaDock:
                    if spaceBelow >= newHeight || spaceBelow >= spaceAbove {
                        // Anchor top edge, grow downward
                        newY = currentFrame.maxY - newHeight
                    } else {
                        // Anchor bottom edge, grow upward
                        newY = currentFrame.minY
                    }
                }
            }

            let newFrame = NSRect(x: newX, y: newY, width: newWidth, height: newHeight)

            if animated {
                // Animate deliberate mode changes, but keep search-result churn unanimated.
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0.18
                NSAnimationContext.current.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.2, 0.9, 0.4, 1.0)
                window.animator().setFrame(newFrame, display: true)
                NSAnimationContext.endGrouping()
            } else {
                window.setFrame(newFrame, display: false)
            }

            self.lastAppliedDockHeightPreset = heightPreset
            self.lastAppliedDockSurfaceMode = surfaceMode

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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
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
                    navigateClipboardScope(direction: -1)
                    return .handled
                }
                if searchState.activeSmartQueryKey == "notifications" {
                    guard searchState.selectedIndex != nil else { return .handled }
                    if searchState.selectedIndex == 0 {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
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
                    if isL2ContextActive,
                        l2.focusedPillIndex != nil,
                        executeFocusedOrDirectAppPillIfNeeded()
                    {
                        return .handled
                    }
                    if isL2ContextActive, executeFirstMatchingFinderFolderPillIfNeeded() {
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
                        if (l2.chatArmed && !l2.showChatPopover)
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
                AppDelegate.shared?.hideLauncher()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    AppDelegate.shared?.previousFrontmostApp?.activate(options: [
                        .activateIgnoringOtherApps
                    ])
                }
                return .handled
            }
            .onKeyPress(.delete) {
                let text = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    // Unlock locked submenu parent first
                    if lockedSubmenuParent != nil {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                            lockedSubmenuParent = nil
                        }
                        isSearchFieldFocused = true
                        return .handled
                    }
                    // Dismiss file/text selection chip (same as clicking "-")
                    if hasActiveDockContextSelection {
                        dismissSelectionAndStayInGlobalContext()
                        isSearchFieldFocused = true
                        return .handled
                    }
                    if shouldShowContextDockChatSheet || l2.showChatPopover {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                            exitContextDockChatAndScope()
                        }
                        isSearchFieldFocused = true
                        return .handled
                    }
                    if l2.chatArmed {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                            exitContextDockChatAndScope()
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
                return detachFinderFolderQueryModeFromEmptyBackspace() ? .handled : .ignored
            }
            // Right Arrow: focus visible Global app result, otherwise accept ghost text.
            .onKeyPress(.rightArrow) {
                if activateSelectedApplicationScopeFromRightArrowIfPossible() {
                    return .handled
                }
                if activateFocusedGlobalAppScopeIfPossible() {
                    return .handled
                }
                if acceptTopGlobalAppGhostCompletionIfPossible() {
                    return .handled
                }
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
                // page as a context pill (instead of opening the AI chat panel).
                if (isGlobalContextActive || showContextInDock),
                    searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !aiMode.isActive,
                    !showMediaLayer,
                    !isCompactSmartScope,
                    l2.targetApp == nil,
                    AXWebReader.shared.isBrowser(bundleId: frontmost.bundleID),
                    addCurrentSafariPageToContextFromKeyboard()
                {
                    return .handled
                }
                if (isGlobalContextActive || showContextInDock),
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
