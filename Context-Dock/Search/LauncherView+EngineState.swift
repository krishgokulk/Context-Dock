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
    var clipboardSourceFilterBundleId: String {
        get { engineState.clipboardSourceFilterBundleId }
        nonmutating set { engineState.clipboardSourceFilterBundleId = newValue }
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
    var panelConsoleLinesMap: [String: [(line: String, isCommand: Bool)]] {
        get { engineState.panelConsoleLinesMap }
        nonmutating set { engineState.panelConsoleLinesMap = newValue }
    }
    var panelShowConsoleMap: [String: Bool] {
        get { engineState.panelShowConsoleMap }
        nonmutating set { engineState.panelShowConsoleMap = newValue }
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
    var contextDockChatCapturedText: String? {
        get { engineState.contextDockChatCapturedText }
        nonmutating set { engineState.contextDockChatCapturedText = newValue }
    }
    var contextDockChatFiles: [URL] {
        get { engineState.contextDockChatFiles }
        nonmutating set { engineState.contextDockChatFiles = newValue }
    }
    var finderDesktopSearchPills: [DockPill] {
        get { engineState.finderDesktopSearchPills }
        nonmutating set { engineState.finderDesktopSearchPills = newValue }
    }
    var finderDesktopSearchQuery: String {
        get { engineState.finderDesktopSearchQuery }
        nonmutating set { engineState.finderDesktopSearchQuery = newValue }
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
}
