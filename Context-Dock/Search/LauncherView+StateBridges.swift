import AppKit
import Foundation
import SwiftUI

extension LauncherView {
    var debounceTask: Task<Void, Never>? {
        get { launcherViewModel.debounceTask }
        nonmutating set { launcherViewModel.debounceTask = newValue }
    }

    var indexedFileResults: [SearchResult] {
        get { launcherViewModel.indexedFileResults }
        nonmutating set { launcherViewModel.indexedFileResults = newValue }
    }

    var lastQuery: String {
        get { launcherViewModel.lastQuery }
        nonmutating set { launcherViewModel.lastQuery = newValue }
    }

    var isKeyboardNavigation: Bool {
        get { launcherViewModel.isKeyboardNavigation }
        nonmutating set { launcherViewModel.isKeyboardNavigation = newValue }
    }

    var shouldAutoScroll: Bool {
        get { launcherViewModel.shouldAutoScroll }
        nonmutating set { launcherViewModel.shouldAutoScroll = newValue }
    }

    var removedToolBannerName: String? {
        get { launcherViewModel.removedToolBannerName }
        nonmutating set { launcherViewModel.removedToolBannerName = newValue }
    }

    var isVisible: Bool {
        get { launcherViewModel.isVisible }
        nonmutating set { launcherViewModel.isVisible = newValue }
    }

    var allApplications: [SearchResult] {
        get { launcherViewModel.allApplications }
        nonmutating set { launcherViewModel.allApplications = newValue }
    }

    var allShortcuts: [SearchResult] {
        get { launcherViewModel.allShortcuts }
        nonmutating set { launcherViewModel.allShortcuts = newValue }
    }

    var allContacts: [SearchResult] {
        get { launcherViewModel.allContacts }
        nonmutating set { launcherViewModel.allContacts = newValue }
    }

    var systemDataResults: [SearchResult] {
        get { launcherViewModel.systemDataResults }
        nonmutating set { launcherViewModel.systemDataResults = newValue }
    }

    var runningRegularApps: [NSRunningApplication] {
        get { launcherViewModel.runningRegularApps }
        nonmutating set { launcherViewModel.runningRegularApps = newValue }
    }

    var browserWarmupTask: Task<Void, Never>? {
        get { launcherViewModel.browserWarmupTask }
        nonmutating set { launcherViewModel.browserWarmupTask = newValue }
    }

    var windowResizeTask: Task<Void, Never>? {
        get { launcherViewModel.windowResizeTask }
        nonmutating set { launcherViewModel.windowResizeTask = newValue }
    }

    var l1ResultsReservedHeight: CGFloat {
        get { launcherViewModel.l1ResultsReservedHeight }
        nonmutating set { launcherViewModel.l1ResultsReservedHeight = newValue }
    }

    var measuredGlobalListContentHeight: CGFloat {
        get { launcherViewModel.measuredGlobalListContentHeight }
        nonmutating set { launcherViewModel.measuredGlobalListContentHeight = newValue }
    }

    var measuredChatContentHeight: CGFloat {
        get { launcherViewModel.measuredChatContentHeight }
        nonmutating set { launcherViewModel.measuredChatContentHeight = newValue }
    }

    var showFolderPreview: Bool {
        get { launcherViewModel.showFolderPreview }
        nonmutating set { launcherViewModel.showFolderPreview = newValue }
    }

    var showFolderPreviewBinding: Binding<Bool> {
        Binding(
            get: { launcherViewModel.showFolderPreview },
            set: { launcherViewModel.showFolderPreview = $0 }
        )
    }

    var folderPreviewPath: String? {
        get { launcherViewModel.folderPreviewPath }
        nonmutating set { launcherViewModel.folderPreviewPath = newValue }
    }

    var folderPreviewSelectedFile: String? {
        get { launcherViewModel.folderPreviewSelectedFile }
        nonmutating set { launcherViewModel.folderPreviewSelectedFile = newValue }
    }

    var folderPreviewSelectedFileBinding: Binding<String?> {
        Binding(
            get: { launcherViewModel.folderPreviewSelectedFile },
            set: { launcherViewModel.folderPreviewSelectedFile = $0 }
        )
    }

