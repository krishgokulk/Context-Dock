import SwiftUI

extension LauncherView {
    var calculatedHeight: CGFloat {
        DockHeightResolver.resolve(currentDockHeightMetrics)
    }

    /// Compact smart scopes reserve 450 for their list.
    private var compactSmartScopePanelHeight: CGFloat { 450 }

    var currentDockHeightPreset: DockHeightPreset {
        DockHeightResolver.resolvePreset(currentDockHeightPresetMetrics)
    }

    private var currentDockHeightMetrics: DockHeightMetrics {
        let statusBarHeight: CGFloat = settings.enableStatusBar ? 45 : 0
        let contextHeight: CGFloat =
            (settings.enableFrontmostDetection && frontmost.isSectionExpanded) ? 45 : 0
        let dockRowHeight = CGFloat(settings.dockIconSize) + 4
        let dockVerticalPadding: CGFloat = 12
        // Mirror dockBaseView: the input bar is the stable 56 whenever it is expanded (focused,
        // global context, or showing the action list) so the reserved window height does not
        // wobble between the empty and typed states. Only the collapsed floating dock row uses
        // the icon-row height.
        let inputBarExpanded =
            (isSearchBarExpanded || usesVerticalListDockLayout)
            && (l2.focusedPillIndex == nil || usesVerticalListDockLayout)
            && !showMediaLayer
        let searchBarHeight: CGFloat =
            inputBarExpanded
            ? 56
            : max(50, dockRowHeight + dockVerticalPadding)
        let indexingBarHeight: CGFloat = fileIndexManager.progress.isIndexing ? 30 : 0
        let pureGlobalCompactTyping =
            isGlobalContextActive
            && shouldUsePureGlobalAppSearch
            && globalInlineAppScope == nil
            && globalContextViewModel.typingSnapshot.phase != .expanded

        return DockHeightMetrics(
            surfaceMode: currentDockSurfaceMode,
            statusBarHeight: statusBarHeight,
            contextHeight: contextHeight,
            searchBarHeight: searchBarHeight,
            indexingBarHeight: indexingBarHeight,
            finderSearchPanelHeight: finderSearchPanelHeightForCurrentState,
            contextChipHeight: contextChipHeightForCurrentState,
            aiMessageCount: aiMode.messages.count,
            showsContextDockAppPanel: searchState.activeSmartQueryKey != nil
                && !isCompactSmartScope
                && shouldShowContextDockAppPanel,
            compactSmartScope: isCompactSmartScope,
            compactScopePanelHeight: compactSmartScopePanelHeight,
            mediaHasDuration: mediaObserver.duration > 0,
            contextDockChatMessageCount: l2.chatMessages.count,
            listViewDockHeight: listViewDockHeight,
            selectionScopeAIChat: hasSelectionScopeSurface && aiMode.isActive,
            resultCount: pureGlobalCompactTyping ? 0 : searchState.results.count,
            loadingApps: pureGlobalCompactTyping ? false : searchState.isLoadingApps,
            l1ResultsReservedHeight: pureGlobalCompactTyping ? 0 : l1ResultsReservedHeight,
            measuredChatContentHeight: measuredChatContentHeight
        )
    }

    private var currentDockHeightPresetMetrics: DockHeightPresetMetrics {
        let pureGlobalCompactTyping =
            isGlobalContextActive
            && shouldUsePureGlobalAppSearch
            && globalInlineAppScope == nil
            && globalContextViewModel.typingSnapshot.phase != .expanded
        return DockHeightPresetMetrics(
            surfaceMode: currentDockSurfaceMode,
            usesVerticalListDockLayout: usesVerticalListDockLayout,
            listViewDockHeight: listViewDockHeight,
            selectionScopeAIChat: hasSelectionScopeSurface && aiMode.isActive,
            showsFinderSearchResultsPanel: shouldShowFinderSearchResultsPanel(for: searchState.query),
            showsContextDockAppPanel: pureGlobalCompactTyping ? false : shouldShowContextDockAppPanel,
            compactSmartScope: isCompactSmartScope,
            resultCount: pureGlobalCompactTyping ? 0 : searchState.results.count,
            loadingApps: pureGlobalCompactTyping ? false : searchState.isLoadingApps,
            searchBarExpanded: isSearchBarExpanded,
            aiMessageCount: aiMode.messages.count
        )
    }

    var finderSearchPanelHeightForCurrentState: CGFloat {
        guard
            showContextInDock && !showMediaLayer
                && shouldShowFinderSearchResultsPanel(for: searchState.query)
        else { return 0 }

        if isFinderSemanticLoading && searchState.results.isEmpty {
            return 170
        }
        if !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && searchState.results.isEmpty
        {
            return 150
        }

        let resultRowHeight: CGFloat = 50
        let resultsHeight = min(CGFloat(searchState.results.count) * resultRowHeight, 400)
        return resultsHeight + 48
    }

    private var contextChipHeightForCurrentState: CGFloat {
        if aiMode.isActive || showContextInDock || showMediaLayer { return 0 }
        guard settings.enableContextAIExtensions else { return 0 }
        guard hasMeaningfulHeightContext else { return 0 }
        guard searchState.query.isEmpty else { return 0 }
        let hasSuggestions = allShortcuts.contains { shortcut in
            guard let metadata = shortcutMetadataCache[shortcut.title] else { return false }
            return metadata.matches(context: currentContext)
        }
        return hasSuggestions ? 70 : 0
    }

    private var hasMeaningfulHeightContext: Bool {
        switch currentContext {
        case .filesSelected(let urls):
            return !urls.isEmpty
        case .textSelected(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .url(let urlString):
            return !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .appFocused, .contactSelected, .none:
            return false
        }
    }
}
