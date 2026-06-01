import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension LauncherView {
    var searchBarSection: some View {
        Group {
            if shouldUseIntegratedScopeSheet {
                compactScopeIntegratedSheet
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if settings.effectiveDockAtBottom {
                // Dock at bottom: results float above, dock bar anchored at bottom.
                VStack(spacing: panelGapBelowSearchBar) {
                    if hasResultsToShow {
                        resultsCardAlignedToSearchInput
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(
                                        with: .scale(scale: 0.96, anchor: .bottom)),
                                    removal: .opacity.combined(
                                        with: .scale(scale: 0.96, anchor: .bottom))
                                ))
                    }
                    // Clipboard floats left of the main dock pill — liquid-drop separation
                    HStack(alignment: .bottom, spacing: 8) {
                        clipboardFloatingIconPill
                            .transition(
                                .scale(scale: 0.7, anchor: .bottomTrailing).combined(with: .opacity)
                            )
                        dockCard(inDockMode: true)
                            .onDrop(
                                of: [.fileURL, .text, .plainText, .url],
                                isTargeted: $clipboardDropTargeted
                            ) { providers in
                                handleDockContextDrop(providers)
                            }
                            .onHover { hovering in
                                if hovering && clipboardDropTargetVisible {
                                    revealClipboardDropTarget()
                                }
                            }
                        floatingAppLogoButton
                    }
                }
            } else {
                // Dock at top: dock bar anchored at top, results float below.
                VStack(spacing: panelGapBelowSearchBar) {
                    HStack(alignment: .bottom, spacing: 8) {
                        clipboardFloatingIconPill
                            .transition(
                                .scale(scale: 0.7, anchor: .bottomTrailing).combined(with: .opacity)
                            )
                        dockCard(inDockMode: false)
                            .onDrop(
                                of: [.fileURL, .text, .plainText, .url],
                                isTargeted: $clipboardDropTargeted
                            ) { providers in
                                handleDockContextDrop(providers)
                            }
                            .onHover { hovering in
                                if hovering && clipboardDropTargetVisible {
                                    revealClipboardDropTarget()
                                }
                            }
                        floatingAppLogoButton
                    }
                    if hasResultsToShow {
                        resultsCardAlignedToSearchInput
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(
                                        with: .scale(scale: 0.96, anchor: .top)),
                                    removal: .opacity.combined(
                                        with: .scale(scale: 0.96, anchor: .top))
                                ))
                    }
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: showGlobalClipboardPill)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hasResultsToShow)
        .ifLet(resolvedColorScheme) { view, scheme in
            view.environment(\.colorScheme, scheme)
        }
    }

    var compactScopeIntegratedSheet: some View {
        let maxSheetHeight: CGFloat = isCompactSmartScope ? 450 : 480
        return HStack(spacing: 0) {
            Color.clear
                .frame(width: resultsPanelLeadingInset)
            VStack(spacing: 0) {
                dockBaseView(inDockMode: settings.effectiveDockAtBottom)
                    .frame(width: resultsPanelWidth, alignment: .leading)

                Rectangle()
                    .fill(Color.white.opacity(isEffectiveDark ? 0.12 : 0.16))
                    .frame(height: 1)
                    .padding(.horizontal, 18)

                resultsContentView
                    .frame(minHeight: 0, maxHeight: maxSheetHeight)
                    .frame(width: resultsPanelWidth, alignment: .leading)
            }
            .frame(width: resultsPanelWidth, alignment: .leading)
            .background(alignment: .topLeading) {
                GlassBackground(cornerRadius: 28, isDark: isEffectiveDark)
                    .frame(width: resultsPanelWidth)
            }
            .mask(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .frame(width: resultsPanelWidth)
            }
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.42), .white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .frame(width: resultsPanelWidth)
            }
            Spacer(minLength: 0)
        }
        .frame(width: calculatedWidth, alignment: .leading)
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
    }

    // MARK: - Dock Base View (always visible, doesn't move)
    @ViewBuilder
    func dockBaseView(inDockMode: Bool) -> some View {
        let outerVerticalPadding: CGFloat = 6
        let inputVerticalPadding: CGFloat = 6
        let pinnedRowHeight: CGFloat = CGFloat(settings.dockIconSize) + 4
        let inputPillHeight: CGFloat = CGFloat(settings.dockIconSize) + 8
        let inputIsExpanded =
            (isSearchBarExpanded || usesVerticalListDockLayout)
            && (l2.focusedPillIndex == nil || usesVerticalListDockLayout)
            && !showMediaLayer
        let collapsedInputWidth: CGFloat = inputPillHeight

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Left slot: full search input OR icon-only anchor during app/action pill keyboard nav
                // In list view mode the pill list is a separate panel below the search bar,
                // so nav focus should never collapse the search bar to an icon.
                let actionPillNavActive =
                    l2.focusedPillIndex != nil && showContextInDock && !isGlobalContextActive
                    && !aiMode.isActive && !usesVerticalListDockLayout
                let globalAppNavActive =
                    focusedAppPillIndex != nil && isGlobalContextActive && !aiMode.isActive
                    && !usesVerticalListDockLayout
                let pillNavActive = actionPillNavActive || globalAppNavActive
                let compactScopeKey = isCompactSmartScope ? searchState.activeSmartQueryKey : nil
                if pillNavActive {
                    searchAsPillView
                }
                if !pillNavActive && !showMediaLayer {
                    HStack(spacing: 10) {
                        // Search icon
                        if aiMode.isActive {
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
                                Image(systemName: settings.selectedAIProvider.iconName)
                                    .foregroundStyle(providerColor)
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .menuStyle(.borderlessButton)
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
                                    updateWindowSize()
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
                                    let preferFrontmostMenuIcon =
                                        hasFrontmostMenuPillsInCurrentCache(for: searchState.query)
                                    let typedAppIcon =
                                        (scopedGlobalAppIcon != nil
                                            || (shouldUsePureGlobalAppSearch
                                                && !preferFrontmostMenuIcon)
                                            || hasActiveDockContextSelection)
                                        ? nil : typedL2AppIcon(for: searchState.query)
                                    // In Finder desktop-only mode (no window open) treat icon as nil → globe
                                    let displayIcon =
                                        scopedGlobalAppIcon?.icon ?? previewGlobalAppResult?.icon
                                        ?? l2.targetApp?.icon ?? typedAppIcon?.icon
                                        ?? frontmost.icon
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
                                        if let selIcon = activeSelectionIcon {
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
                                            // No selection — Context Dock glyph
                                            ContextDockGlyph(size: 27, opacity: 1.0)
                                                .frame(width: 28, height: 28)
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
                                            .id(
                                                scopedGlobalAppIcon?.bundleId
                                                    ?? previewGlobalAppBundleId ?? l2.targetApp?
                                                    .bundleId ?? typedAppIcon?.bundleId
                                                    ?? frontmost.bundleID
                                            )
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
                        if shouldShowFrontmostContextChip, let icon = frontmost.icon {
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
                                Text(frontmost.name)
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
                            && !shouldShowFrontmostContextChip && !aiMode.isActive
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
                                    !aiMode.isActive, !isL2ContextActive,
                                    allGlobalInlineAppScopes.isEmpty,
                                    searchState.activeSmartQueryKey == nil,
                                    searchState.contextApp == nil
                                else { return nil }
                                return searchState.results[idx]
                            }()
                            let focusedDockPill =
                                allGlobalInlineAppScopes.isEmpty
                                ? focusedDockPillForInputPreview() : nil
                            let focusedGlobalAppResult =
                                allGlobalInlineAppScopes.isEmpty
                                ? focusedGlobalAppResultForInputPreview() : nil
                            let topGlobalAppResult =
                                allGlobalInlineAppScopes.isEmpty
                                ? topGlobalAppResultForInputPreview() : nil
                            // Spotlight-style: show result name in bar whenever a result is selected (even while typing)
                            let showingResultPreview =
                                focusedDockPill != nil || focusedGlobalAppResult != nil
                                || topGlobalAppResult != nil || selectedResult != nil

                            ZStack(alignment: .leading) {
                                if !allGlobalInlineAppScopes.isEmpty {
                                    globalInlineScopeQueryOverlay
                                }
                                // Selected result preview (Spotlight-style: "Visual Studio Code.app — Open")
                                if let pill = focusedDockPill {
                                    let title = pill.name
                                    let typed = searchState.query
                                    let isPrefixMatch = title.lowercased().hasPrefix(
                                        typed.lowercased())

                                    HStack(spacing: 0) {
                                        if isPrefixMatch && !typed.isEmpty {
                                            Text(typed)
                                                .font(.system(size: 15))
                                                .foregroundStyle(.clear)
                                            Text(String(title.dropFirst(typed.count)))
                                                .font(.system(size: 15))
                                                .foregroundStyle(.secondary.opacity(0.45))
                                                .lineLimit(1)
                                        } else {
                                            Text(title)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                        }
                                        if let badge = pill.badge, !badge.isEmpty {
                                            Text("  \(badge)")
                                                .font(.system(size: 15))
                                                .foregroundStyle(.secondary.opacity(0.25))
                                        }
                                        Text("  — ↵")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.25))
                                    }
                                } else if let result = focusedGlobalAppResult {
                                    let title = result.title
                                    let typed = searchState.query
                                    let isPrefixMatch = title.lowercased().hasPrefix(
                                        typed.lowercased())

                                    HStack(spacing: 0) {
                                        if isPrefixMatch && !typed.isEmpty {
                                            Text(typed)
                                                .font(.system(size: 15))
                                                .foregroundStyle(.clear)
                                            Text(String(title.dropFirst(typed.count)))
                                                .font(.system(size: 15))
                                                .foregroundStyle(.secondary.opacity(0.45))
                                                .lineLimit(1)
                                        } else {
                                            Text(title)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                        }
                                        Text("  —  \(selectedResultAction(result))")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.35))
                                    }
                                } else if let result = topGlobalAppResult,
                                    result.title.lowercased().hasPrefix(
                                        searchState.query.lowercased()),
                                    !searchState.query.isEmpty
                                {
                                    // Prefix match only: show typed (invisible) + grey completion + action
                                    let title = result.title
                                    let typed = searchState.query
                                    HStack(spacing: 0) {
                                        Text(typed)
                                            .font(.system(size: 15))
                                            .foregroundStyle(.clear)
                                        Text(String(title.dropFirst(typed.count)))
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.45))
                                            .lineLimit(1)
                                        Text("  —  \(selectedResultAction(result))")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.35))
                                    }
                                } else if let result = selectedResult {
                                    // Intelligent inline completion:
                                    // • Prefix match  → show typed text (invisible spacer) + greyed remainder + action
                                    // • Fuzzy match   → show full result name + action
                                    let title = result.title
                                    let typed = searchState.query
                                    let isPrefixMatch = title.lowercased().hasPrefix(
                                        typed.lowercased())

                                    HStack(spacing: 0) {
                                        if isPrefixMatch && !typed.isEmpty {
                                            // Typed portion — invisible spacer so grey completion aligns after cursor
                                            Text(typed)
                                                .font(.system(size: 15))
                                                .foregroundStyle(.clear)
                                            // Grey completion (the "remaining" part)
                                            Text(String(title.dropFirst(typed.count)))
                                                .font(.system(size: 15))
                                                .foregroundStyle(.secondary.opacity(0.45))
                                                .lineLimit(1)
                                        } else {
                                            // Fuzzy match — show full name in primary color
                                            Text(title)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                        }
                                        // Action hint
                                        Text("  —  \(selectedResultAction(result))")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.35))
                                    }
                                } else if !shouldUsePureGlobalAppSearch,
                                    !hasActiveDockContextSelection,
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
                                } else if let subCtx = submenuGhostContext,
                                    let firstChild = subCtx.children.first,
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
                                } else if let ghost = ghostPillCompletion,
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
                                        if let badge = ghost.badge, !badge.isEmpty {
                                            Text("  \(badge)")
                                                .font(.system(size: 15))
                                                .foregroundStyle(.secondary.opacity(0.2))
                                        }
                                        Text("  — ↵")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary.opacity(0.2))
                                    }
                                } else if searchState.query.isEmpty {
                                    // Normal placeholders (always visible when field is empty)
                                    if lockedSubmenuParent != nil {
                                        Text("filter…")
                                            .foregroundStyle(.secondary.opacity(0.4))
                                            .font(.system(size: 15, weight: .regular))
                                    } else if aiMode.isActive {
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
                                            Text("  — type to search and ask about this folder…")
                                                .foregroundStyle(.secondary.opacity(0.25))
                                                .font(.system(size: 15, weight: .regular))
                                                .lineLimit(1)
                                        }
                                    } else if isGlobalContextActive {
                                        // Global context: "Global Context" as ghost placeholder
                                        Text("Global Context")
                                            .foregroundStyle(.secondary.opacity(0.55))
                                            .font(.system(size: 15, weight: .medium))
                                            .lineLimit(1)
                                    } else if showContextInDock
                                        && !dockScopeDisplayName.trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        ).isEmpty
                                    {
                                        // Context dock: app name + capability hints.
                                        Text(dockScopeGhostPrompt)
                                            .foregroundStyle(.primary.opacity(0.75))
                                            .font(.system(size: 15, weight: .semibold))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    } else {
                                        Text("Context-Dock")
                                            .foregroundStyle(.secondary.opacity(0.5))
                                            .font(.system(size: 15, weight: .regular))
                                    }
                                }

                                TextField("", text: $searchState.query)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.primary)
                                    .focused($isSearchFieldFocused)
                                    .focusEffectDisabled()
                                    .background(FocusRingSuppressor())
                                    // For prefix match: TextField stays visible (shows typed text + cursor).
                                    // For fuzzy match or empty: hide it so the full result name shows cleanly.
                                    .opacity(
                                        {
                                            if let pill = focusedDockPill {
                                                let isPrefixMatch = pill.name.lowercased()
                                                    .hasPrefix(
                                                        searchState.query.lowercased())
                                                return (isPrefixMatch && !searchState.query.isEmpty)
                                                    ? 1 : 0
                                            }
                                            if let result = focusedGlobalAppResult {
                                                let isPrefixMatch = result.title.lowercased()
                                                    .hasPrefix(
                                                        searchState.query.lowercased())
                                                return (isPrefixMatch && !searchState.query.isEmpty)
                                                    ? 1 : 0
                                            }
                                            if let result = topGlobalAppResult {
                                                // Only hide TextField for prefix match (ghost shows completion).
                                                // For fuzzy match the TextField stays visible so typed text shows.
                                                let isPrefixMatch = result.title.lowercased()
                                                    .hasPrefix(
                                                        searchState.query.lowercased())
                                                return (isPrefixMatch && !searchState.query.isEmpty)
                                                    ? 1 : 1
                                            }
                                            if let result = selectedResult {
                                                let isPrefixMatch = result.title.lowercased()
                                                    .hasPrefix(
                                                        searchState.query.lowercased())
                                                return (isPrefixMatch && !searchState.query.isEmpty)
                                                    ? 1 : 0
                                            }
                                            return allGlobalInlineAppScopes.isEmpty ? 1 : 0
                                        }()
                                    )
                                    .onChange(of: searchState.query) { oldValue, newValue in
                                        if searchState.activeSmartQueryKey == "clipboard" {
                                            focusedClipboardEntryIndex = nil
                                        }
                                        if isCompactSmartScope {
                                            refreshCompactScopeResults()
                                            resetCollapseTimer()
                                            return
                                        }
                                        // Typing dismisses any pending AI-found menu proposal
                                        if !newValue.isEmpty, pendingAIMenuProposal != nil {
                                            pendingAIMenuProposal = nil
                                        }
                                        if lockedFindToken == nil {
                                            if activateFindTokenIfNeeded(from: newValue) {
                                                return
                                            }
                                        } else {
                                            l2.appCompletion = nil
                                            l2.showResultsPopover = false
                                        }
                                        // In L2 context dock mode, pills filter in the pill row —
                                        // do NOT run L1 search (which would expand the window with results).
                                        if !aiMode.isActive && !showContextInDock {
                                            performSearch()
                                        }
                                        // When a submenu parent is locked, skip all app-scope detection —
                                        // input is purely a child filter, not an app name.
                                        if isL2ContextActive && lockedSubmenuParent == nil
                                            && lockedFindToken == nil
                                        {
                                            let q =
                                                newValue
                                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                                .lowercased()
                                            if q.isEmpty {
                                                dismissedGlobalInlineAppScopes = [:]
                                            }
                                            if shouldUsePureGlobalAppSearch {
                                                l2.appCompletion = nil
                                                l2.showResultsPopover = false
                                                focusedAppPillIndex = nil
                                                l2.focusedPillIndex = nil
                                                if activateRunningGlobalAppScopeIfMentioned(
                                                    for: newValue)
                                                {
                                                    resetCollapseTimer()
                                                    return
                                                }
                                                if !q.isEmpty, allApplications.isEmpty,
                                                    !searchState.isLoadingApps
                                                {
                                                    loadApplicationsInBackground()
                                                }
                                                if globalInlineAppScope == nil {
                                                    scheduleGlobalAppMatchRebuild(
                                                        query: q, delayNanoseconds: 45_000_000)
                                                } else {
                                                    scheduleGlobalGroupedListRebuild(
                                                        query: q, delayNanoseconds: 45_000_000)
                                                }
                                                resetCollapseTimer()
                                                return
                                            }
                                            if globalInlineAppScope != nil {
                                                clearGlobalInlineAppScope(preserveQuery: true)
                                            }
                                            let finderFolderSearchActive =
                                                isFinderFolderSearchModeEnabled(for: newValue)
                                                || (finderFolderQueryModeActive
                                                    && isFinderFolderSearchAttached())
                                            if finderFolderSearchActive {
                                                l2.appCompletion = nil
                                                l2.showResultsPopover = false
                                            } else {
                                                l2.showResultsPopover = false
                                                if !isGlobalContextActive {
                                                    triggerCrossAppMenuLoadIfNeeded(for: newValue)
                                                }
                                            }
                                            scheduleFinderSemanticSearchIfNeeded(for: newValue)
                                            updateFinderGoToPills(for: newValue)
                                            let finderSearchPopoverActive =
                                                shouldUseFinderSearchPopover(for: q)
                                            let pillQuery = finderSearchPopoverActive ? "" : q
                                            scheduleDockPillRebuild(
                                                query: pillQuery,
                                                delayNanoseconds: settings.useListViewForPills
                                                    ? 20_000_000 : 55_000_000,
                                                refreshContext: false
                                            )
                                            if usesVerticalListDockLayout {
                                                DispatchQueue.main.async {
                                                    reclaimSearchInputFocus()
                                                }
                                            }
                                        }
                                        // Update partial app autocomplete for L2 (skip when submenu locked
                                        // or when files/text/folders are actively selected).
                                        if isL2ContextActive && isGlobalContextActive
                                            && lockedSubmenuParent == nil && lockedFindToken == nil
                                            && !hasActiveDockContextSelection
                                        {
                                            let trimmed = newValue.trimmingCharacters(
                                                in: .whitespaces)
                                            let installedScopeMode =
                                                contextDockInstalledAppScopeMatching
                                            let dockOnlyMode =
                                                contextDockRunningOnlyAppMatching
                                                && !installedScopeMode
                                            if shouldUseFinderSearchPopover(for: trimmed) {
                                                l2.appCompletion = nil
                                            } else if trimmed.isEmpty
                                                || {
                                                    guard
                                                        let target = L2AppActionRouter.shared
                                                            .appScopeTarget(for: trimmed)
                                                    else {
                                                        return false
                                                    }
                                                    return !dockOnlyMode
                                                        || runningBundleIdsForContextDock()
                                                            .contains(target.bundleId)
                                                }()
                                                || installedAppMenuTarget(
                                                    for: trimmed,
                                                    runningOnly: dockOnlyMode,
                                                    includeAppsWithoutMenuSnapshot:
                                                        installedScopeMode,
                                                    allowPrefixAlias: installedScopeMode
                                                ) != nil
                                            {
                                                l2.appCompletion = nil
                                            } else {
                                                l2.appCompletion = bestL2PartialAppCompletion(
                                                    for: trimmed, runningOnly: dockOnlyMode
                                                )
                                            }
                                            if let target = l2.targetApp, !trimmed.isEmpty {
                                                if let otherTarget = L2AppActionRouter.shared
                                                    .appScopeTarget(
                                                        for: trimmed.lowercased()),
                                                    otherTarget.bundleId != target.bundleId
                                                {
                                                    withAnimation(.easeInOut(duration: 0.15)) {
                                                        l2.targetApp = nil
                                                    }
                                                    if searchState.contextApp?.resultType
                                                        == .application
                                                    {
                                                        clearSearchContext(preserveQuery: true)
                                                    }
                                                }
                                            }
                                        } else if lockedSubmenuParent != nil
                                            || lockedFindToken != nil
                                            || (isL2ContextActive
                                                && (!isGlobalContextActive
                                                    || hasActiveDockContextSelection))
                                        {
                                            // Locked: clear any stale app completion
                                            l2.appCompletion = nil
                                        }
                                        if isL2ContextActive || aiMode.isActive {
                                            scheduleBrowserContextWarmup(reason: "query changed")
                                        }
                                        resetCollapseTimer()
                                    }
                                    .onChange(of: isSearchFieldFocused) { oldValue, newValue in
                                        if newValue {
                                            collapseTimer?.cancel()
                                        } else {
                                            if settings.persistentContextDock {
                                                persistentDockCollapseTask?.cancel()
                                                persistentDockCollapseTask = Task { @MainActor in
                                                    try? await Task.sleep(nanoseconds: 180_000_000)
                                                    collapsePersistentDockIfIdle()
                                                }
                                                return
                                            }
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
                                            guard !trimmed.isEmpty else { return }
                                            if executeFocusedOrDirectAppPillIfNeeded() {
                                                return
                                            }
                                            handleL2Query(trimmed)
                                        } else if aiMode.isActive {
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
                                            guard searchState.selectedIndex != nil else { return }
                                            executeSelectedResult()
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

                            if shouldShowGlobalRunningAppStrip {
                                globalRunningAppStrip
                            }

                            // Trailing area: focused context icon OR result icon OR clear OR controls
                            if let pill = focusedDockPill {
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
                            } else if aiMode.isActive {
                                aiModeControls
                            } else if shouldShowGlobalInputLoadingIndicator {
                                GlobalInputLoadingDots()
                                    .frame(width: 26, height: 26)
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            } else if shouldShowContextDockInputLoadingIndicator {
                                GlobalInputLoadingDots()
                                    .frame(width: 26, height: 26)
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            } else if !searchState.query.isEmpty {
                                Button(action: clearInputQuery) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary.opacity(0.5))
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .help("Clear")
                            } else if isGlobalContextActive, activeSelectionLabel != nil {
                                // (-) dismiss: clears the active selection and returns to dock context
                                Button {
                                    withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                                        showGlobalClipboardPill = false
                                        globalClipboardText = ""
                                        dismissContextAndReturnToDock()
                                    }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary.opacity(0.55))
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .help("Dismiss selection")
                            } else if isGlobalContextActive {
                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                        globalContextActivation = nil
                                        showContextInDock = true
                                    }
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary.opacity(0.65))
                                        .frame(width: 22, height: 22)
                                        .background(Color.white.opacity(0.08), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Connect to Desktop")
                                Image(systemName: "return")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary.opacity(0.55))
                            } else if showContextInDock {
                                // Context dock: optional action button (+ for Finder, tabs for Safari)
                                // followed by the ↵ return hint — both always visible at the same time
                                if !isCompactSmartScope,
                                    l2.targetApp == nil,
                                    frontmost.bundleID == "com.apple.finder",
                                    canAttachCurrentFinderFolderToConversation
                                {
                                    addFinderFolderButton
                                } else if !isCompactSmartScope,
                                    l2.targetApp == nil,
                                    AXWebReader.shared.isBrowser(bundleId: frontmost.bundleID)
                                {
                                    safariTabsButton
                                }
                                Image(systemName: "return")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary.opacity(0.55))
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
                            showContextInDock || isGlobalContextActive || aiMode.isActive
                        let typedMatch =
                            hasActiveDockContextSelection || shouldUsePureGlobalAppSearch
                            ? nil : typedL2AppIcon(for: searchState.query)
                        let inAppScope =
                            (l2.targetApp != nil || typedMatch != nil) && showContextInDock
                        let compactScopeColor: SwiftUI.Color? = {
                            guard let key = searchState.activeSmartQueryKey,
                                key == "clipboard" || key == "notifications"
                            else { return nil }
                            return key == "clipboard" ? .blue : .accentColor
                        }()
                        let scopeColor: SwiftUI.Color =
                            compactScopeColor
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
                            if inContextDock {
                                // Capsule pill — identical shape to expanded appPillButton
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .matchedGeometryEffect(
                                        id: dockResultFocusEffectID,
                                        in: compactScopeFocusNamespace,
                                        properties: .frame,
                                        isSource: true
                                    )
                                    .opacity(dockResultFocused ? 0 : 1)
                                if !dockResultFocused {
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(inAppScope ? 0.24 : 0.22),
                                                    Color.white.opacity(inAppScope ? 0.05 : 0.04),
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
                                                    scopeColor.opacity(inAppScope ? 0.08 : 0.10),
                                                    scopeColor.opacity(inAppScope ? 0.015 : 0.02),
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    // Bright gradient border — matches expanded pill (0.65 → 0.06)
                                    Capsule()
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [
                                                    .white.opacity(0.65), .white.opacity(0.06),
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 1.5
                                        )
                                    // Glow ring — mirrors expanded pill focus ring
                                    Capsule()
                                        .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                                        .blur(radius: 3)
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
                if !isCompactSmartScope && !aiMode.isActive && !usesVerticalListDockLayout {
                    HStack(spacing: 8) {
                        // Floating selection pill — not shown in context dock (already in search bar)
                        if !showContextInDock { selectionFloatingPill }
                        // Clipboard pill moved to searchBarSection (floats left of the main dock card)

                        Group {
                            if showMediaLayer {
                                mediaControlsInDock
                                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                            } else if searchState.activeSmartQueryKey != nil && !isCompactSmartScope
                            {
                                appShortcutsInDock
                                    .transition(.opacity)
                            } else if showContextInDock {
                                if aiMode.isActive {
                                    EmptyView()
                                } else if isGlobalContextActive {
                                    // Global context: empty query shows pinned/running; typed query searches
                                    // pinned, running, and installed applications.
                                    if shouldShowL2UnifiedDockRow {
                                        l2UnifiedDockRow
                                            .transition(.opacity)
                                    }
                                } else if hasAIExtensionsToShow {
                                    aiExtensionsInDock
                                        .transition(.opacity)
                                } else if shouldShowL2UnifiedDockRow {
                                    l2UnifiedDockRow
                                        .transition(.opacity)
                                }
                            } else if !searchState.query.isEmpty {
                                pinnedAppsListView
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

    @ViewBuilder
    var mediaControlsInDock: some View {
        let progress =
            mediaObserver.duration > 0
            ? min(max(mediaObserver.elapsed / max(mediaObserver.duration, 1), 0), 1)
            : 0

        VStack(spacing: 0) {
            // Album art → app icon (observer) → app icon (running apps scan) → music note
            let resolvedMediaIcon: NSImage? =
                mediaObserver.appIcon
                ?? {
                    guard !mediaObserver.appName.isEmpty else { return nil }
                    let name = mediaObserver.appName.lowercased()
                    return NSWorkspace.shared.runningApplications
                        .first(where: { ($0.localizedName ?? "").lowercased() == name })?.icon
                }()

            HStack(spacing: 14) {
                HStack(spacing: 10) {
                    appleMusicIconButton(systemName: "shuffle", disabled: true) {}
                    appleMusicIconButton(systemName: "backward.fill") {
                        mediaObserver.skipBack()
                    }
                    Button {
                        mediaObserver.togglePlayPause()
                    } label: {
                        Image(systemName: mediaObserver.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                Color.accentColor,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help(mediaObserver.isPlaying ? "Pause" : "Play")
                    appleMusicIconButton(systemName: "forward.fill") {
                        mediaObserver.skipForward()
                    }
                    appleMusicIconButton(systemName: "repeat", disabled: true) {}
                }
                .frame(minWidth: 184, alignment: .leading)

                Group {
                    if let art = mediaObserver.artworkImage {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if let icon = resolvedMediaIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        mediaObserver.title.isEmpty
                            ? (mediaObserver.appName.isEmpty
                                ? "Now Playing" : mediaObserver.appName)
                            : mediaObserver.title
                    )
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                    Text(
                        mediaObserver.artist.isEmpty ? mediaObserver.appName : mediaObserver.artist
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    appleMusicIconButton(systemName: "ellipsis") {}
                    appleMusicIconButton(systemName: "quote.bubble", disabled: true) {}
                    appleMusicIconButton(systemName: "list.bullet", disabled: true) {}
                    appleMusicIconButton(systemName: "speaker.wave.2.fill", disabled: true) {}
                }
                .frame(minWidth: 148, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            if mediaObserver.duration > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                        Capsule()
                            .fill(Color.white.opacity(0.72))
                            .frame(width: max(6, geo.size.width * CGFloat(progress)))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .animation(.linear(duration: 0.25), value: mediaObserver.elapsed)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: mediaObserver.duration > 0 ? 70 : 58)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.035)],
                            startPoint: .top, endPoint: .bottom))
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.58), Color.white.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.5)
                Capsule()
                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                    .blur(radius: 3)
            }
        }
    }

    @ViewBuilder
    func compactMediaButton(
        systemName: String,
        filled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: filled ? 13 : 12, weight: .semibold))
                .foregroundStyle(filled ? .white : .primary)
                .frame(width: filled ? 30 : 26, height: filled ? 30 : 26)
                .background(
                    filled ? Color.accentColor : Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: filled ? 8 : 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func appleMusicIconButton(
        systemName: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    disabled ? Color.secondary.opacity(0.45) : Color.primary.opacity(0.86)
                )
                .frame(width: 24, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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
    var resultsContentView: some View {
        // Show different content based on current mode (AI vs Normal)
        // The L3 media dock can still surface search results while typing.
        let content = Group {
            if aiMode.isActive {
                // AI mode: AI Chat section (works on L1/L2/L3)
                aiChatSection
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if isCompactSmartScope {
                Group {
                    if searchState.activeSmartQueryKey == "clipboard" {
                        clipboardScopeView
                    } else {
                        notificationScopeView
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if showContextInDock && !showMediaLayer
                && (searchState.contextApp != nil
                    || searchState.activeSmartQueryKey != nil)
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
                    // Two-column row: chat left + results/filePreview right
                    HStack(spacing: 0) {
                        l2ChatSection
                        if livePanelVisible {
                            switch livePanelMode {
                            case .results, .filePreview:
                                livePanelView
                                    .transition(
                                        .asymmetric(
                                            insertion: .move(edge: .trailing).combined(
                                                with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)
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

    var globalInlineScopeQueryOverlay: some View {
        HStack(spacing: 6) {
            ForEach(globalInlineQueryPieces) { piece in
                switch piece {
                case .text(let value, _):
                    Text(value)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.primary)
                case .scope(let scope):
                    globalInlineScopeChip(scope)
                }
            }
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2, height: 20)
                .opacity(isSearchFieldFocused ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            reclaimSearchInputFocus()
        }
        .zIndex(2)
    }

    func globalInlineScopeChip(_ scope: GlobalInlineAppScope) -> some View {
        let icon =
            FileManager.default.fileExists(atPath: scope.appPath)
            ? NSWorkspace.shared.icon(forFile: scope.appPath)
            : NSWorkspace.shared.icon(
                forFile: NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: scope.bundleId)?.path ?? "")
        let accent = icon.dominantSwiftUIColor
        let chipTextColor: SwiftUI.Color =
            systemColorScheme == .dark
            ? SwiftUI.Color.white.opacity(0.94)
            : SwiftUI.Color.black.opacity(0.82)

        return HStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(scope.matchedAlias)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(chipTextColor)
                .lineLimit(1)
            Button {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.82)) {
                    removeGlobalInlineAppScope(scope)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(chipTextColor)
                    .frame(width: 16, height: 16)
                    .background(
                        chipTextColor.opacity(systemColorScheme == .dark ? 0.14 : 0.10),
                        in: Circle())
            }
            .buttonStyle(.plain)
            .help("Remove app scope")
            .opacity(isHoveringGlobalInlineScopeChip ? 1 : 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, isHoveringGlobalInlineScopeChip ? 8 : 6)
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
                isHoveringGlobalInlineScopeChip = hovering
            }
        }
    }

    // MARK: - Separator (for smart positioning)
    @ViewBuilder
    var separatorView: some View {
        let shouldShowSeparator =
            if showMediaLayer {
                // Show separator on L3 if media is playing
                mediaObserver.isPlaying
            } else if aiMode.isActive {
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

}
