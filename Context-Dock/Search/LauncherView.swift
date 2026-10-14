import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct GeneralChatFocusApp: Identifiable, Hashable {
    let name: String
    let bundleId: String
    var id: String { bundleId }
}

struct LauncherView {
    /// The launcher's remembered state, outside SwiftUI (#257 E1): the engine that reads
    /// it is headed out of this view. `LauncherView+EngineState` bridges each field.
    @ObservedObject var engineState = LauncherEngineState.shared
    // Max visible list height: rows beyond this scroll inside the glass card.
    let listViewVisibleHeight: CGFloat = 372
    // Computed helpers — always work off the active panel key
    var activeConsoleKey: String {
        if let k = searchState.activeSmartQueryKey { return k }
        if let dockKey = currentL2DockSessionKey { return dockKey }
        if let ctx = searchState.contextApp {
            return ctx.appPath.isEmpty ? ctx.name : ctx.appPath
        }
        return "default"
    }
    /// Returns (or lazily creates) the real PTY terminal for a given panel key.
    func panelTerminal(for key: String) -> TerminalHostController {
        if let existing = panelTerminalControllers[key] { return existing }
        let controller = TerminalHostController(isPanel: true)
        panelTerminalControllers[key] = controller
        return controller
    }
    // Live Panel (right side) — hidden by default, slides in like Claude's artifact panel
    enum LivePanelMode: Equatable {
        case results([ResultEntry])  // AI-returned file/item list
        case terminal  // embedded SwiftTerm PTY
        case nowPlaying  // music player HUD
        case filePreview(url: URL)  // inline QL preview for AI-created files
        struct ResultEntry: Equatable, Identifiable {
            var id: String { path.isEmpty ? name : path }
            var name: String
            var path: String  // empty for non-file items
            var subtitle: String  // size, type, etc.
            var icon: String  // SF symbol name
        }

        static func == (lhs: LivePanelMode, rhs: LivePanelMode) -> Bool {
            switch (lhs, rhs) {
            case (.results, .results): return true
            case (.terminal, .terminal): return true
            case (.nowPlaying, .nowPlaying): return true
            case (.filePreview(let a), .filePreview(let b)): return a == b
            default: return false
            }
        }
    }
    @ObservedObject var contactManager = ContactSearchManager.shared
    @ObservedObject var systemDataManager = SystemDataSearchManager.shared
    @ObservedObject var terminalPackageManager = TerminalPackageManager.shared
    @ObservedObject var cliScopeTerminal = CLIScopeTerminalManager.shared
    @ObservedObject var adapterManager = AppAdapterManager.shared

    @ObservedObject var notificationManager = ILauncherNotificationManager.shared
    @ObservedObject var mediaObserver = MediaPlayerObserver.shared
    @ObservedObject var selectionModel = LauncherEngineState.shared.selectionModel
    // Reserved height for L1 results panel. Resets to 0 when results clear and otherwise tracks
    // visible result count so short result sets do not keep a mostly empty sheet.
    // Preview, shortcut-sheet, and command-key state lives in LauncherViewModel.
    // AI chat mode
    @ObservedObject var appState = AppState.shared
    var aiMode: AIModeState {
        get { appState.aiChat.mode }
        nonmutating set { appState.aiChat.mode = newValue }
    }
    var frontmost: FrontmostAppState {
        get { appState.contextDock.frontmost }
        nonmutating set { appState.contextDock.frontmost = newValue }
    }
    @AppStorage("isMailContextAttached") var isMailContextAttached: Bool = false
    @ObservedObject var launcherViewModel = LauncherEngineState.shared.launcherViewModel
    @ObservedObject var globalContextViewModel = LauncherEngineState.shared.globalContextViewModel
    @ObservedObject var finderContext = LauncherEngineState.shared.finderContext
    @ObservedObject var contextDockViewModel = LauncherEngineState.shared.contextDockViewModel
    @ObservedObject var aiChatViewModel = LauncherEngineState.shared.aiChatViewModel
    @FocusState var isSearchFieldFocused: Bool
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var fileIndexManager = FileIndexManager.shared
    var onClose: () -> Void = {}



    // Context-aware features
    /// Live AX-read snapshot: URL, window title, selection, focused element role.
    /// Refreshed on every context-dock open and frontmost-app change.
    // Live context state lives in ContextDockViewModel.
    /// Deep per-app context from adapter contextReaders (current file, git branch, etc.)

    // AI Extension Suggestions (different from AI Chat mode)
    // AI extension suggestion state lives in AIChatViewModel.

    // Search bar collapse/expand state
    // Search bar lifecycle state lives in LauncherViewModel.

    // Layer memory — restored when closing chat
    // AI layer return state lives in AIChatViewModel.
    // Suppress hover-expand briefly after a layer switch (prevents phantom hover fires on icon change)
    /// True during the opening animation (~0.25s) — suppresses updateWindowSize so the
    /// launch animation can't be interrupted by a SwiftUI layout pass firing a resize.

    // Context in dock state
    var showContextInDock: Bool {
        get { appState.contextDock.isActive }
        nonmutating set { appState.setContextDockActiveDeferred(newValue) }
    }
    var globalContextActivation: GlobalContextActivation? {
        get { appState.globalContext.activation }
        nonmutating set { appState.setGlobalContextActivationDeferred(newValue) }
    }
    var isGlobalContextActive: Bool { globalContextActivation != nil }

    // Track if user has sent a message in current session
    // AI message session state lives in AIChatViewModel.

    // User profile picture

    // Web research
    @ObservedObject var webResearch = WebResearchSession.shared


    // Live menu-bar items loaded from frontmost app on dock open
    // Live and cross-app menu state lives in ContextDockViewModel.
    // Clipboard monitoring for Global Context
    // Clipboard/global-selection state lives in GlobalContextViewModel.
    var isGlobalContextAutoActivated: Bool { globalContextActivation?.autoActivated ?? false }
    var frozenSelectionText: String? { selectionScopePayload?.frozenText }
    var frozenSelectionFullText: String? { selectionScopePayload?.frozenFullText }
    var frozenSelectionSourceBundleId: String? { selectionScopePayload?.sourceBundleId }
    var frozenSelectionFileURLs: [URL] {
        canonicalExistingURLs(
            (selectionScopePayload?.frozenFilePaths ?? []).map { URL(fileURLWithPath: $0) }
        )
    }
    // Pill navigation state lives in ContextDockViewModel.

    // Media layer state (L3 - swipe up from L2 when media is playing)
    var showMediaLayer: Bool {
        get { appState.mediaDock.isActive }
        nonmutating set { appState.mediaDock.isActive = newValue }
    }

    // Combined search pool
    var allItems: [SearchResult] {
        allApplications + cliToolSearchResults + systemCommandSearchResults
            + userExtensionSearchResults
    }

    /// User-authored Global Context extensions. Unlike a command, picking one opens a
    /// floating panel (the same window class as Quick Note) rather than running once.
    var userExtensionSearchResults: [SearchResult] {
        UserGlobalExtensionStore.shared.enabledExtensions.map { ext in
            var result = SearchResult(
                title: ext.name,
                subtitle: "userext://\(ext.id.uuidString)",
                icon: NSImage(systemSymbolName: ext.icon, accessibilityDescription: ext.name),
                action: {
                    ExtensionPanelManager.shared.open(ext)
                },
                type: .extensionCommand,
                filePath: nil,
                contactData: nil,
                displayBadges: [ext.aiEnabled ? "Extension · AI" : "Extension"],
                showsTypeLabel: false,
                stableID: "userext://\(ext.id.uuidString)"
            )
            result.dismissesLauncher = true
            return result
        }
    }


