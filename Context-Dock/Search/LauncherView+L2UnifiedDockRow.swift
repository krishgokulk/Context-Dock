import SwiftUI

extension LauncherView {
    @ViewBuilder
    var l2UnifiedDockRow: some View {
        makeContextDockSurface()
    }

    @ViewBuilder
    func makeGlobalContextSurface() -> some View {
        let presentation = l2DockRowPresentation
        GlobalContextSurface(
            presentation: presentation,
            isFinderDesktopOnlyMode: isFinderDesktopOnlyMode,
            onPillQueryChange: handleL2PillQueryChange,
            onAppear: { handleL2DockRowAppear(pillQuery: presentation.pillQuery) },
            onFinderDesktopModeChange: { enabled in
                await handleFinderDesktopModeChange(enabled, pillQuery: presentation.pillQuery)
            },
            onSwipeDown: handleL2SwipeDown,
            onSwipeUp: handleL2SwipeUp
        ) {
            l2FindTokenContent
        } submenuContent: {
            l2SubmenuContent
        } globalSearchContent: {
            l2GlobalSearchContent(presentation.globalSearch)
        } dockPillContent: {
            l2DockPillContent(presentation)
        }
    }

    @ViewBuilder
    func makeContextDockSurface() -> some View {
        let presentation = l2DockRowPresentation
        ContextDockSurface(
            presentation: presentation,
            isFinderDesktopOnlyMode: isFinderDesktopOnlyMode,
            onPillQueryChange: handleL2PillQueryChange,
            onAppear: { handleL2DockRowAppear(pillQuery: presentation.pillQuery) },
            onFinderDesktopModeChange: { enabled in
                await handleFinderDesktopModeChange(enabled, pillQuery: presentation.pillQuery)
            },
            onSwipeDown: handleL2SwipeDown,
            onSwipeUp: handleL2SwipeUp
        ) {
            l2FindTokenContent
        } submenuContent: {
            l2SubmenuContent
        } globalSearchContent: {
            l2GlobalSearchContent(presentation.globalSearch)
        } dockPillContent: {
            l2DockPillContent(presentation)
        }
    }