    var showContactPreview: Bool {
        get { launcherViewModel.showContactPreview }
        nonmutating set { launcherViewModel.showContactPreview = newValue }
    }

    var showContactPreviewBinding: Binding<Bool> {
        Binding(
            get: { launcherViewModel.showContactPreview },
            set: { launcherViewModel.showContactPreview = $0 }
        )
    }

    var contactPreviewData: SearchResult? {
        get { launcherViewModel.contactPreviewData }
        nonmutating set { launcherViewModel.contactPreviewData = newValue }
    }

    var quickLookDataSource: QuickLookDataSource? {
        get { launcherViewModel.quickLookDataSource }
        nonmutating set { launcherViewModel.quickLookDataSource = newValue }
    }

    var quickLookEventMonitor: Any? {
        get { launcherViewModel.quickLookEventMonitor }
        nonmutating set { launcherViewModel.quickLookEventMonitor = newValue }
    }

    var cmdHoldTask: Task<Void, Never>? {
        get { launcherViewModel.cmdHoldTask }
        nonmutating set { launcherViewModel.cmdHoldTask = newValue }
    }

    var cmdHoldMonitor: Any? {
        get { launcherViewModel.cmdHoldMonitor }
        nonmutating set { launcherViewModel.cmdHoldMonitor = newValue }
    }

    var cmdHoldGlobalMonitor: Any? {
        get { launcherViewModel.cmdHoldGlobalMonitor }
        nonmutating set { launcherViewModel.cmdHoldGlobalMonitor = newValue }
    }

    var cmdTapArmed: Bool {
        get { launcherViewModel.cmdTapArmed }
        nonmutating set { launcherViewModel.cmdTapArmed = newValue }
    }

    var cmdChordUsed: Bool {
        get { launcherViewModel.cmdChordUsed }
        nonmutating set { launcherViewModel.cmdChordUsed = newValue }
    }

    var cmdHoldTriggered: Bool {
        get { launcherViewModel.cmdHoldTriggered }
        nonmutating set { launcherViewModel.cmdHoldTriggered = newValue }
    }

    var isSearchBarExpanded: Bool {
        get { launcherViewModel.isSearchBarExpanded }
        nonmutating set { launcherViewModel.isSearchBarExpanded = newValue }
    }

    var collapseTimer: Task<Void, Never>? {
        get { launcherViewModel.collapseTimer }
        nonmutating set { launcherViewModel.collapseTimer = newValue }
    }

    var suppressCommandScopeToggleUntil: Date {
        get { launcherViewModel.suppressCommandScopeToggleUntil }
        nonmutating set { launcherViewModel.suppressCommandScopeToggleUntil = newValue }
    }

    var suppressHoverExpand: Bool {
        get { launcherViewModel.suppressHoverExpand }
        nonmutating set { launcherViewModel.suppressHoverExpand = newValue }
    }

    var suppressOpenResize: Bool {
        get { launcherViewModel.suppressOpenResize }
        nonmutating set { launcherViewModel.suppressOpenResize = newValue }
    }

    var lastKnownBrowserURL: String {
        get { launcherViewModel.lastKnownBrowserURL }
        nonmutating set { launcherViewModel.lastKnownBrowserURL = newValue }
    }

    var swipeGestureMonitor: Any? {
        get { launcherViewModel.swipeGestureMonitor }
        nonmutating set { launcherViewModel.swipeGestureMonitor = newValue }
    }

    var accumulatedSwipeDeltaY: CGFloat {
        get { launcherViewModel.accumulatedSwipeDeltaY }
        nonmutating set { launcherViewModel.accumulatedSwipeDeltaY = newValue }
    }

    var accumulatedSwipeDeltaX: CGFloat {
        get { launcherViewModel.accumulatedSwipeDeltaX }
        nonmutating set { launcherViewModel.accumulatedSwipeDeltaX = newValue }
    }

    var isHoveringDockArea: Bool {
        get { launcherViewModel.isHoveringDockArea }
        nonmutating set { launcherViewModel.isHoveringDockArea = newValue }
    }

