import AppKit
import Combine
import Darwin
import Foundation

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
    @Published var showFolderPreview = false
    @Published var folderPreviewPath: String?
    @Published var folderPreviewSelectedFile: String?
    @Published var showContactPreview = false
    @Published var contactPreviewData: SearchResult?
    @Published var showShortcutSheet = false
    @Published var shortcutSheetFocusedCommandID: String?
    @Published var shortcutSheetSearchQuery = ""
    @Published var shortcutSheetSourcePID: pid_t = 0
    @Published var shortcutSheetAppName = "App"
    @Published var shortcutSheetSelectionSnapshot: SelectionContextSnapshot?
    @Published var shortcutSheetSelectionExpanded = false
    @Published var shortcutSheetChatMessages: [AIChatMessage] = []
    @Published var shortcutSheetChatLoading = false
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
    @Published var suppressAutomaticGlobalContextUntil: Date = .distantPast

    var appMatchTask: Task<Void, Never>?
    var appMatchGeneration = 0
    var groupedTask: Task<Void, Never>?
    var groupedGeneration = 0
    var clipboardExpiryTimer: Timer?
    var clipboardIndicatorHideTask: Task<Void, Never>?
}

@MainActor
final class ContextDockViewModel: ObservableObject {
    @Published var state = ContextDockState()
    @Published var cachedPills: [DockPill] = []
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
    @Published var lockedFindToken: LauncherView.AppFindToken?
    @Published var showFindTokenMenu = false
    @Published var crossAppMenuTargetPID: pid_t = 0
    @Published var crossAppMenuNeedsLiveLoad = false
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
    var axContextRefreshTimer: Timer?
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
