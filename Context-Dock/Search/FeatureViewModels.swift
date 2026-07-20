import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

struct DockInlineFeedback: Identifiable, Equatable {
    enum Phase: String {
        case progress
        case success
        case failure
    }

    let id: String
    var title: String
    var icon: String
    var phase: Phase
    var subject: String?
    var bundleID: String?
}

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var query = ""
    @Published var indexedFileResults: [SearchResult] = []
    @Published var lastQuery = ""
    @Published var isKeyboardNavigation = false
    @Published var shouldAutoScroll = false
    @Published var removedToolBannerName: String?
    @Published var isVisible = false
    @Published var allApplications: [SearchResult] = []
    @Published var allShortcuts: [SearchResult] = []
    @Published var allContacts: [SearchResult] = []
    @Published var systemDataResults: [SearchResult] = []
    @Published var runningRegularApps: [NSRunningApplication] = []
    @Published var l1ResultsReservedHeight: CGFloat = 0
    /// Measured intrinsic height of the active chat conversation (general chat / context-dock chat),
    /// so the sheet + window size to the REAL content (approval cards, multi-line replies) instead
    /// of a per-message estimate that clipped tall messages.
    @Published var measuredChatContentHeight: CGFloat = 0
    /// When focus is reclaimed with a deliberate select-all (Up-arrow editing), suppress
    /// the move-caret-to-end that otherwise prevents the default select-all-on-focus.
    var pendingSelectAllOnFocus = false
    /// Measured intrinsic height of the global/scoped result list content. Drives the
    /// sheet height so it hugs the actually-rendered rows (no half-empty box, no
    /// count/state mismatch).
    @Published var measuredGlobalListContentHeight: CGFloat = 0
    @Published var showFolderPreview = false
    @Published var folderPreviewPath: String?
    @Published var folderPreviewSelectedFile: String?
    @Published var showContactPreview = false
    @Published var contactPreviewData: SearchResult?
    /// Bumped on field-editor selection changes so the inline-scope overlay
    /// re-renders its caret at the real cursor position.
    @Published var searchInputCaretTick = 0
    @Published var isSearchBarExpanded = true
    @Published var isHoveringSearchIcon = false
    @Published var isHoveringInputField = false
    @Published var suppressMouseDrivenInteractionUntil: Date = .distantPast
    @Published var suppressMouseDrivenInteractionOrigin: NSPoint?
    @Published var suppressCommandScopeToggleUntil: Date = .distantPast
    @Published var suppressHoverExpand = false
    @Published var suppressOpenResize = false
    @Published var lastKnownBrowserURL = ""
    @Published var accumulatedSwipeDeltaY: CGFloat = 0
    @Published var accumulatedSwipeDeltaX: CGFloat = 0
    @Published var isHoveringDockArea = false
    @Published var hoveredDockAppKey: String?
    @Published var hoveredAppPillIndex: Int?
    @Published var isSharingSheetActive = false
    @Published var showNotificationPanel = false
    @Published var showNotificationDock = false
    @Published var notificationDockTab = 0
    @Published var inlineDockFeedback: DockInlineFeedback?
    @Published var appQuitFeedbackPhases: [String: DockInlineFeedback.Phase] = [:]

    var debounceTask: Task<Void, Never>?
    var browserWarmupTask: Task<Void, Never>?
    var windowResizeTask: Task<Void, Never>?
    var quickLookDataSource: QuickLookDataSource?
    var quickLookEventMonitor: Any?
    var cmdHoldTask: Task<Void, Never>?
    var cmdHoldMonitor: Any?
    var cmdHoldGlobalMonitor: Any?
    var cmdTapArmed = false
    var cmdChordUsed = false
    var cmdHoldTriggered = false
    var collapseTimer: Task<Void, Never>?
    var swipeGestureMonitor: Any?
    var appSwitchObserver: NSObjectProtocol?
    var appLaunchObserver: NSObjectProtocol?
    var appTerminateObserver: NSObjectProtocol?
}