    var hoveredDockAppKey: String? {
        get { launcherViewModel.hoveredDockAppKey }
        nonmutating set { launcherViewModel.hoveredDockAppKey = newValue }
    }

    var hoveredAppPillIndex: Int? {
        get { launcherViewModel.hoveredAppPillIndex }
        nonmutating set { launcherViewModel.hoveredAppPillIndex = newValue }
    }

    var isSharingSheetActive: Bool {
        get { launcherViewModel.isSharingSheetActive }
        nonmutating set { launcherViewModel.isSharingSheetActive = newValue }
    }

    var showNotificationPanel: Bool {
        get { launcherViewModel.showNotificationPanel }
        nonmutating set {
            guard launcherViewModel.showNotificationPanel != newValue else { return }
            launcherViewModel.showNotificationPanel = newValue
        }
    }

    var showNotificationDock: Bool {
        get { launcherViewModel.showNotificationDock }
        nonmutating set {
            guard launcherViewModel.showNotificationDock != newValue else { return }
            launcherViewModel.showNotificationDock = newValue
        }
    }

    var showNotificationDockBinding: Binding<Bool> {
        Binding(
            get: { launcherViewModel.showNotificationDock },
            set: { launcherViewModel.showNotificationDock = $0 }
        )
    }

    var notifDockTab: Int {
        get { launcherViewModel.notificationDockTab }
        nonmutating set {
            guard launcherViewModel.notificationDockTab != newValue else { return }
            launcherViewModel.notificationDockTab = newValue
        }
    }

    var notifDockTabBinding: Binding<Int> {
        Binding(
            get: { launcherViewModel.notificationDockTab },
            set: { launcherViewModel.notificationDockTab = $0 }
        )
    }

    var currentContext: UserContext {
        get { contextDockViewModel.currentContext }
        nonmutating set {
            guard contextDockViewModel.currentContext != newValue else { return }
            contextDockViewModel.currentContext = newValue
        }
    }

    var currentContextBinding: Binding<UserContext> {
        Binding(
            get: { contextDockViewModel.currentContext },
            set: { contextDockViewModel.currentContext = $0 }
        )
    }

    var axContext: AXContext {
        get { contextDockViewModel.axContext }
        nonmutating set { contextDockViewModel.axContext = newValue }
    }

    var finderFollowUpTargetPaths: [String] {
        get { finderContext.followUpTargetPaths }
        nonmutating set {
            guard finderContext.followUpTargetPaths != newValue else { return }
            finderContext.followUpTargetPaths = newValue
        }
    }

    var finderFollowUpSourceQuery: String {
        get { finderContext.followUpSourceQuery }
        nonmutating set {
            guard finderContext.followUpSourceQuery != newValue else { return }
            finderContext.followUpSourceQuery = newValue
        }
    }

    var adapterContextData: [String: String] {
        get { contextDockViewModel.adapterContextData }
        nonmutating set { contextDockViewModel.adapterContextData = newValue }
    }

    var selectedFiles: Set<String> {
        get { contextDockViewModel.selectedFiles }
        nonmutating set { contextDockViewModel.selectedFiles = newValue }
    }

    var shortcutMetadataCache: [String: ShortcutMetadata] {
        get { contextDockViewModel.shortcutMetadataCache }
        nonmutating set { contextDockViewModel.shortcutMetadataCache = newValue }
    }

    var isContextExpanded: Bool {
        get { contextDockViewModel.isContextExpanded }
        nonmutating set { contextDockViewModel.isContextExpanded = newValue }
    }

    var axContextRefreshTimer: Timer? {
        get { contextDockViewModel.axContextRefreshTimer }
        nonmutating set { contextDockViewModel.axContextRefreshTimer = newValue }
    }

    var showSafariTabPicker: Bool {
        get { contextDockViewModel.showSafariTabPicker }
        nonmutating set { contextDockViewModel.showSafariTabPicker = newValue }
    }

    var showSafariTabPickerBinding: Binding<Bool> {
        Binding(
            get: { contextDockViewModel.showSafariTabPicker },
            set: { contextDockViewModel.showSafariTabPicker = $0 }
        )
    }

