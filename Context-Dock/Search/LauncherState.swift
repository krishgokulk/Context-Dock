// LauncherState.swift
// Context-Dock
//
// Grouped @State value-type structs for LauncherView.
// Each struct corresponds to one @State var; SwiftUI diffs them like any other value type.

import AppKit
import Foundation
import SwiftUI

// MARK: - Search

struct SearchState {
    var query: String = ""
    var lastQuery: String = ""
    var results: [SearchResult] = []
    var grouped: GroupedResults = GroupedResults()
    var selectedIndex: Int? = nil
    var isKeyboardNavigation: Bool = false
    var shouldAutoScroll: Bool = false
    var revision: Int = 0
    var pinnedResults: [SearchResult] = []
    var pinnedTitle: String? = nil
    var pinnedTypesToExclude: Set<SearchResult.ResultType> = []
    var appPanelAllItems: [SearchResult] = []
    var indexedFileResults: [SearchResult] = []
    var isLoadingApps: Bool = false
    var isInSmartMode: Bool = false
    var lastSmartQuery: String = ""
    var isInitialLaunch: Bool = true
    var activeSmartQueryKey: String? = nil
    var contextApp: SearchContextApp? = nil
}

// MARK: - L2

struct L2State {
    var chatMessages: [AIChatMessage] = []
    var handledApprovalIds: Set<UUID> = []
    var terminalDismissed: Bool = false
    var activeDockSessionKey: String? = nil
    var isLoading: Bool = false
    var currentTask: Task<Void, Never>? = nil
    var activeRequestID: UUID? = nil
    var contextExtensions: [ExtensionDiscoveryResult] = []
    var extensionResults: [SearchResult] = []
    var lastAutoRunQuery: String = ""
    var lastAutoRunExtensionID: UUID? = nil
    var lastRunnableQuery: String? = nil
    var appCompletion: (appName: String, bundleId: String, ghost: String, actionQuery: String)? = nil
    var targetApp: (name: String, icon: NSImage?, bundleId: String)? = nil
    var focusedPillIndex: Int? = nil
    var pillNavViaKeyboard: Bool = false
    var chatContextKey: String = ""
    var showResultsPopover: Bool = false
}

// MARK: - AI Mode

struct AIModeState {
    var isActive: Bool = false
    var messages: [AIChatMessage] = []
    var isLoading: Bool = false
    var currentTask: Task<Void, Never>? = nil
    var streamingId: UUID? = nil
    var attachments: [URL] = []
}

// MARK: - Frontmost App

struct FrontmostAppState {
    var name: String = ""
    var bundleID: String = ""
    var icon: NSImage? = nil
    var isSectionExpanded: Bool = false
    var lastSwitchDate: Date = .distantPast
}