@MainActor
final class GlobalContextViewModel: ObservableObject {
    @Published var state = GlobalContextState()
    @Published var focusedAppPillIndex: Int?
    @Published var cachedAppQuery = ""
    @Published var cachedAppMatches: [SearchResult] = []
    var pendingAppQuery: String?
    var cachedGroupedQuery = ""
    @Published var cachedGroupedState: GlobalGroupedListNavigationState?
    var cachedGroupedFingerprint = ""
    var pendingGroupedQuery: String?
    @Published var inlineAppScope: LauncherView.GlobalInlineAppScope?
    @Published var additionalInlineAppScopes: [LauncherView.GlobalInlineAppScope] = []
    @Published var pendingLaunchContextSwitch: (bundleId: String, appName: String)?
    @Published var suppressInlineAppScopeDetection = false
    @Published var dismissedInlineAppScopes: [String: String] = [:]
    @Published var hoveredInlineScopeBundleId: String?
    @Published var isHoveringL2ScopeChip = false
    @Published var isHoveringFrontmostContextChip = false
    @Published var clipboardText = ""
    @Published var showClipboardPill = false
    @Published var lastCheckedPasteboardCount = -1
    @Published var suppressClipboardImportUntilChangeCount: Int?
    @Published var clipboardHistory: [LauncherView.ClipboardEntry] = []
    @Published var showClipboardHistory = false
    @Published var clipboardHistoryExpanded = false
    @Published var clipboardDropTargetVisible = false
    @Published var clipboardDropTargeted = false
    @Published var clipboardScopeShowsGrid = false
    @Published var focusedClipboardEntryIndex: Int?
    @Published var selectedClipboardEntryIDs: Set<UUID> = []
    @Published var dismissedFinderSelectionSignature: String?
    @Published var suppressedAutomaticFinderSelectionSignature: String?
    /// Live text selection observed WHILE the dock is open. Drives ONLY the trailing
    /// selection button — never axContext / hasSelectionScopeSurface, which would
    /// silently flip the dock out of pure global app search mid-typing.
    @Published var liveSelectionPreviewText: String?
    @Published var suppressAutomaticGlobalContextUntil: Date = .distantPast
    @Published var typingSnapshot = GlobalContextTypingSnapshot()
    @Published var preparedResults: GlobalContextPreparedResults?
    @Published var isResolvingFastMatches = false

    var appMatchTask: Task<Void, Never>?
    var appMatchGeneration = 0
    var groupedTask: Task<Void, Never>?
    var groupedGeneration = 0
    var prepareTask: Task<Void, Never>?
    var fastMatchTask: Task<Void, Never>?
    var expandWhenFastMatchesResolve = false
    var autoExpandTask: Task<Void, Never>?
    var sustainedTypingCollapseTask: Task<Void, Never>?
    var lastTypingChangeAt: Date = .distantPast
    var clipboardExpiryTimer: Timer?
    var clipboardIndicatorHideTask: Task<Void, Never>?
}

@MainActor
enum ContextDockPillScheduleStart {
    case skipped
    case duplicate(previewPills: [DockPill])
    case questionStyle
    case scheduled(generation: Int, previewPills: [DockPill])
}