    /// CLI tools the user added appear in search results alongside applications. `packages`
    /// also holds every executable found on PATH, which must not be searchable as a scope.
    var cliToolSearchResults: [SearchResult] {
        return TerminalPackageManager.shared.packages
            .filter(\.isEnabled)
            .filter(TerminalPackageManager.shared.isUserAddedGlobalScope)
            .map { pkg in
                let isTUI = TerminalAIBridge.shared.isTUICommand(pkg.command)
                let symbolName = isTUI ? "terminal.fill" : "arrow.right.square.fill"
                let icon = NSImage(
                    systemSymbolName: symbolName,
                    accessibilityDescription: pkg.name)
                return SearchResult(
                    title: pkg.command,
                    subtitle: "cli://\(pkg.command)",
                    icon: icon,
                    action: {
                        _ = activateInlineDockAppScope(
                            bundleIdentifier: "cli://\(pkg.command)",
                            appName: pkg.name.isEmpty ? pkg.command : pkg.name,
                            queryOverride: ""
                        )
                    },
                    type: .cliTool,
                    filePath: nil,
                    contactData: nil,
                    stableID: "cli://\(pkg.command)"
                )
            }
    }

    /// User-editable global commands appear in the normal app-style result list.
    var systemCommandSearchResults: [SearchResult] {
        SystemCommandsRegistry.shared.commands
            .filter(\.isEnabled)
            .map { command in
                var result = SearchResult(
                    title: command.name,
                    subtitle: "syscmd://\(command.id.uuidString)",
                    icon: NSImage(systemSymbolName: command.icon, accessibilityDescription: command.name),
                    action: {
                        runSystemCommand(command, originalQuery: searchState.query)
                    },
                    type: .extensionCommand,
                    filePath: nil,
                    contactData: nil,
                    displayBadges: [command.actionTypeLabel],
                    showsTypeLabel: false,
                    stableID: "syscmd://\(command.id.uuidString)"
                )
                result.dismissesLauncher = true
                return result
            }
    }

    var expandedDockWidth: CGFloat { DockShellWidth.dockWindowWidth }  // Spotlight-matched
    var visibleDockWidth: CGFloat { expandedDockWidth }




    var calculatedWidth: CGFloat {
        visibleDockWidth + floatingClipboardOccupiedWidth + floatingAppLogoOccupiedWidth
    }

    var floatingClipboardOccupiedWidth: CGFloat {
        0
    }


    var shouldShowFloatingAppLogo: Bool {
        false
    }

    var floatingAppLogoOccupiedWidth: CGFloat {
        shouldShowFloatingAppLogo ? 44 : 0
    }

    var isCompactSmartScope: Bool {
        guard let key = searchState.activeSmartQueryKey else { return false }
        return key == "clipboard" || key == "notifications"
    }


    var usesVerticalListDockLayout: Bool {
        shouldShowSeparateActionList
    }

    var currentDockSurfaceMode: DockSurfaceMode {
        if showMediaLayer { return .mediaDock }
        if shouldShowContextDockChatSheet || isContextDockChatRoutingLocked
            // Inside a CLI tool scope the input composes the next command, so keep the
            // opaque chat surface while typing — don't fall through to the transparent
            // Global Context surface (which made the sheet go see-through mid-query).
            || (isCLIToolScopeLocked && (l2.chatArmed || !l2.chatMessages.isEmpty))
        {
            return .contextDockChat
        }
        // Selection Scope is its own scoped surface. Its AI answers should render in-place
        // inside the selection sheet, not promote the whole dock into system-wide AI Assistant.
        if aiMode.isActive && !hasSelectionScopeSurface { return .generalChat }
        if isGlobalContextActive { return .globalContext }
        return .contextDock
    }


    /// Single source of truth for "is there meaningful selected content right now?"
    /// Uses >3 char threshold for text to filter cursor-position noise from Electron/Catalyst apps.
    /// Does NOT include frozenSelectionText — that is a captured label, not live content.
    var activeSelection: ActiveSelection? {
        // Files: shared resolver handles AX paths + currentContext + dismissal
        let files = effectiveFinderSelectionURLsForPills()
        if !files.isEmpty { return .files(files) }
        // AX text (>3 chars filters cursor-position events)
        let axText = (axContext.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if axText.count > 3 { return .text(axText) }
        // Resolved context (Share Sheet, Services, or explicit set)
        switch currentContext {
        case .textSelected(let t):
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 3 { return .text(trimmed) }
        case .url(let u):
            let trimmed = u.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return .url(trimmed) }
        default: break
        }
        return nil
    }

    /// Selection Scope freezes the payload at entry so the source app can lose focus without
    /// losing the scope. Use this for Selection Scope UI/actions; use `activeSelection` only
    /// when the caller truly needs the live AX state.
    var effectiveSelectionForScope: ActiveSelection? {
        if let payload = selectionScopePayload {
            let files = payload.frozenFilePaths.map { URL(fileURLWithPath: $0) }
            if !files.isEmpty { return .files(files) }
            let fullText = payload.frozenFullText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fullText, !fullText.isEmpty { return .text(fullText) }
            let label = payload.frozenText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let label, !label.isEmpty, payload.frozenIcon == "text.cursor" {
                return .text(label)
            }
        }
        return activeSelection
    }

    var hasActiveDockContextSelection: Bool {
        activeSelection != nil || globalContextActivationHasFrozenPayload
    }

    /// True while Selection Scope is active — i.e. a selection has been frozen into
    /// selectionScopePayload. Surface-independent by design (see selectionScopePayload).
    var globalContextActivationHasFrozenPayload: Bool {
        guard let payload = selectionScopePayload else { return false }
        return payload.frozenText?.isEmpty == false || !payload.frozenFilePaths.isEmpty
    }

    var hasSelectionScopeSurface: Bool {
        // Selection availability is not Selection Scope. A live Finder/text selection only
        // shows the trailing selection button; it must not replace frontmost app menus until
        // the user explicitly opens Selection Scope from that button.
        globalContextActivationHasFrozenPayload
    }

    var shouldUsePureGlobalAppSearch: Bool {
        // Only an EXPLICIT Finder scope (the inline Finder chip) means "search
        // files" and should beat global app search. Do NOT use the broad
        // isFinderDesktopOnlyMode here — it's also true when Finder merely happens
        // to be the frontmost app, which would wrongly turn plain Global Context
        // (no chip) into file search instead of apps/commands/running apps.
        let explicitFinderScope =
            globalInlineAppScope?.bundleId == "com.apple.finder"
        // The clipboard pill appears whenever the pasteboard changes (0.75s watcher)
        // — it must NOT hijack the surface while the user is typing a query, or
        // pure global search dies mid-keystroke (↓ expansion silently bails).
        // It only claims the surface on an empty field, where clipboard scope lives.
        let clipboardClaimsSurface =
            showGlobalClipboardPill && !globalClipboardText.isEmpty
            && searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isGlobalContextActive
            && !hasSelectionScopeSurface
            // Browsing a folder is file search by definition — the folder's contents are
            // the surface. Falling back to app search there collapsed the sheet the moment
            // the field was cleared on entry.
            && !isBrowsingFinderFolder
            && !clipboardClaimsSurface
            && l2.targetApp == nil
            && !explicitFinderScope
            && searchState.activeSmartQueryKey == nil
            && searchState.contextApp == nil
            && lockedSubmenuParent == nil
            && currentDockSurfaceMode != .generalChat
            && !showMediaLayer
            && !isContextDockChatRoutingLocked
    }


