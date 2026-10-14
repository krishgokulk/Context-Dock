// LauncherView+EngineState.swift
// Context-Dock
//
// The launcher reads and writes its remembered state through these, so the call sites are
// unchanged while the fields live in `LauncherEngineState` (#257, stage E1).

import AppKit
import SwiftUI

extension LauncherView {
    var searchState: SearchState {
        get { engineState.searchState }
        nonmutating set { engineState.searchState = newValue }
    }
    var queryChangeTask: Task<Void, Never>? {
        get { engineState.queryChangeTask }
        nonmutating set { engineState.queryChangeTask = newValue }
    }
    var queryChangeGeneration: Int {
        get { engineState.queryChangeGeneration }
        nonmutating set { engineState.queryChangeGeneration = newValue }
    }
    var notepadSelectedNoteID: UUID? {
        get { engineState.notepadSelectedNoteID }
        nonmutating set { engineState.notepadSelectedNoteID = newValue }
    }
    var notepadAIGenerating: Bool {
        get { engineState.notepadAIGenerating }
        nonmutating set { engineState.notepadAIGenerating = newValue }
    }
    var notepadFrontmostContext: String? {
        get { engineState.notepadFrontmostContext }
        nonmutating set { engineState.notepadFrontmostContext = newValue }
    }
    var notepadFrontmostLabel: String? {
        get { engineState.notepadFrontmostLabel }
        nonmutating set { engineState.notepadFrontmostLabel = newValue }
    }
    var notepadCapturedText: String? {
        get { engineState.notepadCapturedText }
        nonmutating set { engineState.notepadCapturedText = newValue }
    }
    var notepadAttachments: [URL] {
        get { engineState.notepadAttachments }
        nonmutating set { engineState.notepadAttachments = newValue }
    }
    var clipboardSourceFilterBundleId: String {
        get { engineState.clipboardSourceFilterBundleId }
        nonmutating set { engineState.clipboardSourceFilterBundleId = newValue }
    }
    var clipboardSourceFilterName: String {
        get { engineState.clipboardSourceFilterName }
        nonmutating set { engineState.clipboardSourceFilterName = newValue }
    }
    var clipboardSourcePillFocusIndex: Int? {
        get { engineState.clipboardSourcePillFocusIndex }
        nonmutating set { engineState.clipboardSourcePillFocusIndex = newValue }
    }
    var chatFocusApps: [GeneralChatFocusApp] {
        get { engineState.chatFocusApps }
        nonmutating set { engineState.chatFocusApps = newValue }
    }
    var generalChatArtifact: URL? {
        get { engineState.generalChatArtifact }
        nonmutating set { engineState.generalChatArtifact = newValue }
    }
    var pendingAttachmentTurn: Bool {
        get { engineState.pendingAttachmentTurn }
        nonmutating set { engineState.pendingAttachmentTurn = newValue }
    }
    var isShowingChatFocusAppPicker: Bool {
        get { engineState.isShowingChatFocusAppPicker }
        nonmutating set { engineState.isShowingChatFocusAppPicker = newValue }
    }
    var hoveredChatFocusBundleId: String? {
        get { engineState.hoveredChatFocusBundleId }
        nonmutating set { engineState.hoveredChatFocusBundleId = newValue }
    }
    var panelConsoleLinesMap: [String: [(line: String, isCommand: Bool)]] {
        get { engineState.panelConsoleLinesMap }
        nonmutating set { engineState.panelConsoleLinesMap = newValue }
    }
    var panelShowConsoleMap: [String: Bool] {
        get { engineState.panelShowConsoleMap }
        nonmutating set { engineState.panelShowConsoleMap = newValue }
    }
    var panelConsoleHeight: CGFloat {
        get { engineState.panelConsoleHeight }
        nonmutating set { engineState.panelConsoleHeight = newValue }
    }
    var panelTerminalControllers: [String: TerminalHostController] {
        get { engineState.panelTerminalControllers }
        nonmutating set { engineState.panelTerminalControllers = newValue }
    }
    var livePanelMode: LivePanelMode {
        get { engineState.livePanelMode }
        nonmutating set { engineState.livePanelMode = newValue }
    }
    var livePanelVisible: Bool {
        get { engineState.livePanelVisible }
        nonmutating set { engineState.livePanelVisible = newValue }
    }
    var globalQuitIdleDismissTask: Task<Void, Never>? {
        get { engineState.globalQuitIdleDismissTask }
        nonmutating set { engineState.globalQuitIdleDismissTask = newValue }
    }
    var globalQuitIdleDismissGeneration: Int {
        get { engineState.globalQuitIdleDismissGeneration }
        nonmutating set { engineState.globalQuitIdleDismissGeneration = newValue }
    }
    var qlRightClickPos: CGPoint? {
        get { engineState.qlRightClickPos }
        nonmutating set { engineState.qlRightClickPos = newValue }
    }
    var panelTerminalHost: TerminalHostController? {
        get { engineState.panelTerminalHost }
        nonmutating set { engineState.panelTerminalHost = newValue }
    }
    var l2: L2State {
        get { engineState.l2 }
        nonmutating set { engineState.l2 = newValue }
    }
    var pendingTerminalCommand: PendingTerminalCommand? {
        get { engineState.pendingTerminalCommand }
        nonmutating set { engineState.pendingTerminalCommand = newValue }
    }
    var pendingFinderOperation: PendingFinderOperation? {
        get { engineState.pendingFinderOperation }
        nonmutating set { engineState.pendingFinderOperation = newValue }
    }
    var finderDesktopRecentPills: [DockPill] {
        get { engineState.finderDesktopRecentPills }
        nonmutating set { engineState.finderDesktopRecentPills = newValue }
    }
    var finderDesktopIndexedPills: [DockPill] {
        get { engineState.finderDesktopIndexedPills }
        nonmutating set { engineState.finderDesktopIndexedPills = newValue }
    }
    var finderBrowsePath: String? {
        get { engineState.finderBrowsePath }
        nonmutating set { engineState.finderBrowsePath = newValue }
    }
    var expandedClipboardEntryIDs: Set<UUID> {
        get { engineState.expandedClipboardEntryIDs }
        nonmutating set { engineState.expandedClipboardEntryIDs = newValue }
    }
    var contextDockChatCapturedText: String? {
        get { engineState.contextDockChatCapturedText }
        nonmutating set { engineState.contextDockChatCapturedText = newValue }
    }
    var contextDockChatFiles: [URL] {
        get { engineState.contextDockChatFiles }
        nonmutating set { engineState.contextDockChatFiles = newValue }
    }
    var finderDesktopFullIndexPrimed: Bool {
        get { engineState.finderDesktopFullIndexPrimed }
        nonmutating set { engineState.finderDesktopFullIndexPrimed = newValue }
    }
    var finderDesktopSearchPills: [DockPill] {
        get { engineState.finderDesktopSearchPills }
        nonmutating set { engineState.finderDesktopSearchPills = newValue }
    }
    var finderDesktopSearchQuery: String {
        get { engineState.finderDesktopSearchQuery }
        nonmutating set { engineState.finderDesktopSearchQuery = newValue }
    }
    var launchSelectionScopeGraceUntil: Date {
        get { engineState.launchSelectionScopeGraceUntil }
        nonmutating set { engineState.launchSelectionScopeGraceUntil = newValue }
    }
    var selectionScopePayload: GlobalContextActivation? {
        get { engineState.selectionScopePayload }
        nonmutating set { engineState.selectionScopePayload = newValue }
    }
    var selectionScopeSheetCollapsed: Bool {
        get { engineState.selectionScopeSheetCollapsed }
        nonmutating set { engineState.selectionScopeSheetCollapsed = newValue }
    }
    var selectionScopeSourceAcceptsReplacement: Bool {
        get { engineState.selectionScopeSourceAcceptsReplacement }
        nonmutating set { engineState.selectionScopeSourceAcceptsReplacement = newValue }
    }
    var selectionRouterExecutedRouteTitle: String? {
        get { engineState.selectionRouterExecutedRouteTitle }
        nonmutating set { engineState.selectionRouterExecutedRouteTitle = newValue }
    }
    var selectionRouterNoRouteNote: String? {
        get { engineState.selectionRouterNoRouteNote }
        nonmutating set { engineState.selectionRouterNoRouteNote = newValue }
    }
    var selectionRouterPendingEmail: PendingSelectionEmail? {
        get { engineState.selectionRouterPendingEmail }
        nonmutating set { engineState.selectionRouterPendingEmail = newValue }
    }
    var lastAppliedSelectionActivation: Int {
        get { engineState.lastAppliedSelectionActivation }
        nonmutating set { engineState.lastAppliedSelectionActivation = newValue }
    }
    var pendingPrivacyApproval: AIPrivacyApprovalCenter.PendingApproval? {
        get { engineState.pendingPrivacyApproval }
        nonmutating set { engineState.pendingPrivacyApproval = newValue }
    }
    var pendingCapabilityApproval: AICapabilityApprovalCenter.PendingApproval? {
        get { engineState.pendingCapabilityApproval }
        nonmutating set { engineState.pendingCapabilityApproval = newValue }
    }
    var pendingAdapterApproval: AdapterActionRequest? {
        get { engineState.pendingAdapterApproval }
        nonmutating set { engineState.pendingAdapterApproval = newValue }
    }
    var pendingActionCandidates: [DoraXActionCandidate] {
        get { engineState.pendingActionCandidates }
        nonmutating set { engineState.pendingActionCandidates = newValue }
    }
    var pendingActionQuery: String {
        get { engineState.pendingActionQuery }
        nonmutating set { engineState.pendingActionQuery = newValue }
    }
    var pendingCapabilityGap: CapabilityGapService.Gap? {
        get { engineState.pendingCapabilityGap }
        nonmutating set { engineState.pendingCapabilityGap = newValue }
    }
    var capabilityGapWorking: Bool {
        get { engineState.capabilityGapWorking }
        nonmutating set { engineState.capabilityGapWorking = newValue }
    }
    var lastAppliedDockHeightPreset: DockHeightPreset? {
        get { engineState.lastAppliedDockHeightPreset }
        nonmutating set { engineState.lastAppliedDockHeightPreset = newValue }
    }
    var lastAppliedDockSurfaceMode: DockSurfaceMode? {
        get { engineState.lastAppliedDockSurfaceMode }
        nonmutating set { engineState.lastAppliedDockSurfaceMode = newValue }
    }
    var lastAppliedGlobalTypingPhase: GlobalContextTypingPhase? {
        get { engineState.lastAppliedGlobalTypingPhase }
        nonmutating set { engineState.lastAppliedGlobalTypingPhase = newValue }
    }
    var renderedDockHeight: CGFloat? {
        get { engineState.renderedDockHeight }
        nonmutating set { engineState.renderedDockHeight = newValue }
    }
    var isHoveringSearchIcon: Bool {
        get { engineState.isHoveringSearchIcon }
        nonmutating set { engineState.isHoveringSearchIcon = newValue }
    }
    var isHoveringInputField: Bool {
        get { engineState.isHoveringInputField }
        nonmutating set { engineState.isHoveringInputField = newValue }
    }
    var suppressMouseDrivenInteractionUntil: Date {
        get { engineState.suppressMouseDrivenInteractionUntil }
        nonmutating set { engineState.suppressMouseDrivenInteractionUntil = newValue }
    }
    var suppressMouseDrivenInteractionOrigin: NSPoint? {
        get { engineState.suppressMouseDrivenInteractionOrigin }
        nonmutating set { engineState.suppressMouseDrivenInteractionOrigin = newValue }
    }
    var isHoveringNowPlayingIcon: Bool {
        get { engineState.isHoveringNowPlayingIcon }
        nonmutating set { engineState.isHoveringNowPlayingIcon = newValue }
    }
    var showMediaHoverDock: Bool {
        get { engineState.showMediaHoverDock }
        nonmutating set { engineState.showMediaHoverDock = newValue }
    }
}