    var safariTabPickerTabs: [SafariTab] {
        get { contextDockViewModel.safariTabPickerTabs }
        nonmutating set { contextDockViewModel.safariTabPickerTabs = newValue }
    }

    var safariTabPickerLoading: Bool {
        get { contextDockViewModel.safariTabPickerLoading }
        nonmutating set { contextDockViewModel.safariTabPickerLoading = newValue }
    }

    var appSwitchObserver: NSObjectProtocol? {
        get { launcherViewModel.appSwitchObserver }
        nonmutating set { launcherViewModel.appSwitchObserver = newValue }
    }

    var appLaunchObserver: NSObjectProtocol? {
        get { launcherViewModel.appLaunchObserver }
        nonmutating set { launcherViewModel.appLaunchObserver = newValue }
    }

    var appTerminateObserver: NSObjectProtocol? {
        get { launcherViewModel.appTerminateObserver }
        nonmutating set { launcherViewModel.appTerminateObserver = newValue }
    }

    var remPanelChatMessages: [AIChatMessage] {
        get { aiChatViewModel.remPanelMessages }
        nonmutating set { aiChatViewModel.remPanelMessages = newValue }
    }

    var remPanelIsProcessing: Bool {
        get { aiChatViewModel.remPanelIsProcessing }
        nonmutating set { aiChatViewModel.remPanelIsProcessing = newValue }
    }

    var remPanelAITask: Task<Void, Never>? {
        get { aiChatViewModel.remPanelTask }
        nonmutating set { aiChatViewModel.remPanelTask = newValue }
    }

    var remIsInstalled: Bool? {
        get { aiChatViewModel.remIsInstalled }
        nonmutating set { aiChatViewModel.remIsInstalled = newValue }
    }

    var showAIExtensionSuggestions: Bool {
        get { aiChatViewModel.showExtensionSuggestions }
        nonmutating set { aiChatViewModel.showExtensionSuggestions = newValue }
    }

    var showAIExtensionSuggestionsBinding: Binding<Bool> {
        Binding(
            get: { aiChatViewModel.showExtensionSuggestions },
            set: { aiChatViewModel.showExtensionSuggestions = $0 }
        )
    }

    var aiExtensionSuggestions: [SuggestedExtension] {
        get { aiChatViewModel.extensionSuggestions }
        nonmutating set { aiChatViewModel.extensionSuggestions = newValue }
    }

    var chatReturnContextInDock: Bool {
        get { aiChatViewModel.returnContextInDock }
        nonmutating set { aiChatViewModel.returnContextInDock = newValue }
    }

    var chatReturnBrowserLayer: Bool {
        get { aiChatViewModel.returnBrowserLayer }
        nonmutating set { aiChatViewModel.returnBrowserLayer = newValue }
    }

    var chatReturnGlobalContext: GlobalContextActivation? {
        get { aiChatViewModel.returnGlobalContext }
        nonmutating set { aiChatViewModel.returnGlobalContext = newValue }
    }

    var hasUserSentMessageInCurrentSession: Bool {
        get { aiChatViewModel.hasUserSentMessageInCurrentSession }
        nonmutating set { aiChatViewModel.hasUserSentMessageInCurrentSession = newValue }
    }

    var suggestedExtensionCode: String? {
        get { aiChatViewModel.suggestedExtensionCode }
        nonmutating set { aiChatViewModel.suggestedExtensionCode = newValue }
    }

    var originalUserQuery: String? {
        get { aiChatViewModel.originalUserQuery }
        nonmutating set { aiChatViewModel.originalUserQuery = newValue }
    }

    var focusedAppPillIndex: Int? {
        get { globalContextViewModel.focusedAppPillIndex }
        nonmutating set { globalContextViewModel.focusedAppPillIndex = newValue }
    }

    var cachedGlobalAppQuery: String {
        get { globalContextViewModel.cachedAppQuery }
        nonmutating set { globalContextViewModel.cachedAppQuery = newValue }
    }

    var cachedGlobalAppMatches: [SearchResult] {
        get { globalContextViewModel.cachedAppMatches }
        nonmutating set { globalContextViewModel.cachedAppMatches = newValue }
    }