    var shouldShowSeparateActionList: Bool {
        guard showContextInDock,
            !showMediaLayer,
            currentDockSurfaceMode != .generalChat,
            !isContextDockChatRoutingLocked,
            shouldShowL2UnifiedDockRow
        else { return false }

        // Selection Scope shows its result sheet (Ask AI + actions + share) on an empty query too,
        // except when it was opened by the dedicated hotkey — that entry starts as a compact bar
        // and unfolds on the first keystroke (or ↓).
        if hasSelectionScopeSurface {
            guard !aiMode.isActive else { return false }
            let selectionQuery = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if selectionQuery.isEmpty { return !selectionScopeSheetCollapsed }
            // Any typed query opens the sheet. With no menu/extension match it holds just the
            // Ask AI row, which is the stable way into selection-grounded chat — one row is a
            // destination, not an empty state.
            return true
        }

        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Finder desktop-only mode is a dedicated file-search scope. Once the user types,
        // it owns the result sheet even while its fast index or Spotlight enrichment is
        // publishing rows; never collapse back to the input capsule between snapshots.
        // Finder desktop file search owns the sheet whenever it has something to show:
        // once the user types, and — this is the browse case — whenever a folder has been
        // drilled into, where the field is empty on purpose and the folder's contents are
        // the list. Without the browse clause the rows existed and were rendered into a
        // layout that has no room for them, which showed as a sliver of one row under the
        // input.
        if isFinderDesktopOnlyMode && (!q.isEmpty || isBrowsingFinderFolder) { return true }
        if shouldUsePureGlobalAppSearch {
            let hasExtensionScope =
                currentGlobalScopedBundleID?.hasPrefix("syscmd://") == true
                || currentGlobalScopedBundleID?.hasPrefix("cli://") == true
            guard !q.isEmpty || hasExtensionScope else { return false }
            return hasExpandedGlobalContextResults
        }
        let finderSearchPopoverActive = shouldUseFinderSearchPopover(for: q)
        let pillQuery = finderSearchPopoverActive ? "" : q
        if isGlobalContextActive && currentGlobalScopedBundleID != nil {
            guard !shouldShowGlobalScopedChatPin else { return false }
            // Running-app scope always owns the below-input result sheet, including
            // empty-query cached menus. Do not let async cache availability switch the
            // shared shell back to beside-input layout. Finder remains query-driven file
            // search, so an empty Finder scope stays compact.
            if isActiveGlobalRunningAppMenuScope() { return true }
            guard !q.isEmpty else { return false }
            if pendingDockPillQuery == pillQuery || isResolvingDockPills(for: pillQuery) {
                // Preview rows are already a renderable snapshot. Keep the shared sheet alive
                // while slower menu enrichment finishes instead of deadlocking visibility on a
                // resolver flag that can legitimately remain active across multiple passes.
                return stableVisibleDockPills(for: pillQuery).contains { !$0.isSeparator }
            }
            return stableVisibleDockPills(for: pillQuery).contains { !$0.isSeparator }
        }
        // Context Dock uses the SAME separate vertical list as Global Context (input on top,
        // results full-width below). The earlier `return false` here routed Context Dock to
        // the inline in-dockBaseView layout, which is what actually detached the results to
        // the RIGHT of the input — the separate list renders correctly beneath it.
        // Scoped app shows menus on empty query (see l2DockRowPresentation).
        let pills =
            (pillQuery.isEmpty && l2.targetApp == nil) ? [] : stableVisibleDockPills(for: pillQuery)
        let hasActiveContextSelection = hasSelectionScopeSurface
        let contextDockBuildInFlight =
            !isGlobalContextActive
            && !pillQuery.isEmpty
            && (pendingDockPillQuery == pillQuery || isResolvingDockPills(for: pillQuery))
        let visibleActionPills = pills.filter { !$0.isSeparator }
        let hasRealContextDockActionPills = visibleActionPills.contains { pill in
            if isSearchOnlyDockPill(pill) { return false }
            let kind = pill.rankingKind.lowercased()
            let badge = (pill.badge ?? "").lowercased()
            if kind == "applaunch" || kind == "application" || badge == "switch" {
                return false
            }
            return true
        }
        let searchOnlyContextDockPills =
            !isGlobalContextActive
            && !q.isEmpty
            && !visibleActionPills.isEmpty
            && !hasRealContextDockActionPills
        // Finder desktop-only mode is itself a file-search surface. Its primary file/folder
        // rows can carry the shared `contentSearch` ranking kind, so treating them like the
        // generic cross-app "Search …" suggestions collapses the result sheet even though
        // Finder has real matches ready to render.
        if searchOnlyContextDockPills && !isFinderDesktopOnlyMode {
            return false
        }
        if contextDockBuildInFlight {
            return visibleActionPills.contains { pill in
                !pill.isSeparator && !isSearchOnlyDockPill(pill)
            }
        }

        let showPinnedRow =
            q.isEmpty
            && l2.targetApp == nil
            && (pills.isEmpty || (isGlobalContextActive && !hasActiveContextSelection))
        let showGlobalAppSearch = shouldUsePureGlobalAppSearch && !q.isEmpty
        let hasListContent =
            pills.contains(where: { !$0.isSeparator })
            || showGlobalAppSearch
            || (!isGlobalContextActive && hasRealContextDockActionPills)
        return hasListContent
            && !showPinnedRow
            && (!shouldShowContextDockAIQueryFallback || hasRealContextDockActionPills)
            && (!l2.chatAutoArmedForNoMenuMatch || hasRealContextDockActionPills)
    }

    func currentCachedDockPills(for query: String) -> [DockPill] {
        if isFinderDesktopOnlyMode {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var ranked = rankDockPills(
                buildFinderDesktopModePills(query: q),
                rawQuery: q,
                rankingQuery: q,
                scopedBundleId: "com.apple.finder",
                scopedAppName: "Finder",
                isExplicitAppScope: false,
                includeNonMatching: q.isEmpty
            )
            if finderDesktopHasNoSearchScope {
                ranked.append(finderAddSearchDirectorySuggestionPill())
            }
            return ranked
        }
        if lastPillQuery == query { return cachedDockPills }
        if searchState.activeSmartQueryKey == "clipboard" {
            return buildClipboardHistoryPills(query: query)
        }
        if pendingDockPillQuery == query {
            return pendingDockPreviewPills
        }
        return []
    }

