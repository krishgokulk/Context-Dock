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
    var results: [SearchResult] = []
    var grouped: GroupedResults = GroupedResults()
    var selectedIndex: Int? = nil
    var revision: Int = 0
    var resultFingerprint: String = ""
    var pinnedResults: [SearchResult] = []
    var pinnedTitle: String? = nil
    var pinnedTypesToExclude: Set<SearchResult.ResultType> = []
    var appPanelAllItems: [SearchResult] = []
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
    /// Truthful, user-visible orchestration activity for Context Dock chat.
    /// This reports app/tool work, never private model reasoning.
    var loadingStatus: String? = nil
    var currentTask: Task<Void, Never>? = nil
    var activeRequestID: UUID? = nil
    var contextExtensions: [ExtensionDiscoveryResult] = []
    var extensionResults: [SearchResult] = []
    var lastAutoRunQuery: String = ""
    var lastAutoRunExtensionID: UUID? = nil
    var lastRunnableQuery: String? = nil
    var appCompletion: AppCompletion? = nil
    var targetApp: ScopedApp? = nil
    var focusedPillIndex: Int? = nil
    var pillNavViaKeyboard: Bool = false
    var chatContextKey: String = ""
    var showResultsPopover: Bool = false
    var showChatPopover: Bool = false
    var chatArmed: Bool = false
    var chatAutoArmedForNoMenuMatch: Bool = false
    var chatDismissed: Bool = false
    var chatDraftAppName: String = ""
    var chatDraftBundleId: String = ""
}

// MARK: - AI Mode

struct AIModeState {
    var isActive: Bool = false
    var messages: [AIChatMessage] = []
    var isLoading: Bool = false
    /// Live agentic-loop status shown beside the typing indicator
    /// ("Searching app tools…", "Running search_items via Artifacts…").
    var loadingStatus: String? = nil
    /// Tool chips collected during the current request, attached to the final answer.
    var pendingToolChips: [String] = []
    /// Minimal DoraX Action Chat execution state (planner stages + discovered routes +
    /// chosen route). Nil when no action is in flight. Deliberately tiny — a launcher
    /// progress strip, not an IDE "thinking" log.
    var actionProgress: ActionProgress? = nil
    var currentTask: Task<Void, Never>? = nil
    var streamingId: UUID? = nil
    var attachments: [URL] = []
    // Selection Scope chat context — the selected text / files / page URL the conversation is
    // grounded in. Injected into every message of the session so the AI always answers about
    // the user's current selection (webpage, document, files, …).
    var selectionText: String? = nil
    var selectionFiles: [URL] = []
    var selectionURL: String? = nil
    // Awaiting user confirmation before sending an AI result via Share (two-step "Send via X?").
    var pendingShare: PendingSelectionShare? = nil
}

struct PendingSelectionShare: Equatable {
    let text: String
    let destination: String
}

/// Tiny planner-progress model for General AI Chat's DoraX Action Chat pipeline. Ordered
/// stage labels with a completed count (first N done, the next is active); an optional
/// discovered-route checklist under "Discovering capabilities"; and the chosen route +
/// reason. Rendered as a compact strip, never a scrolling log.
struct ActionProgress: Equatable {
    var steps: [String] = []
    var completedCount: Int = 0
    var discovered: [String] = []
    var selectedRoute: String? = nil
    var selectedReason: String? = nil
    var failed: Bool = false

    /// Append a stage (if new) and mark everything up to and including the previous one done.
    mutating func advance(to label: String) {
        if let idx = steps.firstIndex(of: label) {
            completedCount = idx
        } else {
            completedCount = steps.count
            steps.append(label)
        }
    }

    /// Mark every stage complete (terminal "Done").
    mutating func finish() { completedCount = steps.count }
}

// MARK: - Frontmost App

struct FrontmostAppState {
    var name: String = ""
    var bundleID: String = ""
    var icon: NSImage? = nil
    var isSectionExpanded: Bool = false
    var lastSwitchDate: Date = .distantPast
}

// MARK: - Active Selection

/// The current meaningful selection the user has in another app.
/// "Meaningful" = >3 chars for text (filters cursor-position noise), any file, any URL.
enum ActiveSelection: Equatable {
    case text(String)
    case files([URL])
    case url(String)

    var label: String {
        switch self {
        case .text(let t): return String(t.prefix(50))
        case .files(let urls):
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files selected"
        case .url(let u): return URL(string: u)?.host ?? String(u.prefix(40))
        }
    }
}

// MARK: - Scoped App

struct ScopedApp {
    var name: String
    var bundleId: String
    var icon: NSImage?
}

extension ScopedApp: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleId == rhs.bundleId && lhs.name == rhs.name
    }
}

// MARK: - App Completion

struct AppCompletion: Equatable {
    var appName: String
    var bundleId: String
    var ghost: String
    var actionQuery: String
}

// MARK: - Global Context Activation

struct GlobalContextActivation: Equatable {
    var autoActivated: Bool
    var frozenText: String?
    var frozenFullText: String?
    var frozenIcon: String?
    var sourceBundleId: String?
    var frozenFilePaths: [String]

    static let manual = GlobalContextActivation(autoActivated: false)

    init(
        autoActivated: Bool,
        frozenText: String? = nil,
        frozenFullText: String? = nil,
        frozenIcon: String? = nil,
        sourceBundleId: String? = nil,
        frozenFilePaths: [String] = []
    ) {
        self.autoActivated = autoActivated
        self.frozenText = frozenText
        self.frozenFullText = frozenFullText
        self.frozenIcon = frozenIcon
        self.sourceBundleId = sourceBundleId
        self.frozenFilePaths = frozenFilePaths
    }
}