@MainActor
final class ContextDockViewModel: ObservableObject {
    @Published var state = ContextDockState()
    @Published var cachedPills: [DockPill] = []
    @Published var visiblePills: [DockPill] = []
    @Published var pendingAIProposal: AIMenuProposal?
    @Published var pendingPillQuery: String?
    @Published var pendingPreviewPills: [DockPill] = []
    @Published var lastPillQuery = ""
    @Published var menuDebugText = "menu debug unavailable"
    @Published var contextMenuPills: [AXMenuItem] = []
    @Published var previousEnabledIDs: Set<UUID> = []
    @Published var lastFinderSelectionRefresh: Date = .distantPast
    @Published var liveMenuItems: [AXMenuItem] = []
    @Published var lastLiveMenuStructureRefresh: Date = .distantPast
    @Published var lastLiveMenuSignature = ""
    @Published var crossAppMenuItems: [AXMenuItem] = []
    @Published var lockedSubmenuParent: AXMenuItem?
    /// When set, the dock shows ONLY the live native share destinations (AirDrop,
    /// Mail, Notes, …) for the current content — DoraX's own inline Share Sheet.
    @Published var inlineShareActive = false
    @Published var lockedFindToken: LauncherView.AppFindToken?
    @Published var showFindTokenMenu = false
    var crossAppMenuTargetPID: pid_t = 0
    var crossAppMenuNeedsLiveLoad = false
    @Published var warmingMenuBundleIds: Set<String> = []
    @Published var hoveredDockPillIndex: Int?
    @Published var isHoveringPillRow = false
    @Published var listViewHoveredIndex: Int?
    @Published var pillScrollAccumulator: CGFloat = 0
    @Published var currentContext: UserContext = .none
    @Published var axContext: AXContext = .empty
    @Published var adapterContextData: [String: String] = [:]
    @Published var selectedFiles: Set<String> = []
    @Published var shortcutMetadataCache: [String: ShortcutMetadata] = [:]
    @Published var isContextExpanded = false
    @Published var showSafariTabPicker = false
    @Published var safariTabPickerTabs: [SafariTab] = []
    @Published var safariTabPickerLoading = false

    var pillBuildTask: Task<Void, Never>?
    var pillBuildGeneration = 0
    var menuLoadTask: Task<Void, Never>?
    var liveMenuRefreshTask: Task<Void, Never>?
    var menuAvailabilityRefreshTask: Task<Void, Never>?
    var menuAvailabilityRefreshGeneration = 0
    var crossAppMenuTask: Task<Void, Never>?
    var finderDesktopSearchTask: Task<Void, Never>?
    var finderDesktopSearchGeneration = 0
    var finderDesktopFastMatchTask: Task<Void, Never>?
    var finderDesktopFastMatchGeneration = 0
    var finderDesktopSearchRecords: [FinderDesktopSearchRecord] = []
    var finderDesktopPillsByPath: [String: DockPill] = [:]
    var axContextRefreshTimer: Timer?
    var cachedPreviewPillQuery = ""
    var cachedPreviewPillSourceFingerprint = ""
    var cachedPreviewPillScopeKey = ""
    var cachedPreviewPills: [DockPill] = []
    var lastFinderDirectoryRefresh: Date = .distantPast

    func resetPillRenderingState(cancelBuild: Bool = false) {
        pendingPreviewPills = []
        pendingPillQuery = nil
        visiblePills = []
        if cancelBuild {
            pillBuildTask?.cancel()
            pillBuildTask = nil
        }
    }

    func clearPendingPillBuild(cancelBuild: Bool = false) {
        pendingPreviewPills = []
        pendingPillQuery = nil
        if cancelBuild {
            pillBuildTask?.cancel()
            pillBuildTask = nil
        }
    }

    func cachedPreviewPills(
        query: String,
        sourceFingerprint: String,
        scopeKey: String
    ) -> [DockPill]? {
        guard cachedPreviewPillQuery == query,
            cachedPreviewPillSourceFingerprint == sourceFingerprint,
            cachedPreviewPillScopeKey == scopeKey
        else { return nil }
        return cachedPreviewPills
    }

    func storePreviewPills(
        _ pills: [DockPill],
        query: String,
        sourceFingerprint: String,
        scopeKey: String
    ) {
        cachedPreviewPillQuery = query
        cachedPreviewPillSourceFingerprint = sourceFingerprint
        cachedPreviewPillScopeKey = scopeKey
        cachedPreviewPills = pills
    }