    func selectionScopedDockPills(_ pills: [DockPill]) -> [DockPill] {
        guard hasSelectionScopeSurface else { return pills }
        return pills.filter { pill in
            guard !pill.isSeparator else { return false }
            let badge = (pill.badge ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let kind = pill.rankingKind.lowercased()
            let name = pill.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if kind == "applaunch" { return false }
            if !isGlobalContextActive,
                badge == "recent items" || kind.contains("recent") || name.hasSuffix(".app")
            {
                return false
            }
            return true
        }
    }

    func currentVisibleDockPills(for query: String) -> [DockPill] {
        selectionScopedDockPills(currentCachedDockPills(for: query))
    }

    func isResolvingDockPills(for query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        return pendingDockPillQuery == q || lastPillQuery != q || dockPillBuildTask != nil
    }

    func stableVisibleDockPills(for query: String) -> [DockPill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let current = currentVisibleDockPills(for: query)
        if current.contains(where: { !$0.isSeparator }) {
            return current
        }
        guard showContextInDock,
            !showMediaLayer,
            currentDockSurfaceMode != .generalChat,
            !isContextDockChatRoutingLocked,
            !shouldUsePureGlobalAppSearch,
            !q.isEmpty
        else {
            return current
        }
        if hasSelectionScopeSurface {
            // Hold the previous matching rows while a keystroke rebuild is still resolving —
            // otherwise the sheet blanks between snapshots and the rows visibly jump.
            guard isResolvingDockPills(for: q) else { return current }
            let previous = selectionScopedDockPills(cachedDockPills).filter { pill in
                guard !pill.isSeparator else { return false }
                return dockPillHasQuerySignal(
                    pill,
                    query: q,
                    rawQuery: q,
                    scopedBundleId: "com.apple.finder",
                    scopedAppName: "Finder"
                )
            }
            return previous.contains(where: { !$0.isSeparator }) ? previous : current
        }
        let preview = selectionScopedDockPills(contextDockPreviewPills(for: query))
        if preview.contains(where: { !$0.isSeparator }) {
            return preview
        }

        guard q.count >= 3 else { return current }

        // Do not flash the AI fallback while a keystroke-triggered pill rebuild is still
        // resolving. Holding prior matching rows is closer to Spotlight/Raycast than repainting a
        // transient "Ask <app>" row and replacing it milliseconds later. Never hold unrelated
        // previous rows (e.g. StoreKit rows for "stop") because that desyncs the ghost from the
        // visible result sheet.
        if isResolvingDockPills(for: q) {
            let scope = resolveDockScope(for: q)
            let previous = selectionScopedDockPills(cachedDockPills).filter { pill in
                guard !pill.isSeparator else { return false }
                return dockPillHasQuerySignal(
                    pill,
                    query: scope.scopedSearchQuery.isEmpty ? q : scope.scopedSearchQuery,
                    rawQuery: q,
                    scopedBundleId: scope.scopedBundleId,
                    scopedAppName: scope.scopedAppName
                )
            }
            return previous.contains(where: { !$0.isSeparator }) ? previous : current
        }

        return current
    }

    func contextDockNoResultFallbackPill(for query: String) -> DockPill {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = l2.targetApp?.name ?? frontmost.name
        var pill = DockPill(
            id: "context-fallback-ai-\(normalizedDockPillText(q))",
            name: q.isEmpty ? "Ask AI" : "Ask AI: \(q)",
            icon: "sparkles",
            accentColorName: "purple",
            badge: appName.isEmpty ? nil : appName,
            execute: {
                guard !q.isEmpty else { return }
                dismissMediaLayer()
                handleL2QuerySkippingMenuRouter(q)
            }
        )
        pill.rankingKind = "aiFallback"
        pill.sourceBundleId = l2.targetApp?.bundleId ?? frontmost.bundleID
        pill.sourceAppName = appName
        pill.searchTerms = [q, appName, "ask"]
        return pill
    }

    func contextDockPreviewPills(for query: String) -> [DockPill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty, !cachedDockPills.isEmpty else { return cachedDockPills }
        let scope = resolveDockScope(for: q)
        let sourceFingerprint = dockPillRenderFingerprint(cachedDockPills)
        let scopeKey = [
            scope.scopedBundleId,
            scope.scopedAppName,
            scope.scopedSearchQuery,
            scope.isExplicitAppScope ? "explicit" : "implicit",
            scope.isGlobalScope ? "global" : "local",
            isGlobalContextActive ? "globalActive" : "contextDock",
            hasSelectionScopeSurface ? "selection" : "noSelection",
        ].joined(separator: "|")
        if let cached = contextDockViewModel.cachedPreviewPills(
            query: q,
            sourceFingerprint: sourceFingerprint,
            scopeKey: scopeKey
        ) {
            return cached
        }
        let filtered = cachedDockPills.filter { pill in
            guard !pill.isSeparator else { return false }
            return dockPillHasQuerySignal(
                pill,
                query: q,
                rawQuery: q,
                scopedBundleId: scope.scopedBundleId,
                scopedAppName: scope.scopedAppName
            )
        }
        let preview: [DockPill] =
            filtered.isEmpty
            ? []
            : rankDockPills(
                filtered,
                rawQuery: q,
                rankingQuery: scope.scopedSearchQuery.isEmpty ? q : scope.scopedSearchQuery,
                scopedBundleId: scope.scopedBundleId,
                scopedAppName: scope.scopedAppName,
                isExplicitAppScope: scope.isExplicitAppScope
            )
        contextDockViewModel.storePreviewPills(
            preview,
            query: q,
            sourceFingerprint: sourceFingerprint,
            scopeKey: scopeKey
        )
        return preview
    }


    func menuItemWithSourceFallback(_ item: AXMenuItem, pid: pid_t, appName: String)
        -> AXMenuItem
    {
        var copy = item
        if copy.sourcePID == 0 { copy.sourcePID = pid }
        if copy.sourceAppName.isEmpty { copy.sourceAppName = appName }
        copy.children = copy.children.map {
            menuItemWithSourceFallback($0, pid: pid, appName: appName)
        }
        return copy
    }

    func lockSubmenuParentForNavigation(_ item: AXMenuItem) {
        let fallbackPID =
            item.sourcePID != 0
            ? item.sourcePID
            : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
        let fallbackName = item.sourceAppName.isEmpty ? frontmost.name : item.sourceAppName
        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
            lockedSubmenuParent = menuItemWithSourceFallback(
                item,
                pid: fallbackPID,
                appName: fallbackName
            )
            searchState.query = ""
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            listViewHoveredIndex = nil
        }
        l2.appCompletion = nil
        l2.showResultsPopover = false
        cachedDockPills = []
    }