    var l2DockRowPresentation: L2DockRowPresentation {
        let q =
            isL2ContextActive
            ? searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
        let pureGlobalAppSearch = shouldUsePureGlobalAppSearch
        let finderSearchPopoverActive = shouldUseFinderSearchPopover(for: q)
        let pillQuery = finderSearchPopoverActive ? "" : q
        // Selection Scope always shows its pills (Ask AI + actions + share), even with an empty
        // query — so the result sheet is visible the moment the launcher opens with a selection.
        let inSelectionScope = hasSelectionScopeSurface
        // A scoped app (running-app scope in Global Context) must show its menus on an
        // empty query, just like Context Dock — otherwise the scoped dock stays empty
        // until a keypress. Only the unscoped global/empty state collapses to no pills.
        let globalFinderFileScope =
            isGlobalContextActive
            && currentGlobalScopedBundleID == "com.apple.finder"
            && isFinderDesktopOnlyMode
        let scopedGlobalAppMode =
            isGlobalContextActive && currentGlobalScopedBundleID != nil && !globalFinderFileScope
        let visibleDockPills =
            scopedGlobalAppMode
            ? stableVisibleDockPills(for: pillQuery)
            : contextDockViewModel.visiblePills
        let pills: [DockPill] = {
            if globalFinderFileScope {
                return visibleDockPills
            }
            if (pureGlobalAppSearch || pillQuery.isEmpty) && !inSelectionScope && l2.targetApp == nil {
                return []
            }
            return visibleDockPills
        }()
        let explicitAppTarget =
            pillQuery.isEmpty ? nil : L2AppActionRouter.shared.appScopeTarget(for: pillQuery)
        let hasActiveContextSelection = hasSelectionScopeSurface
        let hasAnySelection =
            hasActiveContextSelection
            || (showGlobalClipboardPill && !globalClipboardText.isEmpty)
        let preliminaryGlobalNavState: GlobalGroupedListNavigationState? =
            (pureGlobalAppSearch && !q.isEmpty)
            ? visibleGlobalGroupedListNavigationState(for: q) : nil
        let globalAppMatches =
            pureGlobalAppSearch
            ? (
                preliminaryGlobalNavState?.appResults.isEmpty == false
                ? (preliminaryGlobalNavState?.appResults ?? [])
                : (
                    globalContextViewModel.typingSnapshot.phase == .expanded
                    ? matchDockIconRowsForExpandedSheet(query: q)
                    : []
                )
            )
            : currentOrImmediateGlobalAppMatches(for: q)
        let genericAppListQuery = isGenericApplicationListQuery(q)
        let preferFrontmostMenuResults =
            !genericAppListQuery
            && globalAppMatches.isEmpty
            && !q.isEmpty
            && isGlobalContextActive
            && !hasActiveContextSelection
            && l2.targetApp == nil
            && pills.contains { pill in
                guard !pill.isSeparator else { return false }
                return pill.rankingKind == "menu" || pill.rankingKind == "finderMenu"
            }
        let inlineGlobalScope =
            isGlobalContextActive && !hasActiveContextSelection && l2.targetApp == nil
            ? activeGlobalInlineDockScope(for: q)
            : nil
        let scopedGlobalMenuState =
            isGlobalContextActive && currentGlobalScopedBundleID != nil && !globalFinderFileScope
            ? visibleGlobalScopedMenuNavigationState(for: q)
            : nil
        let effectiveAppScope =
            !globalFinderFileScope
            && (scopedGlobalMenuState != nil || inlineGlobalScope?.isExplicitAppScope == true)
        let transientScopedMenuState =
            scopedGlobalMenuState ?? (effectiveAppScope ? visibleGlobalScopedMenuNavigationState(for: q) : nil)
        let displayedGlobalAppMatches = effectiveAppScope ? [] : globalAppMatches
        let scopedMenuListContext: (appName: String, actionQuery: String)? = {
            if let target = l2.targetApp {
                return (target.name, q)
            }
            guard let scope = inlineGlobalScope, scope.isExplicitAppScope else { return nil }
            return (scope.scopedAppName, scope.scopedSearchQuery)
        }()
        let globalNavState: GlobalGroupedListNavigationState? =
            effectiveAppScope
            ? (transientScopedMenuState ?? emptyGlobalGroupedListNavigationState())
            : preliminaryGlobalNavState
        let globalNavIsScopedAppMenus: Bool = {
            guard let s = globalNavState else { return false }
            return s.appResults.isEmpty && !s.appMenuGroups.isEmpty
        }()
        let globalMenuPills =
            globalNavIsScopedAppMenus ? [] : (globalNavState?.menuGroups.flatMap(\.allPills) ?? [])
        let globalCrossAppGroups = globalNavState?.appMenuGroups ?? []
        let showGlobalAppSearch =
            !globalFinderFileScope
            && ((pureGlobalAppSearch && !q.isEmpty && !preferFrontmostMenuResults)
            || effectiveAppScope
            )
        let scopedAppLaunchHint: (bundleId: String, appName: String, appPath: String?)? = {
            let (bundleId, appName): (String, String) = {
                if let scope = inlineGlobalScope, scope.isExplicitAppScope {
                    return (scope.scopedBundleId, scope.scopedAppName)
                }
                return ("", "")
            }()
            guard !bundleId.isEmpty, globalMenuPills.isEmpty else { return nil }
            guard !GlobalContextEngine.shared.hasMenuSnapshot(bundleIdentifier: bundleId) else {
                return nil
            }
            let isRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            }
            guard !isRunning else { return nil }
            let path =
                allApplications.first {
                    Bundle(url: URL(fileURLWithPath: $0.subtitle))?.bundleIdentifier == bundleId
                }?.subtitle
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path
            return (bundleId, appName, path)
        }()
        let globalSearchLoading =
            showGlobalAppSearch
            && (
                (currentGlobalScopedBundleID?.hasPrefix("syscmd://") == true
                    || currentGlobalScopedBundleID?.hasPrefix("cli://") == true)
                    && (globalNavState?.totalCount ?? 0) == 0
                || (!q.isEmpty && scopedAppLaunchHint == nil
                    && searchState.isLoadingApps && globalNavState == nil)
            )

