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
        let inSelectionScope = isGlobalContextActive && hasSelectionScopeSurface
        // A scoped app (running-app scope in Global Context) must show its menus on an
        // empty query, just like Context Dock — otherwise the scoped dock stays empty
        // until a keypress. Only the unscoped global/empty state collapses to no pills.
        let pills =
            (pureGlobalAppSearch || pillQuery.isEmpty) && !inSelectionScope && l2.targetApp == nil
            ? []
            : contextDockViewModel.visiblePills
        let explicitAppTarget =
            pillQuery.isEmpty ? nil : L2AppActionRouter.shared.appScopeTarget(for: pillQuery)
        let hasActiveContextSelection = hasSelectionScopeSurface
        let hasAnySelection =
            hasActiveContextSelection
            || (showGlobalClipboardPill && !globalClipboardText.isEmpty)
        let preliminaryGlobalNavState: GlobalGroupedListNavigationState? =
            (pureGlobalAppSearch && !q.isEmpty)
            ? globalGroupedListNavigationState(for: q) : nil
        let globalAppMatches =
            pureGlobalAppSearch
            ? (preliminaryGlobalNavState?.appResults ?? [])
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
        let effectiveAppScope = inlineGlobalScope?.isExplicitAppScope == true
        let displayedGlobalAppMatches = effectiveAppScope ? [] : globalAppMatches
        let scopedMenuListContext: (appName: String, actionQuery: String)? = {
            guard let scope = inlineGlobalScope, scope.isExplicitAppScope else { return nil }
            return (scope.scopedAppName, scope.scopedSearchQuery)
        }()
        let globalNavState: GlobalGroupedListNavigationState? =
            effectiveAppScope
            ? globalGroupedListNavigationState(for: q)
            : preliminaryGlobalNavState
        let globalMenuPills = globalNavState?.menuGroups.flatMap(\.allPills) ?? []
        let globalCrossAppGroups = globalNavState?.appMenuGroups ?? []
        let globalNavIsScopedAppMenus =
            globalNavState?.appResults.isEmpty == true
            && !(globalNavState?.appMenuGroups.isEmpty ?? true)
        let showGlobalAppSearch =
            (pureGlobalAppSearch && !q.isEmpty && !preferFrontmostMenuResults)
            || effectiveAppScope
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
            showGlobalAppSearch && !q.isEmpty && scopedAppLaunchHint == nil
            && searchState.isLoadingApps && globalNavState == nil

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
                matches: globalNavIsScopedAppMenus
                    ? [] : (globalNavState?.appResults ?? displayedGlobalAppMatches),
                menuPills: globalMenuPills,
                appMenuGroups: globalCrossAppGroups,
                launchHint: scopedAppLaunchHint,
                scopedMenuAppName: scopedMenuListContext?.appName,
                scopedMenuActionQuery: scopedMenuListContext?.actionQuery ?? "",
                isLoading: globalSearchLoading
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

    @ViewBuilder
    func l2GlobalSearchContent(_ presentation: L2GlobalSearchPresentation) -> some View {
        // Siri-style deferral in pure Global Context: while typing, show only the
        // matching-app pill row (instant, cheap); the full grouped result list
        // renders after ↓. App scopes and launch hints keep the list immediately.
        let deferList =
            !globalResultsRevealed
            && presentation.scopedMenuAppName == nil
            && presentation.launchHint == nil
            && globalInlineAppScope == nil
            && !presentation.query.isEmpty
        if deferList {
            VStack(spacing: 6) {
                globalAppSearchPillRow(
                    query: presentation.query, matches: presentation.matches)
                if !presentation.matches.isEmpty || !presentation.menuPills.isEmpty
                    || !presentation.appMenuGroups.isEmpty
                {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Show Results")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                            globalResultsRevealed = true
                        }
                    }
                    .help("Press ↓ to show the full result list")
                }
            }
            .padding(.vertical, 4)
        } else {
            globalAppSearchListView(
                query: presentation.query,
                matches: presentation.matches,
                menuPills: presentation.menuPills,
                appMenuGroups: presentation.appMenuGroups,
                launchHint: presentation.launchHint,
                scopedMenuAppName: presentation.scopedMenuAppName,
                scopedMenuActionQuery: presentation.scopedMenuActionQuery,
                isLoading: presentation.isLoading,
                menuFirst: false
            )
        }
    }

    @ViewBuilder
    func l2DockPillContent(_ presentation: L2DockRowPresentation) -> some View {
        if !presentation.showsGlobalSearch {
            dockPillListView(pills: presentation.pills)
        }
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
            scheduleGlobalAppMatchRebuild(query: newQuery, delayNanoseconds: 0)
            return
        }
        if isFinderDesktopOnlyMode {
            commitFinderDesktopModeSnapshot(query: newQuery, preserveFocus: true)
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
            scheduleGlobalAppMatchRebuild(query: pillQuery, delayNanoseconds: 0)
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