    var pendingGlobalAppQuery: String? {
        get { globalContextViewModel.pendingAppQuery }
        nonmutating set { globalContextViewModel.pendingAppQuery = newValue }
    }

    var globalAppMatchTask: Task<Void, Never>? {
        get { globalContextViewModel.appMatchTask }
        nonmutating set { globalContextViewModel.appMatchTask = newValue }
    }

    var globalAppMatchGeneration: Int {
        get { globalContextViewModel.appMatchGeneration }
        nonmutating set { globalContextViewModel.appMatchGeneration = newValue }
    }

    var cachedGlobalGroupedQuery: String {
        get { globalContextViewModel.cachedGroupedQuery }
        nonmutating set { globalContextViewModel.cachedGroupedQuery = newValue }
    }

    var cachedGlobalGroupedState: GlobalGroupedListNavigationState? {
        get { globalContextViewModel.cachedGroupedState }
        nonmutating set { globalContextViewModel.cachedGroupedState = newValue }
    }

    var pendingGlobalGroupedQuery: String? {
        get { globalContextViewModel.pendingGroupedQuery }
        nonmutating set { globalContextViewModel.pendingGroupedQuery = newValue }
    }

    var globalGroupedTask: Task<Void, Never>? {
        get { globalContextViewModel.groupedTask }
        nonmutating set { globalContextViewModel.groupedTask = newValue }
    }

    var globalGroupedGeneration: Int {
        get { globalContextViewModel.groupedGeneration }
        nonmutating set { globalContextViewModel.groupedGeneration = newValue }
    }

    var globalInlineAppScope: GlobalInlineAppScope? {
        get { globalContextViewModel.inlineAppScope }
        nonmutating set { globalContextViewModel.inlineAppScope = newValue }
    }

    var additionalGlobalInlineAppScopes: [GlobalInlineAppScope] {
        get { globalContextViewModel.additionalInlineAppScopes }
        nonmutating set { globalContextViewModel.additionalInlineAppScopes = newValue }
    }

    var pendingGlobalLaunchContextSwitch: (bundleId: String, appName: String)? {
        get { globalContextViewModel.pendingLaunchContextSwitch }
        nonmutating set { globalContextViewModel.pendingLaunchContextSwitch = newValue }
    }

    var suppressGlobalInlineAppScopeDetection: Bool {
        get { globalContextViewModel.suppressInlineAppScopeDetection }
        nonmutating set { globalContextViewModel.suppressInlineAppScopeDetection = newValue }
    }

    var dismissedGlobalInlineAppScopes: [String: String] {
        get { globalContextViewModel.dismissedInlineAppScopes }
        nonmutating set { globalContextViewModel.dismissedInlineAppScopes = newValue }
    }

    var hoveredGlobalInlineScopeBundleId: String? {
        get { globalContextViewModel.hoveredInlineScopeBundleId }
        nonmutating set { globalContextViewModel.hoveredInlineScopeBundleId = newValue }
    }

    var isHoveringL2ScopeChip: Bool {
        get { globalContextViewModel.isHoveringL2ScopeChip }
        nonmutating set { globalContextViewModel.isHoveringL2ScopeChip = newValue }
    }

    var isHoveringFrontmostContextChip: Bool {
        get { globalContextViewModel.isHoveringFrontmostContextChip }
        nonmutating set { globalContextViewModel.isHoveringFrontmostContextChip = newValue }
    }

    var globalClipboardText: String {
        get { globalContextViewModel.clipboardText }
        nonmutating set { globalContextViewModel.clipboardText = newValue }
    }

    var showGlobalClipboardPill: Bool {
        get { globalContextViewModel.showClipboardPill }
        nonmutating set { globalContextViewModel.showClipboardPill = newValue }
    }

    var lastCheckedPasteboardCount: Int {
        get { globalContextViewModel.lastCheckedPasteboardCount }
        nonmutating set { globalContextViewModel.lastCheckedPasteboardCount = newValue }
    }

    var clipboardHistory: [ClipboardEntry] {
        get { globalContextViewModel.clipboardHistory }
        nonmutating set { globalContextViewModel.clipboardHistory = newValue }
    }

