import AppKit
import Foundation

extension LauncherView {
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
        nonmutating set { contextDockViewModel.cachedPills = newValue }
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