    func preparePillRebuild(
        query: String,
        isDeletion: Bool,
        isQuestionStyle: Bool,
        cachedPills: [DockPill],
        previewPills: [DockPill]
    ) -> ContextDockPillScheduleStart {
        if pendingPillQuery == query, pillBuildTask != nil {
            return .duplicate(previewPills: isDeletion ? cachedPills : previewPills)
        }

        pillBuildGeneration &+= 1
        pillBuildTask?.cancel()

        if isQuestionStyle {
            lastPillQuery = query
            resetPillRenderingState(cancelBuild: true)
            return .questionStyle
        }

        pendingPillQuery = query
        return .scheduled(
            generation: pillBuildGeneration,
            previewPills: isDeletion ? cachedPills : previewPills
        )
    }

    func scheduledPillRebuildCanContinue(generation: Int, query: String) -> Bool {
        pillBuildGeneration == generation && pendingPillQuery == query
    }

    func finishScheduledPillRebuild(query: String) {
        lastPillQuery = query
        clearPendingPillBuild(cancelBuild: true)
    }

    /// Render identity for flicker-free commits: only swap published arrays when
    /// visible row content changed.
    func pillRenderFingerprint(_ pills: [DockPill]) -> String {
        pills.map {
            "\($0.id)|\($0.name)|\($0.badge ?? "")|\($0.isEnabled ? 1 : 0)|\($0.menuStatusBadge ?? "")|\($0.menuItemImage != nil ? 1 : 0)"
        }.joined(separator: "#")
    }

    func commitPreviewPills(_ pills: [DockPill]) {
        guard pillRenderFingerprint(pendingPreviewPills) != pillRenderFingerprint(pills)
        else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            pendingPreviewPills = pills
            visiblePills = pills
        }
    }

    func replaceCachedPills(
        _ pills: [DockPill],
        preserveFocus: Bool,
        focusedIndex: Int?,
        setFocusedIndex: (Int?) -> Void,
        clearPillKeyboardNavigation: () -> Void
    ) {
        guard pillRenderFingerprint(cachedPills) != pillRenderFingerprint(pills) else {
            if pillRenderFingerprint(visiblePills) != pillRenderFingerprint(pills) {
                visiblePills = pills
            }
            return
        }

        let previousFocusedID: String? = {
            guard preserveFocus,
                let index = focusedIndex,
                cachedPills.indices.contains(index)
            else { return nil }
            return cachedPills[index].id
        }()

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            cachedPills = pills
            visiblePills = pills
        }

        guard preserveFocus else { return }
        if let previousFocusedID,
            let newIndex = pills.firstIndex(where: { $0.id == previousFocusedID && !$0.isSeparator })
        {
            setFocusedIndex(newIndex)
            return
        }
        if let index = focusedIndex,
            !pills.indices.contains(index) || pills[index].isSeparator
        {
            setFocusedIndex(nil)
            clearPillKeyboardNavigation()
        }
    }
}

@MainActor
final class MediaDockViewModel: ObservableObject {
    @Published var state = MediaDockState()
}

@MainActor
final class AIChatViewModel: ObservableObject {
    @Published var state = AIChatState()
    @Published var remPanelMessages: [AIChatMessage] = []
    @Published var remPanelIsProcessing = false
    @Published var remIsInstalled: Bool?
    @Published var showExtensionSuggestions = false
    @Published var extensionSuggestions: [SuggestedExtension] = []
    @Published var returnContextInDock = false
    @Published var returnBrowserLayer = false
    @Published var returnGlobalContext: GlobalContextActivation?
    @Published var hasUserSentMessageInCurrentSession = false
    @Published var suggestedExtensionCode: String?
    @Published var originalUserQuery: String?

    var remPanelTask: Task<Void, Never>?
}

@MainActor
final class AutomationViewModel: ObservableObject {
    @Published var state = AutomationState()
}