    func menuItemHasNativeShortcut(_ item: AXMenuItem) -> Bool {
        item.shortcutChar?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func shouldExposeCachedMenuItem(_ item: AXMenuItem) -> Bool {
        // Apple-menu Recent Items never surface, even when the live Apple menu is allowed.
        if isAppleRecentItemsMenuItem(item) { return false }
        return item.isEnabled
            || menuItemHasNativeShortcut(item)
            || item.resolvedFilePath != nil
            || item.isLeaf
    }

    func makeMenuDockPill(
        id: String,
        item: AXMenuItem,
        sourceBundleId: String,
        sourceAppName: String,
        accentColorName: String = "gray",
        badge: String?,
        trackingIdentifier: String,
        searchTerms: [String],
        executeLeaf: @escaping () -> Void
    ) -> DockPill {
        ContextDockPillBuilder(
            menuSymbol: { menuSymbol(for: $0) },
            menuIcon: { resolvedMenuIcon(for: $0) },
            menuContextLabel: { menuContextLabel(from: $0) },
            isEnabled: { shouldExposeCachedMenuItem($0) },
            statusBadge: { item, bundleId in
                menuStatusBadge(for: item, bundleIdentifier: bundleId)
            },
            resolvedURL: { item in
                if let path = item.resolvedFilePath,
                   FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
                return resolveCachedMenuFileURL(from: item)
            },
            onSubmenuParent: { lockSubmenuParentForNavigation($0) }
        )
        .makeMenuDockPill(
            input: .init(
                id: id,
                item: item,
                sourceBundleId: sourceBundleId,
                sourceAppName: sourceAppName,
                accentColorName: accentColorName,
                badge: badge,
                trackingIdentifier: trackingIdentifier,
                searchTerms: searchTerms
            ),
            executeLeaf: executeLeaf
        )
        .applyingSafariFavicon(safariHistoryBookmarkURL(for: item, sourceBundleId: sourceBundleId))
    }

    /// Safari History/Bookmarks menu rows resolve to the page's real URL via the
    /// local history DB so the row can show the site favicon (same as Global Context).
    func safariHistoryBookmarkURL(for item: AXMenuItem, sourceBundleId: String) -> URL? {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        // Works for every app's History/Bookmarks rows (Safari, Chrome, Edge, Arc,
        // Brave, Firefox, Zen, and even non-browser players whose history titles match
        // a page we have indexed). Resolver merges all browser histories + the Safari
        // extension map; then a host-from-title guess for domain-shaped titles.
        if let resolved = SafariLinkResolver.shared.url(forTitle: title) { return resolved }
        return Self.webURLGuess(fromTitle: title)
    }

    /// Best-effort web URL from a menu row title. Matches a whole-string host
    /// ("github.com", "music.youtube.com/…") or the first domain-shaped token
    /// embedded in the title ("Settings for github.com…"). Returns nil for plain
    /// labels so non-web menu commands never get a bogus favicon.
    static func webURLGuess(fromTitle title: String) -> URL? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = URL(string: trimmed),
            let scheme = direct.scheme?.lowercased(),
            scheme == "https" || scheme == "http", direct.host != nil
        {
            return direct
        }

        let hostPattern = "(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,24}(?:/[^\\s]*)?"
        guard
            let regex = try? NSRegularExpression(
                pattern: hostPattern, options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard
            let match = regex.firstMatch(in: trimmed, options: [], range: range),
            let matchRange = Range(match.range, in: trimmed)
        else { return nil }

        let candidate = String(trimmed[matchRange])
        return URL(string: "https://\(candidate)")
    }

    func submenuLeafChildren(from parent: AXMenuItem) -> [AXMenuItem] {
        var leaves: [AXMenuItem] = []
        for child in parent.children {
            if child.isLeaf {
                leaves.append(child)
            } else {
                leaves.append(contentsOf: child.children.filter(\.isLeaf))
            }
        }
        return leaves
    }

    func makeSubmenuChildDockPills(
        parent: AXMenuItem,
        idPrefix: String,
        sourceBundleId: String,
        sourceAppName: String,
        accentColorName: String = "blue",
        trackingPrefix: String,
        searchTerms: [String],
        executeChild: @escaping (AXMenuItem) -> Void
    ) -> [DockPill] {
        // Share submenu children are NOT surfaced from AX (unreliable + the AX-click
        // mis-fired). DoraX populates share destinations from NSSharingService instead
        // (every installed share-extension), executed by object identity.
        if normalizedDockPillText(parent.title).contains("share") { return [] }
        return submenuLeafChildren(from: parent)
            .filter { !isRejectedTopMenuItem($0, appName: sourceAppName) && shouldExposeCachedMenuItem($0) }
            .prefix(maxListViewDockPills)
            .map { child in
                var pill = DockPill(
                    id: "\(idPrefix)-child-\(child.id)",
                    name: child.title,
                    icon: menuSymbol(for: child),
                    accentColorName: accentColorName,
                    badge: child.shortcutDisplay,
                    execute: { executeChild(child) }
                )
                pill.menuItemImage = resolvedMenuIcon(for: child)
                pill.menuItemName = child.title
                pill.sourceBundleId = sourceBundleId
                pill.sourceAppName = sourceAppName
                pill.menuContext = parent.title
                pill.rankingKind = "submenuChild"
                pill.isEnabled = shouldExposeCachedMenuItem(child)
                pill.hasLiveAvailability = child.hasLiveAvailability
                pill.menuStatusBadge = menuStatusBadge(for: child, bundleIdentifier: sourceBundleId)
                pill.keyboardShortcutLabel = child.shortcutDisplay
                pill.trackingIdentifier =
                    "\(trackingPrefix):\(child.path.joined(separator: " > ").lowercased())"
                pill.searchTerms = child.path + parent.path + searchTerms + [parent.title]
                return pill.applyingSafariFavicon(
                    safariHistoryBookmarkURL(for: child, sourceBundleId: sourceBundleId))
            }
    }

    func resolveCachedMenuFileURL(from item: AXMenuItem) -> URL? {
        guard item.children.isEmpty else { return nil }
        let path = item.path.map(normalizedDockPillText)
        let likelyDocumentMenu =
            path.contains("recent items")
            || path.contains("open recent")
            || path.contains("documents")
        guard likelyDocumentMenu else { return nil }
        return resolveCachedFileURL(fromMenuTitle: item.title)
    }

    func resolveCachedFileURL(fromMenuTitle title: String) -> URL? {
        let cleaned = cleanCachedMenuFileTitle(title)
        guard cleaned.count >= 3 else { return nil }
        if let literalURL = resolveLiteralCachedFileURL(cleaned) {
            return literalURL
        }
        let normalizedCleaned = normalizedDockPillText(cleaned)

        for doc in RecentItemsService.shared.recentDocuments() {
            let names = [
                doc.url.lastPathComponent,
                doc.url.deletingPathExtension().lastPathComponent,
                doc.name,
            ].map(normalizedDockPillText)
            if names.contains(normalizedCleaned),
                FileManager.default.fileExists(atPath: doc.url.path)
            {
                return doc.url
            }
        }

        let matches = fileIndexManager.advancedSearch(
            AdvancedFileSearchQuery(
                rootPath: NSHomeDirectory(),
                residualQuery: cleaned,
                includeDirectories: false,
                filesOnly: true,
                limit: 12
            ))
        if let exact = matches.first(where: {
            normalizedDockPillText($0.name) == normalizedCleaned
                || normalizedDockPillText(URL(fileURLWithPath: $0.path).lastPathComponent)
                    == normalizedCleaned
        }) {
            return URL(fileURLWithPath: exact.path)
        }
        return nil
    }

    func resolveLiteralCachedFileURL(_ value: String) -> URL? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (raw.hasPrefix("\"") && raw.hasSuffix("\""))
            || (raw.hasPrefix("'") && raw.hasSuffix("'"))
        {
            raw.removeFirst()
            raw.removeLast()
        }
        guard raw.hasPrefix("/") || raw.hasPrefix("~/") else { return nil }

        var candidates = [(raw as NSString).expandingTildeInPath]
        if raw.contains(" - ") {
            let prefix = raw.components(separatedBy: " - ").first ?? raw
            candidates.append((prefix as NSString).expandingTildeInPath)
        }

        for candidate in Set(candidates) where FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    func cleanCachedMenuFileTitle(_ title: String) -> String {
        var value =
            title
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: " (Edited)", with: "")
            .replacingOccurrences(of: " — Edited", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains(" - ") {
            let ext = URL(fileURLWithPath: value).pathExtension
            if ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value = value.components(separatedBy: " - ").first ?? value
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func menuStatusBadge(for item: AXMenuItem, bundleIdentifier: String) -> String? {
        if item.hasLiveAvailability {
            if item.isEnabled || shouldTreatDisabledLiveMenuAsRunnable(item) {
                return "Live"
            }
            return "Unavailable now"
        }
        if isVolatileCachedMenuPath(item.path) {
            if !bundleIdentifier.isEmpty,
                let age = AppMenuCapabilityCache.shared.snapshotAge(
                    bundleIdentifier: bundleIdentifier),
                age <= 30
            {
                return nil
            }
            return "Stale"
        }
        if !bundleIdentifier.isEmpty,
            warmingMenuBundleIds.contains(bundleIdentifier)
        {
            return "Updating..."
        }
        if !bundleIdentifier.isEmpty,
            NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
            })
        {
            return nil
        }
        return bundleIdentifier.isEmpty ? nil : "Needs launch"
    }

    func shouldTreatDisabledLiveMenuAsRunnable(_ item: AXMenuItem) -> Bool {
        guard menuItemHasNativeShortcut(item) else { return false }
        let root = item.path.first.map(normalizedDockPillText) ?? ""
        let title = normalizedDockPillText(item.title)

        // Finder can report these disabled while native shortcuts remain valid.
        // Keep shortcut-driven window closing available without weakening other
        // context-sensitive File menu actions.
        let closeWindowTitles: Set<String> = [
            "close window", "close all", "close all windows",
        ]
        if closeWindowTitles.contains(title) { return true }

        // Some SwiftUI/Catalyst/AppKit apps report navigation/menu-tab commands as disabled
        // until the native menu is opened, even though the shortcut works. Keep truly
        // context-sensitive edit/file commands unavailable.
        let contextSensitiveRoots: Set<String> = ["edit", "file"]
        if contextSensitiveRoots.contains(root) { return false }

        let contextSensitiveTitles: Set<String> = [
            "copy", "cut", "paste", "delete", "rename", "duplicate",
            "save", "save as", "export", "print",
        ]
        if contextSensitiveTitles.contains(title) { return false }

        return true
    }

    func mergeCachedMenusWithLiveAvailability(
        cached cachedItems: [AXMenuItem],
        live liveItems: [AXMenuItem]
    ) -> [AXMenuItem] {
        ContextDockEngine.shared.mergeCachedMenusWithLiveAvailability(
            cached: cachedItems,
            live: liveItems
        )
    }

    func isVolatileCachedMenuPath(_ path: [String]) -> Bool {
        let normalized = path.map(normalizedDockPillText)
        guard !normalized.isEmpty else { return false }
        if let title = path.last, BrowserStableMenuCommand.isStable(title: title) { return false }
        let volatileBranches: Set<String> = [
            "history",
            "bookmarks",
            "open recent",
            "recent items",
            "recent documents",
            "recent projects",
            "recent files",
            "recent folders",
            "recently closed",
            "closed tabs",
            "closed windows",
        ]
        if normalized.contains(where: { volatileBranches.contains($0) }) { return true }
        return normalized.first == "window" && normalized.count > 2
    }



    func dedupeDockPillsByTrackingIdentifier(_ pills: [DockPill]) -> [DockPill] {
        var seen = Set<String>()
        var output: [DockPill] = []
        for pill in pills {
            let key =
                !pill.trackingIdentifier.isEmpty
                ? pill.trackingIdentifier
                : "\(pill.sourceBundleId):\(pill.rankingKind):\(normalizedDockPillText(pill.name))"
            guard seen.insert(key).inserted else { continue }
            output.append(pill)
        }
        return output
    }


    var contextDockRunningOnlyAppMatching: Bool {
        false
    }

    var contextDockInstalledAppScopeMatching: Bool {
        false
    }

    var maxListViewDockPills: Int {
        28
    }



    // MARK: - System Settings Deep-Link Pills




    /// When System Settings is frontmost, emit pills for every pane so the user can navigate
    /// directly via query (e.g. "wallpaper", "wifi", "bluetooth") without relying on menu items.
    func buildSystemSettingsPills(
        query q: String,
        scopedBundleId: String? = nil,
        scopedAppName: String? = nil
    ) -> [DockPill] {
        guard
            frontmost.bundleID == "com.apple.systempreferences"
                || l2.targetApp?.bundleId == "com.apple.systempreferences"
                || scopedBundleId == "com.apple.systempreferences"
        else { return [] }

        // If the user installed a System Settings adapter pack, it owns these
        // actions (with correct, up-to-date deep links). Suppress the hardcoded
        // built-in panes so they don't duplicate or shadow the pack with stale
        // links (e.g. Wallpaper moved panes on macOS 26).
        if let adapter = AppAdapterManager.shared.adapter(for: "com.apple.systempreferences"),
            !adapter.actions.isEmpty {
            return []
        }

        typealias Pane = (name: String, terms: [String], url: String, icon: String)
        let panes: [Pane] = [
            (
                "Wallpaper", ["background", "desktop", "display background", "wallpapper"],
                "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
                "photo.on.rectangle"
            ),
            (
                "Wi-Fi", ["wifi", "network", "internet", "wireless", "wlan"],
                "x-apple.systempreferences:com.apple.Network-Settings.extension", "wifi"
            ),
            (
                "Bluetooth", ["bluetooth", "bt", "airdrop"],
                "x-apple.systempreferences:com.apple.BluetoothSettings", "bluetooth"
            ),
            (
                "Display", ["screen", "resolution", "brightness", "retina", "monitor"],
                "x-apple.systempreferences:com.apple.Display-Settings.extension", "display"
            ),
            (
                "Notifications", ["notification", "alerts", "banners", "badges", "do not disturb"],
                "x-apple.systempreferences:com.apple.Notifications-Settings.extension", "bell.badge"
            ),
            (
                "Sound", ["audio", "volume", "speakers", "microphone", "mute", "output", "input"],
                "x-apple.systempreferences:com.apple.Sound-Settings.extension", "speaker.wave.2"
            ),
            (
                "Focus", ["focus", "do not disturb", "dnd", "quiet hours"],
                "x-apple.systempreferences:com.apple.Focus-Settings.extension", "moon"
            ),
            (
                "Appearance",
                ["dark mode", "light mode", "accent", "theme", "sidebar", "interface"],
                "x-apple.systempreferences:com.apple.Appearance-Settings.extension", "paintbrush"
            ),
            (
                "Accessibility",
                ["accessibility", "zoom", "voiceover", "voice over", "captions", "a11y"],
                "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
                "accessibility"
            ),
            (
                "Privacy & Security",
                ["privacy", "security", "permissions", "access", "firewall", "location"],
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                "lock.shield"
            ),
            (
                "Lock Screen", ["lock", "screensaver", "sleep", "password", "login screen"],
                "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension", "lock"
            ),
            (
                "Keyboard",
                ["keyboard", "typing", "shortcuts", "function keys", "dictation", "fn"],
                "x-apple.systempreferences:com.apple.Keyboard-Settings.extension", "keyboard"
            ),
            (
                "Mouse", ["mouse", "scroll", "click", "pointer", "cursor", "tracking"],
                "x-apple.systempreferences:com.apple.Mouse-Settings.extension", "cursorarrow"
            ),
            (
                "Trackpad", ["trackpad", "gesture", "swipe", "pinch", "tap"],
                "x-apple.systempreferences:com.apple.Trackpad-Settings.extension", "hand.point.up"
            ),
            (
                "Battery", ["battery", "power", "energy", "charging", "low power"],
                "x-apple.systempreferences:com.apple.Battery-Settings.extension", "battery.100"
            ),
            (
                "Software Update", ["update", "macos update", "os update", "upgrade"],
                "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
                "arrow.down.circle"
            ),
            (
                "iCloud", ["icloud", "cloud", "sync", "apple id", "account"],
                "x-apple.systempreferences:com.apple.Internet-Settings.extension", "icloud"
            ),
            (
                "General", ["general", "sharing", "storage", "airdrop", "handoff"],
                "x-apple.systempreferences:com.apple.GeneralSettings.extension", "gearshape"
            ),
            (
                "Users & Groups", ["user", "account", "group", "login", "password", "guest"],
                "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension", "person.2"
            ),
            (
                "Date & Time", ["date", "time", "clock", "timezone", "24 hour"],
                "x-apple.systempreferences:com.apple.Date-Time-Settings.extension", "clock"
            ),
        ]

        return panes.map { pane in
            let urlStr = pane.url
            var pill = DockPill(
                id: "syspref:\(urlStr)",
                name: pane.name,
                icon: pane.icon,
                accentColorName: "blue",
                badge: nil,
                execute: {
                    if let u = URL(string: urlStr) { NSWorkspace.shared.open(u) }
                }
            )
            pill.rankingKind = "quickAction"
            pill.sourceBundleId = "com.apple.systempreferences"
            pill.sourceAppName = scopedAppName ?? "System Settings"
            pill.searchTerms = [pane.name.lowercased()] + pane.terms
            return pill
        }
    }

    // MARK: - Safari Command Pills

    /// Builds DockPill items for page-level Safari commands (search, click, open, highlight, etc.).
    /// Menu items (Show Next Tab, Pin Tab, etc.) are skipped here — the AX system already shows them.
    func buildSafariCommandPills(query q: String) -> [DockPill] {
        guard !q.isEmpty else { return [] }
        let isSafariActive =
            frontmost.bundleID == "com.apple.Safari"
            || SafariBrowserBridge.shared.safariContextIfFresh() != nil
        guard isSafariActive else { return [] }
        guard let cmd = SafariCommandBridge.shared.parseIntent(q) else { return [] }
        // AX menu system already shows menu items as pills — skip duplicates
        if case .menuItem = cmd { return [] }

        let (pillName, pillIcon) = safariCommandPillDisplay(cmd, rawQuery: q)
        let capturedQ = q
        var pill = DockPill(
            id: "safari-cmd-\(q.lowercased().prefix(40))",
            name: pillName,
            icon: pillIcon,
            accentColorName: "blue",
            badge: "Safari",
            execute: {
                Task {
                    let result = await SafariCommandBridge.shared.execute(cmd)
                    await MainActor.run {
                        if self.l2.chatMessages.last?.content != capturedQ {
                            self.l2.chatMessages.append(
                                AIChatMessage(role: .user, content: capturedQ))
                        }
                        self.l2.chatMessages.append(
                            AIChatMessage(role: .assistant, content: "🌐 \(result)"))
                        self.searchState.query = ""
                        if !self.isSearchBarExpanded {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                self.isSearchBarExpanded = true
                            }
                            self.requestWindowSizeUpdate(reason: .rowLayoutChanged)
                        }
                    }
                }
            }
        )
        pill.rankingKind = "safariCommand"
        pill.sourceBundleId = "com.apple.Safari"
        pill.sourceAppName = "Safari"
        pill.searchTerms = [pillName, q, "safari"]
        pill.trackingIdentifier = "safari-cmd:\(q.lowercased().prefix(40))"
        return [pill]
    }

