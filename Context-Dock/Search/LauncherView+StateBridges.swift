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



    var measuredGlobalListContentHeight: CGFloat {
        get { launcherViewModel.measuredGlobalListContentHeight }
        nonmutating set { launcherViewModel.measuredGlobalListContentHeight = newValue }
    }


    var folderPreviewPath: String? {
        get { launcherViewModel.folderPreviewPath }
        nonmutating set { launcherViewModel.folderPreviewPath = newValue }
    }











    var isSearchBarExpanded: Bool {
        get { launcherViewModel.isSearchBarExpanded }
        nonmutating set { launcherViewModel.isSearchBarExpanded = newValue }
    }

    var collapseTimer: Task<Void, Never>? {
        get { launcherViewModel.collapseTimer }
        nonmutating set { launcherViewModel.collapseTimer = newValue }
    }


    var suppressHoverExpand: Bool {
        get { launcherViewModel.suppressHoverExpand }
        nonmutating set { launcherViewModel.suppressHoverExpand = newValue }
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






    var currentContext: UserContext {
        get { contextDockViewModel.currentContext }
        nonmutating set {
            guard contextDockViewModel.currentContext != newValue else { return }
            contextDockViewModel.currentContext = newValue
        }
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


    var axContextRefreshTimer: Timer? {
        get { contextDockViewModel.axContextRefreshTimer }
        nonmutating set { contextDockViewModel.axContextRefreshTimer = newValue }
    }



    var safariTabPickerTabs: [SafariTab] {
        get { contextDockViewModel.safariTabPickerTabs }
        nonmutating set { contextDockViewModel.safariTabPickerTabs = newValue }
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








    var hasUserSentMessageInCurrentSession: Bool {
        get { aiChatViewModel.hasUserSentMessageInCurrentSession }
        nonmutating set { aiChatViewModel.hasUserSentMessageInCurrentSession = newValue }
    }


    var originalUserQuery: String? {
        get { aiChatViewModel.originalUserQuery }
        nonmutating set { aiChatViewModel.originalUserQuery = newValue }
    }

    var focusedAppPillIndex: Int? {
        get { globalContextViewModel.focusedAppPillIndex }
        nonmutating set { globalContextViewModel.focusedAppPillIndex = newValue }
    }



    var liveDockSelectionPreviewText: String? {
        get { globalContextViewModel.liveSelectionPreviewText }
        nonmutating set { globalContextViewModel.liveSelectionPreviewText = newValue }
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



    var globalClipboardText: String {
        get { globalContextViewModel.clipboardText }
        nonmutating set { globalContextViewModel.clipboardText = newValue }
    }

    var showGlobalClipboardPill: Bool {
        get { globalContextViewModel.showClipboardPill }
        nonmutating set { globalContextViewModel.showClipboardPill = newValue }
    }

    var lastCheckedPasteboardCount: Int {
        get { ClipboardHistoryEngine.shared.lastCheckedPasteboardCount }
        nonmutating set { ClipboardHistoryEngine.shared.lastCheckedPasteboardCount = newValue }
    }


    var clipboardHistory: [ClipboardEntry] {
        get { ClipboardHistoryEngine.shared.history }
        nonmutating set { ClipboardHistoryEngine.shared.history = newValue }
    }










    var focusedClipboardEntryIndex: Int? {
        get { globalContextViewModel.focusedClipboardEntryIndex }
        nonmutating set { globalContextViewModel.focusedClipboardEntryIndex = newValue }
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



    var listViewHoveredIndex: Int? {
        get { contextDockViewModel.listViewHoveredIndex }
        nonmutating set { contextDockViewModel.listViewHoveredIndex = newValue }
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
    var lastLiveSelectionPoll: Date {
        get { contextDockViewModel.lastLiveSelectionPoll }
        nonmutating set { contextDockViewModel.lastLiveSelectionPoll = newValue }
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