    var showClipboardHistory: Bool {
        get { globalContextViewModel.showClipboardHistory }
        nonmutating set { globalContextViewModel.showClipboardHistory = newValue }
    }

    var showClipboardHistoryBinding: Binding<Bool> {
        Binding(
            get: { globalContextViewModel.showClipboardHistory },
            set: { globalContextViewModel.showClipboardHistory = $0 }
        )
    }

    var clipboardHistoryExpanded: Bool {
        get { globalContextViewModel.clipboardHistoryExpanded }
        nonmutating set { globalContextViewModel.clipboardHistoryExpanded = newValue }
    }

    var clipboardExpiryTimer: Timer? {
        get { globalContextViewModel.clipboardExpiryTimer }
        nonmutating set { globalContextViewModel.clipboardExpiryTimer = newValue }
    }

    var clipboardIndicatorHideTask: Task<Void, Never>? {
        get { globalContextViewModel.clipboardIndicatorHideTask }
        nonmutating set { globalContextViewModel.clipboardIndicatorHideTask = newValue }
    }

    var clipboardDropTargetVisible: Bool {
        get { globalContextViewModel.clipboardDropTargetVisible }
        nonmutating set { globalContextViewModel.clipboardDropTargetVisible = newValue }
    }

    var clipboardDropTargeted: Bool {
        get { globalContextViewModel.clipboardDropTargeted }
        nonmutating set { globalContextViewModel.clipboardDropTargeted = newValue }
    }

    var clipboardDropTargetedBinding: Binding<Bool> {
        Binding(
            get: { globalContextViewModel.clipboardDropTargeted },
            set: { globalContextViewModel.clipboardDropTargeted = $0 }
        )
    }

    var clipboardScopeShowsGrid: Bool {
        get { globalContextViewModel.clipboardScopeShowsGrid }
        nonmutating set { globalContextViewModel.clipboardScopeShowsGrid = newValue }
    }

    var focusedClipboardEntryIndex: Int? {
        get { globalContextViewModel.focusedClipboardEntryIndex }
        nonmutating set { globalContextViewModel.focusedClipboardEntryIndex = newValue }
    }

    var selectedClipboardEntryIDs: Set<UUID> {
        get { globalContextViewModel.selectedClipboardEntryIDs }
        nonmutating set { globalContextViewModel.selectedClipboardEntryIDs = newValue }
    }

    var dismissedFinderSelectionSignature: String? {
        get { globalContextViewModel.dismissedFinderSelectionSignature }
        nonmutating set { globalContextViewModel.dismissedFinderSelectionSignature = newValue }
    }

    var suppressedAutomaticFinderSelectionSignature: String? {
        get { globalContextViewModel.suppressedAutomaticFinderSelectionSignature }
        nonmutating set { globalContextViewModel.suppressedAutomaticFinderSelectionSignature = newValue }
    }

    var suppressAutomaticGlobalContextUntil: Date {
        get { globalContextViewModel.suppressAutomaticGlobalContextUntil }
        nonmutating set { globalContextViewModel.suppressAutomaticGlobalContextUntil = newValue }
    }

    var attachedFinderFolderSearchPath: String {
        get { finderContext.attachedFolderSearchPath }
        nonmutating set { finderContext.attachedFolderSearchPath = newValue }
    }

    var approvedFinderFolderSearchPaths: Set<String> {
        get { finderContext.approvedFolderSearchPaths }
        nonmutating set { finderContext.approvedFolderSearchPaths = newValue }
    }

    var cachedFinderCurrentDirectoryPath: String {
        get { finderContext.cachedCurrentDirectoryPath }
        nonmutating set { finderContext.cachedCurrentDirectoryPath = newValue }
    }

    var attachedFinderFolderSnapshotPath: String {
        get { finderContext.snapshotPath }
        nonmutating set { finderContext.snapshotPath = newValue }
    }

    var attachedFinderFolderSnapshotItems: [FinderFolderSnapshotItem] {
        get { finderContext.snapshotItems }
        nonmutating set { finderContext.snapshotItems = newValue }
    }

    var attachedFinderFolderSnapshotTask: Task<Void, Never>? {
        get { finderContext.snapshotTask }
        nonmutating set { finderContext.snapshotTask = newValue }
    }