    func safariCommandPillDisplay(_ cmd: SafariCommand, rawQuery: String) -> (
        name: String, icon: String
    ) {
        switch cmd {
        case .menuItem(_, let item):
            return (item, "menubar.rectangle")
        case .openTab(let url):
            return ("Open \(url)", "safari")
        case .searchNewTab(let query, let engine):
            return ("Search \"\(query)\" — \(engine.rawValue.capitalized)", "magnifyingglass")
        case .closeCurrentTab:
            return ("Close Tab", "xmark.circle")
        case .runPageJS:
            let isPlay =
                rawQuery.lowercased().hasPrefix("play ")
                || rawQuery.lowercased().hasPrefix("watch ")
            let term =
                rawQuery
                .replacingOccurrences(
                    of: "^(click|tap|press|play|watch|open video)\\s+", with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(of: " from this page", with: "")
                .replacingOccurrences(of: " on this page", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlay {
                return ("Play \"\(term)\"", "play.circle")
            }
            return ("Click \"\(term)\"", "cursorarrow.click.2")
        case .highlightText(let text):
            return ("Highlight \"\(text)\"", "highlighter")
        case .scrollToSelector(let css):
            return ("Scroll to \(css)", "arrow.down.to.line")
        case .scrapeSelector(let css, _):
            return ("Scrape \(css)", "doc.text.magnifyingglass")
        case .extractPrices:
            return ("Extract Prices", "tag")
        case .fillField(let sel, _):
            return ("Fill \(sel)", "pencil.line")
        case .clickElement(let sel):
            return ("Click \(sel)", "cursorarrow.click")
        case .answerInfo:
            return ("Safari Info", "info.circle")
        }
    }





    func isStaleAvailabilityMenuPill(_ pill: DockPill) -> Bool {
        guard pill.rankingKind == "menu" || pill.rankingKind == "finderMenu" else {
            return false
        }
        if !pill.hasLiveAvailability { return true }
        let normalizedName = normalizedDockPillText(pill.name)
        if normalizedName == "close selected" || normalizedName.hasPrefix("close selected ") {
            return true
        }
        // In Global Context with selected files/text, Context Dock owns focus. Several
        // apps recalculate kAXEnabled only while their native menu is open, so a runnable
        // selection action can report disabled. Execution still validates volatile paths.
        if isGlobalContextActive && hasActiveDockContextSelection { return true }
        if hasActiveDockContextSelection && pill.sourceBundleId == "com.apple.finder" {
            return true
        }
        if showContextInDock && !isGlobalContextActive {
            let targetBundleId = l2.targetApp?.bundleId
                ?? AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier
                ?? ""
            if !targetBundleId.isEmpty, pill.sourceBundleId == targetBundleId {
                return true
            }
        }
        return false
    }






    /// Every previewable file currently listed, so Quick Look can walk the scope.
    func visiblePreviewPaths() -> [String] {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return renderedOrderDockPills(for: q).compactMap { $0.previewPath }
    }













    // Execute a cross-app ghost suggestion through the same cache-verify pipeline as visible menu pills.
    func executeLearnedGhostAction(
        bundleID: String, path: [String], shortcutChar: String?, shortcutModifiers: Int
    ) {
        Task.detached(priority: .userInitiated) {
            let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleID && !$0.isTerminated
            })
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let result = await GlobalContextEngine.shared.verifyAndExecuteCachedMenu(
                GlobalMenuExecutionRequest(
                    bundleIdentifier: bundleID,
                    appName: runningApp?.localizedName ?? appURL?.deletingPathExtension()
                        .lastPathComponent ?? bundleID,
                    appPath: appURL?.path,
                    path: path,
                    shortcutChar: shortcutChar,
                    shortcutModifiers: shortcutModifiers
                )
            )

            await MainActor.run {
                switch result.status {
                case .executed:
                    break
                case .executionFallback:
                    // Modern inline dock feedback (tick at the dock's trailing edge
                    // + ghost message in the input), not a separate floating pill.
                    DockActionFeedback.showResult(
                        result.message,
                        icon: "checkmark.circle.fill",
                        success: true,
                        subject: result.app?.localizedName,
                        bundleID: result.app?.bundleIdentifier ?? bundleID)
                case .unavailable, .launchFailed:
                    DockActionFeedback.showResult(
                        result.message,
                        icon: "exclamationmark.triangle.fill",
                        success: false,
                        subject: result.app?.localizedName,
                        bundleID: result.app?.bundleIdentifier ?? bundleID)
                }

                // Quitting an app from its own scope: drop that app's pill so the
                // search bar is immediately ready for the next query.
                if result.status == .executed, GlobalContextEngine.isPlainQuitAction(path: path) {
                    self.removeGlobalInlineAppScopesAfterQuit(bundleID: bundleID)
                }

                if let app = result.app {
                    self.reloadMenuForApp(app)
                    self.refreshVisibleGlobalContextAfterMenuCacheUpdate(
                        bundleIdentifier: app.bundleIdentifier
                    )
                }
            }
        }
    }




