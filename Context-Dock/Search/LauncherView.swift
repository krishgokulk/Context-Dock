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

struct LauncherView: View {
    @State var searchState = SearchState()
    @State var queryChangeTask: Task<Void, Never>? = nil
    @State var queryChangeGeneration: Int = 0
    // Max visible list height: rows beyond this scroll inside the glass card.
    let listViewVisibleHeight: CGFloat = 372
    // These are isolated from searchState so their mutations don't trigger a struct-wide re-render
    // (SwiftUI re-renders all readers of a @State struct when ANY property changes)
    // General launcher/search state lives in LauncherViewModel.
    // rem-powered Reminders panel chat
    // AI chat session state lives in AIChatViewModel.
    // Tool-removal cleanup banner
    // Per-panel terminal history — keyed by searchState.activeSmartQueryKey or searchState.contextApp bundleID
    @State var panelConsoleLinesMap: [String: [(line: String, isCommand: Bool)]] = [:]
    @State var panelShowConsoleMap: [String: Bool] = [:]
    @State var panelConsoleHeight: CGFloat = 160
    // Per-panel embedded PTY terminals (real SwiftTerm instances)
    @State var panelTerminalControllers: [String: TerminalHostController] = [:]
    // Computed helpers — always work off the active panel key
    var activeConsoleKey: String {
        if let k = searchState.activeSmartQueryKey { return k }
        if let dockKey = currentL2DockSessionKey { return dockKey }
        if let ctx = searchState.contextApp {
            return ctx.appPath.isEmpty ? ctx.name : ctx.appPath
        }
        return "default"
    }
    var panelConsoleLines: [(line: String, isCommand: Bool)] {
        panelConsoleLinesMap[activeConsoleKey] ?? []
    }
    var showPanelConsole: Bool {
        panelShowConsoleMap[activeConsoleKey] ?? false
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
    @State var livePanelMode: LivePanelMode = .results([])
    @State var livePanelVisible: Bool = false  // drives the slide-in animation
    @State var qlRightClickPos: CGPoint? = nil  // position for QL pill context menu
    @State var panelTerminalHost: TerminalHostController? = nil
    @ObservedObject var workerPool = BackgroundWorkerPool.shared
    @ObservedObject var miniPlayer = MiniPlayerController.shared
    @StateObject var mediaDockEngine = MediaDockEngine.shared
    @State var l2 = L2State()
    @ObservedObject var contactManager = ContactSearchManager.shared
    @ObservedObject var systemDataManager = SystemDataSearchManager.shared
    @ObservedObject var terminalBridge = TerminalAIBridge.shared
    @ObservedObject var terminalPackageManager = TerminalPackageManager.shared
    @ObservedObject var adapterManager = AppAdapterManager.shared

    @ObservedObject var notificationManager = ILauncherNotificationManager.shared
    @ObservedObject var mediaObserver = MediaPlayerObserver.shared
    @StateObject var taskExecutor = L2AITaskExecutor.shared
    @StateObject var selectionModel = SelectionObserverModel()
    // High-water-mark height for L1 results panel — grows to fit content, never shrinks mid-session.
    // Resets to 0 when results clear. Window resizes once on 0→N transition, stays stable while typing.
    // Preview, shortcut-sheet, and command-key state lives in LauncherViewModel.
    // AI chat mode
    @EnvironmentObject var appState: AppState
    var aiMode: AIModeState {
        get { appState.aiChat.mode }
        nonmutating set { appState.aiChat.mode = newValue }
    }
    var aiModeMessagesBinding: Binding<[AIChatMessage]> {
        Binding(
            get: { appState.aiChat.mode.messages },
            set: { appState.aiChat.mode.messages = $0 }
        )
    }
    @EnvironmentObject var contextEnv: ContextDockEnvironment
    var frontmost: FrontmostAppState {
        get { appState.contextDock.frontmost }
        nonmutating set { appState.contextDock.frontmost = newValue }
    }
    @State var pendingTerminalCommand: PendingTerminalCommand?
    @State var pendingFinderOperation: PendingFinderOperation?
    @State var isMailContextAttached: Bool = false
    @StateObject var launcherViewModel = LauncherViewModel()
    @StateObject var globalContextViewModel = GlobalContextViewModel()
    @StateObject var finderContext = FinderContextViewModel()
    @State var isHoveringSearchIcon = false
    @State var isHoveringInputField = false
    @State var suppressMouseDrivenInteractionUntil: Date = .distantPast
    @State var suppressMouseDrivenInteractionOrigin: NSPoint?
    @StateObject var contextDockViewModel = ContextDockViewModel()
    @StateObject var aiChatViewModel = AIChatViewModel()
    @FocusState var isSearchFieldFocused: Bool
    @Namespace var compactScopeFocusNamespace
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var fileIndexManager = FileIndexManager.shared
    @Environment(\.openSettings) var openSettings
    @Environment(\.colorScheme) var systemColorScheme
    @State var useUnifiedShell: Bool = false  // Feature flag for new architecture
    var onClose: () -> Void = {}

    /// Effective dark/light state: respects forced setting, falls back to system appearance reactively.
    var isEffectiveDark: Bool {
        switch settings.appearanceMode {
        case "light": return false
        case "dark": return true
        default: return systemColorScheme == .dark
        }
    }

    /// Resolved color scheme from user's appearance preference
    var resolvedColorScheme: ColorScheme? {
        switch settings.appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil  // follow system
        }
    }

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
        nonmutating set { appState.contextDock.isActive = newValue }
    }
    var globalContextActivation: GlobalContextActivation? {
        get { appState.globalContext.activation }
        nonmutating set { appState.globalContext.activation = newValue }
    }
    var isGlobalContextActive: Bool { globalContextActivation != nil }

    // Track if user has sent a message in current session
    // AI message session state lives in AIChatViewModel.

    // User profile picture

    // Web research
    @StateObject var webResearch = WebResearchSession.shared

    // Swipe gesture monitor
    // Swipe and launcher hover state lives in LauncherViewModel.
    @State var isHoveringNowPlayingIcon = false  // Hover over Now Playing icon
    @State var showMediaHoverDock = false  // Popover-style media dock on hover

    // Live menu-bar items loaded from frontmost app on dock open
    // Live and cross-app menu state lives in ContextDockViewModel.
    // Clipboard monitoring for Global Context
    // Clipboard/global-selection state lives in GlobalContextViewModel.
    var isGlobalContextAutoActivated: Bool { globalContextActivation?.autoActivated ?? false }
    var frozenSelectionText: String? { globalContextActivation?.frozenText }
    var frozenSelectionIcon: String? { globalContextActivation?.frozenIcon }
    var frozenSelectionSourceBundleId: String? { globalContextActivation?.sourceBundleId }
    var frozenSelectionFileURLs: [URL] {
        canonicalExistingURLs(
            (globalContextActivation?.frozenFilePaths ?? []).map { URL(fileURLWithPath: $0) }
        )
    }
    // Automatic Finder selection suppression lives in GlobalContextViewModel.
    // Safari tab picker popover
    // Safari picker state lives in ContextDockViewModel.
    // Cross-app menu items loaded lazily when query targets a specific app
    // Locked submenu parent — when set, searchState.query is treated as child prefix
    // Locked menu and cross-app loading state lives in ContextDockViewModel.
    // Arrow-key pill navigation: index into the unified pill list
    // Global-context cache/app-scope state lives in GlobalContextViewModel.
    // Dock magnification: tracks which pill the mouse is near
    // Scroll-to-navigate: true when mouse is over the action pill row
    let dockResultFocusEffectID = "dock-result-focus"
    // Pill navigation state lives in ContextDockViewModel.

    // Media layer state (L3 - swipe up from L2 when media is playing)
    var showMediaLayer: Bool {
        get { appState.mediaDock.isActive }
        nonmutating set { appState.mediaDock.isActive = newValue }
    }

    // Combined search pool
    var allItems: [SearchResult] {
        allApplications + cliToolSearchResults + systemCommandSearchResults
    }

    /// Synthetic Homebrew search result — shows up when user types "brew" or "homebrew".
    var homebrewSearchResult: SearchResult? {
        let brewPath =
            FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            ? "/opt/homebrew/bin/brew"
            : FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
                ? "/usr/local/bin/brew" : nil
        guard let path = brewPath else { return nil }
        let icon = NSImage(
            systemSymbolName: "shippingbox.fill", accessibilityDescription: "Homebrew")
        return SearchResult(
            title: "Homebrew",
            subtitle: path,
            icon: icon,
            action: {},
            type: .application,
            filePath: path,
            contactData: nil
        )
    }

    /// Registered CLI tools appear in search results alongside applications.
    var cliToolSearchResults: [SearchResult] {
        return TerminalPackageManager.shared.packages
            .filter(\.isEnabled)
            .filter(isUserAddedGlobalCLITool)
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
                    type: .application,
                    filePath: pkg.installedPath,
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

    // Calculate dynamic height based on content
    var calculatedHeight: CGFloat {
        // Pinned apps are now rendered inline as a horizontal icon strip next to the search bar,
        // so they should not contribute extra height.
        let pinnedAppsHeight: CGFloat = 0
        let statusBarHeight: CGFloat = settings.enableStatusBar ? 45 : 0
        let contextHeight: CGFloat =
            (settings.enableFrontmostDetection && frontmost.isSectionExpanded) ? 45 : 0
        let dockRowHeight = CGFloat(settings.dockIconSize) + 4
        let dockVerticalPadding: CGFloat = 12
        let searchBarHeight: CGFloat =
            usesVerticalListDockLayout
            ? 56
            : max(
                isSearchBarExpanded ? 58 : 50,
                dockRowHeight + dockVerticalPadding
            )
        let indexingBarHeight: CGFloat = fileIndexManager.progress.isIndexing ? 30 : 0
        let finderSearchPanelHeight: CGFloat = {
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
        }()

        // Context chip height (only in L1 search mode with context and suggestions)
        let contextChipHeight: CGFloat = {
            // Not applicable in AI mode, L2 context mode, or the L3 media dock
            if aiMode.isActive || showContextInDock || showMediaLayer { return 0 }

            // If context awareness is disabled, return 0
            guard settings.enableContextAIExtensions else { return 0 }

            // Only expand if we have meaningful context
            let hasContext: Bool = {
                switch currentContext {
                case .filesSelected(let urls): return !urls.isEmpty
                case .textSelected(let text):
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .url(let urlString):
                    return !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .appFocused, .contactSelected, .none: return false
                }
            }()

            if !hasContext { return 0 }

            // Check if we have any matching shortcuts — passive only (not while typing)
            let hasSuggestions: Bool = {
                guard searchState.query.isEmpty else { return false }
                return allShortcuts.contains { shortcut in
                    guard let metadata = shortcutMetadataCache[shortcut.title] else { return false }
                    return metadata.matches(context: currentContext)
                }
            }()

            return hasSuggestions ? 70 : 0
        }()

        // AI mode has different height calculation, but keep the empty AI bar compact so
        // the glass background stays visually consistent with the L2 dock.
        if aiMode.isActive {
            // Each message bubble ~76px; cap window growth at 400px for chat.
            let aiChatHeight: CGFloat =
                aiMode.messages.isEmpty
                ? 0
                : min(CGFloat(aiMode.messages.count) * 76, 400)
            // Always reserve loading space when chat is active — prevents resize on loading toggle
            let aiLoadingHeight: CGFloat = aiMode.messages.isEmpty ? 0 : 48
            return statusBarHeight + pinnedAppsHeight + searchBarHeight + aiChatHeight
                + aiLoadingHeight + 12
        }

        // App panel (calendar/reminders/notes/etc.) — split view with fixed height.
        // While typing in Context Dock, keep the stable inline action list instead.
        if searchState.activeSmartQueryKey != nil
            && !isCompactSmartScope
            && shouldShowContextDockAppPanel
        {
            let panelHeight: CGFloat = 480
            let panelGap: CGFloat = 10
            return statusBarHeight + pinnedAppsHeight + searchBarHeight + panelHeight + panelGap
        }

        if isCompactSmartScope {
            let panelHeight: CGFloat = 450
            let panelGap: CGFloat = 8
            return statusBarHeight + pinnedAppsHeight + searchBarHeight + panelHeight + panelGap
        }

        // Finder current-folder search mode uses the shared result panel instead of pills/popovers.
        if finderSearchPanelHeight > 0 {
            return statusBarHeight + pinnedAppsHeight + searchBarHeight + finderSearchPanelHeight
                + 14
        }

        // L3 Media dock — same compact pill height as normal dock
        if showMediaLayer {
            let mediaPillHeight: CGFloat = mediaObserver.duration > 0 ? 70 : searchBarHeight
            return statusBarHeight + mediaPillHeight + 12
        }

        if shouldShowContextDockChatSheet {
            let messageHeight = min(CGFloat(max(l2.chatMessages.count, 1)) * 92, 400)
            // Always reserve loading space — prevents resize on isLoading toggle during streaming
            let loadingHeight: CGFloat = 54
            let headerHeight: CGFloat = l2.chatMessages.isEmpty ? 0 : 42
            let chatHeight = min(messageHeight + loadingHeight + headerHeight + 26, 500)
            return statusBarHeight + pinnedAppsHeight + searchBarHeight + chatHeight + 10
        }

        if listViewDockHeight > 0 {
            return statusBarHeight + pinnedAppsHeight + listViewDockHeight + 12
        }

        if !searchState.results.isEmpty {
            // High-water-mark allocation: window grows to fit the largest result batch seen,
            // never shrinks mid-session. Resets when results clear. One resize per new max, not per count.
            let h = l1ResultsReservedHeight > 0 ? l1ResultsReservedHeight : 450
            return statusBarHeight + contextHeight + pinnedAppsHeight + searchBarHeight
                + contextChipHeight + indexingBarHeight + h + 10
        } else if searchState.isLoadingApps {
            return statusBarHeight + contextHeight + pinnedAppsHeight + searchBarHeight
                + contextChipHeight + indexingBarHeight + 60
        } else {
            return statusBarHeight + contextHeight + pinnedAppsHeight + searchBarHeight
                + contextChipHeight + indexingBarHeight
        }
    }

    var expandedDockWidth: CGFloat { 660 }  // Spotlight-matched width
    var visibleDockWidth: CGFloat { expandedDockWidth }

    var acceptsMouseDrivenDockInteraction: Bool {
        guard Date() >= suppressMouseDrivenInteractionUntil else { return false }
        guard let origin = suppressMouseDrivenInteractionOrigin else { return true }
        let current = NSEvent.mouseLocation
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        return (dx * dx + dy * dy) > 9
    }

    func beginMouseDrivenInteractionGrace(_ seconds: TimeInterval = 0.45) {
        suppressMouseDrivenInteractionUntil = Date().addingTimeInterval(seconds)
        suppressMouseDrivenInteractionOrigin = NSEvent.mouseLocation
        isHoveringSearchIcon = false
        isHoveringInputField = false
        isHoveringDockArea = false
        hoveredDockAppKey = nil
        hoveredAppPillIndex = nil
        hoveredDockPillIndex = nil
        listViewHoveredIndex = nil
    }

    var notificationDockPopoverWidth: CGFloat {
        let usableDockWidth = max(visibleDockWidth - 28, 280)
        let reservedInputWidth: CGFloat =
            isSearchBarExpanded
            ? min(340, max(usableDockWidth * 0.48, 300))
            : 108
        let candidate = usableDockWidth - reservedInputWidth
        return min(420, max(280, candidate))
    }

    var calculatedWidth: CGFloat {
        visibleDockWidth + floatingClipboardOccupiedWidth + floatingAppLogoOccupiedWidth
    }

    var floatingClipboardOccupiedWidth: CGFloat {
        0
    }

    var shouldShowClipboardFloatingIcon: Bool {
        false
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

    var shouldUseIntegratedScopeSheet: Bool {
        if isCompactSmartScope { return true }
        guard showContextInDock, !showMediaLayer, !usesVerticalListDockLayout else { return false }
        return hasResultsToShow
    }

    var hasSecondaryDockContentBesideInput: Bool {
        if aiMode.isActive { return false }
        if isCompactSmartScope { return false }
        if usesVerticalListDockLayout { return false }
        if showMediaLayer || searchState.activeSmartQueryKey != nil { return true }
        if showContextInDock {
            if aiMode.isActive { return false }
            if isGlobalContextActive {
                return !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return hasAIExtensionsToShow || !searchState.query.isEmpty
        }
        return !searchState.query.isEmpty
    }

    var usesVerticalListDockLayout: Bool {
        shouldShowSeparateActionList
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

    var hasActiveDockContextSelection: Bool {
        // frozenSelectionText covers the "chip visible after focus moved to dock" case
        activeSelection != nil || frozenSelectionText != nil
    }

    var shouldUsePureGlobalAppSearch: Bool {
        isGlobalContextActive
            && !hasActiveDockContextSelection
            && l2.targetApp == nil
            && searchState.activeSmartQueryKey == nil
            && searchState.contextApp == nil
            && lockedSubmenuParent == nil
            && !aiMode.isActive
            && !showMediaLayer
    }

    var shouldShowSeparateActionList: Bool {
        guard showContextInDock,
            !showMediaLayer,
            !aiMode.isActive,
            !l2.chatArmed,
            !l2.showChatPopover,
            shouldShowL2UnifiedDockRow
        else { return false }

        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if shouldUsePureGlobalAppSearch {
            return !q.isEmpty
        }
        let finderSearchPopoverActive = shouldUseFinderSearchPopover(for: q)
        let pillQuery = finderSearchPopoverActive ? "" : q
        let pills = stableVisibleDockPills(for: pillQuery)
        let hasActiveContextSelection = hasActiveDockContextSelection

        let showPinnedRow =
            q.isEmpty
            && l2.targetApp == nil
            && (pills.isEmpty || (isGlobalContextActive && !hasActiveContextSelection))
        let showGlobalAppSearch = shouldUsePureGlobalAppSearch && !q.isEmpty
        let hasListContent =
            pills.contains(where: { !$0.isSeparator })
            || showGlobalAppSearch
        return hasListContent && !showPinnedRow
    }

    func currentCachedDockPills(for query: String) -> [DockPill] {
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
        guard isGlobalContextActive, hasActiveDockContextSelection else { return pills }
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

    func stableVisibleDockPills(for query: String) -> [DockPill] {
        let current = currentVisibleDockPills(for: query)
        if current.contains(where: { !$0.isSeparator }) {
            return current
        }
        guard showContextInDock,
            !showMediaLayer,
            !aiMode.isActive,
            !shouldUsePureGlobalAppSearch,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return current
        }
        let preview = selectionScopedDockPills(contextDockPreviewPills(for: query))
        if preview.contains(where: { !$0.isSeparator }) {
            return preview
        }
        return [contextDockNoResultFallbackPill(for: query)]
    }

    func contextDockNoResultFallbackPill(for query: String) -> DockPill {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = l2.targetApp?.name ?? frontmost.name
        var pill = DockPill(
            id: "context-fallback-ai-\(normalizedDockPillText(q))",
            name: "Ask \(appName)",
            icon: "bubble.left.and.bubble.right",
            accentColorName: "purple",
            badge: nil,
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
        guard !filtered.isEmpty else { return cachedDockPills }
        return rankDockPills(
            filtered,
            rawQuery: q,
            rankingQuery: scope.scopedSearchQuery.isEmpty ? q : scope.scopedSearchQuery,
            scopedBundleId: scope.scopedBundleId,
            scopedAppName: scope.scopedAppName,
            isExplicitAppScope: scope.isExplicitAppScope
        )
    }

    func cachedMenuItemsForApp(_ app: NSRunningApplication, maxResults: Int = 120)
        -> [AXMenuItem]
    {
        let pid = app.processIdentifier
        let name = app.localizedName ?? ""
        var items = GlobalContextEngine.shared.cachedMenuItems(for: app, maxResults: maxResults)
            .filter(shouldShowCachedMenuItem)
        for index in items.indices {
            items[index].sourcePID = pid
            items[index].sourceAppName = name
        }
        return items
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
        item.isEnabled
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
        guard sourceBundleId == "com.apple.Safari" else { return nil }
        let root = (item.path.first ?? "").lowercased()
        guard root.contains("history") || root.contains("bookmark") else { return nil }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return SafariLinkResolver.shared.url(forTitle: title)
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
        submenuLeafChildren(from: parent)
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

    func shouldShowCachedMenuItem(_ item: AXMenuItem) -> Bool {
        item.path.first.map { normalizedDockPillText($0) != "window" } ?? true
    }

    func hasFrontmostMenuPillsInCurrentCache(for query: String) -> Bool {
        guard isGlobalContextActive, !hasActiveDockContextSelection else { return false }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        guard !resolveDockScope(for: q).isExplicitAppScope else { return false }
        return !cachedFrontmostGlobalMenuPills(query: q, maxResults: 1).isEmpty
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

    var searchInputVisualWidth: CGFloat {
        let dockHorizontalPadding: CGFloat = 24
        let interItemSpacing: CGFloat = 12
        let usable = max(visibleDockWidth - dockHorizontalPadding, 44)
        guard hasSecondaryDockContentBesideInput else { return usable }
        return max(44, (usable - interItemSpacing) / 2)
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

    var body: some View {
        Group {
            if useUnifiedShell {
                // New unified shell architecture
                UnifiedDockShell(
                    isVisible: .constant(true),
                    results: searchState.results,
                    query: searchState.query,
                    dockPills: []  // TODO: wire from LauncherView state
                )
            } else {
                // Legacy LauncherView implementation
                ZStack {
                    contentKeyHandlersView

                    // Contact Preview Overlay
                    if showContactPreview, let contact = contactPreviewData {
                        ContactPreviewCard(contact: contact, isPresented: showContactPreviewBinding)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }

                    // AI Extension Suggestions Overlay
                    if showAIExtensionSuggestions {
                        ZStack {
                            // Dim background
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3)) {
                                        showAIExtensionSuggestions = false
                                    }
                                }

                            // AI Suggestions View
                            AIModeView(
                                currentContext: currentContextBinding,
                                isVisible: showAIExtensionSuggestionsBinding
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }

                }
            }
        }
        .onReceive(adapterManager.$pendingApproval) { pending in
            DispatchQueue.main.async {
                if let pending {
                    openAdapterApprovalWindow(request: pending)
                } else {
                    AdapterApprovalWindowHost.close()
                }
            }
        }
        .onReceive(AICapabilityApprovalCenter.shared.$pending) { pending in
            if let pending {
                openAICapabilityApprovalWindow(pending: pending)
            } else {
                AICapabilityApprovalWindowHost.close()
            }
        }
        .onReceive(AIPrivacyApprovalCenter.shared.$pending) { pending in
            if let pending {
                openAIPrivacyApprovalWindow(pending: pending)
            } else {
                AIPrivacyApprovalWindowHost.close()
            }
        }
        .onReceive(TerminalAIBridge.shared.$pendingApproval) { pending in
            if let pending = pending {
                let risk = pending.classification.riskLevel.displayName
                let approvalMsg = AIChatMessage(
                    role: .approval,
                    content: pending.command,
                    structuredData: "\(pending.purpose)|||/\(risk)"
                )
                if l2.targetApp != nil || showContextInDock {
                    // L2 app scope active — show inline in L2 chat
                    l2.chatMessages.append(approvalMsg)
                } else if searchState.activeSmartQueryKey != nil {
                    // Legacy panel fallback
                    remPanelChatMessages.append(approvalMsg)
                } else {
                    openCommandApprovalWindow(pending: pending)
                }
            } else {
                // Close popup if one was open (for non-panel contexts)
                CommandApprovalWindowHost.close()
            }
        }
    }


    // MARK: - System Settings Deep-Link Pills

    func buildGlobalAppleMenuFallbackPills(query q: String) -> [DockPill] {
        let normalizedQuery = normalizedDockPillText(q)
        guard !normalizedQuery.isEmpty else { return [] }

        typealias AppleCommand = (name: String, aliases: [String], icon: String, action: () -> Void)
        let commands: [AppleCommand] = [
            (
                "About This Mac", ["about", "mac", "about this mac"], "laptopcomputer",
                {
                    clickAppleMenuItem(named: "About This Mac")
                }
            ),
            (
                "System Settings...",
                ["settings", "system settings", "preferences", "system preferences"], "gearshape",
                {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
            ),
            (
                "App Store...", ["app store", "updates", "software"], "app.badge",
                {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/App Store.app"))
                }
            ),
            (
                "Force Quit...", ["force quit", "quit app", "force"], "exclamationmark.octagon",
                {
                    clickAppleMenuItem(named: "Force Quit...")
                }
            ),
            (
                "Sleep", ["sleep", "slee", "standby"], "moon",
                {
                    runAppleMenuScript(#"tell application "System Events" to sleep"#)
                }
            ),
            (
                "Restart...", ["restart", "reboot"], "arrow.clockwise.circle",
                {
                    clickAppleMenuItem(named: "Restart...")
                }
            ),
            (
                "Shut Down...", ["shutdown", "shut down", "power off"], "power",
                {
                    clickAppleMenuItem(named: "Shut Down...")
                }
            ),
            (
                "Lock Screen", ["lock", "lock screen"], "lock",
                {
                    runAppleMenuScript(
                        #"tell application "System Events" to keystroke "q" using {control down, command down}"#
                    )
                }
            ),
            (
                "Log Out...", ["log out", "logout", "sign out"],
                "rectangle.portrait.and.arrow.right",
                {
                    clickAppleMenuItem(named: "Log Out...")
                }
            ),
        ]

        return commands.compactMap { command -> DockPill? in
            let haystack = ([command.name] + command.aliases)
                .map(normalizedDockPillText)
                .joined(separator: " ")
            let tokenMatch =
                normalizedQuery
                .split(separator: " ")
                .allSatisfy { haystack.contains($0) }
            guard haystack.contains(normalizedQuery) || tokenMatch else { return nil }

            var pill = DockPill(
                id: "apple-menu-fallback-\(normalizedDockPillText(command.name))",
                name: command.name,
                icon: command.icon,
                accentColorName: "gray",
                badge: "Apple Menu",
                execute: command.action
            )
            pill.menuContext = "Apple Menu"
            pill.rankingKind = "menu"
            pill.sourceAppName = "Apple Menu"
            pill.searchTerms = [command.name] + command.aliases
            pill.trackingIdentifier = "apple-menu:\(normalizedDockPillText(command.name))"
            pill.rankingScore = command.name.lowercased().hasPrefix(normalizedQuery) ? 600 : 420
            return pill
        }
    }

    func clickAppleMenuItem(named itemName: String) {
        let escaped = itemName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "System Events"
                set frontProc to first application process whose frontmost is true
                click menu item "\(escaped)" of menu 1 of menu bar item 1 of menu bar 1 of frontProc
            end tell
            """
        runAppleMenuScript(script)
    }

    func runAppleMenuScript(_ source: String) {
        Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String
                    ?? "Apple menu action unavailable"
                await MainActor.run {
                    AppToast.show(
                        message,
                        icon: "exclamationmark.triangle",
                        tint: .orange.opacity(0.9)
                    )
                }
            }
        }
    }

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
                            self.updateWindowSize()
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

    /// Execute the currently focused pill. Only call when l2.focusedPillIndex is non-nil.
    /// Clears the input field afterwards so the dock is ready for the next command.
    func executeFirstOrFocusedPill() {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pills = buildDockPills(query: q)
        guard let idx = l2.focusedPillIndex, idx < pills.count else { return }
        let pill =
            pills[idx].isSeparator
            ? pills.first(where: { !$0.isSeparator }) ?? pills[idx]
            : pills[idx]
        executeDockPill(pill)
        // Clear input and focus so dock returns to default state
        searchState.query = ""
        l2.focusedPillIndex = nil
    }

    func executeDockPill(_ pill: DockPill) {
        UsageTracker.shared.recordAccess(for: defaultDockPillTrackingIdentifier(pill))
        if let url = pill.resolvedURL,
            FileManager.default.fileExists(atPath: url.path)
        {
            NSWorkspace.shared.open(url)
            searchState.query = ""
            l2.focusedPillIndex = nil
            hideLauncherAfterResultExecution()
            return
        }
        pill.execute()
        hideLauncherAfterResultExecution()
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
        return false
    }

    func directAppActionQuery(for query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        guard isGlobalContextActive || l2.targetApp != nil else { return nil }
        guard !(isGlobalContextActive && hasActiveDockContextSelection) else { return nil }
        if let target = L2AppActionRouter.shared.explicitAppTarget(for: q) {
            return target.actionQuery
        }
        if let target = installedAppMenuTarget(
            for: q,
            includeAppsWithoutMenuSnapshot: contextDockInstalledAppScopeMatching,
            allowPrefixAlias: contextDockInstalledAppScopeMatching
        ) {
            return target.actionQuery
        }
        if let partial = l2.appCompletion ?? bestL2PartialAppCompletion(for: q),
            !partial.actionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return partial.actionQuery
        }
        if l2.targetApp != nil {
            return q
        }
        return nil
    }

    @discardableResult
    func focusFirstDockPillIfAvailable(for query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pillQuery = shouldUseFinderSearchPopover(for: normalizedQuery) ? "" : normalizedQuery
        let pills = buildDockPills(query: pillQuery)
        guard let firstVisibleIndex = pills.firstIndex(where: { !$0.isSeparator }) else {
            return false
        }

        l2.pillNavViaKeyboard = true
        l2.focusedPillIndex = firstVisibleIndex
        return true
    }

    func isDirectAppActionQuery(_ actionQuery: String) -> Bool {
        let normalized =
            actionQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let tokens = normalized.split(separator: " ")
        return (1...2).contains(tokens.count)
    }

    @discardableResult
    func executeFocusedOrDirectAppPillIfNeeded() -> Bool {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pills = buildDockPills(query: q)
        guard !pills.isEmpty else { return false }

        if let idx = l2.focusedPillIndex, idx < pills.count {
            executeFirstOrFocusedPill()
            return true
        }

        guard let actionQuery = directAppActionQuery(for: q),
            isDirectAppActionQuery(actionQuery)
        else {
            return false
        }

        let defaultPill = pills.first(where: { !$0.isSeparator })
        let isPureScopedSelection: Bool = {
            guard let target = l2.targetApp else { return false }
            let aliases = dockPillAppAliases(appName: target.name, bundleId: target.bundleId)
            return aliases.contains(q)
        }()
        let pill =
            isPureScopedSelection
            ? (pills.first(where: { !$0.isSeparator && $0.rankingKind != "appLaunch" })
                ?? defaultPill)
            : defaultPill
        guard let pill else { return false }

        let scope = resolveDockScope(for: q)
        let isScopedCLIQuery =
            pill.rankingKind == "cliTool"
            && scope.isExplicitAppScope
            && !scope.scopedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isScopedCLIQuery {
            return false
        }

        executeDockPill(pill)
        searchState.query = ""
        l2.focusedPillIndex = nil
        return true
    }

    @discardableResult
    func executeFirstAttachedFinderFolderResultIfNeeded() -> Bool {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !finderFolderQueryModeActive else { return false }
        guard !q.isEmpty, isFinderCurrentWindowSearchAttached() else { return false }
        let pills = buildDockPills(query: q)
        guard
            let pill = pills.first(where: {
                !$0.isSeparator
                    && $0.sourceBundleId == "com.apple.finder"
                    && ($0.rankingKind == "finderCurrent" || $0.rankingKind == "finderSearch")
            })
        else { return false }

        pill.execute()
        l2.focusedPillIndex = nil
        hideLauncherAfterResultExecution()
        return true
    }

    func firstMatchingFinderFolderPill(for rawQuery: String? = nil) -> DockPill? {
        let q = (rawQuery ?? searchState.query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !q.isEmpty else { return nil }

        let pills = buildDockPills(query: q)
        let finderFolderKinds: Set<String> = ["finderGoTo", "finderCurrent", "finderSearch"]
        return pills.first(where: { pill in
            guard !pill.isSeparator else { return false }
            guard pill.sourceBundleId == "com.apple.finder" else { return false }
            guard finderFolderKinds.contains(pill.rankingKind) else { return false }
            guard pill.icon.localizedCaseInsensitiveContains("folder") else { return false }

            let name = pill.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return name.hasPrefix(q) || name.contains(q)
        })
    }

    @discardableResult
    func executeFirstMatchingFinderFolderPillIfNeeded() -> Bool {
        guard let pill = firstMatchingFinderFolderPill() else { return false }
        executeDockPill(pill)
        searchState.query = ""
        l2.focusedPillIndex = nil
        return true
    }

    @ViewBuilder
    var l2UnifiedDockRow: some View {
        let q =
            isL2ContextActive
            ? searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
        let pureGlobalAppSearch = shouldUsePureGlobalAppSearch
        let finderSearchPopoverActive = shouldUseFinderSearchPopover(for: q)
        let pillQuery = finderSearchPopoverActive ? "" : q
        let pills = pureGlobalAppSearch ? [] : stableVisibleDockPills(for: pillQuery)
        let explicitAppTarget =
            pillQuery.isEmpty ? nil : L2AppActionRouter.shared.appScopeTarget(for: pillQuery)

        VStack(alignment: .leading, spacing: 0) {

            // Active selection = files/text/URL right now (not stale clipboard)
            let hasActiveContextSelection = hasActiveDockContextSelection
            let hasAnySelection: Bool =
                hasActiveContextSelection
                || (showGlobalClipboardPill && !globalClipboardText.isEmpty)
            // App results filter from the first typed character. Cache enriches ranking later,
            // but first paint never waits on menus, Recent Items, or AX.
            let globalAppMatches = currentOrImmediateGlobalAppMatches(for: q)
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
            let inlineGlobalAppScopeActive = inlineGlobalScope?.isExplicitAppScope == true
            let effectiveAppScope = inlineGlobalAppScopeActive
            let displayedGlobalAppMatches =
                effectiveAppScope
                ? []
                : globalAppMatches
            let scopedMenuListContext: (appName: String, actionQuery: String)? = {
                if let scope = inlineGlobalScope, scope.isExplicitAppScope {
                    return (scope.scopedAppName, scope.scopedSearchQuery)
                }
                return nil
            }()
            // Single source of truth for menus and cross-app groups.
            // globalGroupedListNavigationState already applies the strict filter and handles all
            // modes (frontmost, explicit app scope, cross-app). Using it here ensures the view
            // and keyboard navigation always operate on identical data.
            let globalNavState: GlobalGroupedListNavigationState? =
                (pureGlobalAppSearch && !q.isEmpty) || effectiveAppScope
                ? globalGroupedListNavigationState(for: q) : nil
            // Flatten frontmost groups back to pills so globalAppSearchListView can re-group
            // (it uses groupMenuPillsByTitle internally for chip display logic).
            let globalMenuPills: [DockPill] = globalNavState?.menuGroups.flatMap(\.allPills) ?? []
            let globalCrossAppGroups: [AppMenuGroup] = globalNavState?.appMenuGroups ?? []
            let globalNavIsScopedAppMenus =
                globalNavState?.appResults.isEmpty == true
                && !(globalNavState?.appMenuGroups.isEmpty ?? true)
            // When files/folders/text are actively selected, show their context actions —
            // not app launchers. App search only shows when there is no active selection.
            let showGlobalAppSearch =
                (pureGlobalAppSearch && !q.isEmpty && !preferFrontmostMenuResults)
                || effectiveAppScope
            // Placeholder hint: show "Open [App] to enable menu search" when the scoped app
            // has no cached menus and isn't currently running.
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
                && (searchState.isLoadingApps
                    || pendingGlobalGroupedQuery == globalGroupedStateCacheKey(for: q)
                    || (!effectiveAppScope && pendingGlobalAppQuery == q
                        && globalAppMatches.isEmpty))

            HStack(spacing: 6) {
                // Submenu locked mode: show vertical child suggestion list instead of pills
                if let findToken = lockedFindToken, showFindTokenMenu, findToken.hasChildMenu {
                    findTokenDropdownView(findToken)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(
                                    with: .scale(
                                        scale: 0.97,
                                        anchor: settings.effectiveDockAtBottom ? .bottom : .top)),
                                removal: .opacity.combined(
                                    with: .scale(
                                        scale: 0.97,
                                        anchor: settings.effectiveDockAtBottom ? .bottom : .top))
                            ))
                } else if let locked = lockedSubmenuParent, let subCtx = submenuGhostContext {
                    submenuDropdownView(
                        parent: locked, children: subCtx.children, prefix: subCtx.childPrefix
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(
                                with: .scale(
                                    scale: 0.97,
                                    anchor: settings.effectiveDockAtBottom ? .bottom : .top)),
                            removal: .opacity.combined(
                                with: .scale(
                                    scale: 0.97,
                                    anchor: settings.effectiveDockAtBottom ? .bottom : .top))
                        ))
                } else if showGlobalAppSearch {
                    globalAppSearchListView(
                        query: q,
                        matches: globalNavIsScopedAppMenus
                            ? [] : (globalNavState?.appResults ?? displayedGlobalAppMatches),
                        menuPills: globalMenuPills,
                        appMenuGroups: globalCrossAppGroups,
                        launchHint: scopedAppLaunchHint,
                        scopedMenuAppName: scopedMenuListContext?.appName,
                        scopedMenuActionQuery: scopedMenuListContext?.actionQuery ?? "",
                        isLoading: globalSearchLoading,
                        menuFirst: false
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    dockPillListView(pills: pills)
                }
            }
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: hasAnySelection)
        }
        .padding(.horizontal, 2)
        .animation(
            .spring(response: 0.22, dampingFraction: 0.85), value: explicitAppTarget?.bundleId
        )
        .onChange(of: pillQuery) { newQuery in
            l2.focusedPillIndex = nil
            focusedAppPillIndex = nil
            if shouldUsePureGlobalAppSearch, !newQuery.isEmpty, allApplications.isEmpty,
                !searchState.isLoadingApps
            {
                loadApplicationsInBackground()
            }
            if shouldUsePureGlobalAppSearch {
                l2.appCompletion = nil
                l2.showResultsPopover = false
                if globalInlineAppScope == nil {
                    scheduleGlobalAppMatchRebuild(query: newQuery, delayNanoseconds: 12_000_000)
                } else {
                    scheduleGlobalGroupedListRebuild(query: newQuery, delayNanoseconds: 50_000_000)
                }
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
        .onAppear {
            if shouldUsePureGlobalAppSearch, !pillQuery.isEmpty, allApplications.isEmpty,
                !searchState.isLoadingApps
            {
                loadApplicationsInBackground()
            }
            if shouldUsePureGlobalAppSearch {
                if globalInlineAppScope == nil {
                    scheduleGlobalAppMatchRebuild(query: pillQuery, delayNanoseconds: 0)
                } else {
                    scheduleGlobalGroupedListRebuild(query: pillQuery, delayNanoseconds: 0)
                }
                return
            }
            scheduleDockPillRebuild(query: pillQuery, delayNanoseconds: 0)
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let dy = value.translation.height
                    let dx = value.translation.width

                    guard abs(dy) > abs(dx) else { return }
                    guard !isExplicitAppScopeLocked else { return }

                    if dy > 30 {
                        // Swipe DOWN → Global Context (manual, should not auto-return)
                        if !isGlobalContextActive {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                globalContextActivation = GlobalContextActivation(
                                    autoActivated: false)
                            }
                            scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
                        }
                    } else if dy < -30 {
                        // Swipe UP
                        if isGlobalContextActive {
                            // Exit Global Context → return to Context Dock
                            dismissContextAndReturnToDock()
                        } else if !showMediaLayer && settings.enableLayer3 {
                            // Context Dock → Media Dock
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
        )
    }

    /// Compact pill shown in place of the search input while app-pill navigation is active.
    /// Looks exactly like a regular app pill: [icon | separator | label]
    @ViewBuilder
    var searchAsPillView: some View {
        Button(action: {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.80)) {
                focusedAppPillIndex = nil
                l2.focusedPillIndex = nil
                l2.pillNavViaKeyboard = false
            }
            DispatchQueue.main.async { isSearchFieldFocused = true }
        }) {
            Group {
                if isGlobalContextActive {
                    if let selIcon = frozenSelectionIcon ?? activeSelectionIcon {
                        Image(systemName: selIcon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.purple.opacity(0.90))
                    } else {
                        ContextDockGlyph(size: 20, opacity: 0.75)
                    }
                } else if let appIcon = l2.targetApp?.icon ?? frontmost.icon {
                    // Show frontmost app icon as the anchor
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .opacity(0.9)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.75))
                }
            }
            .frame(width: 44, height: 40)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(
                        LinearGradient(
                            colors: [.white.opacity(0.08), .white.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                    Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Tap to restore search")
    }

    // Inline ghost label shown in the search bar when a selection is active in global context
    var activeSelectionPromptText: String? {
        let files = effectiveFinderSelectionURLsForPills()
        if files.count > 1 {
            return "Selection — what would you like to do…"
        }
        if let label = frozenSelectionText ?? activeSelectionLabel {
            return "\(label)  —  type to act…"
        }
        return nil
    }

    var activeSelectionLabel: String? {
        let axFiles =
            isDismissedFinderSelection(axContext.selectedFilePaths)
            ? []
            : axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        if !axFiles.isEmpty {
            return axFiles.count == 1
                ? axFiles[0].lastPathComponent : "\(axFiles.count) files selected"
        }
        if let t = axContext.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !t.isEmpty
        {
            return String(t.prefix(50))
        }
        if showGlobalClipboardPill, !globalClipboardText.isEmpty {
            let entry = clipboardHistory.first
            return entry?.preview ?? String(globalClipboardText.prefix(50))
        }
        switch currentContext {
        case .filesSelected(let urls) where !urls.isEmpty && !isDismissedFinderSelection(urls):
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        case .textSelected(let t) where !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return String(t.prefix(50))
        case .url(let u) where !u.isEmpty:
            return URL(string: u)?.host ?? String(u.prefix(50))
        default: return nil
        }
    }

    // SF Symbol that represents the type of the current selection
    var activeSelectionIcon: String? {
        let axFiles =
            isDismissedFinderSelection(axContext.selectedFilePaths)
            ? []
            : axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        if !axFiles.isEmpty {
            return axFiles.count == 1
                ? fileIcon(for: axFiles[0].pathExtension.lowercased()) : "doc.on.doc.fill"
        }
        if let t = axContext.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !t.isEmpty
        {
            return "text.cursor"
        }
        if showGlobalClipboardPill, !globalClipboardText.isEmpty {
            return clipboardHistory.first?.icon ?? "doc.on.clipboard"
        }
        switch currentContext {
        case .filesSelected(let urls) where !urls.isEmpty && !isDismissedFinderSelection(urls):
            return urls.count == 1
                ? fileIcon(for: urls[0].pathExtension.lowercased()) : "doc.on.doc.fill"
        case .textSelected: return "text.cursor"
        case .url: return "link"
        default: return nil
        }
    }

    func finderInputSymbolForSearchText() -> String? {
        guard showContextInDock, !isGlobalContextActive, !aiMode.isActive else { return nil }

        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }
        guard !query.hasPrefix("+") else { return nil }

        if let pill = firstMatchingFinderFolderPill(for: query) {
            return pill.icon.contains("folder") ? "folder.fill" : pill.icon
        }

        return nil
    }

    func menuInputIconForSearchText(hasAppMatch: Bool) -> (image: NSImage?, symbol: String)?
    {
        guard !hasAppMatch else { return nil }
        guard showContextInDock, !isGlobalContextActive, !aiMode.isActive else { return nil }

        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 2 else { return nil }

        guard
            let pill = cachedDockPills.first(where: {
                !$0.isSeparator
                    && ($0.rankingKind == "menu" || $0.rankingKind == "finderMenu")
                    && ($0.name.lowercased().hasPrefix(query)
                        || $0.name.lowercased().contains(query))
            })
        else { return nil }

        return (pill.menuItemImage, pill.icon)
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
                    AppToast.show(
                        result.message, icon: "checkmark.circle", tint: .blue.opacity(0.85))
                case .unavailable, .launchFailed:
                    AppToast.show(
                        result.message, icon: "exclamationmark.triangle", tint: .orange.opacity(0.9)
                    )
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

    /// Cross-app menus grouped by source app — primary implementation.
    /// Scans running regular apps with cached menu snapshots, returns one group per app.
    /// Apps sorted by usage score; only matching menu items included (strict contains filter).
    func crossAppMenuGroups(for query: String, limit: Int = 12) -> [AppMenuGroup] {
        guard !query.isEmpty,
            isGlobalContextActive,
            !hasActiveDockContextSelection,
            globalInlineAppScope == nil
        else { return [] }
        let lower = query.lowercased()
        guard lower.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return [] }
        let ownBundleId = Bundle.main.bundleIdentifier ?? ""
        let runningApps = NSWorkspace.shared.runningApplications.compactMap {
            app -> GlobalMenuAppSnapshot? in
            guard let bid = app.bundleIdentifier else { return nil }
            guard app.activationPolicy == .regular,
                !app.isTerminated,
                bid != "com.apple.finder",
                GlobalContextEngine.shared.hasMenuSnapshot(bundleIdentifier: bid)
            else { return nil }
            return GlobalMenuAppSnapshot(
                bundleID: bid,
                name: app.localizedName ?? "",
                icon: app.icon,
                processIdentifier: app.processIdentifier,
                isRunning: true
            )
        }
        let descriptors = GlobalContextEngine.shared.crossAppMenuDescriptorGroups(
            query: lower,
            runningApps: runningApps,
            excludedBundleIDs: [frontmost.bundleID, ownBundleId, "com.apple.finder"]
                .filter { !$0.isEmpty }.reduce(into: Set<String>()) { $0.insert($1) },
            includeCachedNonRunning: true,
            limit: limit
        )
        return appMenuGroups(from: descriptors)
    }

    /// Flat cross-app pills — delegates to `crossAppMenuGroups` and flattens.
    /// Used for ghost completion and legacy callers that need a flat list.
    func crossAppMenuPills(for query: String, limit: Int = 8) -> [DockPill] {
        crossAppMenuGroups(for: query, limit: limit).flatMap(\.pills)
    }

    // Top-ranked pill whose name starts with the current searchState.query — used for inline ghost completion
    var ghostPillCompletion: DockPill? {
        guard !aiMode.isActive else { return nil }
        guard lockedSubmenuParent == nil else { return nil }
        guard !searchState.query.isEmpty else { return nil }
        guard !(isL2ContextActive && l2.targetApp == nil && l2.appCompletion != nil) else {
            return nil
        }
        let lower = searchState.query.lowercased()

        // Frontmost-scoped sources: cached pills + frontmost menu cache.
        // Skip in pure global app search — not frontmost-scoped there.
        if !shouldUsePureGlobalAppSearch {
            if let match = cachedDockPills.first(where: {
                guard !$0.isSeparator,
                    $0.name.lowercased().hasPrefix(lower),
                    $0.name.count > searchState.query.count
                else { return false }

                // In global context: only allow pills scoped to explicit targetApp.
                // Never surface frontmost-scoped pills — global context is app-agnostic.
                if isGlobalContextActive {
                    guard let targetId = l2.targetApp?.bundleId, !targetId.isEmpty else {
                        return false
                    }
                    return $0.sourceBundleId == targetId
                }
                if isL2ContextActive {
                    let expectedBundleId = l2.targetApp?.bundleId ?? frontmost.bundleID
                    guard !expectedBundleId.isEmpty else { return false }
                    return $0.sourceBundleId == expectedBundleId
                }
                return true
            }) {
                return match
            }

            // Frontmost menu cache ghost only in L2/frontmost-scoped mode.
            // Global context is app-agnostic — suppress to prevent per-app inconsistency.
            if !frontmost.bundleID.isEmpty && !isGlobalContextActive {
                let frontItems = GlobalContextEngine.shared.cachedMenuItems(
                    bundleIdentifier: frontmost.bundleID, appName: "", query: lower, maxResults: 1
                )
                if let item = frontItems.first,
                    item.title.lowercased().hasPrefix(lower),
                    item.title.count > searchState.query.count
                {
                    let capturedBID = frontmost.bundleID
                    let capturedPath = item.path
                    let capturedSC = item.shortcutChar
                    let capturedMod = item.shortcutModifiers
                    let capturedPID =
                        AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
                    return DockPill(
                        id: "frontmost-ghost-\(capturedBID)-\(item.title)",
                        name: item.title,
                        icon: "menubar.rectangle",
                        accentColorName: nil,
                        badge: item.shortcutDisplay,
                        execute: { [self] in
                            self.executeDockMenuAction(
                                sourcePID: capturedPID, path: capturedPath,
                                shortcutChar: capturedSC, shortcutModifiers: capturedMod
                            )
                        }
                    )
                }
            }
        }

        // Cross-app: valid in global context (no selection) and pure L1.
        // Blocked in L2 frontmost-scoped mode (dock scoped to frontmost app).
        guard !isL2ContextActive || isGlobalContextActive else { return nil }
        return crossAppMenuPills(for: lower, limit: 1).first
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

    @ViewBuilder
    var selectionContextChip: some View {
        // Prefer live AX state (axContext) for immediate updates; fall back to currentContext
        let axFiles =
            isDismissedFinderSelection(axContext.selectedFilePaths)
            ? []
            : axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        let axText = axContext.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !axFiles.isEmpty {
            let label =
                axFiles.count == 1
                ? axFiles[0].lastPathComponent
                : "\(axFiles.count) files"
            let icon =
                axFiles.count == 1
                ? fileIcon(for: axFiles[0].pathExtension.lowercased())
                : "doc.on.doc.fill"
            selectionChipView(icon: icon, label: label, onDismiss: dismissContextAndReturnToDock)
        } else if !axText.isEmpty {
            let snippet = String(axText.prefix(40))
            selectionChipView(
                icon: "text.cursor",
                label: "\"\(snippet)\(axText.count > 40 ? "…" : "")\"",
                onDismiss: dismissContextAndReturnToDock)
        } else {
            switch currentContext {
            case .filesSelected(let urls) where !urls.isEmpty:
                let label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
                let icon =
                    urls.count == 1
                    ? fileIcon(for: urls[0].pathExtension.lowercased()) : "doc.on.doc.fill"
                selectionChipView(
                    icon: icon, label: label, onDismiss: dismissContextAndReturnToDock)
            case .textSelected(let text)
            where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                selectionChipView(
                    icon: "text.cursor",
                    label: "\"\(String(t.prefix(40)))\(t.count > 40 ? "…" : "")\"",
                    onDismiss: dismissContextAndReturnToDock)
            case .url(let urlStr) where !urlStr.isEmpty:
                selectionChipView(
                    icon: "link",
                    label: URL(string: urlStr)?.host ?? String(urlStr.prefix(40)),
                    onDismiss: dismissContextAndReturnToDock)
            default:
                EmptyView()
            }
        }
    }

    /// Clears the active global context and returns to the frontmost app's Context-Dock scope.
    func dismissContextAndReturnToDock() {
        let dismissedFinderPaths: [String] = {
            if !axContext.selectedFilePaths.isEmpty {
                return axContext.selectedFilePaths
            }
            if case .filesSelected(let urls) = currentContext {
                return urls.map(\.path)
            }
            return []
        }()
        if !dismissedFinderPaths.isEmpty {
            dismissedFinderSelectionSignature = finderSelectionSignature(dismissedFinderPaths)
        }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
            currentContext = .none
            globalContextActivation = nil
            axContext = .empty
        }
        scheduleDockPillRebuild(query: lastPillQuery, delayNanoseconds: 0)
        setFrontmostAppContextOnly(reason: "dismiss context chip")
    }

    /// Clears selected file/text payload but stays in Global Context.
    func dismissSelectionAndStayInGlobalContext() {
        let dismissedFinderPaths: [String] = {
            if !axContext.selectedFilePaths.isEmpty {
                return axContext.selectedFilePaths
            }
            if case .filesSelected(let urls) = currentContext {
                return urls.map(\.path)
            }
            return frozenSelectionFileURLs.map(\.path)
        }()
        if !dismissedFinderPaths.isEmpty {
            dismissedFinderSelectionSignature = finderSelectionSignature(dismissedFinderPaths)
        }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.82)) {
            currentContext = .none
            axContext = .empty
            globalContextActivation = GlobalContextActivation(autoActivated: false)
            showContextInDock = true
            showMediaLayer = false
            aiMode.isActive = false
            searchState.activeSmartQueryKey = nil
            searchState.contextApp = nil
            searchState.query = ""
            searchState.results = []
            searchState.selectedIndex = nil
            l2.targetApp = nil
            l2.focusedPillIndex = nil
            focusedAppPillIndex = nil
        }
        setCachedGlobalGroupedState(
            query: "",
            state: buildGlobalGroupedListNavigationState(for: ""),
            animated: false
        )
        scheduleGlobalAppMatchRebuild(query: "", delayNanoseconds: 0)
        scheduleGlobalGroupedListRebuild(query: "", delayNanoseconds: 0)
        scheduleDockPillRebuild(query: "", delayNanoseconds: 0, refreshContext: false)
    }

    @ViewBuilder
    func selectionChipView(icon: String, label: String, onDismiss: @escaping () -> Void)
        -> some View
    {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.green.opacity(0.85))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.75))
                .lineLimit(1)
                .frame(maxWidth: 130)
            Button(action: onDismiss) {
                Image(systemName: "minus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.green.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5))
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // Shared condition: whether any results panel should be visible.
    var hasResultsToShow: Bool {
        guard !showMediaLayer else { return false }
        return !searchState.results.isEmpty
            || (!searchState.query.isEmpty && !isL2ContextActive && !aiMode.isActive)
            || (aiMode.isActive
                && (!aiMode.messages.isEmpty || aiMode.isLoading || aiMode.streamingId != nil))
            || (showContextInDock && showFindTokenMenu && (lockedFindToken?.hasChildMenu == true))
            || shouldShowContextDockChatSheet
            || (shouldShowContextDockAppPanel
                && !(showContextInDock && l2.chatArmed && !l2.showChatPopover))
            || shouldShowFinderSearchResultsPanel(for: searchState.query)
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

    var shouldShowFrontmostContextChip: Bool {
        showContextInDock
            && !isGlobalContextActive
            && isSearchBarExpanded
            && settings.enableFrontmostDetection
            && !isCompactSmartScope
            && l2.targetApp == nil
            && globalInlineAppScope == nil
            && !showMediaLayer
            && !aiMode.isActive
            && !frontmost.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && frontmost.icon != nil
    }

    // Results card: its own glass container, visually detached from the dock bar.
    @ViewBuilder
    var resultsCard: some View {
        resultsContentView
            .frame(
                minHeight: 0,
                maxHeight: (aiMode.isActive || shouldShowContextDockChatSheet)
                    ? 500
                    : (l1ResultsReservedHeight > 0 ? l1ResultsReservedHeight : 450)
            )
            .frame(width: resultsPanelWidth, alignment: .leading)
            .background {
                GlassBackground(cornerRadius: 20, isDark: isEffectiveDark)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    var resultsCardAlignedToSearchInput: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: resultsPanelLeadingInset)
            resultsCard
            Spacer(minLength: 0)
        }
        .frame(width: calculatedWidth, alignment: .leading)
    }

    @ViewBuilder
    var floatingAppLogoButton: some View {
        if shouldShowFloatingAppLogo {
            ZStack(alignment: .topTrailing) {
                DLogoButton(
                    action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            showNotificationDock.toggle()
                            if showNotificationDock { notifDockTab = 0 }
                        }
                    },
                    isPresented: showNotificationDockBinding,
                    hasUnread: notificationManager.unreadCount > 0,
                    profileImage: nil
                ) {
                    NotificationDockView(
                        selectedTab: notifDockTabBinding,
                        profileImage: nil,
                        onClose: {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                showNotificationDock = false
                            }
                        },
                        onOpenSettings: { openSettings() }
                    )
                    .frame(width: notificationDockPopoverWidth)
                    .ifLet(resolvedColorScheme) { view, scheme in
                        view.environment(\.colorScheme, scheme)
                    }
                    .presentationBackground(.clear)
                }
                .help(
                    showNotificationDock
                        ? "Close Notifications"
                        : notificationManager.unreadCount > 0
                            ? "\(notificationManager.unreadCount) unread notification(s)"
                            : "Notifications")

                if notificationManager.unreadCount > 0 {
                    ZStack {
                        Circle().fill(Color.red).frame(width: 14, height: 14)
                        Text(
                            notificationManager.unreadCount > 9
                                ? "9+" : "\(notificationManager.unreadCount)"
                        )
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                    }
                    .offset(x: 4, y: -4)
                }
            }
        }
    }

    // Dock bar card: always wrapped in the unified glass card so the NSTextField
    // never changes view-identity (and never loses focus) when pills appear/disappear.
    func dockCard(inDockMode: Bool) -> some View {
        unifiedListDockCard(inDockMode: inDockMode)
    }

    var shortcutSheetCommands: [ShortcutMenuCommand] {
        ShortcutMenuCommand.filtered(shortcutSheetAllCommands, query: shortcutSheetSearchQuery)
    }

    var selectionSheetCommands: [SelectionSheetCommand] {
        guard let snapshot = shortcutSheetSelectionSnapshot else { return [] }
        return SelectionSheetCommand.filtered(selectionSheetAllCommands(for: snapshot), query: shortcutSheetSearchQuery)
    }

    func currentShortcutSheetCommandIDs() -> [String] {
        if shortcutSheetSelectionSnapshot != nil {
            guard shortcutSheetSelectionExpanded else { return [] }
            // Match the sheet's ranked, Recommended-first display order.
            let searching = !shortcutSheetSearchQuery
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return SelectionSheetCommand.ranked(selectionSheetCommands, searching: searching)
                .flatMap { $0.items }
                .map(\.id)
        }
        return shortcutSheetCommands.map(\.id)
    }

    func executeFocusedShortcutSheetCommand(id: String) -> Bool {
        if shortcutSheetSelectionSnapshot != nil {
            guard shortcutSheetSelectionExpanded else {
                shortcutSheetFocusedCommandID = nil
                return false
            }
            // "rec-" rows are Recommended copies of a real command — resolve back.
            let realID = id.hasPrefix("rec-") ? String(id.dropFirst("rec-".count)) : id
            guard let command = selectionSheetCommands.first(where: { $0.id == realID }) else { return false }
            executeSelectionSheetCommand(command)
            return true
        }
        guard let command = shortcutSheetCommands.first(where: { $0.id == id }) else { return false }
        executeShortcutSheetCommand(command)
        return true
    }

    var shortcutSheetAllCommands: [ShortcutMenuCommand] {
        ShortcutMenuCommand.commands(
            from: liveMenuItems,
            query: "",
            fallbackSourcePID: shortcutSheetSourcePID
        )
    }

    func selectionSheetAllCommands(for snapshot: SelectionContextSnapshot) -> [SelectionSheetCommand] {
        // Writing Tools powered by the user's selected AI provider (On-Device
        // Foundation Models when chosen). One entry per task, each running
        // through the same in-sheet chat as a typed question.
        let providerName = settings.selectedAIProvider.shortName
        let writingTools: [(id: String, title: String, icon: String, prompt: String, score: Double)] = [
            ("ai-what-is-this", "What is this?", "sparkles",
                "What is this?", 10_000),
            ("ai-summarize", "Summarize", "text.alignleft",
                "Summarize this selection concisely.", 9_950),
            ("ai-key-points", "Key Points", "list.bullet",
                "Extract the key points of this selection as a short bulleted list.", 9_900),
            ("ai-rewrite", "Rewrite", "pencil.line",
                "Rewrite this selection to be clearer and well-structured. Return only the rewritten text.",
                9_850),
            ("ai-simplify", "Simplify", "wand.and.stars",
                "Rewrite this selection in simpler, plain language. Return only the rewritten text.",
                9_800),
            ("ai-make-professional", "Make Professional", "briefcase",
                "Rewrite this selection in a professional tone. Return only the rewritten text.",
                9_750),
            ("ai-translate", "Translate", "character.bubble",
                "Translate this selection to English. If it is already English, translate to the user's likely preferred language. Return only the translation.",
                9_700),
            ("ai-explain", "Explain", "questionmark.bubble",
                "Explain this selection clearly.", 9_650),
        ]
        var commands: [SelectionSheetCommand] = writingTools.map { tool in
            SelectionSheetCommand(
                id: tool.id,
                title: tool.title,
                subtitle: providerName,
                section: "Writing Tools",
                systemImage: tool.icon,
                shortcutDisplay: nil,
                score: tool.score,
                action: { askSelectionSheetAI(query: tool.prompt, snapshot: snapshot) }
            )
        }

        // Built-in file actions — always available for a file selection,
        // independent of the source app's cached menu (which often omits dynamic
        // items like "Open With"). These guarantee the sheet has real,
        // filterable actions instead of falling straight through to AI.
        commands.append(contentsOf: selectionSheetFileActions(for: snapshot))

        let matches = LayeredExtensionManager.shared.discoverExtensions(
            for: "",
            selectedFiles: snapshot.selectedFiles,
            selectedText: snapshot.selectedText,
            frontmostApp: snapshot.sourceAppName,
            layer: .l2_context
        )
        for match in matches.prefix(8) {
            let ext = match.ilExtension
            commands.append(SelectionSheetCommand(
                id: "ext-\(ext.id)",
                title: ext.name,
                subtitle: ext.description,
                section: "Extensions",
                systemImage: ext.icon,
                shortcutDisplay: nil,
                score: 8_000 + match.relevanceScore,
                action: {
                    Task { await executeL2Extension(ext, context: snapshot.userContext) }
                }
            ))
        }

        // Pass empty query so the full File-menu set is included; the view's
        // live filter narrows it per keystroke.
        let menuCommands = ShortcutMenuCommand.commands(
            from: liveMenuItems,
            query: "",
            fallbackSourcePID: shortcutSheetSourcePID
        ).filter { isSelectionSheetFileMenuCommand($0) }
        for command in menuCommands.prefix(12) {
            commands.append(SelectionSheetCommand(
                id: "menu-\(command.id)",
                title: command.title,
                subtitle: command.parentPath.isEmpty ? snapshot.sourceAppName : command.parentPath,
                section: "File Menu",
                systemImage: "menubar.rectangle",
                shortcutDisplay: command.shortcutDisplay,
                score: 1_000 + command.score,
                action: { executeShortcutSheetCommand(command) }
            ))
        }

        return commands
    }

    /// Universal file actions for the selection sheet — work for any file in any
    /// app, no cached menu required. Open With expands to real candidate apps.
    func selectionSheetFileActions(for snapshot: SelectionContextSnapshot) -> [SelectionSheetCommand] {
        let urls = snapshot.selectedFiles
        guard !urls.isEmpty else { return [] }
        let first = urls[0]
        var commands: [SelectionSheetCommand] = []

        func add(_ id: String, _ title: String, _ icon: String, _ score: Double,
                 _ action: @escaping () -> Void) {
            commands.append(SelectionSheetCommand(
                id: "file-\(id)", title: title, subtitle: "File",
                section: "Actions", systemImage: icon, shortcutDisplay: nil,
                score: score, action: action))
        }

        add("open", "Open", "arrow.up.right.square", 7_000) {
            for url in urls { NSWorkspace.shared.open(url) }
        }
        add("quicklook", "Quick Look", "eye", 6_950) {
            _ = self.showQuickLookURL(first, toggleIfSame: false)
        }
        add("reveal", "Reveal in Finder", "folder", 6_900) {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        add("copypath", "Copy Path", "doc.on.clipboard", 6_850) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                urls.map(\.path).joined(separator: "\n"), forType: .string)
        }
        add("share", "Share…", "square.and.arrow.up", 6_800) {
            self.presentSharingPicker(items: urls)
        }
        add("trash", "Move to Bin", "trash", 6_700) {
            for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            AppToast.show("Moved to Bin", icon: "trash", tint: .red.opacity(0.9))
        }

        // Open With — one row per app that can open the file, each with the
        // app's real icon (LaunchServices order: default app first).
        let openWithApps = DefaultAppResolver.shared.getAllApps(for: first).prefix(10)
        for (index, app) in openWithApps.enumerated() {
            let appURL = app.path
            let appIcon = app.icon ?? NSWorkspace.shared.icon(forFile: appURL.path)
            commands.append(SelectionSheetCommand(
                id: "file-openwith-\(app.bundleIdentifier)",
                title: "Open With \(app.displayName)",
                subtitle: "Open With",
                section: "Open With",
                systemImage: "app",
                iconImage: appIcon,
                shortcutDisplay: nil,
                score: 6_600 - Double(index),
                action: {
                    let config = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
                }
            ))
        }
        return commands
    }

    func isSelectionSheetFileMenuCommand(_ command: ShortcutMenuCommand) -> Bool {
        let section = command.section.trimmingCharacters(in: .whitespacesAndNewlines)
        if section.localizedCaseInsensitiveCompare("File") == .orderedSame { return true }
        guard let root = command.item.path.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return root.localizedCaseInsensitiveCompare("File") == .orderedSame
    }

    func executeShortcutSheetCommand(_ command: ShortcutMenuCommand) {
        closeShortcutSheet()
        let item = command.item
        let pid =
            item.sourcePID != 0
            ? item.sourcePID
            : shortcutSheetSourcePID
        guard pid != 0 else { return }
        executeDockMenuAction(
            sourcePID: pid,
            path: item.path,
            shortcutChar: item.shortcutChar,
            shortcutModifiers: item.shortcutModifiers
        )
    }

    func executeSelectionSheetCommand(_ command: SelectionSheetCommand) {
        closeShortcutSheet()
        command.action()
    }

    func addSelectionSheetContextToDock(_ snapshot: SelectionContextSnapshot) {
        closeShortcutSheet(resetSearch: false)
        activateSelectionSheetContext(snapshot, startAI: false, prompt: "")
    }

    func expandSelectionCommandSheet(_ snapshot: SelectionContextSnapshot) {
        shortcutSheetSelectionSnapshot = snapshot
        shortcutSheetSelectionExpanded = true
        shortcutSheetFocusedCommandID = nil
    }

    func openSelectionAI(snapshot: SelectionContextSnapshot, prompt: String) {
        closeShortcutSheet(resetSearch: false)
        activateSelectionSheetContext(snapshot, startAI: true, prompt: prompt)
        DispatchQueue.main.async { submitAIQuery() }
    }

    func activateSelectionSheetContext(
        _ snapshot: SelectionContextSnapshot,
        startAI: Bool,
        prompt: String
    ) {
        currentContext = snapshot.userContext
        globalContextActivation = GlobalContextActivation(
            autoActivated: false,
            frozenText: snapshot.title,
            frozenIcon: snapshot.iconName,
            sourceBundleId: snapshot.sourceBundleID,
            frozenFilePaths: snapshot.selectedFiles.map(\.path)
        )
        showContextInDock = true
        aiMode.isActive = startAI
        searchState.query = prompt
        searchState.results = []
        searchState.selectedIndex = nil
        isSearchFieldFocused = true
        AppDelegate.shared?.showLauncher()
    }

    @ViewBuilder
    func unifiedListDockCard(inDockMode: Bool) -> some View {
        VStack(spacing: 0) {
            if usesVerticalListDockLayout && settings.effectiveDockAtBottom {
                l2UnifiedDockRow
                    .frame(width: visibleDockWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 8)

                Rectangle()
                    .fill(Color.white.opacity(isEffectiveDark ? 0.08 : 0.10))
                    .frame(height: 1)
                    .padding(.horizontal, 22)

                dockBaseView(inDockMode: inDockMode)
                    .frame(width: visibleDockWidth, alignment: .leading)
            } else {
                dockBaseView(inDockMode: inDockMode)
                    .frame(width: visibleDockWidth, alignment: .leading)

                if usesVerticalListDockLayout {
                    Rectangle()
                        .fill(Color.white.opacity(isEffectiveDark ? 0.08 : 0.10))
                        .frame(height: 1)
                        .padding(.horizontal, 22)

                    l2UnifiedDockRow
                        .frame(width: visibleDockWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(
            width: visibleDockWidth,
            alignment: settings.effectiveDockAtBottom ? .bottom : .top
        )
        .background {
            if usesVerticalListDockLayout {
                GlassBackground(cornerRadius: 28, isDark: isEffectiveDark)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: usesVerticalListDockLayout ? 28 : 0,
                style: .continuous
            )
        )
        .overlay {
            if usesVerticalListDockLayout {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isEffectiveDark ? 0.16 : 0.42),
                                .white.opacity(isEffectiveDark ? 0.035 : 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        }
        .shadow(
            color: usesVerticalListDockLayout ? .black.opacity(0.18) : .clear, radius: 24, x: 0,
            y: 12)
    }
    var panelGapBelowSearchBar: CGFloat {
        isCompactSmartScope
            ? 2
            : (usesVerticalListDockLayout && !searchState.results.isEmpty ? 4 : 6)
    }

    // MARK: - Selected Result Preview

    /// Returns the action label shown next to a selected result (like Spotlight's "— Open")
    func selectedResultAction(_ result: SearchResult) -> String {
        if result.subtitle.hasPrefix("syscmd://") {
            return "Run"
        }
        if result.subtitle.hasPrefix("cli://") {
            return "Scope"
        }
        switch result.type {
        case .application: return "Open"
        case .shortcut: return "Run"
        case .file, .document: return "Open"
        case .folder: return "Browse"
        case .contact: return "View"
        case .calendarEvent: return "View Event"
        case .reminder: return "View"
        case .note: return "Open"
        case .mail: return "Open"
        case .photo: return "View"
        case .message: return "Open"
        case .extensionCommand: return "Run"
        case .webSearch: return "Search"
        case .cliTool: return "Attach CLI"
        }
    }

    // MARK: - Spotlight-style App Context (Tab/→ on app result)

    /// Activates context panel for ANY result type (Spotlight-style Tab/→).
    /// Always opens the 2-column AI panel — chat + quick actions.
    func openCLIToolPanel(for package: TerminalPackage) {
        attachCLIToolToCurrentDock(command: package.command, package: package)
    }

    func activateSearchContext(for result: SearchResult) {
        let pseudoScopeId = result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if pseudoScopeId.hasPrefix("cli://") || pseudoScopeId.hasPrefix("syscmd://") {
            if activateInlineDockAppScope(
                bundleIdentifier: pseudoScopeId,
                appName: result.title,
                queryOverride: "",
                preserveGlobalContext: isGlobalContextActive
            ) {
                isSearchFieldFocused = true
            }
            return
        }

        if result.type == .cliTool {
            let package = terminalPackageManager.packages.first(where: {
                $0.command.caseInsensitiveCompare(result.title) == .orderedSame
                    || $0.name.caseInsensitiveCompare(result.title) == .orderedSame
                    || ($0.installedPath?.caseInsensitiveCompare(result.subtitle) == .orderedSame)
            })
            attachCLIToolToCurrentDock(
                command: package?.command ?? result.title,
                package: package
            )
            return
        }

        let appPath = result.type == .application ? result.subtitle : ""

        if result.type == .application {
            let resolvedBundleId =
                (!appPath.isEmpty ? Bundle(path: appPath)?.bundleIdentifier : nil)
                ?? NSWorkspace.shared.runningApplications.first(where: {
                    !$0.isTerminated
                        && $0.localizedName?.caseInsensitiveCompare(result.title) == .orderedSame
                })?.bundleIdentifier

            if let resolvedBundleId,
                activateInlineDockAppScope(
                    bundleIdentifier: resolvedBundleId,
                    appName: result.title,
                    queryOverride: ""
                )
            {
                isSearchFieldFocused = true
                return
            }
        }

        // Find matching customAppEntries key for apps (gives AI access to assigned CLI tools)
        let customEntry =
            result.type == .application
            ? settings.customAppEntries.first(where: {
                $0.label.lowercased() == result.title.lowercased() || $0.appPath == appPath
                    || $0.key == result.title.lowercased().replacingOccurrences(of: " ", with: "_")
            }) : nil

        // Built-in system panel keys for standard apps
        let builtInKey: String? = {
            guard result.type == .application else { return nil }
            let name = result.title.lowercased()
            if name == "reminders" { return "reminders" }
            if name == "calendar" { return "calendar" }
            if name == "notes" { return "notes" }
            if name == "mail" { return "mail" }
            if name == "photos" { return "photos" }
            if name == "messages" { return "messages" }
            if name == "contacts" { return "contacts" }
            if name == "amphetamine" { return "amphetamine" }
            if name == "homebrew" { return "homebrew" }
            if name == "system settings" || name == "system preferences" { return "systemsettings" }
            if name == "safari" { return "safari" }
            if name == "finder" { return "finder" }
            if name == "xcode" { return "xcode" }
            // Fallback: look up via bundle ID and name using AppSettings mapping
            if let appPath = result.filePath
                ?? (result.subtitle.hasSuffix(".app") ? result.subtitle : nil),
                let bundle = Bundle(path: appPath), let bid = bundle.bundleIdentifier
            {
                return AppSettings.shared.appKey(forBundleID: bid, appName: result.title)
            }
            return nil
        }()
        let contextKey = customEntry?.key ?? builtInKey

        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            searchState.contextApp = SearchContextApp(
                name: result.title,
                icon: result.icon,
                key: contextKey,
                appPath: appPath,
                resultType: result.type,
                filePath: result.filePath,
                subtitle: result.subtitle,
                contactEmail: result.contactData?.primaryEmail,
                contactPhone: result.contactData?.primaryPhone
            )
            searchState.query = ""
            searchState.results = []
            searchState.selectedIndex = nil
            isSearchBarExpanded = true
            // Load persisted chat for this panel (panelKey computed just below)
            let panelKeyForLoad =
                contextKey
                ?? result.title.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .components(
                    separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
                        .inverted
                )
                .joined()
            remPanelChatMessages = AppPanelChatStore.shared.load(for: panelKeyForLoad)

            // Set searchState.activeSmartQueryKey — used by handleRemPanelQuery and panel header
            let panelKey =
                contextKey
                ?? result.title.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .components(
                    separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
                        .inverted
                )
                .joined()
            searchState.activeSmartQueryKey = panelKey
            searchState.isInSmartMode = true
            searchState.appPanelAllItems = []
            // Only load data for built-in system types
            if let key = contextKey {
                reloadAppPanelData(for: key)
            }
            // Live panel only shows for meaningful results (terminal, music, file preview, or AI-returned lists)
            // Don't auto-open for plain context — file name/path already visible in chat header
            let isNonApp = result.type != .application
            if isNonApp {
                // Keep panel hidden until AI returns results
                livePanelVisible = false
            } else {
                // For apps, hide the live panel (they just use the AI chat)
                livePanelVisible = false
            }
        }
        isSearchFieldFocused = true
    }

    @discardableResult
    func activateSelectedApplicationScopeFromRightArrowIfPossible() -> Bool {
        guard searchInputCursorIsAtEnd(),
            let index = searchState.selectedIndex,
            searchState.results.indices.contains(index)
        else { return false }

        let result = searchState.results[index]
        if isGlobalContextActive,
            result.type == .extensionCommand,
            result.subtitle.hasPrefix("syscmd://")
        {
            let activated = activateGlobalInlineScope(result: result, bundleID: result.subtitle)
            if activated {
                focusedAppPillIndex = nil
                l2.focusedPillIndex = nil
                reclaimSearchInputFocus()
            }
            return activated
        }
        guard !isGlobalContextActive,
            result.type == .application || result.type == .cliTool
        else { return false }
        activateSearchContext(for: result)
        return true
    }

    /// Exits the pinned L2 dock scope (l2.targetApp) without clearing other state.
    func exitL2DockScope() {
        let retainedQuery = searchState.query
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            l2.targetApp = nil
            isHoveringL2ScopeChip = false
            focusedAppPillIndex = nil
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
        }
        scheduleDockPillRebuild(query: retainedQuery, delayNanoseconds: 0, refreshContext: false)
        if isGlobalContextActive {
            scheduleGlobalAppMatchRebuild(query: retainedQuery, delayNanoseconds: 0)
            scheduleGlobalGroupedListRebuild(query: retainedQuery, delayNanoseconds: 0)
        }
        syncL2DockSession(force: true)
    }

    /// Clears the app context and returns to normal search.
    func clearSearchContext(preserveQuery: Bool = false) {
        if let key = searchState.activeSmartQueryKey {
            AppPanelChatStore.shared.save(remPanelChatMessages, for: key)
        }
        let retainedQuery = searchState.query
        l2.terminalDismissed = false
        pendingAIMenuProposal = nil
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            searchState.contextApp = nil
            searchState.activeSmartQueryKey = nil
            l2.targetApp = nil
            l2.showChatPopover = false
            l2.chatArmed = false
            l2.chatDraftAppName = ""
            l2.chatDraftBundleId = ""
            searchState.isInSmartMode = false
            searchState.appPanelAllItems = []
            remPanelChatMessages = []
            clearPinnedResults()
            searchState.results = []
            searchState.selectedIndex = nil
            selectedClipboardEntryIDs.removeAll()
            focusedClipboardEntryIndex = nil
            livePanelVisible = false
            if !preserveQuery {
                searchState.query = ""
            }
        }
        if preserveQuery {
            searchState.query = retainedQuery
        }
        syncL2DockSession(force: true)
    }

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

    @ViewBuilder
    var resultsSection: some View {
        // App panel: full-screen split view — hides normal search results entirely
        if searchState.activeSmartQueryKey != nil && !isCompactSmartScope {
            appPanelView
        } else if !searchState.results.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {

                        // In dock mode, reverse order so first result is at bottom (closest to dock)
                        let sectionsToRender =
                            settings.effectiveDockAtBottom
                            ? Array(searchState.grouped.sections.reversed())
                            : searchState.grouped.sections

                        // O(1) index lookup — built once per render, used per row
                        let resultIndexMap = Dictionary(
                            uniqueKeysWithValues: searchState.results.enumerated().map {
                                ($1.id, $0)
                            }
                        )

                        // Render grouped sections with headers
                        ForEach(Array(sectionsToRender.enumerated()), id: \.offset) {
                            sectionIndex, section in
                            let (sectionName, sectionResults) = section

                            // In dock mode, also reverse items within each section
                            let itemsToRender =
                                settings.effectiveDockAtBottom
                                ? Array(sectionResults.reversed()) : sectionResults

                            // Section header
                            if searchState.grouped.sections.count > 1 || isCompactSmartScope {
                                HStack {
                                    Text(sectionName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .tracking(0.5)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, settings.effectiveDockAtBottom ? 6 : 12)
                                .padding(.bottom, 4)
                            }

                            // Section items — ForEach by id, no Array(enumerated()) wrapper
                            ForEach(itemsToRender, id: \.id) { result in
                                let globalIndex = resultIndexMap[result.id] ?? 0

                                resultRowView(for: result, at: globalIndex)
                                    .id(result.id)

                                if result.id != itemsToRender.last?.id {
                                    Divider()
                                        .padding(.leading, 60)
                                }
                            }

                            // Divider between sections (but not after last section)
                            if sectionIndex < sectionsToRender.count - 1 {
                                Divider()
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding(.top, settings.effectiveDockAtBottom ? 0 : 8)
                    .padding(.bottom, settings.effectiveDockAtBottom ? 4 : 8)
                }
                .scrollContentBackground(.hidden)
                .background(.clear)
                .frame(maxHeight: 400)
                .onChange(of: searchState.revision) { _, _ in
                    // When docked at bottom, keep the best match in view even if selection didn't change.
                    guard settings.effectiveDockAtBottom else { return }
                    guard let index = searchState.selectedIndex,
                        index >= 0,
                        index < searchState.results.count
                    else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(searchState.results[index].id, anchor: .bottom)
                    }
                }
                .onChange(of: searchState.selectedIndex) { _, newIndex in
                    // Auto-scroll to selected result ONLY when navigating with arrow keys
                    if isKeyboardNavigation || shouldAutoScroll,
                        let index = newIndex,
                        index >= 0 && index < searchState.results.count
                    {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let anchor: UnitPoint =
                                settings.effectiveDockAtBottom ? .bottom : .center
                            proxy.scrollTo(searchState.results[index].id, anchor: anchor)
                        }
                    }
                    if shouldAutoScroll { shouldAutoScroll = false }
                    // Update context extensions for the newly selected result
                    // so context-based dock pills reflect file type / app context immediately
                    updateL2ContextExtensions()
                    refreshQuickLookPreviewForCurrentFocusIfVisible()
                }
            }
        } else if searchState.isLoadingApps {
            loadingView
        }
    }

    // Helper to find global index for a result (for selection tracking)
    func getGlobalIndex(for result: SearchResult) -> Int {
        searchState.results.firstIndex(where: { $0.id == result.id }) ?? 0
    }

    func resultRowView(for result: SearchResult, at index: Int) -> some View {
        ResultRow(
            result: result,
            isSelected: searchState.selectedIndex == index,
            isPinned: result.type == .application && settings.isPinned(path: result.subtitle),
            usesDockCapsuleSelection: showContextInDock || isGlobalContextActive,
            selectionNamespace: compactScopeFocusNamespace,
            selectionEffectID: dockResultFocusEffectID
        )
        .equatable()
        .contentShape(Rectangle())
        .modifier(OptionalDragProviderModifier(provider: result.dragProvider))
        .onTapGesture {
            executeResult(result)
        }
        .onHover { hovering in
            guard acceptsMouseDrivenDockInteraction else { return }
            if hovering {
                if isSearchFieldFocused {
                    return
                }
                if isKeyboardNavigation {
                    // Switch back to mouse mode but don't steal selection immediately
                    isKeyboardNavigation = false
                    return
                }
                searchState.selectedIndex = index
            }
        }
        .contextMenu {
            resultContextMenu(for: result)
        }
    }

    @ViewBuilder
    func resultContextMenu(for result: SearchResult) -> some View {
        Group {
            if result.type == .contact {
                Button {
                    result.action()
                } label: {
                    Label("Open in Contacts", systemImage: "person.crop.circle")
                }
                Button {
                    let email = result.subtitle
                    guard !email.isEmpty else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(email, forType: .string)
                } label: {
                    Label("Copy Email", systemImage: "doc.on.doc")
                }
                Button {
                    let email = result.subtitle
                    guard !email.isEmpty, let url = URL(string: "mailto:\(email)") else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Send Email", systemImage: "envelope")
                }
                Button {
                    let email = result.subtitle
                    guard !email.isEmpty, let url = URL(string: "imessage:\(email)") else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Send Message", systemImage: "message")
                }
            } else if result.type == .application {
                if settings.isPinned(path: result.subtitle) {
                    Button {
                        if let pinnedApp = settings.pinnedApps.first(where: {
                            $0.path == result.subtitle
                        }) {
                            settings.unpinApp(pinnedApp)
                        }
                    } label: {
                        Label("Unpin from Launcher", systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        settings.pinApp(name: result.title, path: result.subtitle)
                    } label: {
                        Label("Pin to Launcher", systemImage: "pin")
                    }
                }
            } else if result.type == .shortcut {
                let shortcutPath = result.subtitle.isEmpty ? result.title : result.subtitle
                if settings.pinnedApps.contains(where: { $0.path == shortcutPath }) {
                    Button {
                        if let pinnedItem = settings.pinnedApps.first(where: {
                            $0.path == shortcutPath
                        }) {
                            settings.unpinApp(pinnedItem)
                        }
                    } label: {
                        Label("Unpin from Launcher", systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        settings.pinItem(name: result.title, path: shortcutPath, type: .shortcut)
                    } label: {
                        Label("Pin to Launcher", systemImage: "pin")
                    }
                }
            } else if let filePath = result.filePath,
                result.type == .file || result.type == .folder || result.type == .document
            {
                if settings.pinnedApps.contains(where: { $0.path == filePath }) {
                    Button {
                        if let pinnedItem = settings.pinnedApps.first(where: { $0.path == filePath }
                        ) {
                            settings.unpinApp(pinnedItem)
                        }
                    } label: {
                        Label("Unpin from Launcher", systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        let itemType: PinnedApp.PinnedItemType =
                            result.type == .folder ? .folder : .file
                        settings.pinItem(name: result.title, path: filePath, type: itemType)
                    } label: {
                        Label("Pin to Launcher", systemImage: "pin")
                    }
                }
                Divider()
                Button {
                    NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button {
                    if let url = URL(string: "file://\(filePath)") {
                        NSWorkspace.shared.open(
                            [url],
                            withApplicationAt: URL(
                                fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                            configuration: NSWorkspace.OpenConfiguration())
                    }
                } label: {
                    Label("Get Info", systemImage: "info.circle")
                }
                Divider()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(filePath, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    var loadingView: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading applications and shortcuts...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    var backgroundView: some View {
        Group {
            // Dark glassy blur is handled by NSVisualEffectView at window level
            // SwiftUI background should be clear to let the blur show through

            Color.clear
        }
    }

    // Determine if background should be shown
    var shouldShowBackground: Bool {
        // Results and chat now show inside expanding dock, so no separate background needed
        return false
    }

    func activateSearchField() {
        // Clear any existing text and results first
        searchState.query = ""
        searchState.results = []
        searchState.selectedIndex = nil

        // Immediately show and focus (no delay for better performance)
        isSearchFieldFocused = true
        isVisible = true

        // Expand search bar on launch
        expandSearchBar()

        // Make window key immediately
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            window.makeKey()
        }
    }

}