    var attachedFinderFolderSnapshotDate: Date {
        get { finderContext.snapshotDate }
        nonmutating set { finderContext.snapshotDate = newValue }
    }

    var attachedFinderFolderSnapshotWatcher: FinderFolderSnapshotWatcher? {
        get { finderContext.snapshotWatcher }
        nonmutating set { finderContext.snapshotWatcher = newValue }
    }

    var attachedFinderFolderSnapshotWatcherTask: Task<Void, Never>? {
        get { finderContext.snapshotWatcherTask }
        nonmutating set { finderContext.snapshotWatcherTask = newValue }
    }

    var finderFollowUpFolderPath: String {
        get { finderContext.followUpFolderPath }
        nonmutating set { finderContext.followUpFolderPath = newValue }
    }

    var finderSemanticTask: Task<Void, Never>? {
        get { finderContext.semanticTask }
        nonmutating set { finderContext.semanticTask = newValue }
    }

    var finderSemanticQuery: String {
        get { finderContext.semanticQuery }
        nonmutating set { finderContext.semanticQuery = newValue }
    }

    var finderSemanticResults: [SearchResult] {
        get { finderContext.semanticResults }
        nonmutating set { finderContext.semanticResults = newValue }
    }

    var finderSemanticPills: [DockPill] {
        get { finderContext.semanticPills }
        nonmutating set { finderContext.semanticPills = newValue }
    }

    var isFinderSemanticLoading: Bool {
        get { finderContext.isSemanticLoading }
        nonmutating set { finderContext.isSemanticLoading = newValue }
    }

    var finderGoToPills: [DockPill] {
        get { finderContext.goToPills }
        nonmutating set { finderContext.goToPills = newValue }
    }

    var finderFolderQueryModeActive: Bool {
        get { finderContext.folderQueryModeActive }
        nonmutating set { finderContext.folderQueryModeActive = newValue }
    }

    var cachedDockPills: [DockPill] {
        get { contextDockViewModel.cachedPills }
        nonmutating set {
            contextDockViewModel.cachedPills = newValue
            if newValue.isEmpty {
                contextDockViewModel.visiblePills = []
            }
        }
    }

    var liveMenuItems: [AXMenuItem] {
        get { contextDockViewModel.liveMenuItems }
        nonmutating set { contextDockViewModel.liveMenuItems = newValue }
    }

    var menuLoadTask: Task<Void, Never>? {
        get { contextDockViewModel.menuLoadTask }
        nonmutating set { contextDockViewModel.menuLoadTask = newValue }
    }

    var liveMenuRefreshTask: Task<Void, Never>? {
        get { contextDockViewModel.liveMenuRefreshTask }
        nonmutating set { contextDockViewModel.liveMenuRefreshTask = newValue }
    }

    var menuAvailabilityRefreshTask: Task<Void, Never>? {
        get { contextDockViewModel.menuAvailabilityRefreshTask }
        nonmutating set { contextDockViewModel.menuAvailabilityRefreshTask = newValue }
    }

    var menuAvailabilityRefreshGeneration: Int {
        get { contextDockViewModel.menuAvailabilityRefreshGeneration }
        nonmutating set { contextDockViewModel.menuAvailabilityRefreshGeneration = newValue }
    }

    var lastLiveMenuStructureRefresh: Date {
        get { contextDockViewModel.lastLiveMenuStructureRefresh }
        nonmutating set { contextDockViewModel.lastLiveMenuStructureRefresh = newValue }
    }

    var lastLiveMenuSignature: String {
        get { contextDockViewModel.lastLiveMenuSignature }
        nonmutating set { contextDockViewModel.lastLiveMenuSignature = newValue }
    }

    var crossAppMenuItems: [AXMenuItem] {
        get { contextDockViewModel.crossAppMenuItems }
        nonmutating set { contextDockViewModel.crossAppMenuItems = newValue }
    }

    var lockedSubmenuParent: AXMenuItem? {
        get { contextDockViewModel.lockedSubmenuParent }
        nonmutating set { contextDockViewModel.lockedSubmenuParent = newValue }
    }