        return L2DockRowPresentation(
            query: q,
            pillQuery: pillQuery,
            pills: pills,
            showsFindToken: lockedFindToken?.hasChildMenu == true && showFindTokenMenu,
            showsSubmenu: lockedSubmenuParent != nil && submenuGhostContext != nil,
            showsGlobalSearch: showGlobalAppSearch,
            hasAnySelection: hasAnySelection,
            explicitAppBundleId: explicitAppTarget?.bundleId,
            dockAtBottom: settings.effectiveDockAtBottom,
            globalSearch: L2GlobalSearchPresentation(
                query: q,
                matches: globalNavIsScopedAppMenus ? [] : (globalNavState?.appResults ?? displayedGlobalAppMatches),
                menuPills: globalMenuPills,
                appMenuGroups: globalCrossAppGroups,
                launchHint: scopedAppLaunchHint,
                scopedMenuAppName: scopedMenuListContext?.appName,
                scopedMenuActionQuery: scopedMenuListContext?.actionQuery ?? "",
                isLoading: globalSearchLoading,
                menuFirst: globalNavState?.menuFirst ?? false
            )
        )
    }

    @ViewBuilder
    var l2FindTokenContent: some View {
        if let findToken = lockedFindToken, showFindTokenMenu, findToken.hasChildMenu {
            findTokenDropdownView(findToken)
        }
    }

    @ViewBuilder
    var l2SubmenuContent: some View {
        if let locked = lockedSubmenuParent, let subCtx = submenuGhostContext {
            submenuDropdownView(
                parent: locked,
                children: subCtx.children,
                prefix: subCtx.childPrefix
            )
        }
    }

    /// Menu-only match (no app/command rows) that has not been revealed with ↓ yet —
    /// the sheet stays collapsed; the strip shows the owning app's pill instead.
    func isDeferredMenuOnlyPresentation(_ presentation: L2GlobalSearchPresentation) -> Bool {
        if isGlobalContextActive, shouldUsePureGlobalAppSearch, globalInlineAppScope == nil {
            return false
        }
        // Sheet policy while typing in pure Global Context:
        //  • 2+ app/command rows → instant sheet (classic launcher feel)
        //  • menu-only matches   → compact dock, owning-app pill in strip, ↓ reveals
        //  • exactly 1 row       → compact dock, that app's pill + ghost text, ↓ reveals
        //  • nothing at all      → compact dock, token-matched app pills, ↓ expands
        guard !globalMenuResultsRevealed,
            !presentation.query.isEmpty,
            presentation.scopedMenuAppName == nil,
            presentation.launchHint == nil,
            globalInlineAppScope == nil
        else { return false }
        let hasMenus = !presentation.menuPills.isEmpty || !presentation.appMenuGroups.isEmpty
        let menuOnly = presentation.matches.isEmpty && hasMenus
        let singleResult = presentation.matches.count == 1 && !hasMenus
        let nothing = presentation.matches.isEmpty && !hasMenus
        return menuOnly || singleResult || nothing
    }

    @ViewBuilder
    func l2GlobalSearchContent(_ presentation: L2GlobalSearchPresentation) -> some View {
        // The Quick Note scope owns its whole surface (split list + editor), so it
        // pre-empts the grouped results list this scope would otherwise render.
        if activeNotepadScopeCommand != nil {
            NotepadScopeView(
                selectedNoteID: $notepadSelectedNoteID,
                isDark: isEffectiveDark,
                onExit: {
                    if let scope = globalInlineAppScope {
                        removeGlobalInlineAppScope(scope)
                    }
                }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                updateMeasuredGlobalListHeight(height)
            }
        } else {
            l2GlobalSearchListContent(presentation)
        }
    }

    @ViewBuilder
    func l2GlobalSearchListContent(_ presentation: L2GlobalSearchPresentation) -> some View {
        // PERSISTENT hierarchy: the results container is ALWAYS in the tree and
        // reveals by clipped height. Conditional creation (`if expanded { list }`)
        // rebuilt the view identity on ↓, so the expansion could never animate
        // continuously from the first key press.
        let scopedGlobalMenuActive =
            isGlobalContextActive && currentGlobalScopedBundleID != nil && !isFinderDesktopOnlyMode
        let expanded =
            isGlobalContextActive && shouldUsePureGlobalAppSearch && !scopedGlobalMenuActive
            ? hasExpandedGlobalContextResults
            : (!globalContextViewModel.typingSnapshot.shouldShowOnlyTopMatch
                && !isDeferredMenuOnlyPresentation(presentation))
        globalAppSearchListView(
            query: presentation.query,
            matches: presentation.matches,
            menuPills: presentation.menuPills,
            appMenuGroups: presentation.appMenuGroups,
            launchHint: presentation.launchHint,
            scopedMenuAppName: presentation.scopedMenuAppName,
            scopedMenuActionQuery: presentation.scopedMenuActionQuery,
            isLoading: presentation.isLoading,
            menuFirst: presentation.menuFirst
        )
        .frame(maxHeight: expanded ? nil : 0, alignment: .top)
        .opacity(expanded ? 1 : 0)
        .clipped()
        .allowsHitTesting(expanded)
        // The NSPanel frame is the single owner of sheet expansion animation. Animating this
        // clipped subtree at the same time made the glass list fade/reveal inside a second,
        // independently changing viewport, which presented as a flash/flicker in every mode.
        // Keeping the hierarchy persistent still preserves row identity; the window animation
        // now reveals the already-laid-out content continuously.
    }

    @ViewBuilder
    func l2DockPillContent(_ presentation: L2DockRowPresentation) -> some View {
        if activeNotepadScopeCommand != nil {
            NotepadScopeView(
                selectedNoteID: $notepadSelectedNoteID,
                isDark: isEffectiveDark,
                onExit: {
                    if let scope = globalInlineAppScope {
                        removeGlobalInlineAppScope(scope)
                    }
                }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                updateMeasuredGlobalListHeight(height)
            }
        } else if !presentation.showsGlobalSearch {
            dockPillListView(pills: presentation.pills)
        }
    }

    /// The scoped SystemCommand when the user is inside a provider:notepad scope,
    /// else nil. Drives the Quick Note split editor surface.
    var activeNotepadScopeCommand: SystemCommand? {
        guard isGlobalContextActive,
            let bundle = currentGlobalScopedBundleID,
            bundle.hasPrefix("syscmd://"),
            let id = UUID(uuidString: String(bundle.dropFirst("syscmd://".count))),
            let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == id }),
            command.keywords.contains(where: { $0.lowercased() == "provider:notepad" })
        else { return nil }
        return command
    }

    func handleL2PillQueryChange(_ newQuery: String) {
        l2.focusedPillIndex = nil
        focusedAppPillIndex = nil
        if isContextDockChatRoutingLocked {
            contextDockViewModel.resetPillRenderingState(cancelBuild: true)
            return
        }
        if shouldUsePureGlobalAppSearch, !newQuery.isEmpty, allApplications.isEmpty,
            !searchState.isLoadingApps
        {
            loadApplicationsInBackground()
        }
        if shouldUsePureGlobalAppSearch {
            l2.appCompletion = nil
            l2.showResultsPopover = false
            if currentGlobalScopedBundleID != nil || globalInlineAppScope != nil {
                scheduleGlobalGroupedListRebuild(query: newQuery)
            } else {
                updateGlobalContextTypingSnapshot(query: newQuery)
            }
            return
        }
        if isFinderDesktopOnlyMode {
            scheduleFinderDesktopFastMatch(query: newQuery, preserveFocus: true)
            scheduleFinderDesktopSearchEnrichment(query: newQuery)
            return
        }
        if newQuery != lastPillQuery {
            scheduleDockPillRebuild(
                query: newQuery,
                delayNanoseconds: 20_000_000,
                refreshContext: false
            )
        }
    }

    func handleL2DockRowAppear(pillQuery: String) {
        if isContextDockChatRoutingLocked {
            contextDockViewModel.resetPillRenderingState(cancelBuild: true)
            return
        }
        if shouldUsePureGlobalAppSearch, !pillQuery.isEmpty, allApplications.isEmpty,
            !searchState.isLoadingApps
        {
            loadApplicationsInBackground()
        }
        if shouldUsePureGlobalAppSearch {
            if globalInlineAppScope == nil {
                updateGlobalContextTypingSnapshot(query: pillQuery)
            } else {
                scheduleGlobalGroupedListRebuild(query: pillQuery, delayNanoseconds: 0)
            }
            return
        }
        if isFinderDesktopOnlyMode {
            primeFinderDesktopModeCache(commitQuery: pillQuery, preserveFocus: true)
            scheduleFinderDesktopSearchEnrichment(query: pillQuery)
            return
        }
        scheduleDockPillRebuild(query: pillQuery, delayNanoseconds: 0)
    }

    func handleFinderDesktopModeChange(_ enabled: Bool, pillQuery: String) async {
        if enabled {
            if finderDesktopIndexedPills.isEmpty && finderDesktopRecentPills.isEmpty {
                primeFinderDesktopModeCache(
                    commitQuery: searchState.query.trimmingCharacters(in: .whitespacesAndNewlines),
                    preserveFocus: true
                )
            }
            await refreshFinderDesktopRecentPills()
            // Build the COMPLETE index (all file types, incl images) so the instant filter is
            // stable for any query — not just whatever the L1 document/file index happened to
            // hold. Cheap to re-run (Spotlight + dedupe); persists for the session.
            if finderDesktopFullIndexPrimed == false {
                finderDesktopFullIndexPrimed = true
                await primeFinderDesktopFullIndex()
            }
        } else {
            contextDockViewModel.finderDesktopSearchTask?.cancel()
            contextDockViewModel.finderDesktopSearchTask = nil
            contextDockViewModel.finderDesktopFastMatchTask?.cancel()
            contextDockViewModel.finderDesktopFastMatchTask = nil
            contextDockViewModel.finderDesktopSearchRecords = []
            contextDockViewModel.finderDesktopPillsByPath = [:]
            finderDesktopRecentPills = []
            finderDesktopSearchPills = []
            finderDesktopSearchQuery = ""
        }
    }

    func handleL2SwipeDown() {
        guard !isExplicitAppScopeLocked else { return }
        guard !isGlobalContextActive else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            globalContextActivation = GlobalContextActivation(autoActivated: false)
        }
        scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
    }

    func handleL2SwipeUp() {
        guard !isExplicitAppScopeLocked else { return }
        if isGlobalContextActive {
            dismissContextAndReturnToDock()
        } else if !showMediaLayer && settings.enableLayer3 {
            Task {
                await mediaObserver.refreshNowPlaying()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    showContextInDock = true
                    showMediaLayer = true
                }
                if searchState.query.isEmpty && !isSearchFieldFocused {
                    startCollapseTimer()
                }
            }
        }
    }
}