    /// When searchState.query is an exact match for a non-leaf menu item (submenu parent), optionally
    /// followed by a space + child prefix letter(s), returns the parent item, the typed child
    /// prefix, and the filtered leaf children. Drives submenu ghost text + instant child pills.
    ///
    /// Examples:
    ///   "sort by"   → parent=Sort By, prefix="",  children=[Attachments,Date,Flags,…]
    ///   "sort by d" → parent=Sort By, prefix="d",  children=[Date]
    ///   "file"      → parent=File,    prefix="",  children=[New Message,…]
    var submenuGhostContext:
        (parent: AXMenuItem, childPrefix: String, children: [AXMenuItem])?
    {
        // Locked mode: parent is fixed, searchState.query is the child filter prefix
        if let locked = lockedSubmenuParent {
            var leaves: [AXMenuItem] = []
            for child in locked.children {
                if child.isLeaf {
                    leaves.append(child)
                } else {
                    leaves.append(contentsOf: child.children.filter(\.isLeaf))
                }
            }
            leaves = leaves.filter { $0.isEnabled }
            guard !leaves.isEmpty else { return nil }
            let prefix = normalizedDockPillText(
                searchState.query.trimmingCharacters(in: .whitespaces))
            let filtered =
                prefix.isEmpty
                ? leaves : leaves.filter { normalizedDockPillText($0.title).hasPrefix(prefix) }
            return (locked, prefix, prefix.isEmpty ? leaves : filtered)
        }

        guard !liveMenuItems.isEmpty else { return nil }
        let raw = searchState.query.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let tokens = raw.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        // Try from longest prefix downward: "sort by d" tries parent="sort by" before "sort"
        for splitAt in stride(from: tokens.count, through: 1, by: -1) {
            let parentQ = normalizedDockPillText(tokens.prefix(splitAt).joined(separator: " "))
            guard !parentQ.isEmpty else { continue }
            guard
                let parent = liveMenuItems.first(where: {
                    !$0.isLeaf && normalizedDockPillText($0.title) == parentQ
                })
            else { continue }

            // Never ghost-drill a "Share" submenu — DoraX shows NSSharingService
            // destinations (all installed share-extensions) instead of AX children.
            if isShareSheetTitle(parent.title) { continue }

            // Collect enabled leaf children (direct leaves + one level deeper)
            var leafChildren: [AXMenuItem] = []
            for child in parent.children {
                if child.isLeaf {
                    leafChildren.append(child)
                } else {
                    leafChildren.append(contentsOf: child.children.filter(\.isLeaf))
                }
            }
            leafChildren = leafChildren.filter { $0.isEnabled }
            guard !leafChildren.isEmpty else { continue }

            let childPrefix =
                tokens.count > splitAt
                ? normalizedDockPillText(tokens.dropFirst(splitAt).joined(separator: " "))
                : ""
            let filtered =
                childPrefix.isEmpty
                ? leafChildren
                : leafChildren.filter { normalizedDockPillText($0.title).hasPrefix(childPrefix) }

            if childPrefix.isEmpty || !filtered.isEmpty {
                return (parent, childPrefix, childPrefix.isEmpty ? leafChildren : filtered)
            }
        }
        return nil
    }