    var inlineShareActive: Bool {
        get { contextDockViewModel.inlineShareActive }
        nonmutating set { contextDockViewModel.inlineShareActive = newValue }
    }

    var lockedFindToken: AppFindToken? {
        get { contextDockViewModel.lockedFindToken }
        nonmutating set { contextDockViewModel.lockedFindToken = newValue }
    }

    var showFindTokenMenu: Bool {
        get { contextDockViewModel.showFindTokenMenu }
        nonmutating set { contextDockViewModel.showFindTokenMenu = newValue }
    }

    var crossAppMenuTask: Task<Void, Never>? {
        get { contextDockViewModel.crossAppMenuTask }
        nonmutating set { contextDockViewModel.crossAppMenuTask = newValue }
    }

    var crossAppMenuTargetPID: pid_t {
        get { contextDockViewModel.crossAppMenuTargetPID }
        nonmutating set { contextDockViewModel.crossAppMenuTargetPID = newValue }
    }

    var crossAppMenuNeedsLiveLoad: Bool {
        get { contextDockViewModel.crossAppMenuNeedsLiveLoad }
        nonmutating set { contextDockViewModel.crossAppMenuNeedsLiveLoad = newValue }
    }

    var warmingMenuBundleIds: Set<String> {
        get { contextDockViewModel.warmingMenuBundleIds }
        nonmutating set { contextDockViewModel.warmingMenuBundleIds = newValue }
    }

    var hoveredDockPillIndex: Int? {
        get { contextDockViewModel.hoveredDockPillIndex }
        nonmutating set { contextDockViewModel.hoveredDockPillIndex = newValue }
    }

    var isHoveringPillRow: Bool {
        get { contextDockViewModel.isHoveringPillRow }
        nonmutating set { contextDockViewModel.isHoveringPillRow = newValue }
    }

    var listViewHoveredIndex: Int? {
        get { contextDockViewModel.listViewHoveredIndex }
        nonmutating set { contextDockViewModel.listViewHoveredIndex = newValue }
    }

    var pillScrollAccumulator: CGFloat {
        get { contextDockViewModel.pillScrollAccumulator }
        nonmutating set { contextDockViewModel.pillScrollAccumulator = newValue }
    }

    var pendingAIMenuProposal: AIMenuProposal? {
        get { contextDockViewModel.pendingAIProposal }
        nonmutating set { contextDockViewModel.pendingAIProposal = newValue }
    }

    var dockPillBuildTask: Task<Void, Never>? {
        get { contextDockViewModel.pillBuildTask }
        nonmutating set { contextDockViewModel.pillBuildTask = newValue }
    }

    var pendingDockPillQuery: String? {
        get { contextDockViewModel.pendingPillQuery }
        nonmutating set { contextDockViewModel.pendingPillQuery = newValue }
    }

    var pendingDockPreviewPills: [DockPill] {
        get { contextDockViewModel.pendingPreviewPills }
        nonmutating set { contextDockViewModel.pendingPreviewPills = newValue }
    }

    var dockPillBuildGeneration: Int {
        get { contextDockViewModel.pillBuildGeneration }
        nonmutating set { contextDockViewModel.pillBuildGeneration = newValue }
    }

    var lastFinderSelectionRefresh: Date {
        get { contextDockViewModel.lastFinderSelectionRefresh }
        nonmutating set { contextDockViewModel.lastFinderSelectionRefresh = newValue }
    }

    var lastPillQuery: String {
        get { contextDockViewModel.lastPillQuery }
        nonmutating set { contextDockViewModel.lastPillQuery = newValue }
    }

    var menuDebugText: String {
        get { contextDockViewModel.menuDebugText }
        nonmutating set { contextDockViewModel.menuDebugText = newValue }
    }

    var contextMenuPills: [AXMenuItem] {
        get { contextDockViewModel.contextMenuPills }
        nonmutating set { contextDockViewModel.contextMenuPills = newValue }
    }

    var previousEnabledIDs: Set<UUID> {
        get { contextDockViewModel.previousEnabledIDs }
        nonmutating set { contextDockViewModel.previousEnabledIDs = newValue }
    }
}
