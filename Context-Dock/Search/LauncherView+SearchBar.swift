import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension LauncherView {
    var shouldShowSelectionTrailingButton: Bool {
        !showMediaLayer
            && currentDockSurfaceMode != .generalChat
            && !isCompactSmartScope
            && searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // In Selection Scope the left input icon already shows the selection; the trailing
            // button repeats the same icon (the redundant second box). Hide it there.
            && !(isGlobalContextActive && hasSelectionScopeSurface)
            && currentSelectionActivationSnapshot(refresh: false) != nil
    }

    func currentSelectionActivationSnapshot(refresh: Bool = false) -> GlobalContextActivation? {
        let refreshTarget = AppDelegate.shared?.previousFrontmostApp ?? contextTargetApp()
        let ownBundleId = Bundle.main.bundleIdentifier ?? ""
        let shouldRefresh =
            refresh
            && refreshTarget?.bundleIdentifier != ownBundleId
        if shouldRefresh, let app = refreshTarget {
            AXContextReader.shared.refresh(from: app)
            axContext = AXContextReader.shared.current
        }

        let axFiles =
            isDismissedFinderSelection(axContext.selectedFilePaths)
            ? []
            : axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        if !axFiles.isEmpty {
            let label =
                axFiles.count == 1
                ? axFiles[0].lastPathComponent
                : "\(axFiles.count) files selected"
            let icon =
                axFiles.count == 1
                ? fileIcon(for: axFiles[0].pathExtension.lowercased())
                : "doc.on.doc.fill"
            return GlobalContextActivation(
                autoActivated: false,
                frozenText: label,
                frozenIcon: icon,
                sourceBundleId: frontmost.bundleID,
                frozenFilePaths: axFiles.map(\.path)
            )
        }

        if let text = axContext.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            return GlobalContextActivation(
                autoActivated: false,
                frozenText: String(text.prefix(120)),
                frozenIcon: "text.cursor",
                sourceBundleId: frontmost.bundleID
            )
        }

        switch currentContext {
        case .filesSelected(let urls) where !urls.isEmpty && !isDismissedFinderSelection(urls):
            let label =
                urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files selected"
            let icon =
                urls.count == 1
                ? fileIcon(for: urls[0].pathExtension.lowercased())
                : "doc.on.doc.fill"
            return GlobalContextActivation(
                autoActivated: false,
                frozenText: label,
                frozenIcon: icon,
                sourceBundleId: frontmost.bundleID,
                frozenFilePaths: urls.map(\.path)
            )
        case .textSelected(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return GlobalContextActivation(
                autoActivated: false,
                frozenText: String(trimmed.prefix(120)),
                frozenIcon: "text.cursor",
                sourceBundleId: frontmost.bundleID
            )
        case .url(let url) where !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return GlobalContextActivation(
                autoActivated: false,
                frozenText: URL(string: url)?.host ?? String(url.prefix(120)),
                frozenIcon: "link",
                sourceBundleId: frontmost.bundleID
            )
        default:
            break
        }

        if shouldRefresh,
            let app = AppDelegate.shared?.previousFrontmostApp ?? contextTargetApp(),
            let detected = ContextDetector.shared.detectContext(frontmostApp: app)
        {
            switch detected {
            case .files(let urls) where !urls.isEmpty:
                let label =
                    urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files selected"
                let icon =
                    urls.count == 1
                    ? fileIcon(for: urls[0].pathExtension.lowercased())
                    : "doc.on.doc.fill"
                currentContext = .filesSelected(urls)
                return GlobalContextActivation(
                    autoActivated: false,
                    frozenText: label,
                    frozenIcon: icon,
                    sourceBundleId: app.bundleIdentifier ?? frontmost.bundleID,
                    frozenFilePaths: urls.map(\.path)
                )
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                currentContext = .textSelected(trimmed)
                return GlobalContextActivation(
                    autoActivated: false,
                    frozenText: String(trimmed.prefix(120)),
                    frozenIcon: "text.cursor",
                    sourceBundleId: app.bundleIdentifier ?? frontmost.bundleID
                )
            default:
                break
            }
        }

        return nil
    }

    private func isFileOrTextSelectionActivation(_ activation: GlobalContextActivation) -> Bool {
        if !activation.frozenFilePaths.isEmpty { return true }
        if activation.frozenIcon == "text.cursor",
            activation.frozenText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            return true
        }
        return false
    }

    /// If the launcher opened while text/files were selected, enter Selection Scope (Global
    /// Context + selection) directly instead of Context Dock. Returns true when it activated.
    @discardableResult
    func openInSelectionScopeIfSelectionPresent() -> Bool {
        guard let activation = currentSelectionActivationSnapshot(refresh: true),
            isFileOrTextSelectionActivation(activation)
        else {
            return false
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
            globalContextActivation = activation
            aiMode.isActive = false
            showMediaLayer = false
            showContextInDock = true
            searchState.activeSmartQueryKey = nil
            searchState.contextApp = nil
            searchState.query = ""
            searchState.results = []
            searchState.selectedIndex = nil
            l2.focusedPillIndex = nil
            focusedAppPillIndex = nil
            setCachedGlobalGroupedState(
                query: "",
                state: buildGlobalGroupedListNavigationState(for: ""),
                animated: false
            )
        }
        prewarmFinderContextualActionsForSelection()
        return true
    }

    func openSelectionContextFromTrailingButton() {
        let activation =
            currentSelectionActivationSnapshot(refresh: true)
            ?? GlobalContextActivation(autoActivated: false)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
            globalContextActivation = activation
            aiMode.isActive = false
            searchState.activeSmartQueryKey = nil
            searchState.contextApp = nil
            searchState.query = ""
            searchState.results = []
            searchState.selectedIndex = nil
            l2.focusedPillIndex = nil
            focusedAppPillIndex = nil
            setCachedGlobalGroupedState(
                query: "",
                state: buildGlobalGroupedListNavigationState(for: ""),
                animated: false
            )
            requestWindowSizeUpdate(reason: .modeChanged)
        }
        prewarmFinderContextualActionsForSelection()
    }

    @ViewBuilder
    var selectionTrailingButton: some View {
        if let selectionIcon = activeSelectionIcon
            ?? currentSelectionActivationSnapshot(refresh: false)?.frozenIcon
        {
            Button(action: openSelectionContextFromTrailingButton) {
                Image(systemName: selectionIcon)
                    .foregroundStyle(Color.accentColor.opacity(0.86))
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Open selection context")
        }
    }

    @ViewBuilder
    var currentResultsSurface: some View {
        EmptyView()
    }

    var searchBarSection: some View {
        searchBarShellForCurrentMode
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: showGlobalClipboardPill)
        .animation(nil, value: hasResultsToShow)
        .ifLet(resolvedColorScheme) { view, scheme in
            view.environment(\.colorScheme, scheme)
        }
    }

    /// Routes every mode and scope through the single `unifiedSearchPanelSurface`.
    @ViewBuilder
    private var searchBarShellForCurrentMode: some View {
        // One shell for EVERY mode and scope (DoraX "one shell, multiple modes" rule): global,
        // context dock, general chat, context-dock chat, media, clipboard and notification scopes
        // all render through the same container + same search input, so switching only swaps the
        // inner content in place — no surface recreation, no jump. Constant, instant, Spotlight-feel.
        unifiedSearchPanelSurface(inDockMode: settings.effectiveDockAtBottom)
    }

    var shouldShowUnifiedDockModeContent: Bool {
        switch currentDockSurfaceMode {
        case .generalChat:
            return hasUserSentMessageInCurrentSession
                || !aiMode.messages.isEmpty
                || aiMode.isLoading
                || aiMode.streamingId != nil
        case .contextDockChat:
            return shouldShowContextDockChatSheet
                || l2.showChatPopover
                || !l2.chatMessages.isEmpty
                || l2.isLoading
        case .globalContext, .contextDock:
            return hasResultsToShow
        case .mediaDock:
            return false
        }
    }

    var unifiedDockModeContentHeight: CGFloat {
        switch currentDockSurfaceMode {
        case .generalChat, .contextDockChat:
            // Content frame == the window's reserved chat area, both driven by the MEASURED chat
            // content height — so the sheet exactly fits the conversation (no clip, no empty box).
            return DockHeightResolver.chatAreaHeight(measuredContentHeight: measuredChatContentHeight)
        case .globalContext, .contextDock:
            return unifiedSearchContentHeight
        case .mediaDock:
            return 0
        }
    }

    var unifiedSearchContentHeight: CGFloat {
        if shouldSuppressIdleBottomResultsPanel {
            return 0
        }
        if shouldShowContextDockAppPanel {
            return min(searchResultsPanelMaxHeight, 480)
        }
        if isCompactSmartScope {
            return min(searchResultsPanelMaxHeight, 450)
        }
        if shouldShowFinderSearchResultsPanel(for: searchState.query) {
            return min(searchResultsPanelMaxHeight, max(150, finderSearchPanelHeightForCurrentState))
        }
        if !searchState.results.isEmpty {
            let sectionCount = max(searchState.grouped.sections.count, 1)
            let rowHeight: CGFloat = 66
            let headerHeight: CGFloat = sectionCount > 1 ? CGFloat(sectionCount) * 28 : 0
            let contentHeight = CGFloat(searchState.results.count) * rowHeight + headerHeight + 18
            return min(searchResultsPanelMaxHeight, max(120, contentHeight))
        }
        if searchState.isLoadingApps {
            return 80
        }
        return 0
    }

    @ViewBuilder
    var unifiedDockModeContent: some View {
        switch currentDockSurfaceMode {
        case .generalChat:
            aiChatSection
        case .contextDockChat:
            l2ChatSection
        case .globalContext, .contextDock:
            searchResultsContent
        case .mediaDock:
            EmptyView()
        }
    }

    /// True when the dock should show the glowing pill rather than the results/chat card.
    /// - Chat modes: stay a pill while COMPOSING the query and only expand once the chat actually
    ///   has content (first user/assistant message / loading), so the glow hides on the first
    ///   response — not on the first keystroke.
    /// - Other modes: idle = empty query with nothing to show. (The global app list / pills live in
    ///   currentListDockSurface, not searchState.results, so hasResultsToShow alone misses them.)
    var isIdleDockBar: Bool {
        switch currentDockSurfaceMode {
        case .generalChat:
            return aiMode.messages.isEmpty && !aiMode.isLoading && aiMode.streamingId == nil
        case .contextDockChat:
            return l2.chatMessages.isEmpty && !l2.isLoading
        case .globalContext, .contextDock, .mediaDock:
            return searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !shouldShowUnifiedDockModeContent
                && !usesVerticalListDockLayout
                && !hasResultsToShow
        }
    }

    @ViewBuilder
    func unifiedSearchPanelSurface(inDockMode: Bool) -> some View {
        // One stable container — the VStack (and its dockBaseView/TextField) is ALWAYS present, only
        // the card chrome is conditional, so the input is never recreated (focus survives the first
        // keystroke). Idle = glass pill (embeddedInSheet:false → dockBaseView draws its glowing
        // capsule); content = flush input inside the material card. The idle⇄content switch is made
        // instant via .animation(nil, value: idle) so the card and the input-glow never cross-fade
        // (that overlap was the "two sheets"). Matches the compact pill look of chat/media.
        let idle = isIdleDockBar
        HStack(spacing: 0) {
            Color.clear
                .frame(width: resultsPanelLeadingInset)
            VStack(spacing: 0) {
                if usesVerticalListDockLayout && inDockMode {
                    currentListDockSurface
                        .frame(width: resultsPanelWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                    Rectangle()
                        .fill(Color.white.opacity(isEffectiveDark ? 0.08 : 0.10))
                        .frame(height: 1)
                        .padding(.horizontal, 22)
                }

                dockBaseView(inDockMode: inDockMode, fillWidth: true, embeddedInSheet: !idle)
                    .frame(width: resultsPanelWidth, alignment: .leading)
                    .onDrop(
                        of: [.fileURL, .text, .plainText, .url],
                        isTargeted: clipboardDropTargetedBinding
                    ) { providers in
                        handleDockContextDrop(providers)
                    }
                    .onHover { hovering in
                        if hovering && clipboardDropTargetVisible {
                            revealClipboardDropTarget()
                        }
                    }

                if usesVerticalListDockLayout && !inDockMode {
                    Rectangle()
                        .fill(Color.white.opacity(isEffectiveDark ? 0.08 : 0.10))
                        .frame(height: 1)
                        .padding(.horizontal, 22)
                    currentListDockSurface
                        .frame(width: resultsPanelWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                }

                // Mode-specific content below the input: search results (global / context dock),
                // AI chat (general chat), app chat (context-dock chat). Media has none.
                // Chat modes render at their INTRINSIC height and report it back (measuredChat-
                // ContentHeight) so the window fits the real conversation; search modes use the
                // computed results height. Gate chat on message presence (not the measured height,
                // which starts at 0) to avoid a chicken-and-egg where it never gets to render.
                let isChatMode =
                    currentDockSurfaceMode == .generalChat
                    || currentDockSurfaceMode == .contextDockChat
                let modeContentHeight = unifiedDockModeContentHeight
                let showsModeContent = isChatMode ? shouldShowUnifiedDockModeContent : (modeContentHeight > 0)
                if showsModeContent {
                    Rectangle()
                        .fill(Theme.separator(isEffectiveDark))
                        .frame(height: 1)
                        .padding(.horizontal, 18)

                    // Chat: the section sizes itself — it measures its intrinsic message height and
                    // frames its own scroll to min(measured, cap), so the sheet hugs short chats and
                    // scrolls long ones with no clipping. Search: computed height.
                    if isChatMode {
                        unifiedDockModeContent
                            .frame(width: resultsPanelWidth, alignment: .leading)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        unifiedDockModeContent
                            .frame(height: modeContentHeight)
                            .frame(width: resultsPanelWidth, alignment: .leading)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .frame(width: resultsPanelWidth, alignment: .leading)
            .background {
                if !idle {
                    // Solid dock-color material (no glassEffect): the glass rim produced
                    // a double outline against the window edge. One material fill + one
                    // subtle stroke = a single clean edge, no shadow.
                    ZStack {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.clear)
                            .background(GlassBackground(cornerRadius: 28, isDark: isEffectiveDark))
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(isEffectiveDark ? 0.075 : 0.14),
                                        .white.opacity(isEffectiveDark ? 0.018 : 0.04),
                                        .black.opacity(isEffectiveDark ? 0.035 : 0.012),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        // User-adjustable darkness (Appearance ▸ Glass Darkness).
                        if settings.glassDarkness > 0.001 {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(Color.black.opacity(settings.glassDarkness * 0.22))
                        }
                    }
                }
            }
            .overlay {
                if !idle {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(isEffectiveDark ? 0.34 : 0.58),
                                    .white.opacity(isEffectiveDark ? 0.10 : 0.20),
                                    .white.opacity(isEffectiveDark ? 0.025 : 0.08),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                }
            }
            .animation(nil, value: idle)
            Spacer(minLength: 0)
        }
        .frame(width: calculatedWidth, alignment: .leading)
    }

    // MARK: - Dock Base View (always visible, doesn't move)
    @ViewBuilder
    func dockBaseView(inDockMode: Bool, fillWidth: Bool = false, embeddedInSheet: Bool = false) -> some View {
        // fillWidth: inside unifiedSearchPanelSurface the input bar must span the full
        // resultsPanelWidth so the pill row and the result rows read as one block. Without it the
        // capsule collapses to collapsedInputWidth whenever a result/app pill is focused, leaving a
        // narrow pill floating over the wider panel ("two docks" look).
        let inputIsExpanded =
            fillWidth
            || ((isSearchBarExpanded || usesVerticalListDockLayout)
                && (l2.focusedPillIndex == nil || usesVerticalListDockLayout)
                && !showMediaLayer)
        // Input bar size is driven by the expanded state, NOT by whether results/action-list are
        // showing. Keying it off usesVerticalListDockLayout made the bar grow the moment the user
        // typed (52 → 56) because the action list only appears once there's a query. Lock the
        // expanded bar to the larger height so the empty and typed states stay the same size.
        let outerVerticalPadding: CGFloat = inputIsExpanded ? 4 : 6
        let inputVerticalPadding: CGFloat = inputIsExpanded ? 4 : 6
        let inputPillHeight: CGFloat =
            inputIsExpanded ? 56 : CGFloat(settings.dockIconSize) + 8
        let inputTextSize: CGFloat = 15
        let inputTextWeight: Font.Weight = .medium
        let collapsedInputWidth: CGFloat = inputPillHeight

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Left slot: full search input OR icon-only anchor during app/action pill keyboard nav
                // In list view mode the pill list is a separate panel below the search bar,
                // so nav focus should never collapse the search bar to an icon.
                let actionPillNavActive =
                    l2.focusedPillIndex != nil && showContextInDock && !isGlobalContextActive
                    && currentDockSurfaceMode != .generalChat && !usesVerticalListDockLayout
                let globalAppNavActive =
                    focusedAppPillIndex != nil && isGlobalContextActive
                    && currentDockSurfaceMode != .generalChat
                    && !usesVerticalListDockLayout
                let pillNavActive = actionPillNavActive || globalAppNavActive
                let compactScopeKey = isCompactSmartScope ? searchState.activeSmartQueryKey : nil
                if pillNavActive {
                    searchAsPillView
                }
                if !pillNavActive && !showMediaLayer {
                    HStack(spacing: 10) {
                        // Search icon
                        if currentDockSurfaceMode == .generalChat {
                            Menu {
                                ForEach(AIProvider.allCases) { provider in
                                    Button(action: {
                                        settings.selectedAIProvider = provider
                                    }) {
                                        HStack {
                                            Image(systemName: provider.iconName)
                                            Text(provider.shortName)
                                            Spacer()
                                            if settings.selectedAIProvider == provider {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }

                                Divider()

                                Button("AI Settings...") {
                                    openSettings()
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: settings.selectedAIProvider.iconName)
                                        .foregroundStyle(providerColor)
                                        .font(.system(size: 15, weight: .semibold))
                                        .frame(width: 20, height: 20)
                                    Text(settings.selectedAIProvider.shortName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .foregroundStyle(.secondary.opacity(0.75))
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .padding(.leading, 9)
                                .padding(.trailing, 9)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [
                                                    .white.opacity(isEffectiveDark ? 0.28 : 0.42),
                                                    .white.opacity(isEffectiveDark ? 0.06 : 0.12),
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 0.8
                                        )
                                )
                            }
                            .menuStyle(.borderlessButton)
                            .buttonStyle(.plain)
                            .fixedSize()
                            .onHover { hovering in
                                guard acceptsMouseDrivenDockInteraction else { return }
                                isHoveringSearchIcon = hovering
                                if hovering {
                                    expandSearchBar()
                                } else {
                                    // Start collapse timer when stopping hover (if no input and not focused)
                                    if searchState.query.isEmpty && !isSearchFieldFocused {
                                        startCollapseTimer()
                                    }
                                }
                            }
                            .help("Select AI Provider")
                        } else {
                            Button(action: {
                                if isGlobalContextActive,
                                    activeSelectionIcon == nil,
                                    globalInlineAppScope == nil,
                                    l2.targetApp == nil,
                                    compactScopeKey == nil
                                {
                                    activateNotificationScope()
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        expandSearchBar()
                                    }
                                    requestWindowSizeUpdate(reason: .rowLayoutChanged)
                                }
                            }) {
                                // Globe on L3, app icon on L2 (target override or frontmost), magnifying glass on L1
                                if showMediaLayer {
                                    // Media layer: show album art, or player app icon, or music note
                                    let mediaIcon: NSImage? =
                                        mediaObserver.artworkImage
                                        ?? mediaObserver.appIcon
                                        ?? NSWorkspace.shared.runningApplications
                                        .first(where: {
                                            ($0.localizedName ?? "") == mediaObserver.appName
                                        })?.icon
                                    if let icon = mediaIcon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 28, height: 28)
                                            .clipShape(
                                                RoundedRectangle(
                                                    cornerRadius: mediaObserver.artworkImage != nil
                                                        ? 6 : 7)
                                            )
                                            .opacity(isHoveringSearchIcon ? 1.0 : 0.9)
                                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                                            .id("media-\(mediaObserver.appName)")
                                    } else {
                                        Image(systemName: "music.note")
                                            .foregroundStyle(
                                                .secondary.opacity(isHoveringSearchIcon ? 0.8 : 0.6)
                                            )
                                            .font(.system(size: 16, weight: .medium))
                                            .frame(width: 24, height: 24)
                                    }
                                } else if showContextInDock && settings.enableFrontmostDetection {
                                    // l2.targetApp overrides frontmost icon after Tab completion
                                    let focusedGlobalAppResult =
                                        focusedGlobalAppResultForInputPreview()
                                    let topGlobalAppResult = topGlobalAppResultForInputPreview()
                                    let previewGlobalAppResult =
                                        focusedGlobalAppResult ?? topGlobalAppResult
                                    let previewGlobalAppBundleId = previewGlobalAppResult.flatMap {
                                        bundleIdentifier(forApplicationResult: $0)
                                    }
                                    let scopedGlobalAppIcon = globalScopedAppIcon(
                                        for: searchState.query)
                                    let topGlobalMenuIcon = topGlobalMenuGroupIconForInputPreview(
                                        query: searchState.query)
                                    let preferFrontmostMenuIcon =
                                        hasFrontmostMenuPillsInCurrentCache(for: searchState.query)
                                    let typedAppIcon =
                                        (scopedGlobalAppIcon != nil
                                            || (shouldUsePureGlobalAppSearch
                                                && !preferFrontmostMenuIcon)
                                            || hasSelectionScopeSurface)
                                        ? nil : typedL2AppIcon(for: searchState.query)
                                    let browserPageIcon =
                                        isContextDockChatConnected ? currentBrowserPageIcon() : nil
                                    let feedbackAppIcon = inlineDockFeedbackAppIcon()
                                    // In Finder desktop-only mode (no window open) treat icon as nil → globe.
                                    // Built as a typed candidate list (first non-nil wins) instead of a
                                    // long `??` chain: the mixed-optional chain took ~9s to type-check and
                                    // blew the solver limit on older Xcode toolchains (CI). Same result.
                                    let displayIconCandidates: [NSImage?] = [
                                        feedbackAppIcon,
                                        scopedGlobalAppIcon?.icon,
                                        previewGlobalAppResult?.icon,
                                        topGlobalMenuIcon,
                                        l2.targetApp?.icon,
                                        typedAppIcon?.icon,
                                        browserPageIcon,
                                        isGlobalContextActive ? nil : frontmost.icon,
                                    ]
                                    let displayIcon: NSImage? =
                                        displayIconCandidates.first(where: { $0 != nil }) ?? nil
                                    let displayIconIdentityCandidates: [String?] = [
                                        launcherViewModel.inlineDockFeedback?.bundleID,
                                        scopedGlobalAppIcon?.bundleId,
                                        previewGlobalAppBundleId,
                                        topGlobalMenuIcon == nil ? nil : "global-menu",
                                        l2.targetApp?.bundleId,
                                        typedAppIcon?.bundleId,
                                        currentBrowserPageIconIdentity,
                                        frontmost.bundleID,
                                    ]
                                    let displayIconIdentity: String? =
                                        displayIconIdentityCandidates.first(where: { $0 != nil }) ?? nil
                                    let menuIcon = menuInputIconForSearchText(
                                        hasAppMatch: scopedGlobalAppIcon != nil
                                            || previewGlobalAppResult != nil || l2.targetApp != nil
                                            || typedAppIcon != nil
                                    )
                                    if isGlobalContextActive && !preferFrontmostMenuIcon
                                        && l2.targetApp == nil && typedAppIcon == nil
                                        && previewGlobalAppResult == nil
                                        && scopedGlobalAppIcon == nil
                                    {
                                        if let feedbackIcon = feedbackAppIcon {
                                            // Action in progress (quit/launch/run): show THAT app's
                                            // icon on the left so the toast reads "[Safari] Safari
                                            // quit … ✓" instead of the generic dock arrow.
                                            Image(nsImage: feedbackIcon)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 26, height: 26)
                                                .clipShape(
                                                    RoundedRectangle(
                                                        cornerRadius: 6, style: .continuous))
                                                .transition(
                                                    .scale(scale: 0.8).combined(with: .opacity))
                                                .id("feedback-\(displayIconIdentity ?? "app")")
                                        } else if let selIcon = frozenSelectionIcon
                                            ?? activeSelectionIcon
                                        {
                                            // Active selection: icon mirrors the content type (file, text, link, clipboard)
                                            Image(systemName: selIcon)
                                                .foregroundStyle(
                                                    Color.purple.opacity(
                                                        isHoveringSearchIcon ? 1.0 : 0.88)
                                                )
                                                .font(.system(size: 16, weight: .semibold))
                                                .frame(width: 24, height: 24)
                                                .transition(
                                                    .scale(scale: 0.8).combined(with: .opacity)
                                                )
                                                .id(selIcon)
                                                .animation(
                                                    .spring(response: 0.22, dampingFraction: 0.75),
                                                    value: selIcon)
                                        } else {
                                            LiquidGlassArrow(size: 24)
                                                .id("context-dock-input-logo")
                                        }
                                    } else if let finderSymbol = finderInputSymbolForSearchText() {
                                        Image(systemName: finderSymbol)
                                            .foregroundStyle(
                                                Color.accentColor.opacity(
                                                    isHoveringSearchIcon ? 1.0 : 0.85)
                                            )
                                            .font(.system(size: 17, weight: .semibold))
                                            .frame(width: 24, height: 24)
                                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                                            .id("finder-input-\(finderSymbol)")
                                            .animation(
                                                .spring(response: 0.22, dampingFraction: 0.75),
                                                value: finderSymbol)
                                    } else if let menuIcon {
                                        if let image = menuIcon.image {
                                            Image(nsImage: image)
                                                .resizable()
                                                .interpolation(.high)
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 24, height: 24)
                                                .opacity(isHoveringSearchIcon ? 1.0 : 0.9)
                                                .transition(
                                                    .scale(scale: 0.7).combined(with: .opacity)
                                                )
                                                .id("menu-input-image-\(menuIcon.symbol)")
                                        } else {
                                            Image(systemName: menuIcon.symbol)
                                                .foregroundStyle(
                                                    Color.accentColor.opacity(
                                                        isHoveringSearchIcon ? 1.0 : 0.85)
                                                )
                                                .font(.system(size: 17, weight: .semibold))
                                                .frame(width: 24, height: 24)
                                                .transition(
                                                    .scale(scale: 0.8).combined(with: .opacity)
                                                )
                                                .id("menu-input-\(menuIcon.symbol)")
                                        }
                                    } else if let appIcon = displayIcon {
                                        // 28 pt icon in context dock — matches expanded appPillButton
                                        let iconSize: CGFloat = showContextInDock ? 28 : 20
                                        Image(nsImage: appIcon)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: iconSize, height: iconSize)
                                            .clipShape(
                                                RoundedRectangle(
                                                    cornerRadius: showContextInDock ? 7 : 4)
                                            )
                                            .opacity(isHoveringSearchIcon ? 1.0 : 0.9)
                                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                                            .id(displayIconIdentity)
                                    } else {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundStyle(
                                                .secondary.opacity(isHoveringSearchIcon ? 0.8 : 0.5)
                                            )
                                            .font(.system(size: 18, weight: .semibold))
                                            .frame(width: 24, height: 24)
                                    }
                                } else {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(
                                            .secondary.opacity(isHoveringSearchIcon ? 0.8 : 0.5)
                                        )
                                        .font(.system(size: 18, weight: .semibold))
                                        .frame(width: 24, height: 24)
                                }
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                guard acceptsMouseDrivenDockInteraction else { return }
                                isHoveringSearchIcon = hovering
                                if hovering && !suppressHoverExpand {
                                    expandSearchBar()
                                }
                            }
                            .help(
                                isGlobalContextActive
                                    ? "Switch to frontmost app context"
                                    : "Switch to Global Context"
                            )
                            // Hide standalone icon when a context/scope chip owns the left slot.
                            .opacity(
                                isSearchBarExpanded
                                    && (compactScopeKey != nil || l2.targetApp != nil
                                        || globalInlineAppScope != nil
                                        || shouldShowFrontmostContextChip) && showContextInDock ? 0 : 1
                            )
                            .frame(
                                width: isSearchBarExpanded
                                    && (compactScopeKey != nil || l2.targetApp != nil
                                        || globalInlineAppScope != nil
                                        || shouldShowFrontmostContextChip) && showContextInDock
                                    ? 0 : nil)
                        }

                        // Spotlight-style app context chip — shown after Tab/→ on app result
                        if let ctx = searchState.contextApp, !showContextInDock {
                            HStack(spacing: 5) {
                                if let icon = ctx.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 16, height: 16)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                                Text(ctx.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Button(action: { clearSearchContext() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 0.5)
                            )
                        }

                        if let compactScopeKey, showContextInDock, isSearchBarExpanded {
                            let isClipboard = compactScopeKey == "clipboard"
                            let label = isClipboard ? "Clipboard" : "Notifications"
                            let symbol = isClipboard ? "doc.on.clipboard" : "bell.badge"
                            let accent =
                                isClipboard ? SwiftUI.Color.blue : SwiftUI.Color.accentColor
                            let chipTextColor: SwiftUI.Color =
                                systemColorScheme == .dark
                                ? SwiftUI.Color.white.opacity(0.94)
                                : SwiftUI.Color.black.opacity(0.82)
                            HStack(spacing: 6) {
                                Image(systemName: symbol)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .frame(width: 18, height: 18)
                                Text(label)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(chipTextColor)
                                    .lineLimit(1)
                                Button {
                                    clearSearchContext()
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(chipTextColor)
                                        .frame(width: 16, height: 16)
                                        .background(
                                            chipTextColor.opacity(
                                                systemColorScheme == .dark ? 0.14 : 0.10),
                                            in: Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove \(label.lowercased()) scope")
                                .opacity(0.72)
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 6)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule(style: .continuous))
                            .background(
                                accent.opacity(systemColorScheme == .dark ? 0.28 : 0.18),
                                in: Capsule(style: .continuous)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        accent.opacity(systemColorScheme == .dark ? 0.48 : 0.34),
                                        lineWidth: 0.8)
                            )
                            .shadow(
                                color: accent.opacity(systemColorScheme == .dark ? 0.28 : 0.16),
                                radius: 8, x: 0, y: 2
                            )
                            .transition(
                                .scale(scale: 0.86, anchor: .leading).combined(with: .opacity))
                        }

                        // Soft frontmost context chip — same visual language as app scope,
                        // but not locked. Frontmost app changes still update this chip.
                        if shouldShowFrontmostContextChip,
                            let icon =
                                inlineDockFeedbackAppIcon()
                                ?? (isContextDockChatConnected ? currentBrowserPageIcon() : nil)
                                ?? frontmost.icon
                        {
                            let accent = icon.dominantSwiftUIColor
                            let chipTextColor: SwiftUI.Color =
                                systemColorScheme == .dark
                                ? SwiftUI.Color.white.opacity(0.94)
                                : SwiftUI.Color.black.opacity(0.82)
                            HStack(spacing: 6) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 18, height: 18)
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous))
                                Text(inlineDockFeedbackAppName() ?? frontmost.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(chipTextColor)
                                    .lineLimit(1)
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, isHoveringFrontmostContextChip ? 9 : 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule(style: .continuous))
                            .background(
                                accent.opacity(systemColorScheme == .dark ? 0.20 : 0.12),
                                in: Capsule(style: .continuous)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        accent.opacity(systemColorScheme == .dark ? 0.36 : 0.24),
                                        lineWidth: 0.8)
                            )
                            .shadow(
                                color: accent.opacity(systemColorScheme == .dark ? 0.20 : 0.12),
                                radius: 7, x: 0, y: 2
                            )
                            .help("Frontmost app context")
                            .onTapGesture {
                                if !frontmost.bundleID.isEmpty {
                                    _ = activateInlineDockAppScope(
                                        bundleIdentifier: frontmost.bundleID,
                                        appName: frontmost.name,
                                        queryOverride: searchState.query,
                                        expand: true,
                                        preserveGlobalContext: isGlobalContextActive
                                    )
                                }
                            }
                            .onHover { hovering in
                                withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) {
                                    isHoveringFrontmostContextChip = hovering
                                }
                            }
                            .transition(
                                .scale(scale: 0.86, anchor: .leading).combined(with: .opacity))
                        }

                        // Pinned L2 scope badge — full capsule matching global inline scope style.
                        if let target = l2.targetApp, showContextInDock, isSearchBarExpanded {
                            let scopeIcon: NSImage =
                                target.icon
                                ?? NSWorkspace.shared.icon(
                                    forFile: NSWorkspace.shared.urlForApplication(
                                        withBundleIdentifier: target.bundleId)?.path ?? "")
                            let accent =
                                target.bundleId.hasPrefix("scope://")
                                ? SwiftUI.Color.accentColor : scopeIcon.dominantSwiftUIColor
                            let chipTextColor: SwiftUI.Color =
                                systemColorScheme == .dark
                                ? SwiftUI.Color.white.opacity(0.94)
                                : SwiftUI.Color.black.opacity(0.82)
                            HStack(spacing: 6) {
                                if target.bundleId == "scope://clipboard" {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 18, height: 18)
                                } else {
                                    Image(nsImage: scopeIcon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 18, height: 18)
                                        .clipShape(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous))
                                }
                                Text(target.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(chipTextColor)
                                    .lineLimit(1)
                                Button {
                                    exitL2DockScope()
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(chipTextColor)
                                        .frame(width: 16, height: 16)
                                        .background(
                                            chipTextColor.opacity(
                                                systemColorScheme == .dark ? 0.14 : 0.10),
                                            in: Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove app scope")
                                .opacity(isHoveringL2ScopeChip ? 1 : 0.72)
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, isHoveringL2ScopeChip ? 8 : 6)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule(style: .continuous))
                            .background(
                                accent.opacity(systemColorScheme == .dark ? 0.28 : 0.18),
                                in: Capsule(style: .continuous)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        accent.opacity(systemColorScheme == .dark ? 0.48 : 0.34),
                                        lineWidth: 0.8)
                            )
                            .shadow(
                                color: accent.opacity(systemColorScheme == .dark ? 0.28 : 0.16),
                                radius: 8, x: 0, y: 2
                            )
                            .onHover { hovering in
                                withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) {
                                    isHoveringL2ScopeChip = hovering
                                }
                            }
                            .transition(
                                .scale(scale: 0.86, anchor: .leading).combined(with: .opacity))
                        }

                        // Submenu parent chip — liquid glass capsule matching the dock bar style
                        if let locked = lockedSubmenuParent, showContextInDock {
                            HStack(spacing: 0) {
                                Text(locked.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(nsColor: .labelColor))
                                    .lineLimit(1)
                                    .padding(.leading, 10)
                                    .padding(.trailing, 6)
                                // Dark circle with › (mirrors the "Get started ›" reference)
                                ZStack {
                                    Circle()
                                        .fill(Color(nsColor: .labelColor).opacity(0.88))
                                        .frame(width: 20, height: 20)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                                }
                                .padding(.trailing, 4)
                            }
                            .frame(height: 30)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                    lockedSubmenuParent = nil
                                }
                            }
                            .transition(
                                .scale(scale: 0.82, anchor: .leading).combined(with: .opacity)
                            )
                            .animation(
                                .spring(response: 0.22, dampingFraction: 0.8), value: locked.title)
                        }

                        if let findToken = lockedFindToken, showContextInDock {
                            findTokenChip(findToken)
                                .transition(
                                    .scale(scale: 0.82, anchor: .leading).combined(with: .opacity))
                        }

                        // Vertical separator between icon and text — mirrors expanded appPillButton
                        // Separator and text field are hidden when a context pill is keyboard-focused
                        // (the input shrinks to icon-only to give pills more room)
                        if inputIsExpanded
                            && showContextInDock && !isGlobalContextActive && l2.targetApp == nil
                            && !shouldShowFrontmostContextChip
                            && currentDockSurfaceMode != .generalChat
                            && l2.focusedPillIndex == nil
                        {
                            Rectangle()
                                .fill(Color.white.opacity(0.16))
                                .frame(width: 1, height: 28)
                        }

                        // Text field - visible when expanded AND no pill is keyboard-focused AND media layer is off.
                        // List view keeps the search header stable even while keyboard focus moves through results.
                        if (isSearchBarExpanded || usesVerticalListDockLayout)
                            && (l2.focusedPillIndex == nil || usesVerticalListDockLayout)
                            && !showMediaLayer
                        {
                            let selectedResult: SearchResult? = {
                                guard let idx = searchState.selectedIndex,
                                    idx < searchState.results.count,
                                    currentDockSurfaceMode != .generalChat, !isL2ContextActive,
                                    allGlobalInlineAppScopes.isEmpty,
                                    l2.targetApp == nil,
                                    searchState.activeSmartQueryKey == nil,
                                    searchState.contextApp == nil
                                else { return nil }
                                return searchState.results[idx]
                            }()
                            let aiFallbackActive =
                                (showContextInDock && l2.chatArmed)
                                || shouldShowContextDockAIQueryFallback
                            let suppressScopedEmptyPreview =
                                showContextInDock
                                && l2.targetApp != nil
                                && searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            let focusedDockPill =
                                allGlobalInlineAppScopes.isEmpty && !aiFallbackActive
                                    && !suppressScopedEmptyPreview
                                ? focusedDockPillForInputPreview() : nil
                            let rawQueryAllowsGhost =
                                searchState.query
                                == searchState.query.trimmingCharacters(
                                    in: .whitespacesAndNewlines)
                            // Once an app is scoped (right-arrow / click), no global-app
                            // completion ghost may render — otherwise the old typed query
                            // bleeds through behind the scope pill.
                            let focusedGlobalAppResult =
                                allGlobalInlineAppScopes.isEmpty && !aiFallbackActive
                                    && l2.targetApp == nil
                                    && !suppressScopedEmptyPreview
                                ? focusedGlobalAppResultForInputPreview() : nil
                            let topGlobalAppResult =
                                allGlobalInlineAppScopes.isEmpty && rawQueryAllowsGhost
                                    && !aiFallbackActive
                                    && l2.targetApp == nil
                                    && !suppressScopedEmptyPreview
                                ? topGlobalAppResultForInputPreview() : nil
                            // Spotlight-style: show result name in bar whenever a result is selected (even while typing)
                            let showingResultPreview =
                                focusedDockPill != nil || focusedGlobalAppResult != nil
                                || topGlobalAppResult != nil || selectedResult != nil
                            ZStack(alignment: .leading) {
                                if !isGlobalContextActive && !allGlobalInlineAppScopes.isEmpty {
                                    globalInlineScopeQueryOverlay
                                }
                                // Selected result preview (Spotlight-style: "Visual Studio Code.app — Open")
                                if let pill = focusedDockPill {
                                    // Finder folder/file pills carry the full path as name —
                                    // ghost shows just the file/folder name, not the path.
                                    let title = inputGhostPillTitle(pill)
                                    let typed = searchState.query
                                    let isPrefixMatch = title.lowercased().hasPrefix(
                                        typed.lowercased())

                                    HStack(spacing: 0) {
                                        if isPrefixMatch && !typed.isEmpty {
                                            Text(typed)
                                                .font(.system(size: inputTextSize, weight: inputTextWeight))
                                                .foregroundStyle(.clear)
                                            Text(String(title.dropFirst(typed.count)))
                                                .font(.system(size: inputTextSize, weight: inputTextWeight))
                                                .foregroundStyle(.secondary.opacity(0.45))
                                                .lineLimit(1)
                                        } else {
                                            Text(title)
                                                .font(.system(size: inputTextSize, weight: inputTextWeight))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                        }
                                        if let badge = pill.badge, !badge.isEmpty {
                                            Text("  \(badge)")
                                                .font(.system(size: inputTextSize, weight: .regular))
                                                .foregroundStyle(.secondary.opacity(0.25))
                                        }
                                        Text("  — ↵")
                                            .font(.system(size: inputTextSize, weight: .regular))
                                            .foregroundStyle(.secondary.opacity(0.25))
                                    }
                                } else if let result = focusedGlobalAppResult {
                                    let title = inputFieldDisplayTitle(for: result)
                                    let typed = searchState.query
                                    let isPrefixMatch = title.lowercased().hasPrefix(
                                        typed.lowercased())

                                    HStack(spacing: 0) {
                                        if isPrefixMatch && !typed.isEmpty {
                                            Text(typed)
                                                .font(.system(size: inputTextSize, weight: inputTextWeight))
                                                .foregroundStyle(.clear)
                                            Text(String(title.dropFirst(typed.count)))
                                                .font(.system(size: inputTextSize, weight: inputTextWeight))
                                                .foregroundStyle(.secondary.opacity(0.45))
                                                .lineLimit(1)
                                        } else {
                                            Text(title)
                                                .font(.system(size: inputTextSize, weight: inputTextWeight))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                        }
                                        Text("  —  \(selectedResultAction(result))")
                                            .font(.system(size: inputTextSize, weight: .regular))
                                            .foregroundStyle(.secondary.opacity(0.35))
                                    }
                                } else if let result = topGlobalAppResult,
                                    inputFieldDisplayTitle(for: result).lowercased().hasPrefix(
                                        searchState.query.lowercased()),
                                    !searchState.query.isEmpty
                                {
                                    // Prefix match only: show typed (invisible) + grey completion + action
                                    let title = inputFieldDisplayTitle(for: result)
                                    let typed = searchState.query
                                    HStack(spacing: 0) {
                                        Text(typed)
                                            .font(.system(size: inputTextSize, weight: inputTextWeight))
                                            .foregroundStyle(.clear)
                                        Text(String(title.dropFirst(typed.count)))
                                            .font(.system(size: inputTextSize, weight: inputTextWeight))
                                            .foregroundStyle(.secondary.opacity(0.45))
                                            .lineLimit(1)
                                        Text("  —  \(selectedResultAction(result))")
                                            .font(.system(size: inputTextSize, weight: .regular))
                                            .foregroundStyle(.secondary.opacity(0.35))
                                    }
                                } else if let result = selectedResult {
                                    // Intelligent inline completion:
                                    // • Prefix match  → show typed text (invisible spacer) + greyed remainder + action
                                    // • Fuzzy match   → show full result name + action
                                    let title = inputFieldDisplayTitle(for: result)
                                    let typed = searchState.query
                                    let isPrefixMatch = title.lowercased().hasPrefix(
                                        typed.lowercased())

                                    HStack(spacing: 0) {
                                        if isPrefixMatch && !typed.isEmpty {
                                            // Typed portion — invisible spacer so grey completion aligns after cursor
                                            Text(typed)
                                                .font(.system(size: inputTextSize, weight: inputTextWeight))
                                                .foregroundStyle(.clear)
                                            // Grey completion (the "remaining" part)
                                            Text(String(title.dropFirst(typed.count)))
                                                .font(.system(size: inputTextSize, weight: inputTextWeight))
                                                .foregroundStyle(.secondary.opacity(0.45))
                                                .lineLimit(1)
                                        } else {
                                            // Fuzzy match — show full name in primary color
                                            Text(title)
                                                .font(.system(size: inputTextSize, weight: inputTextWeight))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                        }
                                        // Action hint
                                        Text("  —  \(selectedResultAction(result))")
                                            .font(.system(size: inputTextSize, weight: .regular))
                                            .foregroundStyle(.secondary.opacity(0.35))
                                    }
                                } else if !aiFallbackActive,
                                    !shouldUsePureGlobalAppSearch,
                                    !hasSelectionScopeSurface,
                                    isL2ContextActive, l2.targetApp == nil,
                                    let completion = l2.appCompletion,
                                    !completion.ghost.isEmpty,
                                    completion.actionQuery.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty,
                                    !searchState.query.isEmpty,
                                    !searchState.query.contains(" ")
                                {
                                    // L2 partial app autocomplete ghost text: "sa" → "sa[fari]  — Tab"
                                    HStack(spacing: 0) {
                                        Text(searchState.query)
                                            .font(.system(size: 15))
                                            .foregroundStyle(.clear)  // invisible spacer — aligns with real TextField cursor
                                        Text(completion.ghost)
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.4))
                                            .lineLimit(1)
                                        Text("  — Tab")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.25))
                                    }
                                } else if !aiFallbackActive,
                                    (!isGlobalContextActive || lockedSubmenuParent != nil),
                                    let subCtx = submenuGhostContext,
                                    let firstChild = subCtx.children.first,
                                    rawQueryAllowsGhost,
                                    lockedSubmenuParent != nil || !searchState.query.isEmpty
                                {
                                    // Locked mode: show child prefix completion → "d[ate]  — →"
                                    // Unlocked mode: "sort by"   → "sort by  ›  Date  — →"
                                    //                "sort by d"  → "sort by d[ate]  — →"
                                    HStack(spacing: 0) {
                                        if lockedSubmenuParent != nil {
                                            // Parent is shown as chip — just complete the child prefix
                                            if !searchState.query.isEmpty {
                                                Text(searchState.query)
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(.clear)
                                            }
                                            let suffix = String(
                                                firstChild.title.dropFirst(
                                                    min(
                                                        subCtx.childPrefix.count,
                                                        firstChild.title.count)
                                                )
                                            )
                                            if !suffix.isEmpty {
                                                Text(suffix)
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(.secondary.opacity(0.35))
                                                    .lineLimit(1)
                                            }
                                        } else {
                                            Text(searchState.query)
                                                .font(.system(size: 15))
                                                .foregroundStyle(.clear)
                                            if subCtx.childPrefix.isEmpty {
                                                Text("  ›  \(firstChild.title)")
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(.secondary.opacity(0.35))
                                                    .lineLimit(1)
                                            } else {
                                                let suffix = String(
                                                    firstChild.title.dropFirst(
                                                        min(
                                                            subCtx.childPrefix.count,
                                                            firstChild.title.count)
                                                    )
                                                )
                                                if !suffix.isEmpty {
                                                    Text(suffix)
                                                        .font(.system(size: 15))
                                                        .foregroundStyle(.secondary.opacity(0.35))
                                                        .lineLimit(1)
                                                }
                                            }
                                        }
                                        Text("  — →")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.2))
                                    }
                                } else if !aiFallbackActive,
                                    let ghost = ghostPillCompletion,
                                    rawQueryAllowsGhost,
                                    !searchState.query.isEmpty
                                {
                                    // Pill ghost completion: "slee" → "slee[p]  — ↵"
                                    HStack(spacing: 0) {
                                        Text(searchState.query)
                                            .font(.system(size: 15))
                                            .foregroundStyle(.clear)
                                        Text(String(ghost.name.dropFirst(searchState.query.count)))
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.35))
                                            .lineLimit(1)
                                        Text("  — ↵")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.2))
                                    }
                                } else if searchState.query.isEmpty {
                                    // Normal placeholders (always visible when field is empty)
                                    if let feedback = launcherViewModel.inlineDockFeedback {
                                        Text(feedback.title)
                                            .foregroundStyle(.secondary.opacity(0.46))
                                            .font(.system(size: 15, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    } else if lockedSubmenuParent != nil {
                                        Text("filter…")
                                            .foregroundStyle(.secondary.opacity(0.4))
                                            .font(.system(size: 15, weight: .regular))
                                    } else if currentDockSurfaceMode == .generalChat {
                                        Text("Ask \(settings.selectedAIProvider.shortName)...")
                                            .foregroundStyle(.secondary.opacity(0.5))
                                            .font(.system(size: 15, weight: .regular))
                                    } else if isGlobalContextActive,
                                        let prompt = activeSelectionPromptText
                                    {
                                        if searchState.contextApp == nil, l2.targetApp == nil {
                                            Text(prompt)
                                                .foregroundStyle(.secondary.opacity(0.34))
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        } else {
                                            // Chip hidden by another chip — show label in ghost text
                                            HStack(spacing: 0) {
                                                Text(prompt)
                                                    .foregroundStyle(.secondary.opacity(0.5))
                                                    .font(.system(size: 15, weight: .regular))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }
                                    } else if let ctx = searchState.contextApp {
                                        // Context panel (file, folder, app, contact, etc.)
                                        Text(
                                            remPanelIsProcessing
                                                ? "Processing…" : "Ask AI about \(ctx.name)…"
                                        )
                                        .foregroundStyle(.secondary.opacity(0.5))
                                        .font(.system(size: 15, weight: .regular))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    } else if let key = searchState.activeSmartQueryKey {
                                        // Built-in panel (reminders, calendar, notes, etc.)
                                        let label =
                                            settings.customAppEntries.first(where: { $0.key == key }
                                            )?
                                            .label ?? key.capitalized
                                        Text(
                                            key == "clipboard"
                                                ? "Search Clipboard…"
                                                : (key == "notifications"
                                                    ? "Search Notifications…"
                                                    : (remPanelIsProcessing
                                                        ? "Processing…" : "Ask AI about \(label)…"))
                                        )
                                        .foregroundStyle(.secondary.opacity(0.5))
                                        .font(.system(size: 15, weight: .regular))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    } else if isFinderDesktopOnlyMode,
                                        attachedFinderFolderSearchPath.isEmpty
                                    {
                                        // Finder desktop mode: show capability hint, not the Desktop pseudo-folder.
                                        Text(dockScopeGhostPrompt)
                                            .foregroundStyle(.secondary.opacity(0.55))
                                            .font(.system(size: 15, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    } else if !attachedFinderFolderSearchPath.isEmpty,
                                        frontmost.bundleID == "com.apple.finder"
                                    {
                                        // Finder folder attached as AI context scope
                                        let folderName = URL(
                                            fileURLWithPath: attachedFinderFolderSearchPath
                                        ).lastPathComponent
                                        HStack(spacing: 0) {
                                            Text(folderName.isEmpty ? "Current Folder" : folderName)
                                                .foregroundStyle(.secondary.opacity(0.5))
                                                .font(.system(size: 15, weight: .medium))
                                                .lineLimit(1)
                                            Text("  — search files & ask AI…")
                                                .foregroundStyle(.secondary.opacity(0.25))
                                                .font(.system(size: 15, weight: .regular))
                                                .lineLimit(1)
                                        }
                                    } else if showContextInDock && l2.chatArmed && !l2.showChatPopover {
                                        HStack(spacing: 0) {
                                            if let pageTitle = connectedBrowserPageGhostTitle {
                                                Text(pageTitle)
                                                    .foregroundStyle(.secondary.opacity(0.55))
                                                    .font(.system(size: 15, weight: .medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                                    .frame(maxWidth: 260, alignment: .leading)
                                                Text("  — ask about this page…")
                                                    .foregroundStyle(.secondary.opacity(0.25))
                                                    .font(.system(size: 15, weight: .regular))
                                                    .lineLimit(1)
                                            } else {
                                                Text("Ask \(contextDockChatDraftAppName)")
                                                    .foregroundStyle(.secondary.opacity(0.55))
                                                    .font(.system(size: 15, weight: .medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                                Text("  — press Enter to send…")
                                                    .foregroundStyle(.secondary.opacity(0.25))
                                                    .font(.system(size: 15, weight: .regular))
                                                    .lineLimit(1)
                                            }
                                        }
                                    } else if isGlobalContextActive, l2.targetApp == nil {
                                        // Global context (no app scoped): tell the user what they
                                        // can do here. When an app IS scoped (right-arrow), fall
                                        // through to the scoped "Ask <app>" prompt below instead.
                                        Text("Search Apps or menus")
                                            .foregroundStyle(.secondary.opacity(0.55))
                                            .font(.system(size: 15, weight: .medium))
                                            .lineLimit(1)
                                    } else if showContextInDock
                                        && !dockScopeDisplayName.trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        ).isEmpty
                                    {
                                        if let target = l2.targetApp {
                                            HStack(spacing: 0) {
                                                Text("Ask \(target.name)")
                                                    .foregroundStyle(.secondary.opacity(0.48))
                                                    .font(.system(size: 15, weight: .medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                                Text("…")
                                                    .foregroundStyle(.secondary.opacity(0.30))
                                                    .font(.system(size: 15, weight: .regular))
                                            }
                                        } else {
                                            // Context dock: app name + capability hints.
                                            Text(dockScopeGhostPrompt)
                                                .foregroundStyle(.primary.opacity(0.75))
                                                .font(.system(size: 15, weight: .semibold))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                    } else {
                                        Text("Context-Dock")
                                            .foregroundStyle(.secondary.opacity(0.5))
                                            .font(.system(size: 15, weight: .regular))
                                    }
                                }

                                TextField("", text: $searchState.query)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: inputTextSize, weight: inputTextWeight))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .focused($isSearchFieldFocused)
                                    .focusEffectDisabled()
                                    .background(FocusRingSuppressor())
                                    .accessibilityLabel("Search — Context Dock")
                                    // For prefix match: TextField stays visible (shows typed text + cursor).
                                    // For fuzzy match or empty: hide it so the full result name shows cleanly.
                                    .opacity(
                                        {
                                            if settings.effectiveDockAtBottom
                                                && usesVerticalListDockLayout
                                                && !searchState.query.isEmpty
                                            {
                                                return 1
                                            }
                                            if let pill = focusedDockPill {
                                                let isPrefixMatch = pill.name.lowercased()
                                                    .hasPrefix(
                                                        searchState.query.lowercased())
                                                return (isPrefixMatch && !searchState.query.isEmpty)
                                                    ? 1 : 0
                                            }
                                            if let result = focusedGlobalAppResult {
                                                let isPrefixMatch = inputFieldDisplayTitle(for: result)
                                                    .lowercased()
                                                    .hasPrefix(searchState.query.lowercased())
                                                return (isPrefixMatch && !searchState.query.isEmpty)
                                                    ? 1 : 0
                                            }
                                            if let result = topGlobalAppResult {
                                                // Only hide TextField for prefix match (ghost shows completion).
                                                // For fuzzy match the TextField stays visible so typed text shows.
                                                let isPrefixMatch = inputFieldDisplayTitle(for: result)
                                                    .lowercased()
                                                    .hasPrefix(searchState.query.lowercased())
                                                return (isPrefixMatch && !searchState.query.isEmpty)
                                                    ? 1 : 1
                                            }
                                            if let result = selectedResult {
                                                let isPrefixMatch = inputFieldDisplayTitle(for: result)
                                                    .lowercased()
                                                    .hasPrefix(searchState.query.lowercased())
                                                return (isPrefixMatch && !searchState.query.isEmpty)
                                                    ? 1 : 0
                                            }
                                            if !isGlobalContextActive && !allGlobalInlineAppScopes.isEmpty {
                                                return 0
                                            }
                                            return 1
                                        }()
                                    )
                                    .onChange(of: searchState.query) { oldValue, newValue in
                                        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            launcherViewModel.inlineDockFeedback = nil
                                        }
                                        // Global Context app search filters instantly like the
                                        // file index — no 85 ms defer between keystroke and rows.
                                        // The deferred pass still runs for everything else.
                                        if isL2ContextActive, shouldUsePureGlobalAppSearch,
                                            lockedSubmenuParent == nil, lockedFindToken == nil,
                                            !isContextDockChatRoutingLocked, !isCompactSmartScope,
                                            searchState.activeSmartQueryKey == nil
                                        {
                                            let q = newValue
                                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                                .lowercased()
                                            if globalInlineAppScope == nil {
                                                scheduleGlobalAppMatchRebuild(query: q)
                                            } else {
                                                scheduleGlobalGroupedListRebuild(query: q)
                                            }
                                        }
                                        scheduleDeferredQueryChange(from: oldValue, to: newValue)
                                        if currentDockSurfaceMode == .globalContext,
                                            !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        {
                                            DispatchQueue.main.async {
                                                self.reclaimSearchInputFocus()
                                            }
                                        }
                                    }
                                    .onChange(of: isSearchFieldFocused) { oldValue, newValue in
                                        if newValue {
                                            collapseTimer?.cancel()
                                            // Kill the default select-all-on-focus: place the
                                            // caret at the end so the next backspace deletes ONE
                                            // char, not the whole (auto-selected) query. Skip when
                                            // a deliberate Up-arrow select-all is pending.
                                            if launcherViewModel.pendingSelectAllOnFocus {
                                                launcherViewModel.pendingSelectAllOnFocus = false
                                            } else if !searchState.query.isEmpty {
                                                DispatchQueue.main.async {
                                                    if let tv = NSApp.keyWindow?.firstResponder
                                                        as? NSTextView
                                                    {
                                                        moveSearchInsertionPointToEnd(in: tv)
                                                    }
                                                }
                                            }
                                        } else {
                                            if searchState.query.isEmpty
                                                && !usesVerticalListDockLayout
                                            {
                                                startCollapseTimer()
                                            }
                                        }
                                    }
                                    .onSubmit {
                                        if isL2ContextActive {
                                            if isCompactSmartScope {
                                                guard searchState.selectedIndex != nil else {
                                                    return
                                                }
                                                executeSelectedResult()
                                                return
                                            }
                                            dismissMediaLayer()
                                            let trimmed = searchState.query.trimmingCharacters(
                                                in: .whitespacesAndNewlines
                                            )
                                            if shouldUseFinderSearchPopover(for: trimmed) {
                                                if let firstResult = finderSemanticResults.first {
                                                    executeFinderFolderSearchResult(firstResult)
                                                }
                                                return
                                            }
                                            if let findToken = lockedFindToken {
                                                executeFindToken(
                                                    findToken, userMessage: "find \(trimmed)")
                                                return
                                            }
                                            if l2.focusedPillIndex != nil,
                                                executeFocusedOrDirectAppPillIfNeeded()
                                            {
                                                return
                                            }
                                            if executeFirstMatchingFinderFolderPillIfNeeded() {
                                                return
                                            }
                                            if executeFirstAttachedFinderFolderResultIfNeeded() {
                                                return
                                            }
                                            if launchTypedAppMatchIfNeeded() {
                                                return
                                            }
                                            if trimmed.isEmpty,
                                                shouldShowContextDockChatSheet || l2.showChatPopover || l2.chatArmed
                                            {
                                                exitContextDockChatAndScope()
                                                return
                                            }
                                            guard !trimmed.isEmpty else { return }
                                            // Send when arming the chat OR when a conversation is
                                            // already open (chatArmed clears after the first send, so
                                            // without shouldShowContextDockChatSheet follow-up queries
                                            // were silently dropped).
                                            if l2.chatArmed
                                                || shouldShowContextDockChatSheet
                                                || shouldShowContextDockAIQueryFallback
                                            {
                                                handleL2QuerySkippingMenuRouter(trimmed)
                                            }
                                        } else if currentDockSurfaceMode == .generalChat {
                                            if launchTypedAppMatchIfNeeded() {
                                                return
                                            }
                                            let q = searchState.query.trimmingCharacters(
                                                in: .whitespacesAndNewlines
                                            )
                                            if q.count > 3 {
                                                submitAIQuery()
                                            }
                                        } else if searchState.activeSmartQueryKey == "clipboard" {
                                            let q = searchState.query.trimmingCharacters(
                                                in: .whitespacesAndNewlines
                                            )
                                            if q.isEmpty {
                                                _ = pasteFocusedClipboardEntriesToFrontmost()
                                            } else {
                                                _ = submitClipboardScopeAIQuery(q)
                                            }
                                        } else if searchState.activeSmartQueryKey == "notifications"
                                        {
                                            guard searchState.selectedIndex != nil else { return }
                                            executeSelectedResult()
                                        } else if searchState.activeSmartQueryKey != nil
                                            || searchState.contextApp != nil
                                        {
                                            let q = searchState.query.trimmingCharacters(
                                                in: .whitespacesAndNewlines
                                            )
                                            guard !q.isEmpty else { return }
                                            handleRemPanelQuery()
                                        } else {
                                            executeSelectedResult()
                                        }
                                    }
                            }
                            .transition(
                                .opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))

                            if shouldShowSafariTabStrip {
                                safariTabStrip
                            } else if shouldShowGlobalRunningAppStrip {
                                globalRunningAppStrip
                            }

                            // Trailing area: a single status pill that the "+" morphs INTO during
                            // an action (spinner → ✓ / ✗), so there's never a separate tick pill
                            // next to the "+". Covers all phases; the "+" branch below only renders
                            // when there's no active feedback.
                            if let feedback = launcherViewModel.inlineDockFeedback,
                                currentDockSurfaceMode != .generalChat
                            {
                                inlineDockFeedbackActionIcon(feedback)
                                    .allowsHitTesting(false)
                                    .transition(
                                        .scale(scale: 0.88, anchor: .trailing)
                                            .combined(with: .opacity))
                            } else if let pill = focusedDockPill {
                                HStack(spacing: 8) {
                                    if let image = pill.menuItemImage {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 24, height: 24)
                                    } else {
                                        Image(systemName: pill.icon)
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(
                                                accentColor(for: pill.accentColorName))
                                            .frame(width: 24, height: 24)
                                    }
                                    if !searchState.query.isEmpty {
                                        Button(action: clearInputQuery) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary.opacity(0.5))
                                                .font(.system(size: 14))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Clear")
                                    }
                                }
                            } else if let result = selectedResult {
                                // Spotlight-style: show result icon on the right while a result is selected
                                HStack(spacing: 8) {
                                    if let icon = result.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 28, height: 28)
                                            .clipShape(
                                                RoundedRectangle(
                                                    cornerRadius: 6, style: .continuous)
                                            )
                                            .shadow(radius: 2)
                                    }
                                    if !searchState.query.isEmpty {
                                        Button(action: clearInputQuery) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary.opacity(0.5))
                                                .font(.system(size: 14))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Clear")
                                    }
                                }
                            } else if currentDockSurfaceMode == .generalChat {
                                aiModeControls
                            } else if searchState.isLoadingApps && searchState.results.isEmpty {
                                GlobalInputLoadingDots()
                                    .frame(width: 26, height: 26)
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            } else if shouldShowGlobalInputLoadingIndicator {
                                GlobalInputLoadingDots()
                                    .frame(width: 26, height: 26)
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            } else if shouldShowContextDockInputLoadingIndicator {
                                GlobalInputLoadingDots()
                                    .frame(width: 26, height: 26)
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            } else if showContextInDock && isContextDockChatConnected {
                                contextDockChatCloseButton
                            } else if !searchState.query.isEmpty {
                                Button(action: clearInputQuery) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary.opacity(0.5))
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .help("Clear")
                            } else if showGlobalClipboardPill && !globalClipboardText.isEmpty {
                                Button {
                                    activateClipboardScope()
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundStyle(Color.indigo.opacity(0.78))
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .help("Open clipboard")
                            } else if isGlobalContextActive {
                                HStack(spacing: 6) {
                                    // Live selection appears NEXT TO the other trailing
                                    // controls, never replacing them.
                                    if shouldShowSelectionTrailingButton {
                                        selectionTrailingButton
                                    }
                                    if isContextDockChatConnected {
                                        contextDockChatCloseButton
                                    }
                                }
                            } else if showContextInDock {
                                // "+" affordance per frontmost app: Finder window → attach the
                                // current folder for search; any other app → connect frontmost-app
                                // chat. Pressing → (or the button) turns the "+" into "−".
                                // A live selection shows its icon BESIDE the "+", not instead.
                                HStack(spacing: 6) {
                                    if shouldShowSelectionTrailingButton {
                                        selectionTrailingButton
                                    }
                                    if isContextDockChatConnected {
                                        contextDockChatCloseButton
                                    } else if !isCompactSmartScope {
                                        let finderContext =
                                            frontmost.bundleID == "com.apple.finder"
                                            || l2.targetApp?.bundleId == "com.apple.finder"
                                        if finderContext {
                                            // Finder window present (not desktop-only) → "+" attaches
                                            // the current folder for recursive/content search.
                                            if canAttachCurrentFinderFolderToConversation {
                                                addFinderFolderButton
                                            }
                                        } else if l2.targetApp == nil, !frontmost.bundleID.isEmpty,
                                            frontmost.bundleID != Bundle.main.bundleIdentifier
                                        {
                                            contextDockChatButton
                                        }
                                    }
                                }
                            } else if shouldShowSelectionTrailingButton {
                                selectionTrailingButton
                            }
                        }
                    }
                    .padding(
                        .horizontal,
                        ((isSearchBarExpanded || usesVerticalListDockLayout)
                            && (l2.focusedPillIndex == nil || usesVerticalListDockLayout)
                            && !showMediaLayer) ? 12 : 8
                    )
                    .padding(.vertical, inputVerticalPadding)
                    .frame(width: inputIsExpanded ? nil : collapsedInputWidth)
                    .frame(maxWidth: inputIsExpanded ? .infinity : collapsedInputWidth)
                    .frame(height: inputPillHeight)
                    .background {
                        // Context dock: keep app scope readable without turning the
                        // search capsule into a saturated app-colored panel.
                        let inContextDock =
                            showContextInDock || isGlobalContextActive
                                || currentDockSurfaceMode == .generalChat
                        let typedMatch =
                            hasSelectionScopeSurface || shouldUsePureGlobalAppSearch
                            ? nil : typedL2AppIcon(for: searchState.query)
                        let inAppScope =
                            (l2.targetApp != nil || typedMatch != nil) && showContextInDock
                        let compactScopeColor: SwiftUI.Color? = {
                            guard let key = searchState.activeSmartQueryKey,
                                key == "clipboard" || key == "notifications"
                            else { return nil }
                            return key == "clipboard" ? .blue : .accentColor
                        }()
                        let feedbackGlowColor = inlineDockFeedbackGlowColor()
                        let scopeColor: SwiftUI.Color =
                            feedbackGlowColor
                            ?? compactScopeColor
                            ?? l2.targetApp?.icon?.dominantSwiftUIColor
                            ?? typedMatch?.icon.dominantSwiftUIColor
                            ?? frontmost.icon?.dominantSwiftUIColor
                            ?? .white
                        let compactScopeResultFocused =
                            isCompactSmartScope
                            && (searchState.selectedIndex != nil
                                || focusedClipboardEntryIndex != nil)
                        let dockResultFocused =
                            compactScopeResultFocused
                            || (usesVerticalListDockLayout
                                && (focusedAppPillIndex != nil || l2.focusedPillIndex != nil))
                            || ((showContextInDock || isGlobalContextActive)
                                && searchState.selectedIndex != nil)
                        ZStack {
                            if embeddedInSheet {
                                // Flush in the sheet: the surrounding UnifiedDockSurface IS the
                                // container, so the input draws no pill of its own (Spotlight/Raycast
                                // model — search field is the top row, results below, one block).
                                EmptyView()
                            } else if inContextDock {
                                // Capsule pill — identical shape to expanded appPillButton
                                Capsule()
                                    .fill(Color.clear)
                                    .background(GlassBackground(cornerRadius: 999, isDark: isEffectiveDark))
                                    .clipShape(Capsule(style: .continuous))
                                    .matchedGeometryEffect(
                                        id: dockResultFocusEffectID,
                                        in: compactScopeFocusNamespace,
                                        properties: .frame,
                                        isSource: true
                                    )
                                    .opacity(dockResultFocused ? 0 : 1)
                                if !dockResultFocused {
                                    // Subtle dark underlay so the pill stays visible on BOTH
                                    // backdrops: against the wallpaper (context dock, standalone)
                                    // and against the material sheet behind it (general chat /
                                    // integrated panel), where the lighter glass alone vanished.
                                    Capsule()
                                        .fill(Color.black.opacity(isEffectiveDark ? 0.025 : 0.008))
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(inAppScope ? 0.12 : 0.10),
                                                    Color.white.opacity(inAppScope ? 0.036 : 0.03),
                                                    Color.black.opacity(isEffectiveDark ? 0.015 : 0.004),
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                    // App-color tint
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    scopeColor.opacity(inAppScope ? 0.055 : 0.06),
                                                    scopeColor.opacity(inAppScope ? 0.018 : 0.02),
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    // Crisp rim + soft outer glow — matches the media dock pill.
                                    // The glow tracks the idle-pill state: in search modes it drops
                                    // the moment results swap in, but in chat modes the pill (and its
                                    // glow) persists while composing the query and only hides when the
                                    // chat expands on the first response.
                                    let showIdleGlow = isIdleDockBar
                                    Capsule()
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [
                                                    .white.opacity(showIdleGlow ? 0.58 : 0.30),
                                                    .white.opacity(showIdleGlow ? 0.18 : 0.08),
                                                    .white.opacity(0.035),
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: showIdleGlow ? 1.5 : 1.0
                                        )
                                    if showIdleGlow {
                                        Capsule()
                                            .strokeBorder(
                                                (feedbackGlowColor ?? .white).opacity(
                                                    feedbackGlowColor.map { _ in 0.9 } ?? 0.75),
                                                lineWidth: 1.5
                                            )
                                            .blur(radius: 3)
                                    }
                                }
                            } else {
                                // Non-context-dock: plain dark rounded rect
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.black.opacity(0.18))
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.08),
                                                Color.white.opacity(0.04),
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 0.75
                                    )
                            }
                        }
                        .animation(
                            .spring(response: 0.28, dampingFraction: 0.75), value: inContextDock
                        )
                        .animation(.easeInOut(duration: 0.25), value: inAppScope)
                        .animation(.easeInOut(duration: 0.3), value: frontmost.bundleID)
                    }
                    .onHover { hovering in
                        guard acceptsMouseDrivenDockInteraction else { return }
                        isHoveringInputField = hovering

                        // Auto-shrink when mouse leaves input field (if no text and not focused)
                        if !hovering && searchState.query.isEmpty && !isSearchFieldFocused
                            && !usesVerticalListDockLayout
                        {
                            startCollapseTimer()
                        }
                    }
                    .animation(
                        .spring(response: 0.28, dampingFraction: 0.72), value: isSearchBarExpanded)
                }  // end if focusedAppPillIndex == nil

                // Pinned apps or context chips/AI extensions or browser (3-layer swipeable)
                if !isCompactSmartScope && currentDockSurfaceMode != .generalChat
                    && !usesVerticalListDockLayout
                {
                    HStack(spacing: 8) {
                        // Floating selection pill — not shown in context dock (already in search bar)
                        if !showContextInDock { selectionFloatingPill }
                        // Clipboard pill moved to searchBarSection (floats left of the main dock card)

                        Group {
                            if showMediaLayer {
                                mediaDockSurface
                                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                            } else if searchState.activeSmartQueryKey != nil && !isCompactSmartScope
                            {
                                appShortcutsInDock
                                    .transition(.opacity)
                            } else if showContextInDock {
                                if currentDockSurfaceMode == .generalChat {
                                    EmptyView()
                                } else if isGlobalContextActive {
                                    // Global context: empty query shows pinned/running; typed query searches
                                    // pinned, running, and installed applications.
                                    if shouldShowL2UnifiedDockRow {
                                        globalContextSurface
                                            .transition(.opacity)
                                    }
                                } else if hasAIExtensionsToShow {
                                    aiExtensionsInDock
                                        .transition(.opacity)
                                } else if shouldShowL2UnifiedDockRow {
                                    contextDockSurface
                                        .transition(.opacity)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(
                            height: showMediaLayer
                                ? (mediaObserver.duration > 0 ? 70 : inputPillHeight)
                                : nil
                        )

                    }
                    .onHover { hovering in
                        guard acceptsMouseDrivenDockInteraction else { return }
                        isHoveringDockArea = hovering
                        // When mouse enters the dock area, switch from keyboard nav to hover nav
                        if hovering { l2.pillNavViaKeyboard = false }
                    }
                    .animation(
                        .spring(response: 0.3, dampingFraction: 0.75), value: showContextInDock
                    )
                    .animation(
                        .spring(response: 0.28, dampingFraction: 0.82), value: showMediaLayer)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, outerVerticalPadding)

        }
        .frame(maxWidth: .infinity)
    }

    /// SF Symbol name for a file extension
    func fileIcon(for ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff": return "photo"
        case "mp4", "mov", "avi", "mkv", "m4v": return "film"
        case "mp3", "aac", "flac", "wav", "m4a": return "music.note"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        case "doc", "docx", "pages": return "doc.text"
        case "xls", "xlsx", "numbers", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        case "swift", "py", "js", "ts", "rb", "go", "rs", "kt":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    // MARK: - Results Content (for smart positioning)
    @ViewBuilder
    var searchResultsContent: some View {
        // Search-only content. General Chat and Context Dock Chat own their surfaces.
        let content = Group {
            if isCompactSmartScope {
                Group {
                    if searchState.activeSmartQueryKey == "clipboard" {
                        clipboardScopeView
                    } else {
                        notificationScopeView
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if showContextInDock && !showMediaLayer
                && !(l2.chatArmed && !l2.showChatPopover)
                && shouldShowContextDockAppPanel
            {
                appPanelView
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if showContextInDock && !showMediaLayer
                && shouldShowFinderSearchResultsPanel(for: searchState.query)
            {
                finderFolderSearchResultsPanel
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if showContextInDock && !showMediaLayer {
                VStack(spacing: 0) {
                    Group {
                        if livePanelVisible {
                            switch livePanelMode {
                            case .results, .filePreview:
                                livePanelView
                                    .transition(
                                        .asymmetric(
                                            insertion: .move(edge: .trailing).combined(
                                                with: .opacity),
                                            removal: .move(edge: .trailing).combined(
                                                with: .opacity)
                                        ))
                            default:
                                EmptyView()
                            }
                        }
                    }
                    .animation(
                        .spring(response: 0.28, dampingFraction: 0.85), value: livePanelVisible)
                    // Terminal drawer below chat (only for .terminal mode)
                    if livePanelVisible, case .terminal = livePanelMode,
                        let term = panelTerminalControllers[activeConsoleKey]
                    {
                        Divider().opacity(0.12)
                        inlineDockTerminalView(term: term)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                // Normal mode: Search results (works on L1/L2/L3)
                // L3 stays media-first, but search typing still uses the shared results list.
                indexingProgressSection
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                resultsSection
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }

        if settings.effectiveDockAtBottom {
            // In dock mode, add padding to results (match compact dock height)
            content
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        } else {
            // In normal mode, add subtle padding at top for smooth connection to dock
            content
                .padding(.top, isCompactSmartScope ? 0 : 4)
        }
    }

    @ViewBuilder
    var finderFolderSearchResultsPanel: some View {
        let scope = resolveDockScope(for: searchState.query)
        let folderPath = currentFinderFolderPath()
        let folderName = URL(fileURLWithPath: folderPath).lastPathComponent
        let query = scope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(folderName.isEmpty ? "Current Folder Search" : folderName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("Names + Content")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 12)

            if isFinderSemanticLoading && searchState.results.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Searching filenames and indexed content in this folder…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 16)
            } else if !query.isEmpty && searchState.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                    Text("No matches in this Finder folder.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("Try another name or content phrase.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 16)
            } else {
                resultsSection
            }
        }
    }

    private var inlineCaretBar: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 2, height: 20)
    }

    private func inlineQueryText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var globalInlineScopeQueryOverlay: some View {
        // Establish a dependency on caret movement so arrow keys re-render.
        _ = launcherViewModel.searchInputCaretTick
        let pieces = globalInlineQueryPieces
        let tokenRanges = globalInlineQueryTokenRanges()
        let caretOffset = searchInputCursorOffset()

        // Where the real caret renders: inside a text piece (split at offset)
        // or between pieces (slot index; pieces.count = trailing slot).
        var inPieceSplit: (pieceIndex: Int, local: Int)? = nil
        var caretSlot: Int? = nil
        if let caret = caretOffset {
            var resolved = false
            for (index, piece) in pieces.enumerated() {
                guard let span = globalInlinePieceSpan(piece, tokenRanges: tokenRanges) else {
                    continue
                }
                if caret <= span.lowerBound {
                    caretSlot = index
                    resolved = true
                    break
                }
                if caret < span.upperBound {
                    if case .text = piece {
                        inPieceSplit = (index, caret - span.lowerBound)
                    } else {
                        caretSlot = index + 1  // pills are atomic — snap after
                    }
                    resolved = true
                    break
                }
                if caret == span.upperBound {
                    caretSlot = index + 1
                    resolved = true
                    break
                }
            }
            if !resolved { caretSlot = pieces.count }
        } else if isSearchFieldFocused {
            caretSlot = pieces.count
        }

        return HStack(spacing: 4) {
            if pieces.isEmpty {
                if isSearchFieldFocused { inlineCaretBar }
                Text("Type action…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.42))
                    .lineLimit(1)
            } else {
                ForEach(Array(pieces.enumerated()), id: \.element.id) { index, piece in
                    if caretSlot == index { inlineCaretBar }
                    switch piece {
                    case .scope(let scope):
                        globalInlineScopeChip(scope)
                    case .text(let value, _):
                        if let split = inPieceSplit, split.pieceIndex == index {
                            let parts = splitTokenForCaret(value, utf16Offset: split.local)
                            HStack(spacing: 0) {
                                inlineQueryText(parts.0)
                                inlineCaretBar
                                inlineQueryText(parts.1)
                            }
                        } else {
                            inlineQueryText(value)
                        }
                    }
                }
                if caretSlot == pieces.count { inlineCaretBar }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        // Animate the inline scope chip in/out so scoping reads as a smooth content
        // swap within the one shell, not a snap. Keyed on the scope set + caret slot.
        .animation(
            .spring(response: 0.26, dampingFraction: 0.84),
            value: globalInlineAppScope?.bundleId
        )
        .animation(
            .spring(response: 0.26, dampingFraction: 0.84),
            value: additionalGlobalInlineAppScopes.count
        )
        .onTapGesture {
            reclaimSearchInputFocus()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)
        ) { note in
            guard let textView = note.object as? NSTextView,
                textView.window === AppDelegate.shared?.launcherWindow
            else { return }
            launcherViewModel.searchInputCaretTick &+= 1
        }
        .focusable(false)
        .focusEffectDisabled()
        .zIndex(2)
    }

    func globalInlineScopeChip(_ scope: GlobalInlineAppScope) -> some View {
        let isHovered = hoveredGlobalInlineScopeBundleId == scope.bundleId
        let icon: NSImage = {
            if scope.bundleId.hasPrefix("syscmd://") {
                let id = String(scope.bundleId.dropFirst("syscmd://".count))
                if let uuid = UUID(uuidString: id),
                    let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == uuid }),
                    let image = NSImage(systemSymbolName: command.icon, accessibilityDescription: command.name)
                {
                    return image
                }
            }
            if scope.bundleId.hasPrefix("cli://"),
                let image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: scope.appName)
            {
                return image
            }
            return FileManager.default.fileExists(atPath: scope.appPath)
                ? NSWorkspace.shared.icon(forFile: scope.appPath)
                : NSWorkspace.shared.icon(
                    forFile: NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: scope.bundleId)?.path ?? "")
        }()
        let accent = icon.dominantSwiftUIColor
        let hoverAccent = SwiftUI.Color.red
        let activeAccent = isHovered ? hoverAccent : accent
        let labelColor: SwiftUI.Color =
            systemColorScheme == .dark
            ? .white.opacity(0.96)
            : .black.opacity(0.88)

        return HStack(spacing: 5) {
            Image(nsImage: icon)
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(scope.matchedAlias)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(labelColor)
                .shadow(color: .black.opacity(systemColorScheme == .dark ? 0.35 : 0.08), radius: 1, y: 0.5)
        }
            .padding(.leading, 7)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .background(
                activeAccent.opacity(
                    isHovered
                    ? (systemColorScheme == .dark ? 0.34 : 0.24)
                    : (systemColorScheme == .dark ? 0.26 : 0.16)
                ),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.58 : 0.50),
                                activeAccent.opacity(
                                    isHovered
                                    ? (systemColorScheme == .dark ? 0.72 : 0.48)
                                    : (systemColorScheme == .dark ? 0.38 : 0.24)
                                ),
                                Color.white.opacity(0.10),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                            )
            )
            .shadow(
                color: activeAccent.opacity(
                    isHovered
                    ? (systemColorScheme == .dark ? 0.42 : 0.28)
                    : 0.0
                ),
                radius: isHovered ? 9 : 0,
                x: 0,
                y: 0
            )
            .shadow(color: .black.opacity(isHovered ? 0.18 : 0.20), radius: 6, x: 0, y: 2)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .onTapGesture {
                if isHovered {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        removeGlobalInlineAppScopeFromBackspace(scope)
                    }
                    hoveredGlobalInlineScopeBundleId = nil
                    DispatchQueue.main.async { reclaimSearchInputFocus() }
                } else {
                    reclaimSearchInputFocus()
                }
            }
            .zIndex(isHovered ? 10 : 0)
            // Small margin so the chip stays separated from adjacent query text at the
            // tighter inline spacing (without leaving a stray gap before the caret).
            .padding(.horizontal, 3)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.82, anchor: .leading).combined(with: .opacity),
                    removal: .opacity
                )
            )
            .focusable(false)
            .focusEffectDisabled()
            .help(isHovered ? "Click to remove \(scope.appName) scope" : "\(scope.appName) scope")
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) {
                    if hovering {
                        hoveredGlobalInlineScopeBundleId = scope.bundleId
                    } else if hoveredGlobalInlineScopeBundleId == scope.bundleId {
                        hoveredGlobalInlineScopeBundleId = nil
                    }
                }
            }
    }

    func scheduleDeferredQueryChange(from _: String, to newValue: String) {
        queryChangeGeneration &+= 1
        let generation = queryChangeGeneration
        queryChangeTask?.cancel()
        queryChangeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 85_000_000)
            guard !Task.isCancelled,
                queryChangeGeneration == generation,
                searchState.query == newValue
            else { return }
            handleDeferredQueryChange(newValue, generation: generation)
            guard queryChangeGeneration == generation else { return }
            queryChangeTask = nil
        }
    }

    func handleDeferredQueryChange(_ newValue: String, generation: Int) {
        if searchState.activeSmartQueryKey == "clipboard" {
            focusedClipboardEntryIndex = nil
        }
        if isCompactSmartScope {
            refreshCompactScopeResults()
            resetCollapseTimer()
            return
        }
        if isContextDockChatRoutingLocked {
            pendingAIMenuProposal = nil
            l2.appCompletion = nil
            l2.showResultsPopover = false
            livePanelVisible = false
            searchState.results = []
            searchState.selectedIndex = nil
            focusedAppPillIndex = nil
            l2.focusedPillIndex = nil
            contextDockViewModel.resetPillRenderingState(cancelBuild: true)
            globalAppMatchTask?.cancel()
            globalAppMatchTask = nil
            pendingGlobalAppQuery = nil
            cachedGlobalAppMatches = []
            globalGroupedTask?.cancel()
            globalGroupedTask = nil
            pendingGlobalGroupedQuery = nil
            cachedGlobalGroupedState = nil
            resetCollapseTimer()
            return
        }

        if !newValue.isEmpty, pendingAIMenuProposal != nil {
            pendingAIMenuProposal = nil
        }
        if lockedFindToken != nil {
            l2.appCompletion = nil
            l2.showResultsPopover = false
        }

        if currentDockSurfaceMode != .generalChat && !showContextInDock
            && !shouldUsePureGlobalAppSearch
        {
            performSearch()
        }

        let q = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowMenuOrCrossAppMatching = q.isEmpty || q.count >= 3

        if isL2ContextActive && lockedSubmenuParent == nil && lockedFindToken == nil {
            if q.isEmpty {
                dismissedGlobalInlineAppScopes = [:]
            }
            if shouldUsePureGlobalAppSearch {
                l2.appCompletion = nil
                l2.showResultsPopover = false
                focusedAppPillIndex = nil
                l2.focusedPillIndex = nil
                if !q.isEmpty, allApplications.isEmpty, !searchState.isLoadingApps {
                    loadApplicationsInBackground()
                }
                if !allowMenuOrCrossAppMatching, globalInlineAppScope == nil {
                    // 1–2 chars: app rows still filter live (menu / cross-app matching
                    // stays gated at 3+ chars inside the grouped state builder).
                    scheduleGlobalAppMatchRebuild(query: q)
                    resetCollapseTimer()
                    return
                }
                if globalInlineAppScope == nil {
                    scheduleGlobalAppMatchRebuild(query: q)
                } else {
                    scheduleGlobalGroupedListRebuild(query: q)
                }
                resetCollapseTimer()
                return
            }
            if globalInlineAppScope != nil {
                clearGlobalInlineAppScope(preserveQuery: true)
            }
            let finderFolderSearchActive =
                isFinderFolderSearchModeEnabled(for: newValue)
                || (finderFolderQueryModeActive && isFinderFolderSearchAttached())
            if finderFolderSearchActive {
                l2.appCompletion = nil
                l2.showResultsPopover = false
            } else {
                l2.showResultsPopover = false
            }
            scheduleFinderSemanticSearchIfNeeded(for: newValue)
            updateFinderGoToPills(for: newValue)
            let finderSearchPopoverActive = shouldUseFinderSearchPopover(for: q)
            let pillQuery = finderSearchPopoverActive ? "" : q
            scheduleDockPillRebuild(
                query: pillQuery,
                delayNanoseconds: settings.useListViewForPills ? 20_000_000 : 55_000_000,
                refreshContext: false
            )
        }

        if queryChangeGeneration != generation { return }

        if isL2ContextActive && isGlobalContextActive
            && lockedSubmenuParent == nil && lockedFindToken == nil
            && !hasSelectionScopeSurface
        {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            let installedScopeMode = contextDockInstalledAppScopeMatching
            let dockOnlyMode = contextDockRunningOnlyAppMatching && !installedScopeMode
            if !allowMenuOrCrossAppMatching || shouldUseFinderSearchPopover(for: trimmed) {
                l2.appCompletion = nil
            } else if trimmed.isEmpty
                || {
                    guard let target = L2AppActionRouter.shared.appScopeTarget(for: trimmed) else {
                        return false
                    }
                    return !dockOnlyMode
                        || runningBundleIdsForContextDock().contains(target.bundleId)
                }()
                || installedAppMenuTarget(
                    for: trimmed,
                    runningOnly: dockOnlyMode,
                    includeAppsWithoutMenuSnapshot: installedScopeMode,
                    allowPrefixAlias: installedScopeMode
                ) != nil
            {
                l2.appCompletion = nil
            } else {
                l2.appCompletion = bestL2PartialAppCompletion(
                    for: trimmed, runningOnly: dockOnlyMode
                )
            }
            if allowMenuOrCrossAppMatching, let target = l2.targetApp, !trimmed.isEmpty {
                if let otherTarget = L2AppActionRouter.shared.appScopeTarget(for: trimmed.lowercased()),
                    otherTarget.bundleId != target.bundleId
                {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        l2.targetApp = nil
                    }
                    if searchState.contextApp?.resultType == .application {
                        clearSearchContext(preserveQuery: true)
                    }
                }
            }
        } else if lockedSubmenuParent != nil
            || lockedFindToken != nil
            || (isL2ContextActive && (!isGlobalContextActive || hasSelectionScopeSurface))
        {
            l2.appCompletion = nil
        }
        if (isL2ContextActive || currentDockSurfaceMode == .generalChat)
            && newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            scheduleBrowserContextWarmup(reason: "query changed")
        }
        resetCollapseTimer()
    }

    // MARK: - Separator (for smart positioning)
    @ViewBuilder
    var separatorView: some View {
        let shouldShowSeparator =
            if showMediaLayer {
                // Show separator on L3 if media is playing
                mediaObserver.isPlaying
            } else if currentDockSurfaceMode == .generalChat {
                // Show separator for AI mode
                hasUserSentMessageInCurrentSession && (!aiMode.messages.isEmpty || aiMode.isLoading)
            } else {
                // Show separator for search results
                !searchState.results.isEmpty || fileIndexManager.progress.isIndexing
            }

        if shouldShowSeparator {
            Divider()
                .padding(.horizontal, 12)
                .transition(.opacity)
        }
    }

    func clearInputQuery() {
        if isGlobalContextActive {
            clearGlobalContextQuerySmoothly()
        } else {
            searchState.query = ""
            searchState.results = []
            searchState.selectedIndex = nil
        }
    }

    func inlineDockFeedbackColor(_ phase: DockInlineFeedback.Phase) -> Color {
        switch phase {
        case .progress: return .blue
        case .success: return .green
        case .failure: return .orange
        }
    }

    func inlineDockFeedbackGlowColor() -> Color? {
        guard let feedback = launcherViewModel.inlineDockFeedback else { return nil }
        if inlineDockFeedbackIsDestructive(feedback) {
            return .red
        }
        if let icon = inlineDockFeedbackAppIcon() {
            return icon.dominantSwiftUIColor
        }
        return inlineDockFeedbackColor(feedback.phase)
    }

    func inlineDockFeedbackIsDestructive(_ feedback: DockInlineFeedback) -> Bool {
        let title = feedback.title.lowercased()
        let icon = feedback.icon.lowercased()
        return title.contains("quit")
            || title.contains("delet")
            || title.contains("trash")
            || title.contains("remove")
            || title.contains("empty trash")
            || icon.contains("trash")
            || icon.contains("xmark")
    }

    func inlineDockFeedbackAppName() -> String? {
        guard let feedback = launcherViewModel.inlineDockFeedback else { return nil }
        if let subject = feedback.subject?.trimmingCharacters(in: .whitespacesAndNewlines),
            !subject.isEmpty
        {
            return subject
        }
        guard let bundleID = feedback.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty
        else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }?.localizedName
    }

    func inlineDockFeedbackAppIcon() -> NSImage? {
        guard let rawBundleID = launcherViewModel.inlineDockFeedback?.bundleID else { return nil }
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return nil }
        if let icon = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        })?.icon {
            return preparedDockIcon(icon)
        }
        return resolvedApplicationIcon(
            bundleIdentifier: bundleID,
            appName: inlineDockFeedbackAppName() ?? ""
        )
    }

    @ViewBuilder
    func inlineDockFeedbackChip(_ feedback: DockInlineFeedback) -> some View {
        let accent = inlineDockFeedbackGlowColor() ?? inlineDockFeedbackColor(feedback.phase)
        HStack(spacing: 6) {
            if feedback.phase == .progress {
                ProgressView()
                    .tint(accent)
                    .controlSize(.small)
                    .scaleEffect(0.58)
                    .frame(width: 18, height: 18)
                    .opacity(0.7)
            } else {
                Image(systemName: feedback.phase == .success ? "checkmark" : "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .background(
            accent.opacity(systemColorScheme == .dark ? 0.24 : 0.14),
            in: Capsule(style: .continuous)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    accent.opacity(systemColorScheme == .dark ? 0.44 : 0.28),
                    lineWidth: 0.8)
        )
        .shadow(color: accent.opacity(systemColorScheme == .dark ? 0.24 : 0.12), radius: 7, x: 0, y: 2)
        .help(feedback.title)
    }

    @ViewBuilder
    func inlineDockFeedbackActionIcon(_ feedback: DockInlineFeedback) -> some View {
        let accent = inlineDockFeedbackGlowColor() ?? inlineDockFeedbackColor(feedback.phase)
        // Single morphing status pill: spinner while in progress, ✓ on success, ✗ on failure.
        let statusSymbol: String =
            feedback.phase == .success
            ? "checkmark"
            : (feedback.phase == .failure || inlineDockFeedbackIsDestructive(feedback)
                ? "xmark" : feedback.icon)
        Group {
            if feedback.phase == .progress {
                ProgressView()
                    .tint(accent)
                    .controlSize(.small)
                    .scaleEffect(0.62)
            } else {
                Image(systemName: statusSymbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
            .frame(width: 26, height: 26)
            .background(.regularMaterial, in: Circle())
            .background(accent.opacity(systemColorScheme == .dark ? 0.20 : 0.12), in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(
                        accent.opacity(systemColorScheme == .dark ? 0.42 : 0.28),
                        lineWidth: 0.8)
            )
            .shadow(
                color: accent.opacity(systemColorScheme == .dark ? 0.20 : 0.10),
                radius: 6, x: 0, y: 2
            )
            .help(feedback.title)
    }

}