    // Shared condition: whether any results panel should be visible.
    var hasMatchingGlobalContextResults: Bool {
        guard isGlobalContextActive,
            shouldUsePureGlobalAppSearch,
            globalInlineAppScope == nil
        else { return false }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        if transientGlobalScopedMenuRowCount(for: q) > 0 { return true }
        if globalGroupedListNavigationState(for: q).totalCount > 0 { return true }
        return !matchDockIconRowsForExpandedSheet(query: q).isEmpty
    }

    var hasExpandedGlobalContextResults: Bool {
        guard isGlobalContextActive,
            shouldUsePureGlobalAppSearch,
            globalContextViewModel.typingSnapshot.phase == .expanded
        else { return false }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty,
            let bundleID = currentGlobalScopedBundleID,
            bundleID.hasPrefix("syscmd://") || bundleID.hasPrefix("cli://")
        {
            // The explicit extension scope owns the result sheet. Do not make
            // its shell depend on the first provider read already having rows;
            // Bluetooth/Wi-Fi can briefly be resolving their dynamic content.
            return true
        }
        guard !q.isEmpty else { return false }
        if transientGlobalScopedMenuRowCount(for: q) > 0 { return true }
        if globalGroupedListNavigationState(for: q).totalCount > 0 { return true }
        return !matchDockIconRowsForExpandedSheet(query: q).isEmpty
    }




    var shouldShowContextDockAppPanel: Bool {
        guard searchState.contextApp != nil || searchState.activeSmartQueryKey != nil else {
            return false
        }
        guard showContextInDock, !showMediaLayer else {
            return true
        }
        if isCompactSmartScope {
            return true
        }
        return searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }








    // MARK: - Selected Result Preview


    // MARK: - Spotlight-style App Context (Tab/→ on app result)

    /// Activates context panel for ANY result type (Spotlight-style Tab/→).
    /// Always opens the 2-column AI panel — chat + quick actions.
    func openCLIToolPanel(for package: TerminalPackage) {
        attachCLIToolToCurrentDock(command: package.command, package: package)
    }


    @discardableResult



    func reloadAppPanelData(for key: String) {
        switch key {
        case "clipboard":
            searchState.appPanelAllItems = clipboardSearchResults()
        case "notifications":
            searchState.appPanelAllItems = notificationSearchResults()
        case "reminders":
            loadSystemDataAsPinnedResults(
                query: "", types: [.reminder], title: "Reminders",
                perTypeLimit: 500, allowEmptyQuery: true, excludeTypes: [.reminder])
        case "calendar":
            loadSystemDataAsPinnedResults(
                query: "", types: [.calendarEvent], title: "Calendar",
                perTypeLimit: 500, allowEmptyQuery: true, excludeTypes: [.calendarEvent])
        case "notes":
            loadSystemDataAsPinnedResults(
                query: "", types: [.note], title: "Notes",
                perTypeLimit: 500, allowEmptyQuery: true, excludeTypes: [.note])
        case "mail":
            loadSystemDataAsPinnedResults(
                query: "", types: [.mail], title: "Mail",
                perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.mail])
        case "photos":
            loadSystemDataAsPinnedResults(
                query: "", types: [.photo], title: "Photos",
                perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.photo])
        case "messages":
            clearPinnedResults()
            searchState.appPanelAllItems = []
        case "contacts":
            loadAllContactsAsResults()
        case "safari":
            Task { await loadSafariTabs() }
        default: break
        }
    }








}
