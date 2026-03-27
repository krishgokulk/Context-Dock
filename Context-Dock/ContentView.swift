//
//  ContentView.swift
//  ILauncher
//
//  Created by Krishgokul on 20/11/2025.
//

import SwiftUI
import AppKit
import AppIntents
import Quartz // For Quick Look
import Combine // For ObservableObject
import FoundationModels
import Contacts
import WebKit // For inline browser in L3
import SwiftTerm // For terminal integration

struct SearchResult: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: NSImage?
    let action: () -> Void
    var score: Double = 0.0
    let type: ResultType
    let filePath: String? // For files and folders
    let contactData: ContactData? // For contacts

    // Unique identifier for usage tracking (e.g., app bundle ID, file path, contact ID)
    var trackingIdentifier: String {
        switch type {
        case .application:
            return "app:\(subtitle)" // subtitle contains the full path
        case .shortcut:
            return "shortcut:\(title)"
        case .file, .folder, .document:
            return "file:\(filePath ?? subtitle)"
        case .contact:
            return "contact:\(contactData?.identifier ?? title)"
        case .calendarEvent:
            return "calendar:\(title)"
        case .reminder:
            return "reminder:\(title)"
        case .note:
            return "note:\(title)"
        case .mail:
            return "mail:\(title)"
        case .photo:
            return "photo:\(title)"
        case .message:
            return "message:\(title)"
        case .extensionCommand:
            return "extension:\(title)"
        case .webSearch:
            return "web:\(title)"
        case .cliTool:
            return "cli:\(title)"
        }
    }

    enum ResultType {
        case application
        case shortcut
        case file
        case folder
        case document
        case contact
        case calendarEvent
        case reminder
        case note
        case mail
        case photo
        case message
        case extensionCommand
        case webSearch
        case cliTool      // installed CLI/TUI tool (from TerminalPackageManager)
    }

    struct ContactData {
        let primaryEmail: String
        let allEmails: [String]
        let primaryPhone: String
        let allPhones: [String]
        let identifier: String
    }
}

// MARK: - Shortcuts Query Helper
class ShortcutsLinkQuery {
    struct ShortcutInfo {
        let name: String
    }
    
    func shortcuts() throws -> [ShortcutInfo] {
        var results: [ShortcutInfo] = []
        
        // Method 1: Try using the shortcuts command-line tool
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["list"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse the output - each line is a shortcut name
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        results.append(ShortcutInfo(name: trimmed))
                    }
                }
            }
            
            if task.terminationStatus == 0 {
                print("✅ Successfully queried shortcuts using CLI tool")
                return results
            }
        } catch {
            print("⚠️ Failed to use shortcuts CLI: \(error)")
        }
        
        // Method 2: Fallback to AppleScript
        print("📝 Trying AppleScript fallback...")
        let script = """
        tell application "Shortcuts Events"
            get name of every shortcut
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let output = scriptObject.executeAndReturnError(&error)
            
            if let error = error {
                print("AppleScript error: \(error)")
                throw NSError(domain: "ShortcutsQuery", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to query shortcuts: \(error)"])
            }
            
            // Parse the AppleScript result
            if output.numberOfItems > 0 {
                for i in 1...output.numberOfItems {
                    if let name = output.atIndex(i)?.stringValue {
                        results.append(ShortcutInfo(name: name))
                    }
                }
            }
        }
        
        return results
    }
}

// MARK: - Fuzzy Matching
struct FuzzyMatcher {
    /// Performs fuzzy matching and returns a score (0.0 = no match, higher = better match)
    static func score(_ query: String, against target: String) -> Double? {
        let query = query.lowercased()
        let targetLower = target.lowercased()

        guard !query.isEmpty else { return nil }
        guard !targetLower.isEmpty else { return nil }

        // Fast path: exact match (case-insensitive)
        if targetLower == query {
            return 1000.0
        }

        // Fast path: starts with query
        if targetLower.hasPrefix(query) {
            // Strong bonus for prefix matches, scaled by coverage
            return 900.0 + Double(query.count) / Double(targetLower.count) * 100
        }

        // Check for acronym match (e.g., "gc" matches "Google Chrome")
        if let acronymScore = checkAcronymMatch(query: query, target: target) {
            return acronymScore
        }

        // Check if all characters in query appear in order in target
        var targetIndex = targetLower.startIndex
        var queryIndex = query.startIndex
        var matchedIndices: [String.Index] = []

        while queryIndex < query.endIndex && targetIndex < targetLower.endIndex {
            if query[queryIndex] == targetLower[targetIndex] {
                matchedIndices.append(targetIndex)
                queryIndex = query.index(after: queryIndex)
            }
            targetIndex = targetLower.index(after: targetIndex)
        }

        // If we didn't match all query characters, no match
        guard queryIndex == query.endIndex else {
            return nil
        }

        // Calculate base score from match ratio
        let matchRatio = Double(query.count) / Double(targetLower.count)
        var score = matchRatio * 100

        // Bonus for consecutive matches (rewards continuous substrings)
        var consecutiveBonus = 0.0
        var consecutiveCount = 0
        for i in 1..<matchedIndices.count {
            let prev = matchedIndices[i - 1]
            let curr = matchedIndices[i]
            if targetLower.distance(from: prev, to: curr) == 1 {
                consecutiveCount += 1
                consecutiveBonus += 15.0 + Double(consecutiveCount) * 2.0 // Escalating bonus
            } else {
                consecutiveCount = 0
            }
        }
        score += consecutiveBonus

        // Bonus for matching at word boundaries
        let words = targetLower.split(separator: " ")
        var wordBoundaryBonus = 0.0
        for word in words {
            let wordStr = String(word)
            if wordStr.hasPrefix(query) {
                // Full word prefix match is very strong
                wordBoundaryBonus += 80.0
                break
            } else if wordStr.contains(query) {
                // Substring within word
                wordBoundaryBonus += 40.0
            }
        }
        score += wordBoundaryBonus

        // Bonus for matching at the very start
        if let firstMatch = matchedIndices.first, firstMatch == targetLower.startIndex {
            score += 40.0
        }

        // Bonus for CamelCase matching (e.g., "gc" matches "googleChrome")
        if let camelScore = checkCamelCaseMatch(query: query, target: target) {
            score += camelScore
        }

        return score
    }

    /// Check if query matches the acronym of target words (e.g., "gc" -> "Google Chrome")
    private static func checkAcronymMatch(query: String, target: String) -> Double? {
        let words = target.split(separator: " ")
        guard words.count >= 2 else { return nil }

        let acronym = words.map { String($0.prefix(1)) }.joined().lowercased()
        if acronym.hasPrefix(query.lowercased()) {
            // Acronym match is very strong
            return 850.0 + Double(query.count) * 10.0
        }
        return nil
    }

    /// Check if query matches CamelCase initials (e.g., "gc" -> "googleChrome")
    private static func checkCamelCaseMatch(query: String, target: String) -> Double? {
        let uppercaseIndices = target.indices.filter { target[$0].isUppercase }
        guard !uppercaseIndices.isEmpty else { return nil }

        let camelAcronym = uppercaseIndices.map { String(target[$0]) }.joined().lowercased()
        if camelAcronym.hasPrefix(query.lowercased()) {
            return 60.0 // Good bonus for camel case match
        }
        return nil
    }
}

struct ShortcutMetadata {
    let acceptsFiles: Bool
    let acceptsText: Bool
    let acceptsImages: Bool
    let acceptsContacts: Bool
    let acceptsPDFs: Bool
    let fileExtensions: [String] // e.g., ["pdf", "docx", "png"]

    func matches(context: UserContext) -> Bool {
        switch context {
        case .filesSelected(let urls):
            if acceptsFiles {
                // Check if any file extension matches
                if fileExtensions.isEmpty { return true }
                return urls.contains { url in
                    let ext = url.pathExtension.lowercased()
                    return fileExtensions.contains(ext)
                }
            }
            if acceptsImages {
                return urls.contains { url in
                    ["jpg", "jpeg", "png", "gif", "heic"].contains(url.pathExtension.lowercased())
                }
            }
            if acceptsPDFs {
                return urls.contains { $0.pathExtension.lowercased() == "pdf" }
            }
            return false
        case .textSelected:
            return acceptsText
        case .url:
            return acceptsText // URLs can be treated as text input
        case .contactSelected:
            return acceptsContacts
        case .appFocused, .none:
            return false
        }
    }
}

// JSON decodable version
struct ShortcutMetadataJSON: Codable {
    let acceptsFiles: Bool
    let acceptsText: Bool
    let acceptsImages: Bool
    let acceptsContacts: Bool
    let acceptsPDFs: Bool
    let fileExtensions: [String]
}

// MARK: - Result Grouping
struct GroupedResults {
    var pinnedResults: [SearchResult] = []
    var pinnedSectionTitle: String?
    var suggestedShortcuts: [SearchResult] = [] // Context-aware suggestions
    var shortcuts: [SearchResult] = []
    var apps: [SearchResult] = []
    var files: [SearchResult] = []
    var contacts: [SearchResult] = []
    var system: [SearchResult] = [] // Calendar, Reminders, Notes, Mail, Messages
    var commands: [SearchResult] = [] // Extension commands
    var webResults: [SearchResult] = [] // Web search results

    var allResults: [SearchResult] {
        pinnedResults + apps + commands + shortcuts + suggestedShortcuts + system + contacts + files + webResults
    }

    var isEmpty: Bool {
        allResults.isEmpty
    }

    mutating func add(_ result: SearchResult, isSuggested: Bool = false) {
        if isSuggested && result.type == .shortcut {
            suggestedShortcuts.append(result)
            return
        }

        switch result.type {
        case .extensionCommand:
            commands.append(result)
        case .shortcut:
            shortcuts.append(result)
        case .application:
            apps.append(result)
        case .file, .folder, .document, .photo:
            files.append(result)
        case .contact:
            contacts.append(result)
        case .calendarEvent, .reminder, .note, .mail, .message:
            system.append(result)
        case .webSearch:
            webResults.append(result)
        case .cliTool:
            apps.append(result)  // CLI tools appear in the Applications section
        }
    }

    var sections: [(String, [SearchResult])] {
        var result: [(String, [SearchResult])] = []
        if !pinnedResults.isEmpty {
            result.append((pinnedSectionTitle ?? "Top Results", pinnedResults))
        }
        if !apps.isEmpty { result.append(("Applications", apps)) }
        if !commands.isEmpty { result.append(("Commands", commands)) }
        if !shortcuts.isEmpty { result.append(("Shortcuts", shortcuts)) }
        if !suggestedShortcuts.isEmpty { result.append(("Suggestions", suggestedShortcuts)) }
        if !system.isEmpty { result.append(("Calendar & Notes", system)) }
        if !contacts.isEmpty { result.append(("Contacts", contacts)) }
        if !files.isEmpty { result.append(("Files & Folders", files)) }
        if !webResults.isEmpty { result.append(("Web Results", webResults)) }
        return result
    }
}

struct LauncherView: View {
    @State private var searchText = ""
    @State private var lastSearchQuery = ""
    @State private var searchResults: [SearchResult] = []
    @State private var groupedResults = GroupedResults()
    @State private var selectedResultIndex: Int? = nil
    @State private var isKeyboardNavigation = false // Track if selection is from keyboard (for auto-scroll)
    @State private var shouldAutoScrollToSelection = false
    @State private var searchResultsRevision = 0
    @State private var pinnedResults: [SearchResult] = []
    @State private var pinnedResultsTitle: String?
    @State private var pinnedResultTypesToExclude: Set<SearchResult.ResultType> = []
    // Full unfiltered list for the active app panel (calendar/notes/etc.) — used for in-panel filtering
    @State private var appPanelAllItems: [SearchResult] = []
    // rem-powered Reminders panel chat
    @State private var remPanelChatMessages: [AIChatMessage] = []
    @State private var remPanelIsProcessing: Bool = false
    // Tool-removal cleanup banner
    @State private var removedToolBannerName: String? = nil
    // Per-panel terminal history — keyed by activeSmartQueryKey or searchContextApp bundleID
    @State private var panelConsoleLinesMap: [String: [(line: String, isCommand: Bool)]] = [:]
    @State private var panelShowConsoleMap:  [String: Bool] = [:]
    @State private var panelConsoleHeight: CGFloat = 160
    // Per-panel embedded PTY terminals (real SwiftTerm instances)
    @State private var panelTerminalControllers: [String: TerminalHostController] = [:]
    // Computed helpers — always work off the active panel key
    private var activeConsoleKey: String {
        if let k = activeSmartQueryKey { return k }
        if let ctx = searchContextApp {
            return ctx.appPath.isEmpty ? ctx.name : ctx.appPath
        }
        return "default"
    }
    private var panelConsoleLines: [(line: String, isCommand: Bool)] {
        panelConsoleLinesMap[activeConsoleKey] ?? []
    }
    private var showPanelConsole: Bool {
        panelShowConsoleMap[activeConsoleKey] ?? false
    }
    /// Returns (or lazily creates) the real PTY terminal for a given panel key.
    private func panelTerminal(for key: String) -> TerminalHostController {
        if let existing = panelTerminalControllers[key] { return existing }
        let controller = TerminalHostController(isPanel: true)
        panelTerminalControllers[key] = controller
        return controller
    }
    // Live Panel (right side) — hidden by default, slides in like Claude's artifact panel
    enum LivePanelMode: Equatable {
        case results([ResultEntry])                  // AI-returned file/item list
        case terminal                                // embedded SwiftTerm PTY
        case nowPlaying                              // music player HUD
        case filePreview(url: URL)                  // inline QL preview for AI-created files
        case youtubeResults([YouTubeSearchResult])  // YouTube search results

        struct ResultEntry: Equatable, Identifiable {
            var id: String { path.isEmpty ? name : path }
            var name: String
            var path: String        // empty for non-file items
            var subtitle: String    // size, type, etc.
            var icon: String        // SF symbol name
        }

        static func == (lhs: LivePanelMode, rhs: LivePanelMode) -> Bool {
            switch (lhs, rhs) {
            case (.results, .results): return true
            case (.terminal, .terminal): return true
            case (.nowPlaying, .nowPlaying): return true
            case (.filePreview(let a), .filePreview(let b)): return a == b
            case (.youtubeResults, .youtubeResults): return true
            default: return false
            }
        }
    }
    @State private var livePanelMode: LivePanelMode = .results([])
    @State private var livePanelVisible: Bool = false   // drives the slide-in animation
    @State private var panelTerminalHost: TerminalHostController? = nil
    @ObservedObject private var workerPool = BackgroundWorkerPool.shared
    @ObservedObject private var miniPlayer = MiniPlayerController.shared
    @State private var nowPlayingTitle: String = ""
    @State private var nowPlayingArtist: String = ""
    @State private var nowPlayingAlbum: String = ""
    @State private var nowPlayingIsPlaying: Bool = false
    @State private var nowPlayingTimer: Timer? = nil
    @State private var remPanelAITask: Task<Void, Never>? = nil
    @State private var remIsInstalled: Bool? = nil   // nil = not yet checked
    @State private var l2ContextExtensions: [ExtensionDiscoveryResult] = []
    @State private var l2ExtensionResults: [SearchResult] = []
    @State private var lastL2AutoRunQuery = ""
    @State private var lastL2AutoRunExtensionID: UUID? = nil
    @State var selectedYouTubeResult: YouTubeSearchResult? = nil
    @State private var l2ChatMessages: [AIChatMessage] = []
    @State private var l2IsLoading = false
    @State private var l2CurrentTask: Task<Void, Never>? = nil
    @State private var isVisible = false
    @State private var allApplications: [SearchResult] = []
    @State private var allShortcuts: [SearchResult] = []
    @State private var indexedFileResults: [SearchResult] = []
    @State private var allContacts: [SearchResult] = []
    @State private var systemDataResults: [SearchResult] = []
    @ObservedObject private var contactManager = ContactSearchManager.shared
    @ObservedObject private var systemDataManager = SystemDataSearchManager.shared
    @ObservedObject private var terminalBridge = TerminalAIBridge.shared
    @ObservedObject private var adapterManager = AppAdapterManager.shared

    @ObservedObject private var notificationManager = ILauncherNotificationManager.shared
    @State private var showNotificationPanel = false
    @State private var runningRegularApps: [NSRunningApplication] = []
    @StateObject private var taskExecutor = L2AITaskExecutor.shared
    @StateObject private var selectionModel = SelectionObserverModel()
    @State private var isLoadingApps = false
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    @State private var showFolderPreview = false
    @State private var folderPreviewPath: String?
    @State private var folderPreviewSelectedFile: String? // Track selected file in folder preview = nil

    // App Data Panel — set to app key ("calendar","notes"…) when a smart query is active
    @State private var activeSmartQueryKey: String? = nil
    // Spotlight-style context: set when user presses Tab/→ on an app result
    @State private var searchContextApp: SearchContextApp? = nil
    @State private var showContactPreview = false
    @State private var contactPreviewData: SearchResult? = nil
    @State private var showWebSearch = false
    @State private var webSearchQuery: String = ""
    @State private var quickLookDataSource: QuickLookDataSource? = nil
    @State private var quickLookEventMonitor: Any? = nil // Monitor for Space key Quick Look
    @State private var browserShortcutMonitor: Any? = nil // L3: Cmd+T/W/R etc. forwarded to browser
    @State private var showShortcutSheet = false          // Cmd long-press shortcut overlay
    @State private var shortcutSheetFocusedIdx: Int? = nil // Up/Down nav inside shortcut sheet
    @State private var cmdHoldTask: Task<Void, Never>? = nil
    @State private var cmdHoldMonitor: Any? = nil
    @State private var pillNavViaKeyboard = false          // true only during arrow-key navigation
    // AI-powered favourite matching
    @State private var isAIMode = false // New: AI mode toggle
    @State private var aiChatMessages: [AIChatMessage] = [] // Chat history
    @State private var isAILoading = false // AI response loading state
    @State private var currentAITask: Task<Void, Never>? = nil // Current AI request task
    @State private var frontmostAppName: String = ""
    @State private var pendingTerminalCommand: PendingTerminalCommand?
    @State private var frontmostAppIcon: NSImage? = nil
    @State private var frontmostAppBundleID: String = ""
    @State private var isFrontmostSectionExpanded: Bool = false
    @FocusState private var isSearchFieldFocused: Bool
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var fileIndexManager = FileIndexManager.shared
    @Environment(\.openSettings) private var openSettings
    var onClose: () -> Void

    /// Resolved color scheme from user's appearance preference
    private var resolvedColorScheme: ColorScheme? {
        switch settings.appearanceMode {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil // follow system
        }
    }

    // Context-aware features
    @State private var currentContext: UserContext = .none
    /// Live AX-read snapshot: URL, window title, selection, focused element role.
    /// Refreshed on every context-dock open and frontmost-app change.
    @State private var axContext: AXContext = .empty
    @State private var selectedFiles: Set<UUID> = [] // Multi-selection support
    @State private var shortcutMetadataCache: [String: ShortcutMetadata] = [:] // Cache for shortcut capabilities
    @State private var isContextExpanded: Bool = false // Smooth expansion state for context awareness
    /// Stable key identifying what context the current l2ChatMessages are "about".
    /// When this changes, we clear stale chat history so the AI focuses on the new context.
    @State private var chatContextKey: String = ""

    // AI Extension Suggestions (different from AI Chat mode)
    @State private var showAIExtensionSuggestions = false
    @State private var aiExtensionSuggestions: [SuggestedExtension] = [] // Extension chips for AI mode

    // Search bar collapse/expand state
    @State private var isSearchBarExpanded = true
    @State private var isHoveringSearchIcon = false
    @State private var isHoveringInputField = false // Track if mouse is over input field area
    @State private var collapseTimer: Task<Void, Never>? = nil

    // Layer memory — restored when closing chat
    @State private var chatReturnContextInDock = false
    @State private var chatReturnBrowserLayer = false
    // Suppress hover-expand briefly after a layer switch (prevents phantom hover fires on icon change)
    @State private var suppressHoverExpand = false
    /// True during the opening animation (~0.25s) — suppresses updateWindowSize so the
    /// launch animation can't be interrupted by a SwiftUI layout pass firing a resize.
    @State private var suppressOpenResize = false

    // Context in dock state
    @State private var showContextInDock = false

    // Track if user has sent a message in current session
    @State private var hasUserSentMessageInCurrentSession = false

    // User profile picture
    @State private var userProfileImage: NSImage?

    // Swipe gesture monitor
    @State private var swipeGestureMonitor: Any?
    @State private var accumulatedSwipeDeltaY: CGFloat = 0
    @State private var accumulatedSwipeDeltaX: CGFloat = 0
    @State private var isHoveringDockArea = false // Track if mouse is over dock area (pinned apps/shortcuts)
    @State private var isSharingSheetActive = false // True while share sheet is open — suppresses our arrow-key monitor
    @State private var axContextRefreshTimer: Timer? = nil

    // Live menu-bar items loaded from frontmost app on dock open
    @State private var liveMenuItems: [AXMenuItem] = []
    @State private var menuLoadTask: Task<Void, Never>? = nil
    // Cross-app menu items loaded lazily when query targets a specific app
    @State private var crossAppMenuItems: [AXMenuItem] = []
    @State private var crossAppMenuTask: Task<Void, Never>? = nil
    @State private var crossAppMenuTargetPID: pid_t = 0
    // Context-sensitive pills — items that just became enabled after a selection change
    @State private var contextMenuPills: [AXMenuItem] = []
    @State private var previousEnabledIDs: Set<UUID> = []
    // Arrow-key pill navigation: index into the unified pill list
    @State private var focusedPillIndex: Int? = nil

    // Browser layer state (3rd layer - swipe up from shortcuts)
    @State private var showBrowserLayer = false
    @State private var browserSearchText = ""
    // Removed: @State private var recentWebSearches - now using settings.recentWebSearches
    @State private var browserSearchResults: [SearchResult] = [] // L3 inline search results
    @State private var currentBrowserQuery: String = "" // Current search query for L3
    @FocusState private var isBrowserFieldFocused: Bool

    // Smart search state tracking
    @State private var isInSmartMode = false // Track if we're currently in smart search mode
    @State private var lastSmartQuery: String = "" // Track last query that triggered smart mode
    @State private var showInlineBrowser = false // Show inline browser in L3
    @State private var inlineBrowserQuery = "" // Query for inline browser
    @State private var isInlineBrowserLoading = true

    // Browser content for right side (bookmarks, quick tabs, pinned sites)
    @State private var browserBookmarks: [BrowserItem] = []
    @State private var quickTabs: [BrowserItem] = []
    @State private var pinnedWebsites: [BrowserItem] = []


    // Removed: Smart positioning logic - results always show below dock now
    @State private var isInitialLaunch = true // Track first appearance to skip animation

    // Combined search pool
    private var allItems: [SearchResult] {
        var items = allApplications + allShortcuts
        if settings.enableSpotlightSearch {
            items += indexedFileResults
        }
        // Add contacts and system data to search pool
        items += allContacts
        items += systemDataResults
        // Add installed CLI tools so users can open them as panels
        items += cliToolSearchResults
        // Add Homebrew as a built-in panel if brew is installed
        if let brewResult = homebrewSearchResult { items.append(brewResult) }
        return items
    }

    /// Synthetic Homebrew search result — shows up when user types "brew" or "homebrew".
    private var homebrewSearchResult: SearchResult? {
        let brewPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            ? "/opt/homebrew/bin/brew"
            : FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
            ? "/usr/local/bin/brew" : nil
        guard let path = brewPath else { return nil }
        let icon = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Homebrew")
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

    /// TUI tools + user-pinned CLI tools appear in search results.
    private var cliToolSearchResults: [SearchResult] {
        let pinned = settings.pinnedCLITools
        return TerminalPackageManager.shared.packages
            .filter { TerminalAIBridge.shared.isTUICommand($0.command) || pinned.contains($0.command) }
            .map { pkg in
                let isTUI = TerminalAIBridge.shared.isTUICommand(pkg.command)
                let symbolName = isTUI ? "terminal.fill" : "arrow.right.square.fill"
                let icon = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: pkg.name)
                return SearchResult(
                    title: pkg.name,
                    subtitle: pkg.installedPath ?? pkg.command,
                    icon: icon,
                    action: {},   // overridden by activateSearchContext
                    type: .cliTool,
                    filePath: pkg.installedPath,
                    contactData: nil
                )
            }
    }
    
    // Calculate dynamic height based on content
    private var calculatedHeight: CGFloat {
        // Pinned apps are now rendered inline as a horizontal icon strip next to the search bar,
        // so they should not contribute extra height.
        let pinnedAppsHeight: CGFloat = 0
        let statusBarHeight: CGFloat = settings.enableStatusBar ? 45 : 0
        let contextHeight: CGFloat = (settings.enableFrontmostDetection && isFrontmostSectionExpanded) ? 45 : 0
        let searchBarHeight: CGFloat = isSearchBarExpanded ? 70 : 55 // Matches actual pill height
        let indexingBarHeight: CGFloat = fileIndexManager.progress.isIndexing ? 30 : 0
        let l2ChatHeight: CGFloat = {
            guard showContextInDock && !showBrowserLayer else { return 0 }
            if l2ChatMessages.isEmpty {
                return l2IsLoading ? 50 : 0
            }
            var total: CGFloat = 0
            for message in l2ChatMessages {
                var messageHeight: CGFloat = 80
                if message.content.contains("```") {
                    let codeBlockCount = message.content.components(separatedBy: "```").count - 1
                    messageHeight = 150 + CGFloat(codeBlockCount / 2) * 200
                } else if message.content.count > 200 {
                    let lines = message.content.components(separatedBy: "\n").count
                    messageHeight = CGFloat(lines * 20 + 40)
                }
                total += messageHeight
            }
            total = min(total, 500)
            if l2IsLoading {
                total += 50
            }
            return total
        }()

        // Context chip height (only in L1 search mode with context and suggestions)
        let contextChipHeight: CGFloat = {
            // Not applicable in AI mode, L2 context mode, or L3 browser layer
            if isAIMode || showContextInDock || showBrowserLayer { return 0 }
            
            // If context awareness is disabled, return 0
            guard settings.enableContextAIExtensions else { return 0 }
            
            // Only expand if we have meaningful context
            let hasContext: Bool = {
                switch currentContext {
                case .filesSelected(let urls): return !urls.isEmpty
                case .textSelected(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .url(let urlString): return !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .appFocused, .contactSelected, .none: return false
                }
            }()

            if !hasContext { return 0 }

            // Check if we have any matching shortcuts — passive only (not while typing)
            let hasSuggestions: Bool = {
                guard searchText.isEmpty else { return false }
                return allShortcuts.contains { shortcut in
                    guard let metadata = shortcutMetadataCache[shortcut.title] else { return false }
                    return metadata.matches(context: currentContext)
                }
            }()

            return hasSuggestions ? 70 : 0
        }()

        // AI mode has different height calculation
        if isAIMode {
            let aiChatHeight: CGFloat = aiChatMessages.isEmpty ? 0 : min(CGFloat(aiChatMessages.count) * 80, 400)
            let aiLoadingHeight: CGFloat = isAILoading ? 50 : 0
            return statusBarHeight + pinnedAppsHeight + searchBarHeight + aiChatHeight + aiLoadingHeight + 10
        }

        // Folder preview height calculation
        if showFolderPreview {
            let folderPreviewHeight: CGFloat = 500 // Folder preview content height
            return statusBarHeight + pinnedAppsHeight + searchBarHeight + folderPreviewHeight + 10
        }

        // App panel (calendar/reminders/notes/etc.) — split view with fixed height
        if activeSmartQueryKey != nil {
            let panelHeight: CGFloat = 480 // header + split content area
            return statusBarHeight + pinnedAppsHeight + searchBarHeight + panelHeight + 10
        }

        // L2 Context layer with chat - calculate height for L2 chat messages
        if showContextInDock && !showBrowserLayer && (!l2ChatMessages.isEmpty || l2IsLoading) {
            let l2TotalChatHeight = l2ChatHeight

            // If we also have search results, add them too
            if !searchResults.isEmpty {
                let resultRowHeight: CGFloat = 50
                let resultsHeight = min(CGFloat(searchResults.count) * resultRowHeight, 450)
                return statusBarHeight + pinnedAppsHeight + searchBarHeight + l2TotalChatHeight + resultsHeight + 10
            } else {
                return statusBarHeight + pinnedAppsHeight + searchBarHeight + l2TotalChatHeight + 10
            }
        }

        // L3 Browser layer height calculation
        if showBrowserLayer {
            if showInlineBrowser {
                // Inline browser showing - needs full height
                let browserHeight: CGFloat = 400 // Header + WebView + Button
                return statusBarHeight + pinnedAppsHeight + searchBarHeight + browserHeight + 10
            } else if !searchText.isEmpty {
                // Search results showing in L3
                let resultsHeight: CGFloat = 350 // Recent searches + bookmarks + search button
                return statusBarHeight + pinnedAppsHeight + searchBarHeight + resultsHeight + 10
            } else {
                // Empty L3 - just dock
                return statusBarHeight + pinnedAppsHeight + searchBarHeight + 10
            }
        }

        if !searchResults.isEmpty {
            let resultRowHeight: CGFloat = 50
            let resultsHeight = min(CGFloat(searchResults.count) * resultRowHeight, 450)
            return statusBarHeight + contextHeight + pinnedAppsHeight + searchBarHeight + contextChipHeight + indexingBarHeight + resultsHeight + 10
        } else if isLoadingApps {
            return statusBarHeight + contextHeight + pinnedAppsHeight + searchBarHeight + contextChipHeight + indexingBarHeight + 60
        } else {
            return statusBarHeight + contextHeight + pinnedAppsHeight + searchBarHeight + contextChipHeight + indexingBarHeight
        }
    }

    private var calculatedWidth: CGFloat {
        let expandedWidth: CGFloat = 700
        // Count total visible icons: pinned + deduped running apps
        let pinnedPaths = Set(settings.pinnedApps.map { $0.path })
        let pinnedBundleIds = Set(settings.pinnedApps.compactMap { $0.bundleIdentifier })
        let extraRunning = settings.showRunningAppsInBar ? runningRegularApps.filter { app in
            guard let path = app.bundleURL?.path else { return false }
            return !pinnedPaths.contains(path)
                && (app.bundleIdentifier == nil || !pinnedBundleIds.contains(app.bundleIdentifier!))
        }.count : 0
        let totalIconCount = max(settings.pinnedApps.count + extraRunning, 1)
        let iconBlockWidth: CGFloat = CGFloat(totalIconCount) * 56
        let collapsedWidth: CGFloat = min(700, max(380, 220 + iconBlockWidth))

        let shouldCollapse = !isSearchBarExpanded &&
            searchText.isEmpty &&
            searchResults.isEmpty &&
            !isAIMode &&
            !showBrowserLayer &&
            !showFolderPreview &&
            activeSmartQueryKey == nil

        return shouldCollapse ? collapsedWidth : expandedWidth
    }

    private var contentWithModifiers: some View {
        mainContent
            .frame(width: calculatedWidth)  // Increased from 600 to 700
            // In dock mode anchor content to bottom so dock bar stays fixed while results grow upward.
            // In normal mode anchor to top so results grow downward.
            .frame(height: calculatedHeight, alignment: settings.effectiveDockAtBottom ? .bottom : .top)
            .background {
                backgroundView
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shouldShowBackground)
            }
            .scaleEffect(isVisible ? 1.0 : 0.95)
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isVisible)
            .onChange(of: searchResults.count) { _, _ in updateWindowSize() }
            .onChange(of: aiChatMessages.count) { _, _ in updateWindowSize() }
            .onChange(of: isAILoading) { _, _ in updateWindowSize() }
            .onChange(of: isAIMode) { _, _ in
                suppressHoverExpand = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.suppressHoverExpand = false }
                updateWindowSize()
            }
            .onChange(of: isFrontmostSectionExpanded) { _, _ in updateWindowSize() }
            .onChange(of: isSearchBarExpanded) { _, _ in updateWindowSize() }
            .onChange(of: l2ChatMessages.count) { _, _ in updateWindowSize() }
            .onChange(of: l2IsLoading) { _, _ in updateWindowSize() }
            .onChange(of: showContextInDock) { _, newValue in
                // Block expand during layer transition (icon swap fires phantom hover)
                suppressHoverExpand = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.suppressHoverExpand = false }
                if newValue {
                    // Refresh AX context snapshot (URL, selection, window title, focused role)
                    if let app = AppDelegate.shared?.previousFrontmostApp {
                        AXContextReader.shared.refresh(from: app)
                        axContext = AXContextReader.shared.current
                    }
                    // Reload dock tool extensions so newly installed ones show immediately
                    Task { await L2ExtensionManager.shared.loadExtensions() }
                    updateL2ContextExtensions()
                    // Auto-focus first pill when dock opens
                    let q0 = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let initialPills = buildDockPills(query: q0)
                    focusedPillIndex = initialPills.isEmpty ? nil : 0

                    // Load live menu items from frontmost app only (primary context)
                    // Uses structural cache: second open of same app is instant.
                    menuLoadTask?.cancel()
                    menuLoadTask = Task.detached(priority: .userInitiated) {
                        guard let app = await AppDelegate.shared?.previousFrontmostApp,
                              !app.isTerminated else { return }
                        let pid  = app.processIdentifier
                        let name = app.localizedName ?? ""
                        var items = AXMenuReader.shared.cachedAllMenuItems(for: pid, maxDepth: 6)
                        for i in items.indices {
                            items[i].sourcePID     = pid
                            items[i].sourceAppName = name
                        }
                        await MainActor.run {
                            self.liveMenuItems = items
                            // Seed the enabled-ID baseline so first delta is meaningful
                            self.previousEnabledIDs = Set(items.filter(\.isEnabled).map(\.id))
                            // Sync recentApps from Apple menu "Recent Items > Applications"
                            // — more authoritative than activation-order tracking
                            self.syncRecentAppsFromAppleMenu(items)
                        }
                    }
                    // Start AX selection observer for the frontmost app
                    if let pid = AppDelegate.shared?.previousFrontmostApp?.processIdentifier {
                        selectionModel.start(for: pid)
                    }
                    // Refresh running apps list (for Layer 1 bar) — off main thread
                    let apps = NSWorkspace.shared.runningApplications.filter {
                        $0.activationPolicy == .regular &&
                        $0.bundleIdentifier != Bundle.main.bundleIdentifier
                    }
                    runningRegularApps = apps
                    // Refresh AX context periodically while dock is open so pills update as user interacts
                    axContextRefreshTimer?.invalidate()
                    axContextRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [self] _ in
                        guard self.showContextInDock else { return }
                        if let app = AppDelegate.shared?.previousFrontmostApp {
                            AXContextReader.shared.refresh(from: app)
                            let newCtx = AXContextReader.shared.current
                            // Only trigger re-render if something meaningful changed
                            if newCtx.selectedFilePaths != self.axContext.selectedFilePaths
                                || newCtx.selectedText != self.axContext.selectedText
                                || newCtx.currentURL != self.axContext.currentURL {
                                self.axContext = newCtx
                            }
                        }
                    }
                } else {
                    axContextRefreshTimer?.invalidate()
                    axContextRefreshTimer = nil
                    selectionModel.stop()
                    l2ExtensionResults = []
                    l2ChatMessages = []
                    l2IsLoading = false
                    searchResults = []
                    selectedResultIndex = nil
                    liveMenuItems = []
                    crossAppMenuItems = []
                    crossAppMenuTargetPID = 0
                    contextMenuPills = []
                    previousEnabledIDs = []
                    focusedPillIndex = nil
                    menuLoadTask?.cancel()
                    crossAppMenuTask?.cancel()
                }
                updateWindowSize()
            }
            .onChange(of: showBrowserLayer) { _, newValue in
                if newValue {
                    l2ExtensionResults = []
                    l2ChatMessages = []
                    l2IsLoading = false
                    searchResults = []
                    selectedResultIndex = nil
                    // Block expand during layer transition (globe ↔ magnifying glass icon swap)
                    suppressHoverExpand = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.suppressHoverExpand = false }
                }
                updateWindowSize()
            }
            // AX selection observer fired — diff enabled states and surface context pills
            .onChange(of: selectionModel.changeCount) { _, _ in
                handleSelectionChange()
            }
    }

    private var contentLifecycleView: some View {
        contentWithModifiers
            .blur(radius: showWebSearch ? 3 : 0)
            .onAppear {
                // Load running apps immediately so the dock bar shows them on first launch
                runningRegularApps = NSWorkspace.shared.runningApplications.filter {
                    $0.activationPolicy == .regular &&
                    $0.bundleIdentifier != Bundle.main.bundleIdentifier
                }

                loadApplicationsInBackground()
                initializeFileIndex()
                activateSearchField()
                setupQuickLookEventMonitor()
                setupSwipeGestureMonitor()     // swipe up/down for layer switching
                setupDockPillKeyMonitor()         // Left/Right/Enter for dock pill navigation
                setupBrowserShortcutPassthrough() // Cmd+T/W/R forwarded to browser in L3
                setupCmdHoldMonitor()             // Cmd held 1.5s → shortcut sheet
                loadShortcutMetadata()

                // Check permissions on startup
                _ = contactManager.checkPermission()

                // Start observing app switches if enabled (frontmost app already detected in ILauncherApp)
                if settings.enableFrontmostDetection {
                    startObservingAppSwitches()
                }

                // Detect initial context
                detectAndUpdateContext()

                // Reset chat visibility flag on launch
                hasUserSentMessageInCurrentSession = false

                // Load user profile picture
                loadUserProfilePicture()

                // Update smart positioning on launch (with slight delay to ensure window is positioned)
                DispatchQueue.main.async {
                    updateResultsPosition()
                }

                // Also update after a short delay to catch final window position
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    updateResultsPosition()
                    // Mark initial launch complete after position is set
                    isInitialLaunch = false
                }
            }
            .onDisappear {
                removeQuickLookEventMonitor()
                removeSwipeGestureMonitor() // Cleanup swipe gesture monitor
                stopObservingAppSwitches()
                // Cancel collapse timer when window closes
                collapseTimer?.cancel()
            }
    }

    private var contentSettingsHandlersView: some View {
        contentLifecycleView
            .onChange(of: settings.enableFrontmostDetection) { oldValue, newValue in
                if newValue {
                    // Start observing when enabled
                    startObservingAppSwitches()
                } else {
                    // Clear frontmost app data when disabled
                    frontmostAppName = ""
                    frontmostAppIcon = nil
                    frontmostAppBundleID = ""
                    stopObservingAppSwitches()
                }
            }
            .onChange(of: settings.enableContextAIExtensions) { oldValue, newValue in
                // Smooth transition when context awareness is toggled
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isContextExpanded = newValue

                    if newValue {
                        // When enabled, detect context immediately
                        detectAndUpdateContext()
                    } else {
                        // When disabled, clear context
                        currentContext = .none
                        l2ContextExtensions = []
                    }
                }
            }
            .onChange(of: settings.effectiveDockAtBottom) { oldValue, newValue in
                // Update positioning immediately when setting changes
                updateResultsPosition()

                // Reposition window based on new setting
                guard let window = (NSApp.keyWindow as? KeyableWindow) ??
                        (NSApp.windows.first(where: { ($0 as? KeyableWindow) != nil && $0.isVisible }) as? KeyableWindow),
                      let screen = window.screen ?? NSScreen.main else { return }

                let screenFrame = screen.visibleFrame
                let currentFrame = window.frame

                let newY: CGFloat
                if newValue {
                    // Move to bottom and enable bottom anchoring
                    newY = screenFrame.minY + 10
                    window.anchorAtBottom = true
                } else {
                    // Move to upper third and disable bottom anchoring
                    newY = screenFrame.maxY - screenFrame.height / 3
                    window.anchorAtBottom = false
                }

                let newFrame = NSRect(x: currentFrame.origin.x, y: newY, width: currentFrame.width, height: currentFrame.height)
                window.setFrame(newFrame, display: true, animate: true)
            }
    }

    private var contentNotificationHandlersView: some View {
        contentSettingsHandlersView
            .onReceive(NotificationCenter.default.publisher(for: .launcherWindowOpened)) { _ in
                // Block resize calls during the opening animation so it can't be interrupted
                suppressOpenResize = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    suppressOpenResize = false
                    // Catch any resize request that was suppressed during the animation
                    // (e.g. detectAndUpdateContext expanding the app panel).
                    updateWindowSize()
                }

                let openingForDockContext = AppDelegate.shared?.isDockContextMode ?? false
                if !openingForDockContext {
                    // Normal open → always reset to L1 (dock + pinned apps), like Spotlight
                    searchText = ""
                    searchResults = []
                    selectedResultIndex = nil
                    isAIMode = false
                    showBrowserLayer = false
                    showFolderPreview = false
                    // In L2-only mode, always open directly into the context dock
                    showContextInDock = settings.l2OnlyMode
                    // Also clear app-panel state so calculatedHeight returns base height
                    activeSmartQueryKey = nil
                    searchContextApp = nil
                    isInSmartMode = false
                    appPanelAllItems = []
                }
                // If opening for dock context, the .activateContextDock notification fires 50ms later

                activateSearchField()
                print("🔍 [ContentView] Window opened (dockContext=\(openingForDockContext)), detecting context...")
                detectAndUpdateContext()
                // Read rich AX context (URL, selection, window title) from frontmost app
                if let app = AppDelegate.shared?.previousFrontmostApp {
                    AXContextReader.shared.refresh(from: app)
                    axContext = AXContextReader.shared.current
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToL1)) { _ in
                // Launcher shortcut pressed while in dock context mode — instant switch, no animation
                // In l2OnlyMode the context dock is permanent; just clear search text
                guard !settings.l2OnlyMode else { searchText = ""; return }
                showContextInDock = false
                isAIMode = false
                searchText = ""
                searchResults = []
                selectedResultIndex = nil
                showBrowserLayer = false
                showFolderPreview = false
                activateSearchField()
            }
            .onChange(of: searchResults.count) { oldValue, newValue in
                // Update positioning when results appear/change (L1 only — L2 never has results)
                if newValue > 0 && !isL2ContextActive {
                    updateResultsPosition()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .userContextDetected)) { notification in
                // Receive pre-detected context from AppDelegate (before ILauncher becomes frontmost)
                if let context = notification.userInfo?["context"] as? UserContext {
                    currentContext = context
                    print("✅ [ContentView] Received pre-detected context: \(context.description)")

                    // Load extension suggestions if in AI mode
                    if isAIMode {
                        loadAIExtensionSuggestions()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .overlayAskAboutSelection)) { notification in
                guard let text = notification.userInfo?["text"] as? String else { return }
                searchText = text
                isAIMode = true
                showContextInDock = false
                showBrowserLayer = false
                AppDelegate.shared?.showLauncher()
            }
            .onReceive(NotificationCenter.default.publisher(for: .frontmostAppDetected)) { notification in
                // Receive frontmost app info from ILauncherApp
                if let userInfo = notification.userInfo,
                   let appName = userInfo["name"] as? String,
                   let bundleID = userInfo["bundleID"] as? String {

                    // Check if app changed (not just re-detection of same app)
                    let appChanged = !frontmostAppBundleID.isEmpty && frontmostAppBundleID != bundleID

                    frontmostAppName = appName
                    frontmostAppBundleID = bundleID

                    // Get icon from bundle ID
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                        frontmostAppIcon = app.icon
                    }

                    print("📱 Received frontmost app: \(appName) (\(bundleID))")

                    // Reload menu whenever dock is visible (or when app actually changed)
                    if showContextInDock {
                        if appChanged {
                            // Clear L2 chat for fresh context when switching apps
                            l2ChatMessages = []
                            l2IsLoading = false
                            l2CurrentTask?.cancel()
                            l2CurrentTask = nil
                            updateL2Results([])
                        }
                        // Always reload — covers first open (appChanged=false) AND app switches
                        if let newApp = NSWorkspace.shared.runningApplications
                            .first(where: { $0.bundleIdentifier == bundleID }) {
                            reloadMenuForApp(newApp)
                        }
                    }

                    // Re-detect full context (text selection, etc.) from the new frontmost app
                    // This ensures VS Code / editor selections show up as context actions
                    detectAndUpdateContext()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .servicesOpenWithFiles)) { notification in
                // Receive files shared via Services/Share Sheet
                if let urls = notification.userInfo?["urls"] as? [URL], !urls.isEmpty {
                    print("📁 [Services] Received \(urls.count) file(s) via Share Sheet:")
                    for url in urls {
                        print("   📄 \(url.lastPathComponent)")
                    }
                    
                    // Update context with the shared files
                    currentContext = .filesSelected(urls)
                    updateL2ContextExtensions()
                    print("✅ [Services] Context updated with shared files")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .servicesOpenWithText)) { notification in
                // Receive text shared via Services/Share Sheet
                if let text = notification.userInfo?["text"] as? String, !text.isEmpty {
                    print("📝 [Services] Received text via Share Sheet: \(text.prefix(100))...")
                    
                    // Update context with the shared text
                    currentContext = .textSelected(text)
                    updateL2ContextExtensions()
                    print("✅ [Services] Context updated with shared text")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAIExtensions)) { _ in
                // Toggle AI Extension Suggestions overlay
                detectAndUpdateContext() // Update context before showing
                withAnimation(.spring(response: 0.3)) {
                    showAIExtensionSuggestions.toggle()
                }
                print("🤖 [AI Extensions] Toggled: \(showAIExtensionSuggestions), Context: \(currentContext.description)")
            }
            .onReceive(NotificationCenter.default.publisher(for: .activateContextDock)) { _ in
                // Instant switch — no animation so the layer change feels immediate
                showBrowserLayer = false
                isAIMode = false
                showContextInDock = true
            }
            .onChange(of: currentContext.description) { _, _ in
                // Reload AI extension suggestions when context changes (only if in AI mode)
                if isAIMode {
                    loadAIExtensionSuggestions()
                }

                // Trigger smooth expansion when context is detected
                if settings.enableContextAIExtensions {
                    let hasValidContext: Bool = {
                        switch currentContext {
                        case .filesSelected(let urls): return !urls.isEmpty
                        case .textSelected(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        case .url(let urlString): return !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        default: return false
                        }
                    }()

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        isContextExpanded = hasValidContext
                    }
                }

                // Clear stale chat when the selected content changes so AI focuses on the new context.
                // App-level changes are already handled by .frontmostAppDetected; this covers file/text/URL switches.
                let newKey = contextIdentityKey(currentContext)
                if newKey != "none" && !chatContextKey.isEmpty && newKey != chatContextKey && !l2ChatMessages.isEmpty {
                    print("🔄 [Context] Content changed (\(chatContextKey) → \(newKey)) — clearing L2 chat")
                    l2ChatMessages = []
                    l2IsLoading = false
                    l2CurrentTask?.cancel()
                    l2CurrentTask = nil
                    updateL2Results([])
                }
                if newKey != "none" {
                    chatContextKey = newKey
                }
            }
    }

    private var contentKeyHandlersView: some View {
        contentNotificationHandlersView
            .onExitCommand {
                if showInlineBrowser {
                    // Back from inline browser
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        showInlineBrowser = false
                        inlineBrowserQuery = ""
                    }
                } else if showBrowserLayer {
                    // Close browser layer (L3 → L2)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        showBrowserLayer = false
                    }
                } else if showAIExtensionSuggestions {
                    withAnimation(.spring(response: 0.3)) {
                        showAIExtensionSuggestions = false
                    }
                } else if showFolderPreview {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showFolderPreview = false
                    }
                } else {
                    onClose()
                }
            }
            .onKeyPress(.upArrow) {
                if !showFolderPreview {
                    navigateResults(direction: -1)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.downArrow) {
                if !showFolderPreview {
                    navigateResults(direction: 1)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.space) {
                // Close contact preview if it's showing
                if showContactPreview {
                    withAnimation {
                        showContactPreview = false
                        contactPreviewData = nil
                    }
                    return .handled
                }

                // Only handle space for Quick Look when the search field is NOT focused
                // This allows typing spaces in the search field
                if !showFolderPreview && !isSearchFieldFocused && selectedResultIndex != nil && !searchResults.isEmpty {
                    quickLookSelectedItem()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [.init("y")], phases: .down) { keyPress in
                // Cmd+Y for Quick Look (like Finder)
                if keyPress.modifiers.contains(.command) && !showFolderPreview && selectedResultIndex != nil && !searchResults.isEmpty {
                    quickLookSelectedItem()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.return) {
                if !showFolderPreview {
                    // Any context panel (app, file, folder, contact, etc.) routes Enter → AI chat
                    let isAIAppPanel = searchContextApp != nil
                    if isAIAppPanel && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        handleRemPanelQuery()
                        return .handled
                    } else if isL2ContextActive {
                        let filtered = l2FilteredContextActions
                        if !filtered.isEmpty {
                            // Filter mode: Enter executes the top matching action
                            executeL2FilteredItem(filtered[0])
                        } else {
                            enforceL2ContextMode()
                            handleL2Query()
                        }
                    } else if isAIMode {
                        submitAIQuery()
                    } else if showBrowserLayer {
                        // L3: Open search in inline dock browser
                        if showInlineBrowser {
                            // Already showing browser, ignore
                            return .handled
                        }
                        openInDockBrowser()
                    } else {
                        // L1/L2: Execute selected result
                        executeSelectedResult()
                    }
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.tab) {
                // Tab → always open context panel for selected result (files, folders, apps, etc.)
                if let idx = selectedResultIndex, idx < searchResults.count {
                    let result = searchResults[idx]
                    activateSearchContext(for: result)
                    return .handled
                }

                // Tab = toggle chat layer. Close L2/L3 first for a clean chat layer.
                guard settings.enableAIMode else {
                    return .ignored
                }

                // Clear results when switching modes (outside animation to prevent jumping)
                searchResults = []
                selectedResultIndex = nil
                searchText = ""
                currentAITask?.cancel()
                isAILoading = false
                hasUserSentMessageInCurrentSession = false

                if !isAIMode {
                    // Remember layer before entering chat
                    chatReturnContextInDock = showContextInDock
                    chatReturnBrowserLayer = showBrowserLayer
                }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isAIMode.toggle()
                    if isAIMode {
                        showContextInDock = false
                        showBrowserLayer = false
                    } else {
                        showContextInDock = chatReturnContextInDock
                        showBrowserLayer = chatReturnBrowserLayer
                    }
                }

                // Load extension suggestions when entering AI mode
                if isAIMode {
                    // Don't re-detect context here! We already have it from the previous app via notification
                    print("🔍 [Tab] Entering AI mode, using existing context: \(currentContext.description)")
                    loadAIExtensionSuggestions()
                    // Cancel collapse timer in AI mode
                    collapseTimer?.cancel()
                } else {
                    // Start collapse timer when exiting AI mode
                    if searchText.isEmpty {
                        startCollapseTimer()
                    }
                }

                return .handled
            }
            .onKeyPress(.escape) {
                // Folder preview: ESC exits back to normal search
                if showFolderPreview {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFolderPreview = false
                        folderPreviewPath = nil
                        folderPreviewSelectedFile = nil
                        isInSmartMode = false
                        lastSmartQuery = ""
                        searchResults = []
                        selectedResultIndex = nil
                    }
                    return .handled
                }
                // App panel (calendar/notes/etc.) or search context: ESC exits back to normal search
                if activeSmartQueryKey != nil || searchContextApp != nil {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        activeSmartQueryKey = nil
                        searchContextApp = nil
                        isInSmartMode = false
                        lastSmartQuery = ""
                        clearPinnedResults()
                        searchResults = []
                        systemDataResults = []
                        selectedResultIndex = nil
                        // Save current chat before closing, then reset in-memory
                        if let key = activeSmartQueryKey {
                            AppPanelChatStore.shared.save(remPanelChatMessages, for: key)
                        }
                        remPanelChatMessages = []
                        remPanelIsProcessing = false
                        remIsInstalled = nil
                    }
                    return .handled
                }
                return .ignored
            }
            // Right Arrow → context panel for any selected result
            .onKeyPress(.rightArrow) {
                guard let idx = selectedResultIndex,
                      idx < searchResults.count,
                      searchText.isEmpty || !isSearchFieldFocused
                else { return .ignored }
                activateSearchContext(for: searchResults[idx])
                return .handled
            }
    }

    var body: some View {
        ZStack {
            contentKeyHandlersView

            // Contact Preview Overlay
            if showContactPreview, let contact = contactPreviewData {
                ContactPreviewCard(contact: contact, isPresented: $showContactPreview)
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
                        currentContext: $currentContext,
                        isVisible: $showAIExtensionSuggestions
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }

            // App Adapter Action Approval Overlay
            if let req = adapterManager.pendingApproval {
                AdapterApprovalOverlay(request: req)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(10)
            }

            // Web Search Overlay
            if showWebSearch {
                ZStack {
                    // Dim background
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3)) {
                                showWebSearch = false
                            }
                        }

                    // Web Search View with WebKit
                    WebSearchView(
                        query: webSearchQuery,
                        userScripts: settings.webExtensions.filter { $0.enabled }.map { $0.script },
                        isPresented: $showWebSearch
                    )
                    .frame(width: 900)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .onReceive(TerminalAIBridge.shared.$pendingApproval) { pending in
            if let pending = pending {
                if activeSmartQueryKey != nil {
                    // Panel active — show inline approval card in chat instead of popup
                    let risk = pending.classification.riskLevel.displayName
                    remPanelChatMessages.append(AIChatMessage(
                        role: .approval,
                        content: pending.command,
                        structuredData: "\(pending.purpose)|||/\(risk)"
                    ))
                } else {
                    openCommandApprovalWindow(pending: pending)
                }
            } else {
                // Close popup if one was open (for non-panel contexts)
                CommandApprovalWindowHost.close()
            }
        }
    }

    private func openCommandApprovalWindow(pending: TerminalAIBridge.PendingCommand) {
        CommandApprovalWindowHost.close()
        let view = CommandApprovalView(
            command: pending.command,
            classification: pending.classification,
            purpose: pending.purpose,
            onApprove: { approvedCommand in
                TerminalAIBridge.shared.approveCommand(approvedCommand)
            },
            onDeny: {
                TerminalAIBridge.shared.denyCommand()
            }
        )
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: controller)
        win.title = "Terminal Command Approval"
        win.styleMask = [.titled, .closable]
        win.level = .floating
        let isCritical = pending.classification.riskLevel == .critical
        win.setContentSize(NSSize(width: 520, height: isCritical ? 460 : 410))
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        CommandApprovalWindowHost.window = win
        // When the user closes via the X button, treat as deny
        win.delegate = CommandApprovalWindowHost.shared
    }

    // Helper for sheet binding
    private struct SheetItem: Identifiable {
        let id = UUID()
        let pending: TerminalAIBridge.PendingCommand
    }

    private struct PendingTerminalCommand {
        let command: String
        let purpose: String
    }


    private var mainContent: some View {
        VStack(spacing: 0) {
            topBarSection           // Combined status bar + frontmost toggle
            frontmostAppSection     // Frontmost app context below (collapsible)
            aiExtensionQuickActions // Quick Actions for AI mode (ABOVE search input!)
            searchBarWithPinnedApps // Search bar + pinned apps + results/chat (all inside expanding dock)
        }
        .background(Color.clear)  // Ensure no opaque fill above GlassBackground
    }
    
    // MARK: - Top Bar Section (Status extensions only, no frontmost toggle)
    @ViewBuilder
    private var topBarSection: some View {
        // Removed frontmost toggle - shortcuts now show inline below search bar
        EmptyView()
    }

    // MARK: - Frontmost App Section (Below status bar)
    @ViewBuilder
    private var frontmostAppSection: some View {
        // Context shortcuts now show inside dock on swipe up, not here
        EmptyView()
    }

    @ViewBuilder
    private func appShortcutChip(shortcut: SearchResult) -> some View {
        Button(action: {
            // Execute the shortcut WITH CONTEXT
            executeResult(shortcut)
        }) {
            HStack(spacing: 3) {
                if let icon = shortcut.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                }
                Text(shortcut.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.08))
            .foregroundStyle(.primary)
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help(shortcut.subtitle) // Show full subtitle on hover
    }
    
    @ViewBuilder
    private var indexingProgressSection: some View {
        if fileIndexManager.progress.isIndexing {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                
                Text("Indexing files...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                
                Text("\(fileIndexManager.progress.filesIndexed) files")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue)
                
                Spacer()
                
                Text("\(Int(fileIndexManager.progress.progressPercentage))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.05))
        }
    }
    
    // Search bar with integrated pinned apps
    private var searchBarWithPinnedApps: some View {
        searchBarSection
            .fixedSize(horizontal: false, vertical: false)
            .popover(isPresented: $showShortcutSheet, arrowEdge: .bottom) {
                ShortcutSheetView(
                    items: liveMenuItems,
                    appName: AppDelegate.shared?.previousFrontmostApp?.localizedName ?? "App",
                    onSelect: { item in
                        showShortcutSheet = false
                        shortcutSheetFocusedIdx = nil
                        let pid = item.sourcePID != 0 ? item.sourcePID
                            : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
                        let sourceApp = NSWorkspace.shared.runningApplications
                            .first { $0.processIdentifier == pid && !$0.isTerminated }
                        guard pid != 0 else { return }
                        let path = item.path
                        let sc   = item.shortcutChar
                        let mod  = item.shortcutModifiers
                        Task {
                            sourceApp?.activate(options: [.activateIgnoringOtherApps])
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            await Task.detached(priority: .userInitiated) {
                                if let ch = sc, !ch.isEmpty {
                                    AXMenuReader.shared.executeShortcut(char: ch, modifiers: mod, in: pid)
                                } else {
                                    AXMenuReader.shared.clickMenuItem(path: path, in: pid)
                                }
                            }.value
                        }
                    },
                    focusedIdx: $shortcutSheetFocusedIdx
                )
            }
    }

    @ViewBuilder
    private var pinnedAppsSection: some View {
        EmptyView()
    }

    // MARK: - Dock Context & Apps Helper Views

    private var hasContextToShow: Bool {
        guard settings.enableContextAIExtensions else { return false }

        // Always show for any real frontmost app — live menu bar pills work universally
        if let frontApp = AppDelegate.shared?.previousFrontmostApp,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            return true
        }

        // Fallback: AX-readable context (URL, text selection, files)
        switch currentContext {
        case .filesSelected(let urls): return !urls.isEmpty
        case .textSelected(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .url(let urlString): return !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    @ViewBuilder
    private var pinnedAppsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Pinned apps
                ForEach(settings.pinnedApps) { app in
                    Button(action: {
                        launchPinnedApp(app)
                    }) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .help(app.name)
                    .contextMenu {
                        Button("Unpin from Launcher") {
                            settings.unpinApp(app)
                        }

                        Divider()

                        Button("Open") {
                            launchPinnedApp(app)
                        }

                        if app.type == .folder {
                            Button("Show in Finder") {
                                NSWorkspace.shared.selectFile(app.path, inFileViewerRootedAtPath: "")
                            }
                        }
                    }
                    .onDrag {
                        NSItemProvider(object: app.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: PinnedAppDropDelegate(
                        item: app,
                        pinnedApps: $settings.pinnedApps,
                        settings: settings
                    ))
                }

                // Running apps (when enabled) — shown after pinned, deduplicated
                if settings.showRunningAppsInBar {
                    let pinnedPaths = Set(settings.pinnedApps.map { $0.path })
                    let pinnedBundleIds = Set(settings.pinnedApps.compactMap { $0.bundleIdentifier })
                    let runningApps = runningRegularApps.filter { app in
                        guard let path = app.bundleURL?.path else { return false }
                        return !pinnedPaths.contains(path)
                            && (app.bundleIdentifier == nil || !pinnedBundleIds.contains(app.bundleIdentifier!))
                    }

                    if !runningApps.isEmpty && !settings.pinnedApps.isEmpty {
                        Divider()
                            .frame(height: 28)
                            .padding(.horizontal, 2)
                    }

                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button(action: {
                            app.activate(options: .activateIgnoringOtherApps)
                            onClose()
                        }) {
                            ZStack(alignment: .bottomTrailing) {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .opacity(0.8)
                                }
                                // Green running dot
                                Circle()
                                    .fill(.green)
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5))
                                    .offset(x: 2, y: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(app.localizedName ?? "")
                        .contextMenu {
                            Button("Pin to Launcher") {
                                if let path = app.bundleURL?.path,
                                   let name = app.localizedName {
                                    settings.pinApp(name: name, path: path,
                                                    bundleIdentifier: app.bundleIdentifier)
                                }
                            }
                            Divider()
                            Button("Quit \(app.localizedName ?? "App")", role: .destructive) {
                                app.terminate()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contextChipsInDock: some View {
        // Combine frontmost app shortcuts and context-aware shortcuts
        let allContextShortcuts: [SearchResult] = {
            var shortcuts: [SearchResult] = []

            // Add context-aware shortcuts
            if !searchText.isEmpty && !groupedResults.suggestedShortcuts.isEmpty {
                shortcuts.append(contentsOf: groupedResults.suggestedShortcuts)
            } else if searchText.isEmpty && hasContextToShow {
                let contextMatched = allShortcuts.filter { shortcut in
                    guard let metadata = shortcutMetadataCache[shortcut.title] else { return false }
                    return metadata.matches(context: currentContext)
                }
                shortcuts.append(contentsOf: contextMatched)
            }

            // Remove duplicates by id
            var seen = Set<String>()
            return shortcuts.filter { shortcut in
                guard !seen.contains(shortcut.id.uuidString) else { return false }
                seen.insert(shortcut.id.uuidString)
                return true
            }
        }()

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allContextShortcuts) { shortcut in
                    Button(action: {
                        executeResult(shortcut)
                    }) {
                        HStack(spacing: 6) {
                            if let icon = shortcut.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                            }
                            Text(shortcut.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)
                    .help(shortcut.subtitle)
                }
            }
        }
    }

    // Check if AI extensions are available to show
    private var hasAIExtensionsToShow: Bool {
        return isAIMode && settings.enableContextAIExtensions && !aiExtensionSuggestions.isEmpty
    }

    private var hasL2ExtensionsToShow: Bool {
        return settings.enableContextAIExtensions && !l2ContextExtensions.isEmpty
    }

    private var isL2ContextActive: Bool {
        // L2 is active whenever the context dock is showing, we're not in pure AI mode,
        // and we're not in L3 browser layer. L3 must stay independent from L2.
        showContextInDock && !isAIMode && !showBrowserLayer
    }

    private func enforceL2ContextMode() {
        if showBrowserLayer {
            showBrowserLayer = false
        }
        if showInlineBrowser {
            showInlineBrowser = false
            inlineBrowserQuery = ""
        }
    }

    @ViewBuilder
    private var aiExtensionsInDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(aiExtensionSuggestions) { suggestion in
                    AIExtensionChipButton(
                        suggestion: suggestion,
                        context: currentContext,
                        aiChatMessages: $aiChatMessages
                    )
                }
            }
        }
    }

    // ── L2 Panel Quick Action Pills ─────────────────────────────────────────
    /// Quick actions from all user-created panels, shown as floating pills in L2 mode.
    /// Groups by panel key and shows up to 6 most recently used.
    private var l2PanelQuickActions: [AppShortcut] {
        let allKeys = AppPanelChatStore.shared.allPanelKeys()
        let frontApp = frontmostAppName.lowercased()
        // Prioritise panels matching the current frontmost app, then rest
        var keys = allKeys.filter { $0.localizedCaseInsensitiveContains(frontApp) && !frontApp.isEmpty }
        keys += allKeys.filter { !($0.localizedCaseInsensitiveContains(frontApp) && !frontApp.isEmpty) }
        // Gather shortcuts for these panel keys (max 8)
        var result: [AppShortcut] = []
        for key in keys {
            let shortcuts = settings.shortcuts(for: key)
            result.append(contentsOf: shortcuts)
            if result.count >= 8 { break }
        }
        return Array(result.prefix(8))
    }

    @ViewBuilder
    private var l2QuickActionPills: some View {
        let pills = l2PanelQuickActions
        if !pills.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pills) { sc in
                        Button { executeAppShortcut(sc) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: sc.iconName)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(sc.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    /// L2Extensions from L2ExtensionManager that match the current frontmost app.
    private var frontmostAppL2Extensions: [L2Extension] {
        // Use frontmostAppName (set from last non-ILauncher activation) or fall back to current workspace app
        let appName: String
        let bundleID: String
        if !frontmostAppName.isEmpty {
            appName = frontmostAppName
            bundleID = frontmostAppBundleID
        } else if let ws = NSWorkspace.shared.frontmostApplication,
                  let name = ws.localizedName,
                  !(ws.bundleIdentifier ?? "").contains("ILauncher") {
            appName = name
            bundleID = ws.bundleIdentifier ?? ""
        } else {
            return []
        }
        let appLower = appName.lowercased()
        let bundleLower = bundleID.lowercased()
        return L2ExtensionManager.shared.extensions.filter { ext in
            guard !ext.contextApps.isEmpty else { return false }
            // Check ALL contextApps entries (app name OR bundle ID match)
            return ext.contextApps.contains { ctx in
                let ctxLower = ctx.lowercased()
                return ctxLower == appLower
                    || ctxLower.contains(appLower)
                    || appLower.contains(ctxLower)
                    || (!bundleLower.isEmpty && (ctxLower == bundleLower || ctxLower.contains(bundleLower)))
            }
        }
    }

    // MARK: - Context Dock Filter (type to find actions)

    private struct L2FilteredItem {
        let id: String
        let icon: String
        let name: String
        let isExtension: Bool
    }

    private var l2FilteredContextActions: [L2FilteredItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let appKey = activeSmartQueryKey ?? settings.autoDetectedAppKey ?? ""
        var results: [L2FilteredItem] = []
        for sc in settings.shortcuts(for: appKey) where sc.name.lowercased().contains(q) {
            results.append(L2FilteredItem(id: "sc_\(sc.id)", icon: sc.iconName, name: sc.name, isExtension: false))
        }
        for tool in frontmostAppL2Extensions where tool.displayName.lowercased().contains(q) || tool.toolName.lowercased().contains(q) {
            results.append(L2FilteredItem(id: "ext_\(tool.toolName)", icon: tool.icon, name: tool.displayName, isExtension: true))
        }
        return results
    }

    private func executeL2FilteredItem(_ item: L2FilteredItem) {
        if item.isExtension {
            let toolName = String(item.id.dropFirst(4)) // strip "ext_"
            guard let tool = frontmostAppL2Extensions.first(where: { $0.toolName == toolName }) else { return }
            l2ChatMessages.append(AIChatMessage(role: .user, content: tool.displayName))
            l2IsLoading = true
            Task {
                let (success, output) = await L2ExtensionManager.shared.execute(toolName: tool.toolName, arguments: [:])
                await MainActor.run {
                    let content = success
                        ? (output.isEmpty ? "✅ \(tool.displayName) done." : output)
                        : "❌ \(tool.displayName) failed: \(output)"
                    l2ChatMessages.append(AIChatMessage(role: .assistant, content: content))
                    l2IsLoading = false
                }
            }
        } else {
            let scIdStr = String(item.id.dropFirst(3)) // strip "sc_"
            let appKey = activeSmartQueryKey ?? settings.autoDetectedAppKey ?? ""
            if let sc = settings.shortcuts(for: appKey).first(where: { $0.id.uuidString == scIdStr }) {
                executeAppShortcut(sc)
            }
        }
        searchText = ""
    }


    // MARK: - Unified dock pill list (drives both rendering and keyboard navigation)

    /// A lightweight token for each pill currently visible in the dock.
    struct DockPill: Identifiable {
        let id: String
        let name: String
        let icon: String
        let accentColorName: String?
        let badge: String?           // path parent e.g. "View", "File"
        let execute: () -> Void
        var isSeparator: Bool = false   // if true: renders as "|" divider, not tappable
        var isFavourited: Bool = false   // starred pill — shown first, marked with ★
        var menuItemName: String = ""    // raw menu item title used for favourite toggling
        var sourceBundleId: String = ""  // which app's menu this belongs to
        var isShareAction: Bool = false  // tap → NSSharingServicePicker anchored above pill row
    }

    // MARK: - Finder selected-file context pills

    /// When Finder is frontmost and files are selected, generate instant-action pills
    /// for those files so they appear *before* the generic adapter pills.
    func buildFinderFilePills(query q: String) -> [DockPill] {
        guard axContext.bundleId == "com.apple.finder",
              !axContext.selectedFilePaths.isEmpty else { return [] }
        let paths = axContext.selectedFilePaths
        let count = paths.count
        let first = paths[0]
        let firstName = URL(fileURLWithPath: first).lastPathComponent
        let label = count == 1 ? firstName : "\(count) items selected"
        let ext   = URL(fileURLWithPath: first).pathExtension.lowercased()

        // Pills that always make sense for any selection
        var pills: [DockPill] = []

        func add(_ id: String, _ name: String, _ icon: String, _ color: String, _ action: @escaping () -> Void) {
            if !q.isEmpty && !name.lowercased().contains(q) { return }
            pills.append(DockPill(id: "finder-ctx-\(id)", name: name, icon: icon,
                                  accentColorName: color, badge: label, execute: action))
        }

        add("ql", "Quick Look", "eye", "blue") {
            NSWorkspace.shared.activateFileViewerSelecting(paths.compactMap { URL(fileURLWithPath: $0) })
        }
        add("open", "Open", "arrow.up.right.square", "blue") {
            for p in paths { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        }
        add("reveal", "Show in Finder", "folder", "gray") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
        }
        add("copypath", "Copy Path", "doc.on.clipboard", "teal") {
            let pb = NSPasteboard.general; pb.clearContents()
            pb.setString(paths.joined(separator: "\n"), forType: .string)
        }
        add("share", "Share…", "square.and.arrow.up", "blue") {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            let picker = NSSharingServicePicker(items: urls)
            // Suppress our arrow-key interceptor so the share sheet gets them
            isSharingSheetActive = true
            picker.show(relativeTo: .zero, of: NSApp.keyWindow?.contentView ?? NSView(), preferredEdge: .minY)
            // Watch for the sheet to close and re-enable interception
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // The picker doesn't have a close callback via delegate on all macOS versions,
                // so poll briefly then restore — the sheet is modal enough that keyboard
                // focus returns to our window when it dismisses.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    isSharingSheetActive = false
                }
            }
        }
        add("trash", "Move to Trash", "trash", "red") {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            try? FileManager.default.trashItem(at: urls[0], resultingItemURL: nil)
            if urls.count > 1 { for u in urls.dropFirst() { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) } }
        }

        // Extension-aware pills
        let imageExts = ["jpg","jpeg","png","gif","heic","tiff","bmp","webp","svg"]
        let videoExts = ["mp4","mov","m4v","avi","mkv","wmv"]
        let archiveExts = ["zip","tar","gz","bz2","xz","7z","rar"]
        let textExts   = ["txt","md","markdown","rtf","csv","json","xml","yaml","yml","toml","log"]
        let pdfExts    = ["pdf"]

        func openInApp(_ fileURL: URL, appName: String) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", appName, fileURL.path]
            try? proc.run()
        }

        if imageExts.contains(ext) {
            add("preview-img", "Open in Preview", "photo", "purple") {
                openInApp(URL(fileURLWithPath: first), appName: "Preview")
            }
        }
        if videoExts.contains(ext) {
            add("play", "Play in QuickTime", "play.circle", "red") {
                openInApp(URL(fileURLWithPath: first), appName: "QuickTime Player")
            }
        }
        if pdfExts.contains(ext) {
            add("preview-pdf", "Open in Preview", "doc.richtext", "red") {
                openInApp(URL(fileURLWithPath: first), appName: "Preview")
            }
        }
        if archiveExts.contains(ext) {
            add("unzip", "Unarchive", "archivebox.circle", "yellow") {
                let dir = URL(fileURLWithPath: first).deletingLastPathComponent().path
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", first, "-d", dir]
                try? proc.run()
            }
        }
        if textExts.contains(ext) {
            add("texteditor", "Open in TextEdit", "doc.plaintext", "gray") {
                openInApp(URL(fileURLWithPath: first), appName: "TextEdit")
            }
        }
        return pills
    }

    // MARK: - Cross-app / clipboard / session pill helpers

    /// Pills for apps that can receive the current context (URL, text, file).
    /// Delegates to CrossAppRouter for capability-aware, content-type routing.
    func buildCrossAppPills(query q: String) -> [DockPill] {
        guard settings.crossAppPills else { return [] }
        let runningIds = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
        )
        let routed = CrossAppRouter.shared.buildPills(
            context: axContext,
            runningBundleIds: runningIds,
            query: q
        )
        return routed.compactMap { pill in
            if !q.isEmpty && !pill.label.lowercased().contains(q.lowercased()) { return nil }
            return DockPill(
                id: "cross-\(pill.bundleId)",
                name: pill.label,
                icon: pill.icon,
                accentColorName: pill.badgeColor,
                badge: nil,
                execute: pill.action
            )
        }
    }

    /// Pills derived from the current clipboard content.
    func buildClipboardPills(query q: String) -> [DockPill] {
        guard settings.clipboardAwarePills else { return [] }
        let pb = NSPasteboard.general
        var pills: [DockPill] = []

        // URL on clipboard
        if let urlStr = pb.string(forType: .string), let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true {
            let label = "Open Clipboard URL"
            if q.isEmpty || label.lowercased().contains(q) || "clipboard".contains(q) {
                pills.append(DockPill(id: "clip-url", name: label, icon: "link",
                                      accentColorName: "blue", badge: "Clipboard",
                                      execute: { NSWorkspace.shared.open(url) }))
            }
            let label2 = "Copy Clipboard URL"
            if q.isEmpty || label2.lowercased().contains(q) {
                pills.append(DockPill(id: "clip-copy-url", name: label2, icon: "doc.on.clipboard",
                                      accentColorName: "blue", badge: "Clipboard",
                                      execute: {
                    let p = NSPasteboard.general; p.clearContents(); p.setString(urlStr, forType: .string)
                }))
            }
        } else if let text = pb.string(forType: .string), !text.isEmpty {
            // Plain text on clipboard
            let preview = String(text.prefix(30)).replacingOccurrences(of: "\n", with: " ")
            let label = "Use: \"\(preview)\""
            if q.isEmpty || label.lowercased().contains(q) || "clipboard".contains(q) {
                pills.append(DockPill(id: "clip-text", name: label, icon: "doc.on.clipboard",
                                      accentColorName: "yellow", badge: "Clipboard",
                                      execute: {
                    // Re-paste into frontmost app
                    if let app = AppDelegate.shared?.previousFrontmostApp {
                        app.activate(options: .activateIgnoringOtherApps)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            let src = CGEventSource(stateID: .hidSystemState)
                            let vKey: CGKeyCode = 9 // 'v'
                            CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)?.flags = .maskCommand
                            CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)?.post(tap: .cgSessionEventTap)
                            CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)?.post(tap: .cgSessionEventTap)
                        }
                    }
                }))
            }
        }

        // File URL(s) on clipboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let label = "Open \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) Files")"
            if q.isEmpty || label.lowercased().contains(q) {
                let captured = urls
                pills.append(DockPill(id: "clip-files", name: label, icon: "doc",
                                      accentColorName: "green", badge: "Clipboard",
                                      execute: { NSWorkspace.shared.activateFileViewerSelecting(captured) }))
            }
        }
        return pills
    }

    /// Detect current work session from running apps and re-order adapter actions.
    func sessionRankedAdapterActions(base: [AdapterAction]) -> [AdapterAction] {
        guard settings.sessionDetectionPills else { return base }
        let runningIds = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        // Session profiles: bundles that signal a session type, and action keywords to boost
        let devBundles   = ["com.apple.dt.Xcode","com.microsoft.VSCode","com.jetbrains","io.cursor","com.sublimetext","com.github.atom","com.panic.Nova"]
        let browseBundles = ["com.apple.Safari","com.google.Chrome","org.mozilla.firefox","com.microsoft.edgemac"]
        let commsBundles  = ["com.apple.MobileSMS","com.tinyspeck.slackmacgap","com.microsoft.teams","com.discord","com.apple.mail"]

        let isDev    = devBundles.contains   { b in runningIds.contains { $0.hasPrefix(b) } }
        let isBrowse = browseBundles.contains { b in runningIds.contains { $0.hasPrefix(b) } }
        let isComms  = commsBundles.contains  { b in runningIds.contains { $0.hasPrefix(b) } }

        let boostKeywords: [String]
        if isDev        { boostKeywords = ["build","run","debug","test","deploy","commit","push","pull"] }
        else if isBrowse { boostKeywords = ["open","browse","search","bookmark","read","save"] }
        else if isComms  { boostKeywords = ["send","share","copy","message","paste","email"] }
        else             { return base }

        return base.sorted { a, b in
            let aBoost = boostKeywords.contains { a.name.lowercased().contains($0) }
            let bBoost = boostKeywords.contains { b.name.lowercased().contains($0) }
            if aBoost != bBoost { return aBoost }
            return false
        }
    }

    /// If `q` starts with a known recent/running app name, returns (that app, remainder query).
    /// e.g. "safari tab" → (safariApp, "tab")   "xcode build" → (xcodeApp, "build")
    // MARK: - Instant menu reload on app switch

    /// Called immediately when the frontmost app changes while the dock is open.
    /// Cancels any in-flight menu load and starts a fresh one for `app`.
    private func reloadMenuForApp(_ app: NSRunningApplication) {
        guard showContextInDock, !app.isTerminated else { return }
        let pid  = app.processIdentifier
        let name = app.localizedName ?? ""

        menuLoadTask?.cancel()
        contextMenuPills   = []
        previousEnabledIDs = []

        menuLoadTask = Task.detached(priority: .userInitiated) {
            var items = AXMenuReader.shared.cachedAllMenuItems(for: pid, maxDepth: 6)
            for i in items.indices {
                items[i].sourcePID     = pid
                items[i].sourceAppName = name
            }
            await MainActor.run {
                self.liveMenuItems      = items
                self.previousEnabledIDs = Set(items.filter(\.isEnabled).map(\.id))
                self.syncRecentAppsFromAppleMenu(items)
            }
        }

        // Restart observer for the new app
        selectionModel.start(for: pid)

        // Refresh AX context snapshot
        AXContextReader.shared.refresh(from: app)
        axContext = AXContextReader.shared.current
    }

    // MARK: - Apple menu recent apps sync

    /// Reads "Recent Items > Applications" from the already-loaded liveMenuItems and
    /// updates AppDelegate.recentApps with running apps that match — giving us the
    /// same list macOS itself tracks, not just apps activated while our dock was open.
    private func syncRecentAppsFromAppleMenu(_ items: [AXMenuItem]) {
        // Apple menu items: path[0] == "" (the  symbol), path[1] == "Recent Items"
        let recentNames = items
            .filter { $0.path.count >= 2 && $0.path[0].isEmpty && $0.path[1] == "Recent Items" }
            .map    { $0.title.replacingOccurrences(of: ".app", with: "") }
            .filter { !$0.isEmpty && $0 != "Clear Menu" }

        guard !recentNames.isEmpty else { return }

        let running = NSWorkspace.shared.runningApplications
        let frontPID = AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0

        // Match names to running processes, preserving Apple menu order, skip frontmost & self
        let matched: [NSRunningApplication] = recentNames.compactMap { name in
            running.first {
                $0.activationPolicy == .regular
                && !$0.isTerminated
                && $0.processIdentifier != frontPID
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && ($0.localizedName ?? "") == name
            }
        }

        // Deduplicate and update
        var seen = Set<pid_t>()
        let deduped = matched.filter { seen.insert($0.processIdentifier).inserted }
        AppDelegate.shared?.setRecentAppsFromMenu(Array(deduped.prefix(5)))
    }

    // MARK: - Selection-change handler

    /// Called (debounced 200ms) whenever AXObserver detects a selection/focus change
    /// in the frontmost app. Re-reads only `kAXEnabled` for all cached menu items,
    /// computes the delta (newly enabled items), and surfaces them as context pills.
    private func handleSelectionChange() {
        guard showContextInDock, !liveMenuItems.isEmpty else { return }

        // Re-read enabled states — one attribute call per item, no tree traversal
        let enabledMap = AXMenuReader.shared.refreshEnabledStates(for: liveMenuItems)

        // Apply updates in-place
        var updated = liveMenuItems
        for i in updated.indices {
            if let enabled = enabledMap[updated[i].id] {
                updated[i].isEnabled = enabled
            }
        }

        // Compute delta: items that just became enabled
        let newEnabledIDs = Set(updated.filter(\.isEnabled).map(\.id))
        let deltaIDs      = newEnabledIDs.subtracting(previousEnabledIDs)
        let delta         = updated.filter { deltaIDs.contains($0.id) && !$0.isAppleMenu }
            .sorted { ($0.shortcutChar != nil ? 0 : 1) < ($1.shortcutChar != nil ? 0 : 1) }

        previousEnabledIDs = newEnabledIDs
        liveMenuItems      = updated

        // Keep top 6 newly-enabled items as context pills
        contextMenuPills = Array(delta.prefix(6))

        // Also refresh AX context snapshot so selectedText / selectedFilePaths are current
        if let app = AppDelegate.shared?.previousFrontmostApp {
            AXContextReader.shared.refresh(from: app)
            let newCtx = AXContextReader.shared.current
            if newCtx.selectedFilePaths != axContext.selectedFilePaths
                || newCtx.selectedText  != axContext.selectedText {
                axContext = newCtx
            }
        }
    }

    // MARK: - Share sheet

    /// Shows NSSharingServicePicker anchored above the pill row,
    /// using the current AX context (selected files, URL, or text).
    /// Sets shareSheetVisible = true so arrow keys are passed through to the picker.
    private func showShareSheetForContext() {
        var items: [Any] = axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        if items.isEmpty, let urlStr = axContext.currentURL, let u = URL(string: urlStr) {
            items.append(u)
        }
        if items.isEmpty, let text = axContext.selectedText, !text.isEmpty {
            items.append(text)
        }
        if items.isEmpty {
            // Fallback: show picker with app URL so at least something appears
            if let app = AppDelegate.shared?.previousFrontmostApp,
               let bid = app.bundleIdentifier,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                items = [url]
            } else { return }
        }
        // Show share picker passively — does NOT block pill navigation.
        // User selects a service with the mouse; left/right arrows still move between pills.
        let picker = NSSharingServicePicker(items: items)
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                  let view   = window.contentView else { return }
            let rect = NSRect(x: window.frame.width / 2 - 60, y: 52, width: 120, height: 1)
            picker.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        }
    }

    private func detectCrossAppQuery(_ q: String) -> (NSRunningApplication, String)? {
        guard !q.isEmpty, let delegate = AppDelegate.shared else { return nil }
        let recentApps = delegate.recentApps.filter { !$0.isTerminated }
        let frontPID   = delegate.previousFrontmostApp?.processIdentifier ?? 0
        for app in recentApps {
            guard app.processIdentifier != frontPID else { continue }
            let name = (app.localizedName ?? "").lowercased()
            guard !name.isEmpty else { continue }
            // Require a space after the app name so single-word queries like "centre"
            // never accidentally match a recent app whose name starts with "cent" etc.
            if q.hasPrefix(name + " ") {
                let remainder = String(q.dropFirst(name.count + 1))
                return (app, remainder)
            }
            // Also match shortened names: "safari close tab" matches "Safari Technology Preview"
            let firstWord = name.components(separatedBy: " ").first ?? name
            if firstWord.count >= 3, q.hasPrefix(firstWord + " ") {
                let remainder = String(q.dropFirst(firstWord.count + 1))
                return (app, remainder)
            }
        }
        return nil
    }

    /// Load menu items for a target app into crossAppMenuItems (skips if already loaded for same PID).
    private func loadCrossAppMenu(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != crossAppMenuTargetPID else { return }   // already loaded
        crossAppMenuTargetPID = pid
        crossAppMenuTask?.cancel()
        crossAppMenuTask = Task.detached(priority: .userInitiated) {
            let name  = app.localizedName ?? ""
            var items = AXMenuReader.shared.allMenuItems(for: pid, maxDepth: 6)
            for i in items.indices {
                items[i].sourcePID     = pid
                items[i].sourceAppName = name
            }
            await MainActor.run { self.crossAppMenuItems = items }
        }
    }

    /// Build the ordered list of visible pills for the current dock state.
    /// This is the single source of truth for both rendering and keyboard navigation.
    func buildDockPills(query q: String) -> [DockPill] {
        var pills: [DockPill] = []

        let appKey = activeSmartQueryKey ?? settings.autoDetectedAppKey ?? ""
        let allQuickActions = settings.contextDockShortcuts(for: appKey).isEmpty
            ? settings.shortcuts(for: appKey)
            : settings.contextDockShortcuts(for: appKey)
        let allAppTools = frontmostAppL2Extensions
        let allCtxExts  = l2ContextExtensions

        let quickActions = q.isEmpty ? allQuickActions : allQuickActions.filter { $0.name.lowercased().contains(q) }
        let appTools     = q.isEmpty ? allAppTools     : allAppTools.filter {
            $0.displayName.lowercased().contains(q) || $0.toolName.lowercased().contains(q)
        }
        let ctxExts      = q.isEmpty ? allCtxExts : allCtxExts.filter { $0.ilExtension.name.lowercased().contains(q) }
        let baseAdapters = adapterManager.actions(for: axContext.bundleId, query: q)
        let adapterActs  = Array(sessionRankedAdapterActions(base: Array(baseAdapters.prefix(12))).prefix(8))

        // Use frontmostAppBundleID (always current) rather than axContext.bundleId (may lag on dock open)
        let activeBundleId = frontmostAppBundleID.isEmpty ? axContext.bundleId : frontmostAppBundleID
        let favs = settings.favouriteMenuPills(for: activeBundleId)

        // Live menu items: primary (frontmost app) + optional cross-app when query targets another app
        let menuMatches: [AXMenuItem] = q.isEmpty ? [] : {
            // Check if query starts with a known app name → cross-app mode (requires Cross-App Connect)
            if settings.crossAppPills, let (targetApp, actionQuery) = detectCrossAppQuery(q) {
                loadCrossAppMenu(for: targetApp)
                let filterQ = actionQuery.isEmpty ? q : actionQuery
                let matches = crossAppMenuItems.filter { item in
                    item.title.lowercased().contains(filterQ) ||
                    item.path.contains { $0.lowercased().contains(filterQ) }
                }
                return Array(matches.sorted {
                    ($0.title.lowercased().hasPrefix(filterQ) ? 0 : 1) < ($1.title.lowercased().hasPrefix(filterQ) ? 0 : 1)
                }.prefix(8))
            }
            // Default: frontmost app's menu items only — favourites rank first
            let matches = liveMenuItems.filter { item in
                item.title.lowercased().contains(q) ||
                item.path.contains { $0.lowercased().contains(q) }
            }
            return Array(matches.sorted {
                let aFav   = favs.contains($0.title) ? 0 : 1
                let bFav   = favs.contains($1.title) ? 0 : 1
                if aFav != bFav { return aFav < bFav }
                let aTitle = $0.title.lowercased().hasPrefix(q) ? 0 : 1
                let bTitle = $1.title.lowercased().hasPrefix(q) ? 0 : 1
                if aTitle != bTitle { return aTitle < bTitle }
                return $0.path.count < $1.path.count
            }.prefix(10))
        }()

        // Finder selected-file pills come FIRST — most contextual
        pills += buildFinderFilePills(query: q)

        // Context-reactive pills — menu items that just became enabled after a selection change.
        // Only shown when the user hasn't typed a query (they'd surface via menuMatches otherwise).
        if q.isEmpty && !contextMenuPills.isEmpty {
            for item in contextMenuPills {
                let path      = item.path
                let sourcePID = item.sourcePID != 0 ? item.sourcePID
                    : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
                let sc   = item.shortcutChar
                let mod  = item.shortcutModifiers
                let badge: String? = item.shortcutDisplay ?? (path.count >= 2 ? path[path.count - 2] : nil)
                let sourceApp = NSWorkspace.shared.runningApplications
                    .first { $0.processIdentifier == sourcePID && !$0.isTerminated }
                pills.append(DockPill(
                    id: "ctx-menu-\(item.id)",
                    name: item.title,
                    icon: "sparkles",
                    accentColorName: "blue",
                    badge: badge,
                    execute: {
                        guard sourcePID != 0, sourceApp != nil else { return }
                        Task {
                            sourceApp?.activate(options: [.activateIgnoringOtherApps])
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            await Task.detached(priority: .userInitiated) {
                                if let ch = sc, !ch.isEmpty {
                                    AXMenuReader.shared.executeShortcut(char: ch, modifiers: mod, in: sourcePID)
                                } else {
                                    AXMenuReader.shared.clickMenuItem(path: path, in: sourcePID)
                                }
                            }.value
                        }
                    }
                ))
            }
        }

        for sc in quickActions {
            pills.append(DockPill(id: "qa-\(sc.id)", name: sc.name,
                                  icon: sc.iconName, accentColorName: nil, badge: nil,
                                  execute: { executeAppShortcut(sc) }))
        }
        for tool in appTools {
            pills.append(DockPill(id: "tool-\(tool.toolName)", name: tool.displayName,
                                  icon: tool.icon, accentColorName: "indigo", badge: nil,
                                  execute: {
                l2ChatMessages.append(AIChatMessage(role: .user, content: tool.displayName))
                l2IsLoading = true
                Task {
                    let (ok, out) = await L2ExtensionManager.shared.execute(toolName: tool.toolName, arguments: [:])
                    await MainActor.run {
                        let msg = ok ? (out.isEmpty ? "✅ \(tool.displayName) done." : out)
                                     : "❌ \(tool.displayName) failed: \(out)"
                        l2ChatMessages.append(AIChatMessage(role: .assistant, content: msg))
                        l2IsLoading = false
                    }
                }
            }))
        }
        for result in ctxExts {
            let ext = result.ilExtension
            let ctx = currentContext
            pills.append(DockPill(id: "ctx-\(ext.id)", name: ext.name,
                                  icon: ext.icon, accentColorName: "teal", badge: nil,
                                  execute: { Task { await executeL2Extension(ext, context: ctx) } }))
        }
        for action in adapterActs {
            pills.append(DockPill(id: "adp-\(action.id)", name: action.name,
                                  icon: action.icon, accentColorName: action.accentColor, badge: nil,
                                  execute: { executeAdapterAction(action) }))
        }
        for item in menuMatches {
            let path      = item.path
            let sourcePID = item.sourcePID != 0
                ? item.sourcePID
                : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
            // Only show source badge for cross-app items; Apple menu items are universal — no badge
            let isFrontmost = sourcePID == (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
            let pillBadge: String? = {
                if item.isAppleMenu { return nil }                         // universal — no app badge
                if !item.sourceAppName.isEmpty && !isFrontmost {
                    return item.sourceAppName                              // cross-app badge
                }
                return path.count >= 2 ? path[path.count - 2] : nil       // parent menu name
            }()
            let shortcutChar = item.shortcutChar
            let shortcutMods = item.shortcutModifiers
            let shortcutHint = item.shortcutDisplay
            let sourceApp    = NSWorkspace.shared.runningApplications
                .first { $0.processIdentifier == sourcePID && !$0.isTerminated }

            let isFav = favs.contains(item.title)   // reuse favs computed above — same bundle ID
            var pill = DockPill(id: "menu-\(item.id)", name: item.title,
                                icon: isFav ? "star.fill" : "menubar.rectangle",
                                accentColorName: isFav ? "yellow" : "gray",
                                badge: shortcutHint ?? pillBadge,
                                execute: {
                guard sourcePID != 0, sourceApp != nil else { return }
                Task {
                    sourceApp?.activate(options: [.activateIgnoringOtherApps])
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    await Task.detached(priority: .userInitiated) {
                        if let ch = shortcutChar, !ch.isEmpty {
                            AXMenuReader.shared.executeShortcut(char: ch, modifiers: shortcutMods, in: sourcePID)
                        } else {
                            AXMenuReader.shared.clickMenuItem(path: path, in: sourcePID)
                        }
                    }.value
                }
            })
            pill.isFavourited    = isFav
            pill.menuItemName    = item.title
            pill.sourceBundleId  = activeBundleId
            // Share items → override execute to show NSSharingServicePicker
            if item.title.lowercased().hasPrefix("share") {
                pill = DockPill(id: pill.id, name: pill.name,
                                icon: "square.and.arrow.up",
                                accentColorName: "blue",
                                badge: pill.badge,
                                execute: { showShareSheetForContext() })
                pill.isShareAction   = true
                pill.isFavourited    = isFav
                pill.menuItemName    = item.title
                pill.sourceBundleId  = activeBundleId
            }
            pills.append(pill)
        }
        // Cross-app target pills — gated solely by the user toggle
        pills += buildCrossAppPills(query: q)
        // Clipboard-aware pills — only in l2OnlyMode (always-context-dock)
        if settings.l2OnlyMode {
            pills += buildClipboardPills(query: q)
        }

        // AX Trigger Rules — user-defined "when I see X → show pill Y"
        let resolvedRulePills = AXTriggerRuleEngine.shared.evaluate(context: axContext)
        let filteredRulePills = q.isEmpty ? resolvedRulePills : resolvedRulePills.filter { $0.name.lowercased().contains(q) }
        pills += filteredRulePills.map { r in
            DockPill(id: r.id, name: r.name, icon: r.icon, accentColorName: r.accentColor, badge: nil, execute: r.execute)
        }

        // When filtering: promote starred pills to the front.
        if !q.isEmpty {
            let starredPills = pills.filter { $0.isFavourited }
            let restPills    = pills.filter { !$0.isFavourited }
            if !starredPills.isEmpty {
                return starredPills + restPills
            }
        }

        return pills
    }

    /// Execute the currently focused pill, or the first pill if nothing is focused.
    /// Clears the input field afterwards so the dock is ready for the next command.
    func executeFirstOrFocusedPill() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pills = buildDockPills(query: q)
        guard !pills.isEmpty else { return }
        // Skip separators when finding the target pill
        let idx = min(focusedPillIndex ?? 0, pills.count - 1)
        let pill = pills[idx].isSeparator
            ? pills.first(where: { !$0.isSeparator }) ?? pills[idx]
            : pills[idx]
        pill.execute()
        // Clear input so dock returns to default pill state
        searchText = ""
        focusedPillIndex = 0
    }


    @ViewBuilder
    private var l2UnifiedDockRow: some View {
        let q = isL2ContextActive ? searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
        let pills = buildDockPills(query: q)

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if pills.isEmpty && !q.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text("Press ↩ to ask AI").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        ForEach(Array(pills.enumerated()), id: \.element.id) { idx, pill in
                            unifiedPillButton(pill: pill, index: idx)
                                .id("pill-\(idx)")
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                        // AX context pills only when no search query is active
                        if q.isEmpty { axSmartPills }
                    }
                }
            }
            .onChange(of: focusedPillIndex) { newIndex in
                // Only auto-scroll when navigating via keyboard — not on mouse hover
                guard pillNavViaKeyboard, let idx = newIndex else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    proxy.scrollTo("pill-\(idx)", anchor: .center)
                }
                // Auto-show share sheet the moment a share pill is keyboard-focused
                let allPills = buildDockPills(query: q)
                if idx < allPills.count, allPills[idx].isShareAction {
                    showShareSheetForContext()
                }
            }
        }
        .padding(.horizontal, 2)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: q)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: focusedPillIndex)
        // Auto-focus first pill whenever query changes and pills exist
        .onChange(of: q) { _ in
            let updated = buildDockPills(query: q)
            // Focus first non-separator pill
            focusedPillIndex = updated.firstIndex(where: { !$0.isSeparator })
        }
    }

    /// Single pill button with focus highlight for keyboard navigation.
    @ViewBuilder
    private func unifiedPillButton(pill: DockPill, index: Int) -> some View {
        if pill.isSeparator {
            // Render as a thin vertical divider with optional app-name label
            HStack(spacing: 3) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1, height: 16)
                if !pill.name.isEmpty {
                    Text(pill.name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        } else {
        let accent  = accentColor(for: pill.accentColorName)
        let focused = focusedPillIndex == index
        Button {
            pill.execute()
            searchText = ""
            focusedPillIndex = 0
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pill.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(focused ? .white : accent)
                Text(pill.name)
                    .font(.system(size: 11, weight: focused ? .semibold : .medium))
                    .foregroundStyle(focused ? .white : .primary)
                    .lineLimit(1)
                if let badge = pill.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(focused ? .white.opacity(0.7) : .secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(focused ? .white.opacity(0.2) : .secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(focused ? AnyShapeStyle(accent) : AnyShapeStyle(.regularMaterial), in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? Color.clear : accent.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(pill.name)
        .onHover { hovering in
            if hovering {
                pillNavViaKeyboard = false   // hover → no auto-scroll
                focusedPillIndex = index
            }
        }
        // Right-click context menu — shows Favourite / Unfavourite for menu item pills
        .contextMenu {
            if !pill.menuItemName.isEmpty, !pill.sourceBundleId.isEmpty {
                Button {
                    settings.toggleFavouriteMenuPill(pill.menuItemName, for: pill.sourceBundleId)
                } label: {
                    Label(
                        pill.isFavourited ? "Remove from Favourites" : "Add to Favourites",
                        systemImage: pill.isFavourited ? "star.slash" : "star"
                    )
                }
            }
        }
        } // end else (non-separator)
    }

    // MARK: - App Adapter Action Pill

    /// Renders a single pill button for an `AppAdapter` action.
    @ViewBuilder
    private func adapterActionPill(_ action: AdapterAction) -> some View {
        let accent = accentColor(for: action.accentColor)
        Button {
            executeAdapterAction(action)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: action.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text(action.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(accent.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(action.description.isEmpty ? action.name : action.description)
    }

    /// Resolve an optional color name string into a SwiftUI Color.
    private func accentColor(for name: String?) -> SwiftUI.Color {
        switch name?.lowercased() {
        case "blue":    return .blue
        case "red":     return .red
        case "green":   return .green
        case "orange":  return .orange
        case "yellow":  return .yellow
        case "purple":  return .purple
        case "indigo":  return .indigo
        case "teal":    return .teal
        case "pink":    return .pink
        case "gray", "grey": return .secondary
        default:        return Color.accentColor
        }
    }

    /// Execute an `AppAdapter` action, handling the `.aiPrompt` type inline.
    private func executeAdapterAction(_ action: AdapterAction) {
        if action.type == .aiPrompt {
            // Resolve context vars and pre-fill the AI chat
            let tmpl = action.aiPromptTemplate ?? action.description
            var prompt = tmpl
            prompt = prompt.replacingOccurrences(of: "$CURRENT_URL",      with: axContext.currentURL   ?? "")
            prompt = prompt.replacingOccurrences(of: "$WINDOW_TITLE",     with: axContext.windowTitle  ?? "")
            prompt = prompt.replacingOccurrences(of: "$AX_SELECTED_TEXT", with: axContext.selectedText ?? "")
            prompt = prompt.replacingOccurrences(of: "$APP_NAME",         with: axContext.appName)
            searchText = prompt
            isAIMode = true
            showContextInDock = false
            submitAIQuery()
            return
        }
        Task {
            let (success, output) = await adapterManager.execute(action, context: axContext)
            guard success, !output.isEmpty, output != "Done",
                  action.type != .menubar, action.type != .urlScheme else { return }
            // Show non-trivial output (AppleScript result, shell output, URL) as an AI message
            await MainActor.run {
                let msg = "**\(action.name):** \(output)"
                l2ChatMessages.append(AIChatMessage(role: .assistant, content: msg))
                if !showContextInDock { showContextInDock = true }
            }
        }
    }

    /// Smart pills generated from the live AX context snapshot.
    /// These complement user-configured pills with zero-config, always-relevant actions.
    @ViewBuilder
    private var axSmartPills: some View {
        let ax = axContext
        if !ax.isEmpty {
            // Separator before smart pills
            Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1, height: 20)

            // Copy URL — shown when a browser URL is detected
            if let url = ax.currentURL {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "link").font(.system(size: 10, weight: .semibold)).foregroundStyle(.teal)
                        Text("Copy URL").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.teal.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain).help(url)
                .transition(.scale(scale: 0.8).combined(with: .opacity))

                // Ask About Page — send URL to AI
                Button {
                    let prompt = "What is this page about? URL: \(url)"
                    searchText = prompt
                    isAIMode = true
                    showContextInDock = false
                    submitAIQuery()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(.indigo)
                        Text("Ask About Page").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.indigo.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain).help("Ask AI about this page")
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            // Copy Selection — shown when text is selected in the frontmost app
            if let sel = ax.selectedText, !sel.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sel, forType: .string)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "text.cursor").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                        Text("Copy Selection").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.orange.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain).help(sel.count > 60 ? String(sel.prefix(60)) + "…" : sel)
                .transition(.scale(scale: 0.8).combined(with: .opacity))

                // Ask About Selection
                Button {
                    let text = sel.count > 500 ? String(sel.prefix(500)) : sel
                    searchText = "Explain: \(text)"
                    isAIMode = true
                    showContextInDock = false
                    submitAIQuery()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(.indigo)
                        Text("Ask About Selection").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.indigo.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }

    // MARK: - App Shortcuts Dock Row — shown when a smart query (calendar/notes…) or folder is active
    @ViewBuilder
    private var appShortcutsInDock: some View {
        let key = activeSmartQueryKey ?? folderSmartKey
        // contextPanelActions() already includes user shortcuts when searchContextApp != nil,
        // so only pull shortcuts directly for built-in key panels (no searchContextApp)
        let contextActions = contextPanelActions()
        let hasSearchCtx = searchContextApp != nil
        let extraShortcuts: [AppShortcut] = hasSearchCtx ? [] : {
            // Merge quick-actions and context-dock shortcuts, deduplicated by name
            var seen = Set<String>()
            let quick = settings.shortcuts(for: key)
            let dock  = settings.contextDockShortcuts(for: key)
            for s in quick { seen.insert(s.name) }
            return quick + dock.filter { seen.insert($0.name).inserted }
        }()

        // Context: is there a selected file or text right now?
        let hasFileSelection: Bool = folderPreviewSelectedFile != nil
            || (selectedResultIndex.map { $0 < searchResults.count && searchResults[$0].filePath != nil } ?? false)
            || !ContextDetector.shared.getFinderSelectedFiles().isEmpty
        let hasTextSelection: Bool = {
            guard let app = NSWorkspace.shared.frontmostApplication else { return false }
            let txt = ContextDetector.shared.getSelectedText(from: app) ?? ""
            return !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()
        let hasContext = hasFileSelection || hasTextSelection

        // Filter context-sensitive shortcuts: hide shell/$1 actions when nothing is selected
        let visibleShortcuts = extraShortcuts.filter { sc in
            guard sc.actionType == .shellCommand || sc.actionType == .appleScript else { return true }
            let v = sc.actionValue
            let needsFile = v.contains("$1") || v.contains("$2") || v.contains("$SELECTED_FILES") || v.contains("$SELECTED_FILE")
            let needsText = v.contains("$SELECTED_TEXT")
            if needsFile && !hasFileSelection { return false }
            if needsText && !hasTextSelection { return false }
            return true
        }

        let showHint = contextActions.isEmpty && visibleShortcuts.isEmpty

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(contextActions) { action in
                    dockPillButton(icon: action.icon, label: action.label, action: action.action)
                }
                ForEach(visibleShortcuts) { sc in
                    dockPillButton(icon: sc.iconName, label: sc.name) { executeAppShortcut(sc) }
                }
                if showHint {
                    Text("No quick actions — add some in Settings › App Shortcuts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    /// Floating pill-shaped dock button used for all quick actions.
    @ViewBuilder
    private func dockPillButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// Key used when a folder is open but no app smart query is active
    private var folderSmartKey: String {
        if let path = folderPreviewPath {
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if name == "downloads" { return "downloads" }
        }
        return ""
    }

    private func executeAppShortcut(_ sc: AppShortcut) {
        // ── Gather context ───────────────────────────────────────────────
        // Selected file(s): folder preview selection first, then highlighted search result
        var selectedFilePaths: [String] = []
        if let previewFile = folderPreviewSelectedFile, !previewFile.isEmpty {
            selectedFilePaths = [previewFile]
        } else if let idx = selectedResultIndex, idx < searchResults.count,
                  let path = searchResults[idx].filePath, !path.isEmpty {
            selectedFilePaths = [path]
        }
        // Also pick up any multi-selection from Finder if no in-app selection
        if selectedFilePaths.isEmpty {
            selectedFilePaths = ContextDetector.shared.getFinderSelectedFiles().map { $0.path }
        }

        // Use the app that was frontmost BEFORE ILauncher activated — never ILauncher itself.
        let prevApp = AppDelegate.shared?.previousFrontmostApp

        // Selected text: accessibility API on the pre-ILauncher frontmost app
        let selectedText: String = {
            guard let app = prevApp else { return "" }
            return ContextDetector.shared.getSelectedText(from: app) ?? ""
        }()

        // ── Substitution helper ──────────────────────────────────────────
        func inject(_ value: String) -> String {
            var result = value
            // $1..$N — individual file paths
            for (i, path) in selectedFilePaths.enumerated() {
                let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                result = result.replacingOccurrences(of: "$\(i + 1)", with: escaped)
            }
            // $SELECTED_FILES — space-separated list of all paths (shell-quoted)
            let allEscaped = selectedFilePaths.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: " ")
            result = result.replacingOccurrences(of: "$SELECTED_FILES", with: allEscaped)
            // $SELECTED_TEXT — text selected in frontmost app
            let textEscaped = selectedText.replacingOccurrences(of: "'", with: "'\\''")
            result = result.replacingOccurrences(of: "$SELECTED_TEXT", with: textEscaped)
            // $FRONTMOST_APP — name of the app that was active before ILauncher opened
            let frontmostName = prevApp?.localizedName ?? ""
            result = result.replacingOccurrences(of: "$FRONTMOST_APP", with: frontmostName)
            // $FRONTMOST_BUNDLE — bundle identifier of the pre-ILauncher app
            let frontmostBundle = prevApp?.bundleIdentifier ?? ""
            result = result.replacingOccurrences(of: "$FRONTMOST_BUNDLE", with: frontmostBundle)
            // AX-read context variables ─────────────────────────────────────────
            // $CURRENT_URL — URL currently open in the frontmost browser/app window
            let axURL = axContext.currentURL ?? ""
            result = result.replacingOccurrences(of: "$CURRENT_URL", with: axURL)
            // $WINDOW_TITLE — title of the frontmost window
            let axTitle = axContext.windowTitle ?? ""
            result = result.replacingOccurrences(of: "$WINDOW_TITLE", with: axTitle)
            // $AX_SELECTED_TEXT — selected text read via AX API (more reliable than clipboard)
            let axSel = axContext.selectedText ?? ""
            result = result.replacingOccurrences(of: "$AX_SELECTED_TEXT", with: axSel)
            return result
        }

        switch sc.actionType {
        case .openURL:
            if let url = URL(string: sc.actionValue) { NSWorkspace.shared.open(url) }
        case .openFile:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: sc.actionValue),
                                               configuration: NSWorkspace.OpenConfiguration())
        case .shellCommand:
            let cmd = inject(sc.actionValue)
            let ck = activeConsoleKey
            // Always create panel terminal if needed, open drawer, run command in real PTY
            let panelTerm = panelTerminal(for: ck)
            panelShowConsoleMap[ck] = true
            panelTerm.sendCommand(cmd)
            // Give the terminal focus so output is visible and interactive
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                panelTerm.terminalView.window?.makeFirstResponder(panelTerm.terminalView)
            }
        case .appleScript:
            if let script = NSAppleScript(source: inject(sc.actionValue)) {
                script.executeAndReturnError(nil)
            }
        case .jxa:
            // JXA runs via osascript -l JavaScript, passing selected file + text as argv
            let scriptCode = sc.actionValue
            let ck = activeConsoleKey
            let file1 = selectedFilePaths.first ?? ""
            let selText = selectedText
            Task.detached {
                // Write script to a temp file so we can pass it cleanly
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ilauncher_jxa_\(UUID().uuidString).js")
                try? scriptCode.write(to: tmp, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                var args = ["-l", "JavaScript", tmp.path]
                if !file1.isEmpty { args.append(file1) }
                if !selText.isEmpty { args.append(selText) }
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError  = pipe
                try? proc.run()
                proc.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // Show JXA output in the panel terminal drawer
                await MainActor.run {
                    self.panelShowConsoleMap[ck] = true
                    for line in out.components(separatedBy: "\n") where !line.isEmpty {
                        self.panelConsoleLinesMap[ck, default: []].append((line: line, isCommand: false))
                    }
                }
            }
        }
    }

    // MARK: - File-Type Extensions Dock Row — shown when a file result is highlighted
    private var selectedResultHasFileTypeExtensions: Bool {
        // True if we have context-based extensions for the selected file/result
        // (context extensions already handle file-type matching via their trigger system)
        guard let idx = selectedResultIndex, idx < searchResults.count else {
            return !l2ContextExtensions.isEmpty && !l2ContextExtensions.filter {
                switch $0.matchReason {
                case .fileTypeMatch: return true
                default: return false
                }
            }.isEmpty
        }
        let result = searchResults[idx]
        return (result.type == .file || result.type == .document) && !l2ContextExtensions.isEmpty
    }

    /// Shortcuts relevant to the currently highlighted search result's file type
    private var fileTypeShortcutsForSelection: [AppShortcut] {
        // File selected inside folder preview takes priority
        if let selectedFile = folderPreviewSelectedFile, !selectedFile.isEmpty {
            let ext = URL(fileURLWithPath: selectedFile).pathExtension.lowercased()
            return fileTypeShortcuts(for: ext)
        }
        guard let idx = selectedResultIndex,
              idx < searchResults.count else { return [] }
        let result = searchResults[idx]
        guard result.type == .file || result.type == .document else { return [] }
        let ext = (result.filePath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }) ?? ""
        return fileTypeShortcuts(for: ext)
    }

    /// Name of the currently selected file in the folder preview (for display)
    private var selectedFolderFileName: String? {
        guard let path = folderPreviewSelectedFile, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func fileTypeShortcuts(for ext: String) -> [AppShortcut] {
        // Map common file extensions to app shortcut keys
        // Users can define their own shortcuts for these keys in Settings › App Shortcuts
        let key: String
        switch ext {
        case "pdf":                        key = "pdf"
        case "jpg","jpeg","png","heic","gif","webp","tiff": key = "image"
        case "mp4","mov","avi","mkv","m4v": key = "video"
        case "mp3","aac","flac","wav","m4a": key = "audio"
        case "zip","rar","7z","tar","gz":  key = "archive"
        case "doc","docx","pages":         key = "document"
        case "xls","xlsx","numbers","csv": key = "spreadsheet"
        case "ppt","pptx","key":           key = "presentation"
        case "swift","py","js","ts","rb","go","rs","kt": key = "code"
        default:                           return []
        }
        return settings.shortcuts(for: key)
    }

    /// Unified context-based dock row shown when a file/result is selected.
    /// Uses the scoring system from LayeredExtensionManager — no hardcoded AppShortcut file-type mapping.
    @ViewBuilder
    private var fileTypeExtensionsInDock: some View {
        if l2ContextExtensions.isEmpty {
            pinnedAppsRow
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // File name chip (folder preview only)
                    if let fileName = selectedFolderFileName {
                        let ext = URL(fileURLWithPath: folderPreviewSelectedFile ?? "").pathExtension.lowercased()
                        HStack(spacing: 5) {
                            Image(systemName: fileIcon(for: ext))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(fileName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: 120)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.secondary.opacity(0.12), in: Capsule())
                    }

                    // Context-based action pills — auto-scored by file type, app, selection
                    ForEach(l2ContextExtensions, id: \.ilExtension.id) { result in
                        L2ExtensionChipButton(
                            extensionResult: result,
                            currentContext: currentContext,
                            onExecute: executeL2Extension
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Browser Dock View (Layer 3) - Recent Searches (scrollable chips like pinned apps)
    @ViewBuilder
    private var browserDockView: some View {
        // Show recent searches and bookmarks as horizontal scrollable chips (like pinned apps)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Recent searches (first 5)
                ForEach(settings.recentWebSearches.prefix(5), id: \.self) { search in
                    Button(action: {
                        searchText = search
                        openInDockBrowser()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 11))
                                .foregroundStyle(.gray)
                            Text(search)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.gray.opacity(0.12))
                        )
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("Recent: \(search)")
                }

                // Bookmarks (first 5)
                ForEach(settings.importedBookmarks.prefix(5)) { bookmark in
                    Button(action: {
                        // Open bookmark URL in inline browser
                        searchText = bookmark.url
                        openInDockBrowser()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.yellow)
                            Text(bookmark.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.12))
                        )
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help(bookmark.url)
                }

                // Show hint if both are empty
                if settings.recentWebSearches.isEmpty && settings.importedBookmarks.isEmpty {
                    Text("Recent searches and bookmarks will appear here")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    private var searchBarSection: some View {
        Group {
            if settings.effectiveDockAtBottom {
                // Dock mode: Results above, dock pinned at bottom — all in one sheet
                let hasResultsToShowBottom = !searchResults.isEmpty || (!searchText.isEmpty && !isL2ContextActive) || isAIMode || showBrowserLayer || showFolderPreview
                VStack(spacing: 0) {
                    if hasResultsToShowBottom {
                        resultsContentView
                            .frame(minHeight: showBrowserLayer && showInlineBrowser ? 380 : 0, maxHeight: showFolderPreview ? 600 : 400)
                            .transition(.opacity)
                        Divider().opacity(0.12)
                    }
                    dockBaseView(inDockMode: true)
                }
                .background(GlassBackground(cornerRadius: 20))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            } else {
                // Normal mode: Dock + results in ONE unified sheet
                let hasResultsToShow = !searchResults.isEmpty
                    || (!searchText.isEmpty && !isL2ContextActive)   // L2: no results sheet on typing
                    || isAIMode
                    || showBrowserLayer
                    || showFolderPreview
                    || (showContextInDock && (!l2ChatMessages.isEmpty || l2IsLoading))
                    || activeSmartQueryKey != nil

                VStack(spacing: 0) {
                    dockBaseView(inDockMode: false)

                    if hasResultsToShow {
                        Divider().opacity(0.12)
                        resultsContentView
                            .frame(minHeight: showBrowserLayer && showInlineBrowser ? 380 : 0, maxHeight: showFolderPreview ? 600 : 400)
                            .transition(.opacity)
                    }
                }
                .background(GlassBackground(cornerRadius: 20))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
        }
        .ifLet(resolvedColorScheme) { view, scheme in
            view.environment(\.colorScheme, scheme)
        }
    }

    // MARK: - Dock Base View (always visible, doesn't move)
    @ViewBuilder
    private func dockBaseView(inDockMode: Bool) -> some View {
        let outerVerticalPadding: CGFloat = 10
        let inputVerticalPadding: CGFloat = 8
        let pinnedRowHeight: CGFloat = 48

        VStack(spacing: 0) {
            HStack(spacing: 12) {
            // Search field with darker glassy background
            HStack(spacing: 10) {
                // Search icon
                if isAIMode {
                    Menu {
                        ForEach(AIProvider.allCases) { provider in
                            Button(action: {
                                settings.selectedAIProvider = provider
                            }) {
                                HStack {
                                    Image(systemName: provider.iconName)
                                    Text(provider.shortName)
                                    Spacer()
                                    if settings.selectedAIProvider == provider {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }

                        Divider()

                        Button("AI Settings...") {
                            openSettings()
                        }
                    } label: {
                        Image(systemName: settings.selectedAIProvider.iconName)
                            .foregroundStyle(providerColor)
                            .font(.system(size: 16, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .onHover { hovering in
                        isHoveringSearchIcon = hovering
                        if hovering {
                            expandSearchBar()
                        } else {
                            // Start collapse timer when stopping hover (if no input and not focused)
                            if searchText.isEmpty && !isSearchFieldFocused {
                                startCollapseTimer()
                            }
                        }
                    }
                    .help("Select AI Provider")
                } else {
                    Button(action: {
                        // Click toggles: collapse if expanded, expand if collapsed
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            if isSearchBarExpanded && searchText.isEmpty && !isSearchFieldFocused {
                                isSearchBarExpanded = false
                            } else {
                                expandSearchBar()
                            }
                        }
                        updateWindowSize()
                    }) {
                        // Globe on L3, app icon on L2, magnifying glass on L1
                        if showBrowserLayer {
                            Image(systemName: "globe")
                                .foregroundStyle(.blue.opacity(isHoveringSearchIcon ? 1.0 : 0.8))
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 24, height: 24)
                        } else if showContextInDock && settings.enableFrontmostDetection, let appIcon = frontmostAppIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                                .opacity(isHoveringSearchIcon ? 1.0 : 0.8)
                        } else {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary.opacity(isHoveringSearchIcon ? 0.8 : 0.5))
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 24, height: 24)
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringSearchIcon = hovering
                        if hovering && !suppressHoverExpand {
                            expandSearchBar()
                        }
                    }
                    .help(showBrowserLayer ? "Search Web" : "Search")
                }

                // Spotlight-style app context chip — shown after Tab/→ on app result
                if let ctx = searchContextApp {
                    HStack(spacing: 5) {
                        if let icon = ctx.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 16, height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(ctx.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Button(action: { clearSearchContext() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 0.5)
                    )
                }

                // Text field - visible when expanded (auto-collapses on all layers)
                if isSearchBarExpanded {
                    let selectedResult: SearchResult? = {
                        guard let idx = selectedResultIndex, idx < searchResults.count,
                              !isAIMode, activeSmartQueryKey == nil, searchContextApp == nil
                        else { return nil }
                        return searchResults[idx]
                    }()
                    // Spotlight-style: show result name in bar whenever a result is selected (even while typing)
                    let showingResultPreview = selectedResult != nil

                    ZStack(alignment: .leading) {
                        // Selected result preview (Spotlight-style: "Visual Studio Code.app — Open")
                        if let result = selectedResult {
                            // Intelligent inline completion:
                            // • Prefix match  → show typed text (invisible spacer) + greyed remainder + action
                            // • Fuzzy match   → show full result name + action
                            let title = result.title
                            let typed = searchText
                            let isPrefixMatch = title.lowercased().hasPrefix(typed.lowercased())

                            HStack(spacing: 0) {
                                if isPrefixMatch && !typed.isEmpty {
                                    // Typed portion — invisible spacer so grey completion aligns after cursor
                                    Text(typed)
                                        .font(.system(size: 15))
                                        .foregroundStyle(.clear)
                                    // Grey completion (the "remaining" part)
                                    Text(String(title.dropFirst(typed.count)))
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary.opacity(0.45))
                                        .lineLimit(1)
                                } else {
                                    // Fuzzy match — show full name in primary color
                                    Text(title)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                // Action hint
                                Text("  —  \(selectedResultAction(result))")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary.opacity(0.35))
                            }
                        } else if searchText.isEmpty {
                            // Normal placeholders (always visible when field is empty)
                            if let ctx = searchContextApp {
                                // Context panel (file, folder, app, contact, etc.)
                                Text(remPanelIsProcessing ? "Processing…" : "Ask AI about \(ctx.name)…")
                                    .foregroundStyle(.secondary.opacity(0.5))
                                    .font(.system(size: 15, weight: .regular))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            } else if let key = activeSmartQueryKey {
                                // Built-in panel (reminders, calendar, notes, etc.)
                                let label = settings.customAppEntries.first(where: { $0.key == key })?.label ?? key.capitalized
                                Text(remPanelIsProcessing ? "Processing…" : "Ask AI about \(label)…")
                                    .foregroundStyle(.secondary.opacity(0.5))
                                    .font(.system(size: 15, weight: .regular))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            } else if showBrowserLayer {
                                Text("Browse Web")
                                    .foregroundStyle(.secondary.opacity(0.5))
                                    .font(.system(size: 15, weight: .regular))
                            } else if showContextInDock && !frontmostAppName.isEmpty {
                                // L2: show the frontmost app the user is working in
                                Text(frontmostAppName)
                                    .foregroundStyle(.secondary.opacity(0.5))
                                    .font(.system(size: 15, weight: .regular))
                            } else {
                                Text(isAIMode ? "Ask \(settings.selectedAIProvider.shortName)..." : "Context-Dock")
                                    .foregroundStyle(.secondary.opacity(0.5))
                                    .font(.system(size: 15, weight: .regular))
                            }
                        }

                        TextField("", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .focused($isSearchFieldFocused)
                            // For prefix match: TextField stays visible (shows typed text + cursor).
                            // For fuzzy match or empty: hide it so the full result name shows cleanly.
                            .opacity({
                                if let result = selectedResult {
                                    let isPrefixMatch = result.title.lowercased().hasPrefix(searchText.lowercased())
                                    return (isPrefixMatch && !searchText.isEmpty) ? 1 : 0
                                }
                                return 1
                            }())
                            .onChange(of: searchText) { oldValue, newValue in
                                // In L2 context dock mode, pills filter in the pill row —
                                // do NOT run L1 search (which would expand the window with results).
                                if !isAIMode && !showContextInDock {
                                    performSearch()
                                }
                                resetCollapseTimer()
                            }
                            .onChange(of: isSearchFieldFocused) { oldValue, newValue in
                                if newValue {
                                    collapseTimer?.cancel()
                                } else {
                                    if searchText.isEmpty {
                                        startCollapseTimer()
                                    }
                                }
                            }
                            .onSubmit {
                                if isL2ContextActive {
                                    enforceL2ContextMode()
                                    // Check if any dock pills match the current query.
                                    // If none match → send to the user's selected AI provider.
                                    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                    let appKey2 = activeSmartQueryKey ?? settings.autoDetectedAppKey ?? ""
                                    let hasPillMatch = !q.isEmpty && (
                                        settings.contextDockShortcuts(for: appKey2).contains { $0.name.lowercased().contains(q) }
                                        || frontmostAppL2Extensions.contains { $0.displayName.lowercased().contains(q) || $0.toolName.lowercased().contains(q) }
                                        || l2ContextExtensions.contains { $0.ilExtension.name.lowercased().contains(q) }
                                    )
                                    if !q.isEmpty && !hasPillMatch {
                                        // No pills match — escalate to selected AI provider
                                        isAIMode = true
                                        showContextInDock = false
                                        submitAIQuery()
                                    } else {
                                        handleL2Query()
                                    }
                                } else if showBrowserLayer {
                                    if !searchText.isEmpty {
                                        performBrowserSearch()
                                    }
                                } else if isAIMode {
                                    submitAIQuery()
                                } else {
                                    executeSelectedResult()
                                }
                            }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))

                    // Trailing area: selected result icon OR clear button OR AI controls
                    if let result = selectedResult {
                        // Spotlight-style: show result icon on the right while a result is selected
                        if let icon = result.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .shadow(radius: 2)
                        }
                    } else if isAIMode {
                        aiModeControls
                    } else if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            searchResults = []
                            selectedResultIndex = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary.opacity(0.5))
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                    }
                }
            }
            .padding(.horizontal, isSearchBarExpanded ? 12 : 8)
            .padding(.vertical, inputVerticalPadding)
            .frame(maxWidth: isSearchBarExpanded ? .infinity : 44)
            .background {
                // Inner search field glass — darker inset pill inside the dock container
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75)
                }
            }
            .onHover { hovering in
                isHoveringInputField = hovering

                // Auto-shrink when mouse leaves input field (if no text and not focused)
                if !hovering && searchText.isEmpty && !isSearchFieldFocused {
                    startCollapseTimer()
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSearchBarExpanded)


            // Pinned apps or context chips/AI extensions or browser (3-layer swipeable)
            HStack(spacing: 8) {
                    Group {
                        if showBrowserLayer {
                            // Layer 3: Browser — recent searches + bookmarks
                            browserDockView
                                .transition(.opacity)
                        } else if showFolderPreview && !fileTypeShortcutsForSelection.isEmpty {
                            // File selected inside folder preview — show file-type extensions in pinned slot
                            fileTypeExtensionsInDock
                                .transition(.opacity)
                        } else if activeSmartQueryKey != nil || showFolderPreview {
                            // App/Folder mode (no file selected) — show folder/app quick actions
                            appShortcutsInDock
                                .transition(.opacity)
                        } else if showContextInDock {
                            // Layer 2: show app-specific AI tools first, then query-matched extensions,
                            // then quick-action pills, then file-type extensions
                            if isAIMode && hasAIExtensionsToShow {
                                aiExtensionsInDock
                                    .transition(.opacity)
                            } else {
                                // Unified row: app-based AI tools + context-based extensions together
                                l2UnifiedDockRow
                                    .transition(.opacity)
                            }
                        } else if selectedResultHasFileTypeExtensions {
                            // File selected in results — show relevant file-type extensions
                            fileTypeExtensionsInDock
                                .transition(.opacity)
                        } else {
                            // Layer 1 default — pinned apps
                            pinnedAppsRow
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: 400)
                    .frame(height: pinnedRowHeight) // Fixed height to prevent jumping

                    // User profile picture / notification bell
                    if settings.enableLayer2 || (isAIMode && hasAIExtensionsToShow) || notificationManager.unreadCount > 0 {
                        Button(action: {
                            if notificationManager.unreadCount > 0 {
                                showNotificationPanel = true
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    showContextInDock.toggle()
                                }
                            }
                        }) {
                            ZStack(alignment: .topTrailing) {
                                if let profileImage = userProfileImage {
                                    Image(nsImage: profileImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 28, height: 28)
                                        .clipShape(Circle())
                                        .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                                } else {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(notificationManager.unreadCount > 0
                                                         ? Color.primary : Color.secondary.opacity(0.6))
                                }
                                // Notification badge
                                if notificationManager.unreadCount > 0 {
                                    ZStack {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 14, height: 14)
                                        Text(notificationManager.unreadCount > 9 ? "9+" :
                                             "\(notificationManager.unreadCount)")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .offset(x: 4, y: -4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(notificationManager.unreadCount > 0
                              ? "\(notificationManager.unreadCount) unread notification(s)"
                              : (showContextInDock ? "Show Pinned Apps" : (isAIMode ? "Show AI Extensions" : "Show Context Shortcuts")))
                        .popover(isPresented: $showNotificationPanel, arrowEdge: .bottom) {
                            NotificationPanelView()
                                .frame(width: 340, height: 420)
                        }
                    }
                }
                .onHover { hovering in
                    isHoveringDockArea = hovering
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: showContextInDock)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, outerVerticalPadding)
        }
    }

    /// SF Symbol name for a file extension
    private func fileIcon(for ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "jpg","jpeg","png","heic","gif","webp","tiff": return "photo"
        case "mp4","mov","avi","mkv","m4v": return "film"
        case "mp3","aac","flac","wav","m4a": return "music.note"
        case "zip","rar","7z","tar","gz": return "archivebox"
        case "doc","docx","pages": return "doc.text"
        case "xls","xlsx","numbers","csv": return "tablecells"
        case "ppt","pptx","key": return "rectangle.on.rectangle"
        case "swift","py","js","ts","rb","go","rs","kt": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    // MARK: - Results Content (for smart positioning)
    @ViewBuilder
    private var resultsContentView: some View {
        // Show different content based on current mode (AI vs Normal)
        // L3 browser layer shows web search results, not browser content
        let content = Group {
            if isAIMode {
                // AI mode: AI Chat section (works on L1/L2/L3)
                aiChatSection
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if showContextInDock && !showBrowserLayer {
                VStack(spacing: 0) {
                    l2ChatSection
                    if !l2ChatMessages.isEmpty || l2IsLoading {
                        resultsSection
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: l2ChatMessages.count)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: l2IsLoading)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                // Normal mode: Search results (works on L1/L2/L3)
                // L3 browser layer shows web search results when user types
                indexingProgressSection
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                resultsSection
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }

        if settings.effectiveDockAtBottom {
            // In dock mode, add padding to results (match compact dock height)
            content
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        } else {
            // In normal mode, add subtle padding at top for smooth connection to dock
            content
                .padding(.top, 4)
        }
    }

    // MARK: - Separator (for smart positioning)
    @ViewBuilder
    private var separatorView: some View {
        let shouldShowSeparator = if showBrowserLayer {
            // Show separator on L3 if browser content exists
            !pinnedWebsites.isEmpty || !quickTabs.isEmpty || !browserBookmarks.isEmpty
        } else if isAIMode {
            // Show separator for AI mode
            hasUserSentMessageInCurrentSession && (!aiChatMessages.isEmpty || isAILoading)
        } else {
            // Show separator for search results
            !searchResults.isEmpty || fileIndexManager.progress.isIndexing
        }

        if shouldShowSeparator {
            Divider()
                .padding(.horizontal, 12)
                .transition(.opacity)
        }
    }

    // MARK: - AI Extension Quick Actions (now shown in dock on swipe up)
    @ViewBuilder
    private var aiExtensionQuickActions: some View {
        // AI extensions now show inside dock on swipe up, not here
        EmptyView()
    }

    // MARK: - AI Mode Controls (simplified - no provider badge)
    @ViewBuilder
    private var aiModeControls: some View {
        HStack(spacing: 8) {
            // Clear chat button
            if !aiChatMessages.isEmpty {
                Button(action: {
                    withAnimation {
                        aiChatMessages.removeAll()
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear chat")
            }
            
            // Copy button
            Button(action: {
                copyAIResponse()
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy last response")
            .disabled(aiChatMessages.isEmpty)
        }
    }
    
    private var providerColor: SwiftUI.Color {
        switch settings.selectedAIProvider {
        case .onDevice: return .purple
        case .googleGemini: return .blue
        case .openAI: return .green
        case .anthropic: return .orange
        case .ollama: return .cyan
        case .shortcuts: return .indigo
        }
    }
    
    private func copyAIResponse() {
        guard let lastAssistantMessage = aiChatMessages.last(where: { $0.role == .assistant }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastAssistantMessage.content, forType: .string)
    }

    // MARK: - Context Chip Section
    @ViewBuilder
    private var contextChipSection: some View {
        // Only show if context awareness is enabled
        if settings.enableContextAIExtensions {
            // Only show if we have a meaningful context (not just "none")
            let shouldShowContext: Bool = {
                switch currentContext {
                case .filesSelected(let urls):
                    return !urls.isEmpty
                case .textSelected(let text):
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .url(let urlString):
                    return !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .appFocused, .contactSelected:
                    return false // Don't show chips for app/contact context for now
                case .none:
                    return false
                }
            }()

            // Get suggested shortcuts — passive context only (not while typing).
            // Showing them while typing would expand the window on every keystroke,
            // interrupting the user's search flow. They appear when idle with detected context.
            let suggestedShortcuts: [SearchResult] = {
                guard searchText.isEmpty && shouldShowContext else { return [] }
                return allShortcuts.filter { shortcut in
                    guard let metadata = shortcutMetadataCache[shortcut.title] else { return false }
                    return metadata.matches(context: currentContext)
                }
            }()

            if shouldShowContext && !suggestedShortcuts.isEmpty {
                // Beautiful card-style context display (like macOS 26 Spotlight)
                VStack(spacing: 0) {
                    // Context header with icon and description
                    HStack(spacing: 12) {
                        // Context icon in a pill
                        HStack(spacing: 6) {
                            Image(systemName: currentContext.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.blue)
                            Text(getContextActionTitle())
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.1))
                        )
                        
                        Spacer()
                        
                        // Context detail text
                        Text(getContextDetailText())
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    
                    Divider()
                        .padding(.horizontal, 20)
                    
                    // Suggested shortcuts section
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(suggestedShortcuts.prefix(3)) { shortcut in
                            Button(action: {
                                executeResult(shortcut)
                            }) {
                                HStack(spacing: 12) {
                                    // Shortcut icon
                                    if let icon = shortcut.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 28, height: 28)
                                    } else {
                                        Image(systemName: "bolt.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.orange)
                                            .frame(width: 28, height: 28)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(shortcut.title)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Text(shortcut.subtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.clear)
                            )
                            .onHover { hovering in
                                // Optional: Add hover effect
                            }
                            
                            if shortcut.id != suggestedShortcuts.prefix(3).last?.id {
                                Divider()
                                    .padding(.horizontal, 20)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95).combined(with: .opacity),
                    removal: .scale(scale: 0.95).combined(with: .opacity)
                ))
            }
        }
    }
    
    // Helper functions for context display
    private func getContextActionTitle() -> String {
        switch currentContext {
        case .filesSelected(let urls):
            return urls.count == 1 ? "Send" : "Send \(urls.count) files"
        case .textSelected:
            return "Send"
        case .url:
            return "Send"
        case .appFocused, .contactSelected, .none:
            return "Action"
        }
    }
    
    private func getContextDetailText() -> String {
        switch currentContext {
        case .filesSelected(let urls):
            if urls.count == 1 {
                return urls[0].lastPathComponent
            } else {
                return "\(urls.count) files selected"
            }
        case .textSelected(let text):
            let preview = text.prefix(50)
            return "\"\(preview)\(text.count > 50 ? "..." : "")\""
        case .url(let urlString):
            let preview = urlString.prefix(50)
            return "\"\(preview)\(urlString.count > 50 ? "..." : "")\""
        case .appFocused, .contactSelected, .none:
            return ""
        }
    }

    // MARK: - L2 Chat Section
    @ViewBuilder
    private var l2ChatSection: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 12) {
                ForEach(l2ChatMessages) { message in
                    if message.hasInstallButton {
                        AIChatMessageView(
                            message: message,
                            onInstallExtension: installSuggestedExtension
                        )
                    } else {
                        AIChatMessageView(
                            message: message
                        )
                    }
                }

                if let pending = taskExecutor.pendingToolChoice {
                    ToolSelectionInlineView(
                        pending: pending,
                        onSelect: { tool in
                            taskExecutor.approveToolChoice(tool)
                        },
                        onCancel: {
                            taskExecutor.denyToolChoice()
                        }
                    )
                }

                if l2IsLoading {
                    AILoadingView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 500)
        .padding(.bottom, 8)
        .opacity((!l2ChatMessages.isEmpty || l2IsLoading) ? 1 : 0)
        .frame(height: (!l2ChatMessages.isEmpty || l2IsLoading) ? nil : 0)
    }

    // MARK: - AI Chat Section
    @ViewBuilder
    private var aiChatSection: some View {
        // Chat Messages Section - only show if user has sent a message in current session
        if hasUserSentMessageInCurrentSession && (!aiChatMessages.isEmpty || isAILoading) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(aiChatMessages) { message in
                            AIChatMessageView(message: message)
                                .id(message.id)
                        }

                        if isAILoading {
                            AILoadingView()
                                .id("loading")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 350)
                .padding(.bottom, 8)
                .onChange(of: aiChatMessages.count) { _, _ in
                    withAnimation {
                        if let lastMessage = aiChatMessages.last {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isAILoading) { _, newValue in
                    if newValue {
                        withAnimation {
                            proxy.scrollTo("loading", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
    
    // Removed connector execution indicators - simplified for launcher/file manager focus
    
    // MARK: - AI Extension Suggestions Loading
    private func loadAIExtensionSuggestions() {
        print("🔧 [ContentView] Loading AI extension suggestions...")
        print("🔧 [ContentView] Current context: \(currentContext.description)")
        
        Task {
            let matcher = IntelligentExtensionMatcher.shared
            let detectedContext = convertUserContextToDetectedContext(currentContext)
            
            print("🔧 [ContentView] Converted to DetectedContext: \(detectedContext)")
            
            // Get suggestions from matcher
            var newSuggestions = matcher.suggestExtensions(for: detectedContext)
            print("🔧 [ContentView] Got \(newSuggestions.count) suggestions from matcher")
            
            // If no suggestions from matcher, load default built-in extensions
            if newSuggestions.isEmpty {
                print("⚠️ [ContentView] No suggestions from matcher, loading defaults...")
                let allExtensions = ExtensionManager.shared.getEnabledExtensions()
                print("📦 [ContentView] Found \(allExtensions.count) total extensions")
                
                newSuggestions = allExtensions.map { ext in
                    let score: Double = {
                        switch ext.name.lowercased() {
                        case "copy": return 90.0
                        case "copy-path", "copypath": return 85.0
                        case "file-info", "fileinfo": return 80.0
                        case "count-words", "countwords": return 75.0
                        case "summarize": return 70.0
                        case "uppercase": return 65.0
                        case "lowercase": return 64.0
                        default: return 60.0
                        }
                    }()
                    
                    return SuggestedExtension(
                        scriptExtension: ext,
                        relevanceScore: score,
                        reason: "General purpose action"
                    )
                }
            }
            
            // Sort by relevance
            newSuggestions.sort { $0.relevanceScore > $1.relevanceScore }
            
            print("🔧 [ContentView] Sorted suggestions: \(newSuggestions.count)")
            for (index, suggestion) in newSuggestions.prefix(6).enumerated() {
                print("🔧 [ContentView]   \(index + 1). \(suggestion.scriptExtension.displayName) (score: \(suggestion.relevanceScore))")
            }
            
            await MainActor.run {
                aiExtensionSuggestions = newSuggestions
                print("✅ [ContentView] AI extension suggestions updated!")
            }
        }
    }
    
    private func convertUserContextToDetectedContext(_ context: UserContext) -> DetectedContext {
        switch context {
        case .filesSelected(let urls):
            return .files(urls)
        case .textSelected(let text):
            return .text(text)
        case .url(let urlString):
            return .text(urlString) // URLs are treated as text for extension matching
        case .appFocused(let name, let bundleID):
            return .app(bundleID: bundleID, name: name)
        case .contactSelected(let contact):
            return .text(contact)
        case .none:
            // Try clipboard as fallback
            if let clipboardText = NSPasteboard.general.string(forType: .string), !clipboardText.isEmpty {
                return .text(clipboardText)
            }
            return .app(bundleID: "", name: "Unknown")
        }
    }

    // MARK: - Get Context Extensions for AI Chat Mode
    private func getContextExtensions() -> [SuggestedExtension] {
        let detectedContext = convertUserContextToDetectedContext(currentContext)
        return IntelligentExtensionMatcher.shared.suggestExtensions(for: detectedContext)
    }

    // MARK: - AI Query Submission
    private func submitAIQuery() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        guard !isAILoading else { return }

        print("🤖 AI Query submitted: \(query)")

        // Mark that user has sent a message in current session
        hasUserSentMessageInCurrentSession = true

        // Add user message to chat
        let userMessage = AIChatMessage(role: .user, content: query)
        withAnimation {
            aiChatMessages.append(userMessage)
        }

        // Clear search text
        searchText = ""

        // Start loading
        isAILoading = true

        // Cancel any existing task
        currentAITask?.cancel()

        // Send to AI provider - normal chat
        currentAITask = Task {
            do {
                let response = try await sendToAIProvider(query: query)

                await MainActor.run {
                    let assistantMessage = AIChatMessage(role: .assistant, content: response)
                    withAnimation {
                        aiChatMessages.append(assistantMessage)
                        isAILoading = false
                    }
                    updateWindowSize()
                }
            } catch {
                await MainActor.run {
                    let errorMessage = AIChatMessage(role: .assistant, content: "Sorry, I encountered an error: \(error.localizedDescription)", isError: true)
                    withAnimation {
                        aiChatMessages.append(errorMessage)
                        isAILoading = false
                    }
                    updateWindowSize()
                }
            }
        }
    }

    private func handleL2Query() {
        handleL2Query(searchText.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - rem-powered Reminders panel chat

    /// Appends a message to the panel chat and immediately persists it to disk.
    private func appendPanelMessage(_ msg: AIChatMessage) {
        remPanelChatMessages.append(msg)
        if let key = activeSmartQueryKey ?? searchContextApp?.key {
            AppPanelChatStore.shared.save(remPanelChatMessages, for: key)
        }
    }

    private func handleRemPanelQuery() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        remPanelAITask?.cancel()
        appendPanelMessage(AIChatMessage(role: .user, content: query))
        remPanelIsProcessing = true
        // Add a separator between query sessions so history is readable
        let ck = activeConsoleKey
        if !(panelConsoleLinesMap[ck]?.isEmpty ?? true) {
            panelConsoleLinesMap[ck, default: []].append((line: "────────────────────", isCommand: false))
        }
        searchText = ""

        // Wire live streaming into this panel's terminal drawer
        TerminalAIBridge.shared.streamLineHandler = { line in
            DispatchQueue.main.async {
                // Streaming lines go into the drawer live as they arrive
                self.panelConsoleLinesMap[ck, default: []].append((line: line, isCommand: false))
                self.panelShowConsoleMap[ck] = true
            }
        }

        let provider = settings.selectedAIProvider
        let rawKey = AppSettings.shared.getAPIKey(for: provider)
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey

        // OnDevice / Shortcuts can't run rem commands via tool_use — guide user to a cloud provider
        if provider == .onDevice || provider == .shortcuts {
            remPanelChatMessages.append(AIChatMessage(role: .assistant,
                content: "This panel needs a cloud AI to run commands. Please select OpenAI, Anthropic, Gemini, or Ollama in Settings → AI Provider.",
                isError: true))
            remPanelIsProcessing = false
            return
        }

        // Only OpenAI / Anthropic / Gemini require an API key (Ollama is local)
        let requiresKey = provider == .openAI || provider == .anthropic || provider == .googleGemini
        if requiresKey && apiKey == nil {
            remPanelChatMessages.append(AIChatMessage(role: .assistant,
                content: "No API key found for \(provider.displayName). Add your key in Settings → AI Provider.",
                isError: true))
            remPanelIsProcessing = false
            return
        }

        // Build system prompt dynamically — Reminders uses hard-coded rem knowledge,
        // Build system prompt — covers reminders, apps, files, contacts, etc.
        // activeSmartQueryKey is set when user explicitly opens an app panel;
        // fall back to autoDetectedAppKey (set from NSWorkspace app-switch observer).
        let activeKey = activeSmartQueryKey ?? settings.autoDetectedAppKey ?? "reminders"

        // YouTube panel — has its own search/download handler; bypasses AI system prompt
        if activeKey == "youtube" {
            handleYouTubePanelQuery(query: query)
            return
        }

        let ctx = searchContextApp
        let appLabel = ctx?.name ?? settings.customAppEntries.first(where: { $0.key == activeKey })?.label ?? activeKey.capitalized
        // For file/folder contexts, also include "Files & Folders" (finder) extensions
        let isFileContext = ctx?.resultType == .folder || ctx?.resultType == .file || ctx?.resultType == .document
        // Use scored + installed-only extensions (top 5 most relevant to the query)
        let _userQuery = query  // captured before closures
        let toolExts = settings.topExtensions(for: activeKey, query: _userQuery, maxCount: 5) +
            (isFileContext ? settings.topExtensions(for: "finder", query: _userQuery, maxCount: 3).filter { ext in
                !settings.topExtensions(for: activeKey, query: _userQuery, maxCount: 5).contains(where: { $0.toolName == ext.toolName })
            } : [])

        // AI Prompt extensions — always active. For file/folder contexts also include "finder" prompts.
        let promptExts: [AppToolExtension] = {
            var exts = settings.activePromptExtensions(for: activeKey)
            if isFileContext && activeKey != "finder" {
                let finderPrompts = settings.activePromptExtensions(for: "finder")
                    .filter { fp in !exts.contains(where: { $0.id == fp.id }) }
                exts += finderPrompts
            }
            return exts
        }()

        let systemPrompt: String
        // Generic context for non-app results (files, folders, contacts, etc.)
        let isGenericContext = ctx != nil && ctx?.resultType != .application && activeKey != "reminders"
        // Core tool rules — appended to every system prompt
        let toolRules = """

            ══ EXECUTION RULES — READ CAREFULLY ══
            You have exactly THREE callable tools: run_command, spawn_worker, send_keys.
            DO NOT invent other tool names. DO NOT call "reminders", "remind", "notes", or any
            tool name from the AVAILABLE TOOLS section — those are shell commands to run INSIDE run_command.

            ✅ CORRECT — silently invoke the tool:
               run_command(command: "osascript -l JavaScript /path/script.js \\"list today\\"")
            ❌ WRONG — writing JSON or describing what you'll do:
               {"name": "reminders", "parameters": {...}}
               "I will call the reminders tool with..."
               "Here is the function call: ..."

            RULE: ACT FIRST, EXPLAIN AFTER. Never explain a tool call before making it.
            RULE: run_command for any non-interactive shell command or script.
            RULE: For DESTRUCTIVE actions (delete/remove/overwrite) — preview first, confirm, then execute.
            RULE: Summarise output in plain English. Never dump raw output at the user.
            RULE: STAY ON TOPIC — politely decline unrelated requests.

            ══ ERROR DETECTION — CRITICAL ══
            After EVERY run_command, read the output before responding.
            A command FAILED if its output contains ANY of: "Error:", "error:", "Unknown option",
            "Unknown subcommand", "Missing expected", "Invalid", "not found", "Usage:", "USAGE:".
            ▸ NEVER claim an operation succeeded when the output shows an error.
            ▸ NEVER fabricate results — only report what the actual output says.
            ▸ If a command fails with "Unknown subcommand" or similar, IMMEDIATELY run
              run_command("<tool> --help") to get the real subcommand list, then pick the correct one.
            ▸ NEVER guess or invent subcommands from general knowledge — only use what --help shows.
            ▸ If the error output shows a correct usage line, retry with that exact syntax.
            ▸ Only after 2 failed retries should you report the error to the user verbatim.
            """

        // CLI tool panel — build system prompt from the tool's --help text and subcommands
        if ctx?.resultType == .cliTool, let ctx = ctx {
            let toolCmd = ctx.name
            let toolPath = ctx.filePath ?? ctx.appPath
            let pkg = TerminalPackageManager.shared.packages.first(where: {
                $0.name == ctx.name || $0.command == ctx.name
            })
            let isTUI = TerminalAIBridge.shared.isTUICommand(toolCmd)
            // Inject the FULL scanned help tree — this is what prevents hallucination.
            // The AI must only use commands that appear here.
            let helpSnippet: String = {
                guard let ht = pkg?.helpText, !ht.isEmpty else { return "" }
                return "\n\n══ TOOL REFERENCE (exact output of \(toolCmd) --help) ══\n\(String(ht.prefix(4000)))\n══ END TOOL REFERENCE ══"
            }()
            let subcommandList: String = {
                guard let subs = pkg?.subcommands, !subs.isEmpty else { return "" }
                let list = subs.prefix(30).joined(separator: ", ")
                return "\n\n⚠️ VERIFIED SUBCOMMANDS (from --help scan): \(list)\nDO NOT use any subcommand not in this list. If unsure, run `\(toolCmd) --help` first."
            }()
            let launchNote = isTUI
                ? """

This is a full-screen TUI app (ncurses). The embedded terminal panel on the right is where it runs.

HOW TO CONTROL THIS TUI:
1. Launch: spawn_worker(command="\(toolCmd)", purpose="Launch TUI")
2. After launching, wait ~1s for the TUI to draw its first screen, then navigate using send_keys.
3. Menu selection: send_keys(keys="5\\r") sends key "5" then Enter.
4. Arrow keys: "\\u{1B}[A"=up, "\\u{1B}[B"=down, "\\u{1B}[C"=right, "\\u{1B}[D"=left, "\\r"=Enter.
5. Exit: send_keys(keys="q") or send_keys(keys="\\u{03}") for Ctrl-C.

RULES:
- NEVER call run_command('\(toolCmd)') — requires PTY, will fail.
- NEVER call run_command('\(toolCmd) --help') — same reason.
- Use ONLY the stored TOOL REFERENCE below to know menus/options.
- Chain: spawn_worker → (brief pause) → send_keys to automate the TUI for the user.
"""
                : "\nUse run_command for all operations. Pass flags and subcommands as part of the command string."
            // Always inject real home directory — prevents AI from using placeholder /Users/username
            let homeDir = NSHomeDirectory()
            let folderAccessEnabled = settings.isFolderAccessEnabled(for: toolCmd)
            let folderSection: String = {
                if folderAccessEnabled {
                    return """

FOLDER ACCESS: Granted by user.
HOME: \(homeDir)
Downloads: \(homeDir)/Downloads
Documents: \(homeDir)/Documents
Desktop:   \(homeDir)/Desktop
Pictures:  \(homeDir)/Pictures
Movies:    \(homeDir)/Movies
Music:     \(homeDir)/Music
ALWAYS use these exact absolute paths. NEVER use /Users/username or placeholder paths.
"""
                } else {
                    return """

HOME DIRECTORY: \(homeDir)
ALWAYS use this exact home path in commands. NEVER use /Users/username or placeholder paths.
NOTE: User has not granted folder access for \(toolCmd). Avoid reading or writing ~/Documents, ~/Downloads etc. unless the user explicitly asks.
"""
                }
            }()
            systemPrompt = """
            You are an expert AI assistant for the TUI app '\(toolCmd)' inside ILauncher.
            The embedded terminal on the right is where '\(toolCmd)' runs.\(folderSection)\(launchNote)\(helpSnippet)\(subcommandList)
            \(toolRules)
            """
        } else if isGenericContext, let ctx = ctx {
            // Build the explicit path line so AI always knows exactly where to look
            let contextPath: String = ctx.filePath ?? ctx.subtitle
            let isFolder = ctx.resultType == .folder
            let pathDirective: String = {
                if isFolder && !contextPath.isEmpty {
                    return "\nCURRENT FOLDER: \(contextPath)\nALWAYS use this absolute path in every command. Never use relative paths like './' or '~' — use the full path above."
                } else if let fp = ctx.filePath, !fp.isEmpty {
                    return "\nFILE PATH: \(fp)\nAlways reference this exact absolute path in commands."
                }
                return ""
            }()

            let fileToolDocs: String = {
                guard !toolExts.isEmpty else { return "" }
                let pkgs = TerminalPackageManager.shared.packages
                let docs = toolExts.map { ext -> String in
                    if ext.kind == .script, let lang = ext.scriptLanguage, !ext.toolPath.isEmpty {
                        let runCmd = lang.runCommand(scriptPath: ext.toolPath)
                        var doc = "### \(ext.toolName) [SCRIPT – \(lang.rawValue)]"
                        doc += "\nInvoke: run_command(\"\(runCmd) \\\"<full user query>\\\"\") — pass entire query as one arg"
                        let cap = ext.effectiveHint.isEmpty ? ext.aiHint : ext.effectiveHint
                        if !cap.isEmpty { doc += "\n" + String(cap.prefix(400)) }
                        return doc
                    }
                    let pkg = pkgs.first(where: { $0.command == ext.toolName })
                    var doc = "### \(ext.toolName) [CLI]"
                    if let helpText = pkg?.helpText, !helpText.isEmpty {
                        doc += "\n" + String(helpText.prefix(600))
                    } else if !ext.aiHint.isEmpty {
                        doc += "\n" + ext.aiHint
                    }
                    return doc
                }.joined(separator: "\n\n")
                return "\n\nAvailable tools (use via run_command):\n\(docs)"
            }()
            // Inject file-type tool registry snippet for file/folder contexts
            let registrySnippet: String = {
                guard isFileContext else { return "" }
                let registry = FileTypeToolRegistry.shared
                var snippet = ""
                if !isFolder, let filePath = ctx.filePath {
                    let ext = (filePath as NSString).pathExtension
                    snippet = registry.systemPromptSnippet(for: ext)
                    // If no installed tool handles this file type, suggest what to install
                    if snippet.isEmpty {
                        let missing = registry.suggestMissingTools(for: _userQuery.isEmpty ? ext : _userQuery, maxCount: 2)
                        if !missing.isEmpty {
                            let suggestions = missing.map { "brew install \($0.toolName)" }.joined(separator: "  or  ")
                            snippet = "\n\nNo installed tool found for .\(ext) files. Tell the user to install one: \(suggestions)"
                        }
                    }
                } else if isFolder, !contextPath.isEmpty {
                    let fm = FileManager.default
                    var seenExts = Set<String>()
                    if let contents = try? fm.contentsOfDirectory(atPath: contextPath) {
                        for name in contents {
                            let e = (name as NSString).pathExtension.lowercased()
                            if !e.isEmpty { seenExts.insert(e) }
                        }
                    }
                    snippet = registry.systemPromptSnippet(forAnyOf: Array(seenExts))
                    // Suggest missing tools based on query intent (e.g. "compress video" → ffmpeg)
                    if snippet.isEmpty {
                        let missing = registry.suggestMissingTools(for: _userQuery, maxCount: 2)
                        if !missing.isEmpty {
                            let suggestions = missing.map { "  brew install \($0.toolName)  — \($0.description)" }.joined(separator: "\n")
                            snippet = "\n\nNo installed tool matches this request. Suggest the user install:\n\(suggestions)"
                        }
                    }
                }
                return snippet
            }()
            systemPrompt = """
            You are a focused macOS assistant inside ILauncher. \
            The user is working with: \(ctx.aiContextDescription).\(pathDirective)
            Answer ONLY questions about this specific item. \
            Use run_command to inspect or act on it. Be concise.\(fileToolDocs)\(registrySnippet)
            \(toolRules)
            """
        } else if activeKey == "homebrew" {
            let brewBin = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
                ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
            systemPrompt = """
            You are a Homebrew package manager assistant inside ILauncher.
            Homebrew is installed at: \(brewBin)
            Always run brew commands via run_command. Chain multiple commands when needed.

            PACKAGE MANAGEMENT:
            - Install:      brew install <formula>
            - Install cask: brew install --cask <app>        (GUI apps like Chrome, VS Code)
            - Uninstall:    brew uninstall <formula>
            - Upgrade one:  brew upgrade <formula>
            - Upgrade all:  brew upgrade
            - Update brew:  brew update
            - Search:       brew search <term>
            - Info:         brew info <formula>
            - List all:     brew list
            - Top-level:    brew leaves                      (installed, not as deps)
            - Outdated:     brew outdated

            CASK (GUI APPS):
            - List casks:   brew list --cask
            - Outdated:     brew outdated --cask
            - Info:         brew info --cask <app>

            SERVICES (daemons):
            - List:         brew services list
            - Start:        brew services start <formula>
            - Stop:         brew services stop <formula>
            - Restart:      brew services restart <formula>

            MAINTENANCE:
            - Doctor:       brew doctor                       (diagnose issues)
            - Cleanup:      brew cleanup                      (remove old versions, free disk)
            - Cleanup dry:  brew cleanup -n                   (preview what would be removed)
            - Cache size:   du -sh $(brew --cache)
            - Disk usage:   brew list | xargs brew info --json | jq '.[].installed[].installed_on_request'

            TAPS (third-party repos):
            - Add tap:      brew tap <user/repo>
            - Remove tap:   brew untap <user/repo>
            - List taps:    brew tap

            VERSIONS & PINNING:
            - Pin version:  brew pin <formula>               (stops auto-upgrade)
            - Unpin:        brew unpin <formula>
            - Dependencies: brew deps <formula>
            - What uses it: brew uses --installed <formula>

            BREWFILE (backup/restore):
            - Export:       brew bundle dump --file=~/Brewfile --force
            - Restore:      brew bundle install --file=~/Brewfile
            - List:         brew bundle list --file=~/Brewfile

            WORKFLOW RULES:
            - Always run brew update before major installs/upgrades.
            - Use run_command for each brew step; show output to user.
            - For multi-step tasks (update + upgrade + cleanup), chain with &&.
            - When user asks to "install X", first run brew search X to confirm exact name.
            - When listing packages, use brew list --versions for cleaner output.
            - For disk cleanup suggestions, run brew cleanup -n first so user can approve.
            \(toolRules)
            """
        } else if activeKey == "amphetamine" {
            systemPrompt = """
            You are an Amphetamine assistant inside ILauncher.
            Amphetamine is a macOS app that prevents the Mac from sleeping.
            Control it using osascript (AppleScript) via run_command. Never use caffeinate.

            FULL APPLESCRIPT API (always wrap with: osascript -e '...'):

            START SESSION:
            - Default: osascript -e 'tell application "Amphetamine" to start new session'
            - Timed:   osascript -e 'tell application "Amphetamine" to start new session with options {duration:30, interval:minutes, displaySleepAllowed:false}'
            - Hours:   osascript -e 'tell application "Amphetamine" to start new session with options {duration:2, interval:hours, displaySleepAllowed:true}'
            - interval is either: minutes  OR  hours

            END SESSION:
            - osascript -e 'tell application "Amphetamine" to end session'

            DISPLAY SLEEP:
            - osascript -e 'tell application "Amphetamine" to allow display sleep'
            - osascript -e 'tell application "Amphetamine" to prevent display sleep'

            SCREEN SAVER:
            - osascript -e 'tell application "Amphetamine" to allow screen saver'
            - osascript -e 'tell application "Amphetamine" to prevent screen saver'

            CLOSED DISPLAY MODE:
            - osascript -e 'tell application "Amphetamine" to enable closed display mode'
            - osascript -e 'tell application "Amphetamine" to disable closed display mode'

            QUERY STATUS (run_command, read the output):
            - Is active?:       osascript -e 'tell application "Amphetamine" to return session is active'
            - Time remaining:   osascript -e 'tell application "Amphetamine" to return session time remaining'
              (returns seconds; 0=infinite, -1=trigger, -2=app/date-based, -3=no session)
            - Display sleep?:   osascript -e 'tell application "Amphetamine" to return display sleep allowed'
            - Is trigger?:      osascript -e 'tell application "Amphetamine" to return session is Trigger'

            RULES:
            - ALWAYS use osascript -e '...' via run_command. Never use caffeinate.
            - To check if Amphetamine is running: run_command(command="pgrep -x Amphetamine")
            - If not running, tell user to open it first (open -a Amphetamine).
            - After "notify when ends": after starting a timed session, also call:
              run_command(command="osascript -e 'tell application \\"Amphetamine\\" to start new session with options {duration:N, interval:minutes, displaySleepAllowed:false}' && sleep Ns && osascript -e 'display notification \\"Amphetamine session ended\\" with title \\"Amphetamine\\"'")
            - Convert natural language time: "1 hour" → duration:1, interval:hours; "45 minutes" → duration:45, interval:minutes
            - Give a short friendly confirmation after each action.
            \(toolRules)
            """
        } else if !promptExts.isEmpty && toolExts.isEmpty {
            // ── PURE PROMPT EXTENSION — no CLI/script tools, AI answers directly ──
            // Render the first prompt's template; subsequent prompts are appended.
            let rendered = promptExts.map { ext in
                PromptRunner.shared.render(template: ext.promptTemplate, query: query, appLabel: appLabel)
            }.joined(separator: "\n\n---\n\n")
            systemPrompt = rendered

        } else if !toolExts.isEmpty {
            // USER-SET AI EXTENSIONS — always take priority over built-in hardcoded prompts.
            // Supports CLI tools (binaries on $PATH) AND user scripts (JXA, bash, Python, AppleScript, Lua).
            // If prompt extensions also exist, their rendered template becomes the persona/intro.
            let pkgs = TerminalPackageManager.shared.packages

            let toolDocs = toolExts.map { ext -> String in
                if ext.kind == .script, let lang = ext.scriptLanguage, !ext.toolPath.isEmpty {
                    // ── SCRIPT EXTENSION ───────────────────────────────────────
                    let runCmd = lang.runCommand(scriptPath: ext.toolPath)
                    var doc = "### \(ext.toolName) [SCRIPT – \(lang.rawValue)]"
                    if ext.profile.isDestructive { doc += " ⚠️ DESTRUCTIVE" }
                    doc += "\nInvoke with: run_command(\"\(runCmd) \\\"<full user query as one arg>\\\"\")"
                    doc += "\nPASS THE ENTIRE user query as a single quoted argument — the script handles all parsing internally."
                    // Capability description from aiHint / profile
                    let cap = ext.effectiveHint.isEmpty ? ext.aiHint : ext.effectiveHint
                    if !cap.isEmpty { doc += "\nCapabilities: " + String(cap.prefix(500)) }
                    if !ext.profile.exampleCommands.isEmpty {
                        doc += "\nExamples: " + ext.profile.exampleCommands.joined(separator: " | ")
                    }
                    return doc
                } else {
                    // ── CLI TOOL EXTENSION ─────────────────────────────────────
                    let cmd  = ext.effectiveCommand  // "memo notes" or "memo rem" — scoped per app
                    let base = ext.toolName          // "memo" — binary name for package lookup
                    let pkg  = pkgs.first(where: { $0.command == base })
                    var doc  = "### \(cmd) [CLI]"
                    if cmd != base { doc += "  (binary: \(base))" }
                    if let path = pkg?.installedPath ?? (ext.toolPath.isEmpty ? nil : ext.toolPath) {
                        doc += " at \(path)"
                    }
                    if ext.profile.isDestructive { doc += " ⚠️ DESTRUCTIVE" }
                    doc += "\n"
                    // Prefer scoped subcommand help; fall back to full help or hints
                    let scopedHelp = TerminalPackageManager.shared.helpText(for: cmd, baseCommand: base)
                    let helpSource: String
                    if let sh = scopedHelp, !sh.isEmpty {
                        helpSource = String(sh.prefix(1000))
                    } else if ext.aiHint.contains("--help output:") {
                        helpSource = String(ext.aiHint.prefix(1000))
                    } else if !ext.effectiveHint.isEmpty {
                        helpSource = ext.effectiveHint
                    } else {
                        helpSource = ""
                    }
                    if !helpSource.isEmpty {
                        doc += helpSource
                    } else {
                        doc += "UNKNOWN: Call run_command(\"\(cmd) --help\") first, read output, then answer."
                    }
                    // Context flag — always append this flag to every command for this app panel
                    if !ext.appContextFlag.isEmpty {
                        doc += "\n⚑ CONTEXT FLAG: You MUST append `\(ext.appContextFlag)` to EVERY \(base) command for \(appLabel)."
                        doc += "\n  Example: run_command(\"\(cmd) list \(ext.appContextFlag)\")"
                        doc += "\n  Example: run_command(\"\(cmd) add \(ext.appContextFlag) \\\"Buy milk\\\"\")"
                    }
                    if !ext.profile.exampleCommands.isEmpty {
                        doc += "\nExamples: " + ext.profile.exampleCommands.joined(separator: " | ")
                    }
                    return doc
                }
            }.joined(separator: "\n\n---\n\n")

            // Intent → invocation hints per tool
            let intentLines = toolExts.map { ext -> String in
                if ext.kind == .script, let lang = ext.scriptLanguage, !ext.toolPath.isEmpty {
                    let runCmd = lang.runCommand(scriptPath: ext.toolPath)
                    return "• \(ext.toolName): run_command(\"\(runCmd) \\\"<full user query>\\\"\")"
                }
                let cmd = ext.effectiveCommand
                let ctxFlag = ext.appContextFlag.isEmpty ? "" : " \(ext.appContextFlag)"
                if !ext.profile.capabilities.isEmpty {
                    return "• \(cmd): " + ext.profile.capabilities.prefix(4).joined(separator: " | ")
                        + (ctxFlag.isEmpty ? "" : "  [always append \(ext.appContextFlag)]")
                }
                return "• \(cmd): list → \(cmd) list\(ctxFlag)  |  add → \(cmd) add\(ctxFlag) \"<title>\"  |  delete → \(cmd) delete\(ctxFlag) <id>"
            }.joined(separator: "\n")

            let hasDestructiveTool = toolExts.contains { $0.profile.isDestructive }
            let destructiveWarning = hasDestructiveTool
                ? "\n- ⚠️ One or more tools are DESTRUCTIVE. Always confirm with the user before running delete/remove/overwrite operations."
                : ""

            // If user has a prompt extension too, its rendered template becomes the persona intro.
            // Strip any "User's question: {{query}}" lines — the query is already the user message.
            let promptPersona: String = promptExts.isEmpty ? "" : {
                let rendered = promptExts.map { ext in
                    var t = PromptRunner.shared.render(template: ext.promptTemplate, query: query, appLabel: appLabel)
                    // Remove lines that redundantly embed the query — causes AI to answer in text instead of tool-calling
                    t = t.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                        let l = line.lowercased()
                        return !l.hasPrefix("user's question:") && !l.hasPrefix("user question:")
                            && !l.contains(query.lowercased().prefix(20))
                    }.joined(separator: "\n")
                    return t.trimmingCharacters(in: .whitespacesAndNewlines)
                }.joined(separator: "\n\n")
                return rendered.isEmpty ? "" : rendered + "\n\n"
            }()

            systemPrompt = """
            \(promptPersona)You are an AI assistant for \(appLabel) inside ILauncher.
            Only help with tasks related to \(appLabel).
            All tools run silently via run_command — no terminal is shown. \
            Their output is returned to you; always summarise it in plain English.

            AVAILABLE TOOLS (user-configured for \(appLabel)):
            \(toolDocs)

            HOW TO INVOKE EACH TOOL:
            \(intentLines)

            RULES:
            - For SCRIPT tools: always pass the user's FULL original query as a single argument in quotes.
            - For CLI tools: use ONLY the exact flags and subcommands documented in AVAILABLE TOOLS above.
              Never guess flags. If you're unsure of exact syntax, run "<tool> help <subcommand>" first.
            - The AVAILABLE TOOLS section contains the full --help tree (all subcommand levels).
              Always check the relevant subcommand section before forming a command.
            - For "find/search X": use the search or list subcommand as shown in help.
            - For "create/add X": always check the correct add subcommand syntax before running.
            - Never dump raw output — always give a clean plain-English summary.\(destructiveWarning)
            \(toolRules)
            """
        } else if activeKey == "finder" {
            let finderDir = ContextDetector.shared.getCurrentFinderDirectory() ?? NSHomeDirectory()
            let selectedFiles = ContextDetector.shared.getFinderSelectedFiles()
            let selectedNote = selectedFiles.isEmpty
                ? ""
                : "\nSELECTED FILES:\n" + selectedFiles.prefix(5).map { "  • \($0)" }.joined(separator: "\n")
            let toolContext = FinderToolkit.shared.systemPromptContext()
            systemPrompt = """
            You are a Finder file management assistant inside ILauncher.
            You help users organize, find, rename, and manage files using shell commands and installed scripts.

            CURRENT FINDER DIRECTORY: \(finderDir)\(selectedNote)

            \(toolContext)

            CRITICAL RULES:
            - You are a FILE MANAGER assistant. Do NOT search contacts, photos, or calendars.
            - ALWAYS use run_command to execute operations — never just describe what to do.
            - For destructive operations (sort/organize/rename/delete): ALWAYS run the --dry-run version first,
              show the output to the user, and ask "Shall I proceed?" before running for real.
            - When user asks "show all PDFs" / "list files": run a find command immediately.
            - When user asks "how do I X": use the Find Cmd script to search for the right command.
            - Summarize command output in plain English — never dump raw terminal output.
            - Home directory is: \(NSHomeDirectory())
            \(toolRules)
            """

        } else if activeKey == "reminders" {
            // Fallback: no user extensions set — use built-in rem CLI if installed
            let remPath = ["/opt/homebrew/bin/rem", "/usr/local/bin/rem"]
                .first { FileManager.default.fileExists(atPath: $0) }
            let remNote = remPath != nil
                ? "rem is installed at \(remPath!)."
                : "The `rem` CLI is not installed. Tell the user to run: brew install rem"
            systemPrompt = """
            You are a Reminders assistant inside ILauncher.
            \(remNote)
            You manage macOS Reminders using the `rem` CLI via run_command (runs silently, no terminal).

            rem examples:
            - rem add "call mom" --due "tomorrow at 5pm"
            - rem list
            - rem complete "call mom"
            - rem delete "call mom"
            - rem search "mom"

            Natural language dates work: "tomorrow at 3pm", "next friday", "in 2 hours".
            TIP: User can assign a different CLI (e.g. memo) in Settings → App Shortcuts → Reminders → AI Extensions.
            After actions, give a short friendly confirmation. Summarise lists — don't dump raw JSON.
            \(toolRules)
            """
        } else {
            // Generic fallback — no user extensions, no built-in CLI known
            systemPrompt = """
            You are an AI assistant for \(appLabel) inside ILauncher.
            Only help with tasks related to \(appLabel).
            Run shell commands via run_command (runs silently in the background — no terminal shown).
            TIP: Assign CLI tools in Settings → App Shortcuts → \(appLabel) → AI Extensions to unlock more actions.
            \(toolRules)
            """
        }

        // Build history from chat for multi-turn context (exclude .tool command chips — visual only)
        let history: [ChatMessage] = remPanelChatMessages.dropLast()
            .filter { $0.role != .tool }
            .map { ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.content) }

        // Capture folder path for command fixup (folder panel context)
        let contextFolderPath: String? = {
            guard let ctx = ctx, ctx.resultType == .folder else { return nil }
            let p = ctx.filePath ?? ctx.subtitle
            return p.isEmpty ? nil : p
        }()

        // Check prompt extension cache — if we get a hit, skip the full AI round-trip
        if let cacheHit = promptExts.first.flatMap({ PromptRunner.shared.cachedResponse(for: $0, query: query) }) {
            remPanelChatMessages.append(AIChatMessage(role: .assistant, content: cacheHit))
            remPanelIsProcessing = false
            return
        }

        remPanelAITask = Task {
            do {
                let (response, executedCommands) = try await AIProviderService.shared.sendWithTools(
                    query,
                    context: .none,
                    provider: provider,
                    apiKey: apiKey,
                    conversationHistory: history,
                    commandExecutor: { cmd, purpose in
                        // Fix relative paths: if AI used "find . ..." or "ls" without absolute path
                        // and we're in a folder context, rewrite to use the folder's absolute path
                        let fixedCmd: String = {
                            guard let folderPath = contextFolderPath else { return cmd }
                            var c = cmd
                            // find . → find /absolute/path
                            if c.hasPrefix("find . ") || c == "find ." {
                                c = "find " + folderPath + c.dropFirst(6)
                            } else if c.hasPrefix("find ./ ") {
                                c = "find " + folderPath + "/" + c.dropFirst(8)
                            }
                            // ls (no args or just flags) → ls folderPath
                            if c == "ls" || c.range(of: #"^ls\s+-[a-zA-Z]+$"#, options: .regularExpression) != nil {
                                c = c + " " + folderPath
                            }
                            // du . → du folderPath
                            if c.hasPrefix("du . ") || c == "du ." {
                                c = "du " + folderPath + c.dropFirst(4)
                            }
                            return c
                        }()
                        // Show command chip in chat + open embedded panel terminal
                        await MainActor.run {
                            self.remPanelChatMessages.append(AIChatMessage(
                                role: .tool,
                                content: "$ \(fixedCmd)"
                            ))
                            let ck = self.activeConsoleKey
                            self.panelShowConsoleMap[ck] = true
                            // Ensure panel PTY exists before command fires
                            _ = self.panelTerminal(for: ck)
                        }
                        let result = await TerminalAIBridge.shared.processAICommand(fixedCmd, purpose: purpose)
                        // Also send approved command to the panel's embedded PTY for live display
                        await MainActor.run {
                            let ck = self.activeConsoleKey
                            self.panelTerminalControllers[ck]?.sendCommand(fixedCmd)
                        }
                        // Post-execution: file detection / live panel (streaming already filled output lines)
                        await MainActor.run {
                            let ck = self.activeConsoleKey
                            // If the command created a file, auto-show its preview
                            if result.success, let createdURL = self.detectCreatedFile(command: fixedCmd, output: result.output) {
                                self.showLivePanel(.filePreview(url: createdURL))
                            } else if result.success || !result.output.isEmpty {
                                // Parse output → right panel results (files, tasks, processes, events, etc.)
                                let resultEntries = self.parseCommandOutputForPanel(
                                    command: fixedCmd,
                                    output: result.output,
                                    panelKey: activeKey
                                )
                                if !resultEntries.isEmpty {
                                    self.showLivePanel(.results(resultEntries))
                                }
                            }
                        }
                        return result
                    },
                    systemPromptOverride: systemPrompt
                )
                await MainActor.run {
                    // Strip any leaked raw tool-call syntax the AI accidentally included in its text reply
                    let cleanResponse = Self.stripLeakedToolCalls(response)
                    if !cleanResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        remPanelChatMessages.append(AIChatMessage(role: .assistant, content: cleanResponse))
                        // Cache the response for pure-prompt extensions (no commands were run)
                        if executedCommands.isEmpty, let pExt = promptExts.first {
                            PromptRunner.shared.cacheResponse(cleanResponse, for: pExt, query: query)
                        }
                    }
                    remPanelIsProcessing = false
                    appPanelAllItems = []
                    reloadAppPanelData(for: "reminders")
                    // Auto-switch live panel to terminal if spawn_worker was used
                    let spawnedTUI = executedCommands.contains { $0.command.hasPrefix("spawn_worker") }
                    if spawnedTUI { showLivePanel(.terminal) }
                }
            } catch AIServiceError.unsupportedProvider(_) {
                // Ollama: ask AI to output the rem command as plain text, then run it
                await handleRemPanelQueryLegacy(query: query, systemPrompt: systemPrompt, provider: provider, apiKey: apiKey)
            } catch {
                await MainActor.run {
                    remPanelChatMessages.append(AIChatMessage(role: .assistant,
                        content: "⚠️ \(error.localizedDescription)", isError: true))
                    remPanelIsProcessing = false
                }
            }
        }
    }

    /// Fallback for Ollama (no tool_use): ask AI to output a rem command, then run it directly.
    private func handleRemPanelQueryLegacy(query: String, systemPrompt: String, provider: AIProvider, apiKey: String?) async {
        let legacySystemMsg = systemPrompt + "\n\nIMPORTANT: Respond with ONLY the exact shell command to run (starting with `rem`), nothing else.\nExample: rem add \"buy milk\" --due \"tomorrow at 9am\""
        let historyWithSystem: [ChatMessage] = [ChatMessage(role: .system, content: legacySystemMsg)]
        do {
            let response = try await AIProviderService.shared.sendMessage(
                query,
                context: .none,
                provider: provider,
                apiKey: apiKey,
                conversationHistory: historyWithSystem
            )
            // Extract the rem command from the AI response
            let lines = response.components(separatedBy: .newlines)
            let cmd = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("rem ") })
                ?? lines.first(where: { $0.contains("rem ") })
                ?? ""
            let remCmd = cmd.trimmingCharacters(in: .init(charactersIn: "`\" "))
            if remCmd.isEmpty {
                await MainActor.run {
                    remPanelChatMessages.append(AIChatMessage(role: .assistant,
                        content: "I couldn't figure out the right rem command. Try being more specific, e.g. \"add buy milk tomorrow at 9am\""))
                    remPanelIsProcessing = false
                }
                return
            }
            let (success, output) = await TerminalAIBridge.shared.processAICommand(remCmd, purpose: "rem")
            await MainActor.run {
                let reply = success
                    ? "✅ Done! Ran: `\(remCmd)`\n\(output.isEmpty ? "" : output)"
                    : "❌ Failed: `\(remCmd)`\n\(output)"
                remPanelChatMessages.append(AIChatMessage(role: .assistant, content: reply, isError: !success))
                remPanelIsProcessing = false
                appPanelAllItems = []
                reloadAppPanelData(for: "reminders")
            }
        } catch {
            await MainActor.run {
                remPanelChatMessages.append(AIChatMessage(role: .assistant,
                    content: "⚠️ \(error.localizedDescription)", isError: true))
                remPanelIsProcessing = false
            }
        }
    }

    private func checkRemInstalled() {
        Task {
            // Check known install paths directly — app doesn't inherit shell PATH
            let home = NSHomeDirectory()
            let knownPaths = [
                "/usr/local/bin/rem",
                "/opt/homebrew/bin/rem",
                "\(home)/.local/bin/rem",
                "\(home)/go/bin/rem",
                "\(home)/.cargo/bin/rem",
                "\(home)/bin/rem"
            ]
            let fm = FileManager.default
            if knownPaths.contains(where: { fm.fileExists(atPath: $0) }) {
                await MainActor.run { remIsInstalled = true }
                return
            }
            // Fallback: login shell which — loads user's full PATH
            let proc = Process()
            proc.launchPath = "/bin/bash"
            proc.arguments = ["-l", "-c", "which rem"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run { remIsInstalled = proc.terminationStatus == 0 }
        }
    }

    private func installRem() {
        // Copy install command to clipboard — user runs it in their own terminal
        // (curl|bash is blocked by TerminalAIBridge security policy, correctly so)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("curl -fsSL https://rem.sidv.dev/install | bash", forType: .string)
        remPanelChatMessages.append(AIChatMessage(role: .assistant,
            content: "📋 Install command copied to clipboard!\n\nPaste it in Terminal:\n```\ncurl -fsSL https://rem.sidv.dev/install | bash\n```\nAnswer **n** when asked about the AI agent skill — ILauncher uses your selected provider (\(AppSettings.shared.selectedAIProvider.shortName)) instead.\n\nAlternatively: open ILauncher terminal → type \"install rem\" → AI will handle it."))
    }

    private enum L2RouteDecision {
        case none
        case systemSearch(types: Set<SystemDataType>, title: String, query: String, allowEmpty: Bool)
        case contactSearch(query: String)
        case terminalCommand(command: String, purpose: String)
    }

    private func routeL2QueryDecision(query: String, frontmostName: String?, selectedFiles: [URL]) -> L2RouteDecision {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .none }

        // Action verbs mean the user wants to DO something, not just look things up.
        // These queries must fall through to the AI (Layer 5) so it can execute
        // cross-app operations like "save this link to Notes" or "add a reminder".
        let actionVerbs = ["save", "add", "create", "new", "put", "store", "move", "copy",
                           "send", "share", "delete", "remove", "update", "edit", "rename",
                           "make", "write", "set", "book", "schedule", "open", "launch",
                           "download", "export", "import", "convert", "compress", "extract"]
        let isActionQuery = actionVerbs.contains(where: { normalized.hasPrefix($0) || normalized.contains(" \($0) ") })
        if isActionQuery { return .none }

        // When Contacts app is frontmost, any non-action query is a contact lookup
        let isContactsApp = frontmostName?.lowercased().contains("contact") == true
        if isContactsApp {
            return .contactSearch(query: query)
        }

        // Explicit contact keywords
        let contactKeywords = ["contact", "contacts", "call", "phone", "text", "sms", "imessage"]
        if contactKeywords.contains(where: { normalized.contains($0) }) {
            return .contactSearch(query: query)
        }

        // Name-lookup patterns: "find gowri", "show gokula address", "get X phone number"
        let lookupPrefixes = ["find ", "show ", "get ", "look up ", "lookup ", "search for ", "who is "]
        let contactFields = ["address", "number", "birthday", "birthday", "mobile", "office"]
        let hasLookupPrefix = lookupPrefixes.contains { normalized.hasPrefix($0) }
        let hasContactField = contactFields.contains { normalized.contains($0) }
        if hasLookupPrefix || hasContactField {
            return .contactSearch(query: query)
        }

        let photoKeywords = ["photo", "photos", "image", "images", "picture", "pictures", "screenshot"]
        if photoKeywords.contains(where: { normalized.contains($0) }) {
            return .systemSearch(types: [.photo], title: "Photos", query: normalized, allowEmpty: normalized == "photos" || normalized == "photo")
        }

        if let terminal = terminalCommandFromQuery(query: query, selectedFiles: selectedFiles) {
            return .terminalCommand(command: terminal.command, purpose: terminal.purpose)
        }

        return .none
    }

    private func handleL2RouteDecision(_ decision: L2RouteDecision, query: String) -> Bool {
        switch decision {
        case .none:
            return false
        case .systemSearch(let types, let title, let searchQuery, let allowEmpty):
            l2ChatMessages.append(AIChatMessage(role: .user, content: query))
            l2IsLoading = true
            l2CurrentTask = Task {
                let results = await systemDataManager.searchAll(
                    query: searchQuery,
                    types: types,
                    perTypeLimit: 20,
                    allowEmptyQuery: allowEmpty
                )
                let searchResults = mapSystemResultsToSearchResults(results)
                await MainActor.run {
                    if searchResults.isEmpty {
                        l2ChatMessages.append(AIChatMessage(role: .assistant, content: "No \(title.lowercased()) results found."))
                    } else {
                        l2ChatMessages.append(AIChatMessage(role: .assistant, content: "Found \(searchResults.count) \(title.lowercased()) item(s)."))
                    }
                    updateL2Results(searchResults)
                    l2IsLoading = false
                    l2CurrentTask = nil
                }
                if shouldSuggestExtensionForQuery(query) {
                    if let suggestion = buildL2SuggestedExtensionResponse(for: decision, query: query) {
                        await handleL2AIResponse(suggestion)
                    }
                }
            }
            return true
        case .contactSearch(let searchQuery):
            l2ChatMessages.append(AIChatMessage(role: .user, content: query))
            l2IsLoading = true
            l2CurrentTask = Task {
                let results = await searchContactsForL2(query: searchQuery)
                await MainActor.run {
                    if results.isEmpty {
                        l2ChatMessages.append(AIChatMessage(role: .assistant, content: "No matching contacts found for \"\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))\"."))
                    } else {
                        l2ChatMessages.append(AIChatMessage(role: .assistant, content: "Found \(results.count) contact(s)."))
                    }
                    updateL2Results(results)
                    l2IsLoading = false
                    l2CurrentTask = nil
                }
                // Do NOT fall through to AI extension creation for contact searches —
                // the contact extensions in the dock already cover all contact actions.
            }
            return true
        case .terminalCommand(let command, let purpose):
            l2ChatMessages.append(AIChatMessage(role: .user, content: query))
            l2IsLoading = true
            l2CurrentTask = Task {
                let (success, output) = await TerminalAIBridge.shared.processAICommand(command, purpose: purpose)
                await MainActor.run {
                    let status = success ? "Command executed." : "Command blocked or failed."
                    let response = """
                    \(status)

                    \(output)
                    """
                    l2ChatMessages.append(AIChatMessage(role: .assistant, content: response))
                    updateL2Results(buildL2OutputResults(title: "Terminal Output", output: output))
                    l2IsLoading = false
                    l2CurrentTask = nil
                }
            }
            return true
        }
    }

    private func terminalCommandFromQuery(query: String, selectedFiles: [URL]) -> (command: String, purpose: String)? {
        var raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.lowercased()

        if raw.hasPrefix("$") || raw.hasPrefix(">") {
            raw.removeFirst()
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                return (raw, "Run requested terminal command")
            }
        }

        if normalized.contains("list files") || normalized.contains("show files") {
            return ("ls -la", "List directory contents")
        }

        if normalized.contains("disk space") {
            return ("df -h", "Show disk space")
        }

        if normalized.contains("disk usage") || normalized.contains("folder size") {
            return ("du -sh .", "Show folder size")
        }

        if normalized.contains("git status") {
            return ("git status", "Show git status")
        }

        if normalized.contains("current directory") || normalized == "pwd" {
            return ("pwd", "Show current directory")
        }

        if selectedFiles.count >= 1 {
            let file = selectedFiles[0]
            let filePath = file.path
            let fileName = file.lastPathComponent
            let nameNoExt = file.deletingPathExtension().lastPathComponent
            let parentDir = file.deletingLastPathComponent().path

            // Zip / compress
            if normalized.contains("zip") || normalized.contains("compress") || normalized.contains("archive") {
                let outPath = "\(parentDir)/\(nameNoExt).zip"
                return (
                    "zip -r \"\(outPath)\" \"\(filePath)\" && echo \"✅ Saved to: \(outPath)\"",
                    "Compress \(fileName) → \(nameNoExt).zip"
                )
            }

            // Unzip / extract
            if normalized.contains("unzip") || normalized.contains("extract") {
                let outDir = "\(parentDir)/\(nameNoExt)_extracted"
                return (
                    "unzip -o \"\(filePath)\" -d \"\(outDir)\" && echo \"✅ Extracted to: \(outDir)\"",
                    "Extract \(fileName)"
                )
            }

            // Open in Finder
            if normalized.contains("reveal in finder") || normalized.contains("show in finder") || normalized.contains("open in finder") {
                return ("open -R \"\(filePath)\"", "Reveal \(fileName) in Finder")
            }

            // Open in Terminal
            if normalized.contains("open in terminal") || normalized.contains("open terminal here") || normalized.contains("terminal here") {
                let dir = file.hasDirectoryPath ? filePath : parentDir
                return ("open -a Terminal \"\(dir)\"", "Open Terminal at \(fileName)")
            }

            // File size / info
            if normalized.contains("file size") || normalized.contains("how big") || normalized.contains("how large") {
                return ("du -sh \"\(filePath)\"", "Show size of \(fileName)")
            }

            // MD5 / checksum
            if normalized.contains("md5") || normalized.contains("checksum") || normalized.contains("hash") {
                return ("md5 \"\(filePath)\"", "MD5 checksum of \(fileName)")
            }

            // Rename
            if normalized.contains("rename") {
                // Can't rename without a new name — route to AI tool-use
            } else if selectedFiles.count == 1 {
                if normalized.contains("show file") || normalized.contains("cat ") || normalized.contains("print file") {
                    return ("cat \"\(filePath)\"", "Show file contents")
                }
                if normalized.contains("count lines") || normalized.contains("line count") {
                    return ("wc -l \"\(filePath)\"", "Count lines in file")
                }
            }
        }

        let firstToken = normalized.split(separator: " ").first.map(String.init) ?? ""
        let commandStarters: Set<String> = ["ls", "cat", "head", "tail", "grep", "find", "du", "df", "pwd", "whoami", "date", "uptime", "ps", "git"]
        if commandStarters.contains(firstToken) {
            let classification = TerminalCommandClassifier.shared.classify(raw)
            if classification.canExecute {
                return (raw, classification.explanation)
            }
        }

        return nil
    }

    private func mapSystemResultsToSearchResults(_ systemResults: [SystemSearchResult]) -> [SearchResult] {
        systemResults.map { systemResult in
            let resultType: SearchResult.ResultType
            switch systemResult.type {
            case .calendarEvent:
                resultType = .calendarEvent
            case .reminder:
                resultType = .reminder
            case .note:
                resultType = .note
            case .mail:
                resultType = .mail
            case .photo:
                resultType = .photo
            case .message:
                resultType = .message
            case .voiceRecording, .contact:
                resultType = .file
            }

            return SearchResult(
                title: systemResult.title,
                subtitle: systemResult.subtitle,
                icon: systemResult.icon,
                action: { systemResult.open() },
                score: 0.0,
                type: resultType,
                filePath: nil,
                contactData: nil
            )
        }
    }

    private func searchContactsForL2(query: String) async -> [SearchResult] {
        if !settings.allowContacts {
            return []
        }

        if !contactManager.hasContactsPermission {
            let granted = await contactManager.requestPermission()
            if !granted { return [] }
        }

        let contactResults = await contactManager.getAllContacts()
        let normalized = query.lowercased()
        let ignoreTokens: Set<String> = [
            // explicit contact keywords
            "contact", "contacts", "email", "mail", "message", "call", "phone", "text", "sms", "imessage",
            // lookup verbs and prepositions
            "find", "show", "get", "look", "up", "lookup", "search", "who", "is", "whois",
            // field names / info words people append to queries
            "address", "number", "mobile", "office", "birthday", "info", "detail", "details",
            "full", "profile", "about", "data", "record", "summary",
            // stop words
            "to", "for", "the", "a", "an", "of", "me", "my", "their", "his", "her", "tell", "what", "give"
        ]
        let tokens = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !ignoreTokens.contains($0) }

        let filtered = contactResults.filter { contact in
            let haystack = [
                contact.fullName,
                contact.primaryEmail,
                contact.primaryPhone,
                contact.subtitle
            ]
            .map { $0.lowercased() }
            .joined(separator: " ")

            guard !tokens.isEmpty else { return true }
            return tokens.allSatisfy { haystack.contains($0) }
        }

        let limited = Array(filtered.prefix(20))
        return limited.map { contact in
            SearchResult(
                title: contact.fullName,
                subtitle: contact.subtitle,
                icon: contact.image,
                action: {
                    contact.openInContacts()
                },
                type: .contact,
                filePath: nil,
                contactData: SearchResult.ContactData(
                    primaryEmail: contact.primaryEmail,
                    allEmails: contact.allEmails,
                    primaryPhone: contact.primaryPhone,
                    allPhones: contact.allPhones,
                    identifier: contact.identifier
                )
            )
        }
    }

    private func shouldSuggestExtensionForQuery(_ query: String) -> Bool {
        let frontmostName = frontmostAppName.isEmpty ? nil : frontmostAppName
        let selectedFiles: [URL] = {
            if case .filesSelected(let urls) = currentContext { return urls }
            return []
        }()
        let matches = LayeredExtensionManager.shared.discoverExtensions(
            for: query,
            selectedFiles: selectedFiles,
            frontmostApp: frontmostName,
            layer: .l2_context
        )
        return matches.isEmpty
    }

    private func buildL2SuggestedExtensionResponse(for decision: L2RouteDecision, query: String) -> String? {
        switch decision {
        case .systemSearch(let types, _, _, _):
            if types.contains(.photo) {
                if let suggestion = buildPhotosExtensionSuggestion(query: query) {
                    return suggestion
                }
            }
            if types.contains(.calendarEvent) {
                if let suggestion = buildCalendarExtensionSuggestion(query: query) {
                    return suggestion
                }
            }
            if types.contains(.reminder) {
                if let suggestion = buildRemindersExtensionSuggestion(query: query) {
                    return suggestion
                }
            }
            if types.contains(.note) {
                if let suggestion = buildNotesExtensionSuggestion(query: query) {
                    return suggestion
                }
            }
            if types.contains(.mail) {
                if let suggestion = buildMailExtensionSuggestion(query: query) {
                    return suggestion
                }
            }
            if types.contains(.message) {
                if let suggestion = buildMessagesExtensionSuggestion(query: query) {
                    return suggestion
                }
            }
            return nil
        case .contactSearch:
            return buildContactsExtensionSuggestion(query: query)
        case .terminalCommand, .none:
            return nil
        }
    }

    private func buildPhotosExtensionSuggestion(query: String) -> String? {
        let normalized = query.lowercased()
        let count = parseFirstInt(from: normalized) ?? 10
        if normalized.contains("recent") || normalized.contains("latest") {
            return """
            [SUGGEST_EXTENSION]
            {
                "name": "Recent Photos (\(count))",
                "description": "List the most recent \(count) photos from your Pictures folder.",
                "app": "Photos",
                "code": "#!/bin/bash\\n# Extension: Recent Photos (\\(count))\\n# Description: Lists the most recent \\(count) images from your Pictures folder.\\n# Trigger: recent photos\\n# Layer: l2_context\\n\\nCOUNT=\\(count)\\nROOT=\\\"$HOME/Pictures\\\"\\nmdfind -onlyin \\\"$ROOT\\\" \\\"kMDItemContentTypeTree == 'public.image'\\\" | while IFS= read -r file; do\\n  stat -f \\\"%m %N\\\" \\\"$file\\\"\\ndone | sort -rn | head -n \\\"$COUNT\\\" | cut -d' ' -f2-\\n"
            }
            [/SUGGEST_EXTENSION]
            """
        }

        if let term = extractTerm(after: ["photos of", "pictures of", "images of"], from: query) {
            let safeTerm = term.replacingOccurrences(of: "\"", with: "")
            return """
            [SUGGEST_EXTENSION]
            {
                "name": "Photos of \(safeTerm)",
                "description": "Find photos matching '\(safeTerm)' in your Pictures folder.",
                "app": "Photos",
                "code": "#!/bin/bash\\n# Extension: Photos of \(safeTerm)\\n# Description: Finds images that match the name or keywords.\\n# Trigger: photos of \(safeTerm)\\n# Layer: l2_context\\n\\nTERM=\\\"\(safeTerm)\\\"\\nROOT=\\\"$HOME/Pictures\\\"\\nmdfind -onlyin \\\"$ROOT\\\" \\\"kMDItemContentTypeTree == 'public.image' && (kMDItemFSName == '*$TERM*' || kMDItemKeywords == '*$TERM*')\\\" | head -n 50\\n"
            }
            [/SUGGEST_EXTENSION]
            """
        }

        return nil
    }

    private func buildCalendarExtensionSuggestion(query: String) -> String? {
        let normalized = query.lowercased()
        let days = normalized.contains("today") ? 1 : 7
        return """
        [SUGGEST_EXTENSION]
        {
            "name": "Upcoming Calendar Events",
            "description": "List upcoming calendar events for the next \(days) day(s).",
            "app": "Calendar",
            "code": "#!/bin/bash\\n# Extension: Upcoming Calendar Events\\n# Description: Lists upcoming events for the next \(days) day(s).\\n# Trigger: calendar\\n# Layer: l2_context\\n\\nosascript <<'APPLESCRIPT'\\nset startDate to current date\\nset endDate to startDate + (\(days) * days)\\nset output to \\\"\\\"\\ntell application \\\"Calendar\\\"\\n  repeat with cal in calendars\\n    set evs to every event of cal whose start date >= startDate and start date <= endDate\\n    repeat with e in evs\\n      set output to output & (summary of e) & \\\" - \\\" & (start date of e as string) & linefeed\\n    end repeat\\n  end repeat\\nend tell\\nreturn output\\nAPPLESCRIPT\\n"
        }
        [/SUGGEST_EXTENSION]
        """
    }

    private func buildRemindersExtensionSuggestion(query: String) -> String? {
        let term = extractTerm(after: ["remind me to", "reminder", "reminders"], from: query)
        let filter = term ?? ""
        return """
        [SUGGEST_EXTENSION]
        {
            "name": "Open Reminders List",
            "description": "List incomplete reminders\(filter.isEmpty ? "" : " matching '\(filter)'" ).",
            "app": "Reminders",
            "code": "#!/bin/bash\\n# Extension: Reminders List\\n# Description: Lists incomplete reminders.\\n# Trigger: reminders\\n# Layer: l2_context\\n\\nFILTER=\\\"\(filter.replacingOccurrences(of: "\"", with: ""))\\\"\\nosascript <<'APPLESCRIPT'\\nset filterText to \\\"\(filter.replacingOccurrences(of: "\"", with: ""))\\\"\\nset output to \\\"\\\"\\ntell application \\\"Reminders\\\"\\n  repeat with lst in lists\\n    repeat with r in reminders of lst whose completed is false\\n      if filterText is \\\"\\\" or (name of r) contains filterText then\\n        set output to output & (name of r) & linefeed\\n      end if\\n    end repeat\\n  end repeat\\nend tell\\nreturn output\\nAPPLESCRIPT\\n"
        }
        [/SUGGEST_EXTENSION]
        """
    }

    private func buildNotesExtensionSuggestion(query: String) -> String? {
        let term = extractTerm(after: ["note", "notes", "find note", "search note"], from: query)
        let filter = term ?? ""
        return """
        [SUGGEST_EXTENSION]
        {
            "name": "Search Notes",
            "description": "Search Notes for '\(filter.isEmpty ? "query" : filter)'.",
            "app": "Notes",
            "code": "#!/bin/bash\\n# Extension: Search Notes\\n# Description: Searches Apple Notes by title.\\n# Trigger: notes\\n# Layer: l2_context\\n\\nFILTER=\\\"\(filter.replacingOccurrences(of: "\"", with: ""))\\\"\\nosascript <<'APPLESCRIPT'\\nset filterText to \\\"\(filter.replacingOccurrences(of: "\"", with: ""))\\\"\\nset output to \\\"\\\"\\ntell application \\\"Notes\\\"\\n  repeat with n in notes of default account\\n    if filterText is \\\"\\\" or (name of n) contains filterText then\\n      set output to output & (name of n) & linefeed\\n    end if\\n  end repeat\\nend tell\\nreturn output\\nAPPLESCRIPT\\n"
        }
        [/SUGGEST_EXTENSION]
        """
    }

    private func buildMailExtensionSuggestion(query: String) -> String? {
        return """
        [SUGGEST_EXTENSION]
        {
            "name": "Unread Mail Count",
            "description": "Show unread Mail count from your Inbox.",
            "app": "Mail",
            "code": "#!/bin/bash\\n# Extension: Unread Mail Count\\n# Description: Shows unread count from Inbox.\\n# Trigger: mail\\n# Layer: l2_context\\n\\nosascript -e 'tell application \"Mail\" to count of (every message of inbox whose read status is false)'\\n"
        }
        [/SUGGEST_EXTENSION]
        """
    }

    private func buildMessagesExtensionSuggestion(query: String) -> String? {
        return """
        [SUGGEST_EXTENSION]
        {
            "name": "Open Messages",
            "description": "Open Messages.app for quick access.",
            "app": "Messages",
            "code": "#!/bin/bash\\n# Extension: Open Messages\\n# Description: Opens Messages.app.\\n# Trigger: messages\\n# Layer: l2_context\\n\\nopen -a \"Messages\"\\n"
        }
        [/SUGGEST_EXTENSION]
        """
    }

    private func buildContactsExtensionSuggestion(query: String) -> String? {
        let term = extractTerm(after: ["contact", "contacts", "email", "message", "call"], from: query) ?? ""
        let sanitizedTerm = term.replacingOccurrences(of: "\"", with: "")
        return """
        [SUGGEST_EXTENSION]
        {
            "name": "Find Contact \(term.isEmpty ? "" : "(\(term))")",
            "description": "Search Contacts for matching names.",
            "app": "Contacts",
            "code": "#!/bin/bash\\n# Extension: Find Contact\\n# Description: Searches Contacts by name.\\n# Trigger: contacts\\n# Layer: l2_context\\n\\nFILTER=\\\"\(sanitizedTerm)\\\"\\nosascript <<'APPLESCRIPT'\\nset filterText to \\\"\(sanitizedTerm)\\\"\\nset output to \\\"\\\"\\ntell application \\\"Contacts\\\"\\n  set matches to people whose name contains filterText\\n  repeat with p in matches\\n    set output to output & (name of p) & linefeed\\n  end repeat\\nend tell\\nreturn output\\nAPPLESCRIPT\\n"
        }
        [/SUGGEST_EXTENSION]
        """
    }

    private func extractTerm(after prefixes: [String], from query: String) -> String? {
        let lower = query.lowercased()
        for prefix in prefixes {
            if let range = lower.range(of: prefix) {
                let start = range.upperBound
                let term = query[start...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !term.isEmpty {
                    return term
                }
            }
        }
        return nil
    }

    private func parseFirstInt(from text: String) -> Int? {
        let numbers = text.split(whereSeparator: { !$0.isNumber })
        guard let first = numbers.first else { return nil }
        return Int(first)
    }

    private func isAffirmativeResponse(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let positives = [
            "yes", "y", "ok", "okay", "sure", "do it", "go ahead", "run it", "execute", "confirm"
        ]
        return positives.contains(where: { normalized == $0 })
    }

    private func isNegativeResponse(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let negatives = ["no", "n", "stop", "cancel", "don't", "do not", "nah"]
        return negatives.contains(where: { normalized == $0 })
    }

    private func handleL2Query(_ query: String) {
        guard !query.isEmpty else { return }
        if let existingTask = l2CurrentTask {
            existingTask.cancel()
            l2CurrentTask = nil
            l2IsLoading = false
        }

        // Stamp the context key when the chat starts so we can detect future context switches.
        let currentKey = contextIdentityKey(currentContext)
        if chatContextKey.isEmpty || l2ChatMessages.isEmpty {
            chatContextKey = currentKey == "none" ? chatContextKey : currentKey
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // ── Cross-app natural language ────────────────────────────────────────
        // "send this to salman", "email this to john", "open this in xcode", etc.
        if let intent = CrossAppNLHandler.shared.parse(normalizedQuery) {
            l2ChatMessages.append(AIChatMessage(role: .user, content: query))
            l2IsLoading = true
            let capturedCtx = axContext
            l2CurrentTask = Task {
                guard let resolved = await CrossAppNLHandler.shared.resolve(intent) else {
                    await MainActor.run {
                        l2ChatMessages.append(AIChatMessage(role: .assistant,
                            content: "❌ Couldn't resolve that. Try: \"send this to [name]\" or \"email this to [name]\""))
                        l2IsLoading = false; l2CurrentTask = nil
                    }
                    return
                }
                let output = await CrossAppNLHandler.shared.execute(resolved, axContext: capturedCtx)
                await MainActor.run {
                    l2ChatMessages.append(AIChatMessage(role: .assistant, content: output))
                    l2IsLoading = false; l2CurrentTask = nil
                    searchText = ""
                }
            }
            return
        }
        // ─────────────────────────────────────────────────────────────────────

        if let pending = pendingTerminalCommand {
            if isAffirmativeResponse(normalizedQuery) {
                pendingTerminalCommand = nil
                l2ChatMessages.append(AIChatMessage(role: .user, content: query))
                l2IsLoading = true
                l2CurrentTask = Task {
                    let (success, output) = await TerminalAIBridge.shared.processAICommand(pending.command, purpose: pending.purpose)
                    await MainActor.run {
                        let resultIcon = success ? "✅" : "❌"
                        let resultMessage = AIChatMessage(
                            role: .assistant,
                            content: "\(resultIcon) Command Result:\n```\n\(output)\n```"
                        )
                        l2ChatMessages.append(resultMessage)
                        updateL2Results(buildL2OutputResults(title: "Terminal Output", output: output))
                        l2IsLoading = false
                        l2CurrentTask = nil
                    }
                }
                return
            }
            if isNegativeResponse(normalizedQuery) {
                pendingTerminalCommand = nil
                l2ChatMessages.append(AIChatMessage(role: .user, content: query))
                l2ChatMessages.append(AIChatMessage(role: .assistant, content: "Okay, I won't run that command."))
                return
            }
        }

        detectAndUpdateContext()

        if case .none = currentContext {
            if let frontmostApp = contextTargetApp(),
               let selectedText = ContextDetector.shared.getSelectedText(from: frontmostApp),
               !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentContext = .textSelected(selectedText)
            }
        } else if case .appFocused = currentContext {
            if let frontmostApp = contextTargetApp(),
               let selectedText = ContextDetector.shared.getSelectedText(from: frontmostApp),
               !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentContext = .textSelected(selectedText)
            }
        }

        if case .none = currentContext {
            let finderSelection = ContextDetector.shared.getFinderSelectedFiles()
            if !finderSelection.isEmpty {
                currentContext = .filesSelected(finderSelection)
            }
        } else if case .appFocused = currentContext {
            let finderSelection = ContextDetector.shared.getFinderSelectedFiles()
            if !finderSelection.isEmpty {
                currentContext = .filesSelected(finderSelection)
            }
        }

        let queryLower = query.lowercased()
        if queryLower.contains("pdf") {
            let finderSelection = ContextDetector.shared.getFinderSelectedFiles()
            if !finderSelection.isEmpty {
                currentContext = .filesSelected(finderSelection)
            }
        }

        // Store original query for potential re-execution after extension install
        originalUserQuery = query

        // Clear search text after capturing the query
        searchText = ""

        enforceL2ContextMode()
        if !isSearchBarExpanded {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isSearchBarExpanded = true
            }
            updateWindowSize()
        }

        let frontmostName: String? = {
            switch currentContext {
            case .appFocused(let name, _):
                return name
            default:
                return frontmostAppName.isEmpty ? nil : frontmostAppName
            }
        }()

        let selectedFiles: [URL] = {
            if case .filesSelected(let urls) = currentContext {
                return urls
            }
            return []
        }()

        if frontmostName?.lowercased().contains("safari") == true,
           handleSafariDirectQuery(query: query) {
            return
        }

        let routeDecision = routeL2QueryDecision(
            query: query,
            frontmostName: frontmostName,
            selectedFiles: selectedFiles
        )
        if handleL2RouteDecision(routeDecision, query: query) {
            return
        }

        if L2CommandInterface.shared.canHandle(query: query) {
            let userMessage = AIChatMessage(role: .user, content: query)
            l2ChatMessages.append(userMessage)
            l2IsLoading = true

            l2CurrentTask = Task {
                let result = await L2CommandInterface.shared.handle(query: query, context: currentContext)
                if Task.isCancelled { return }
                if let result = result {
                    let msg = result.message
                    // If message still has legacy command tags, parse and execute them properly
                    let hasCommandTag = msg.contains("[TERMINAL_COMMAND:") || msg.contains("[EXECUTE_COMMAND:") || msg.contains("[USE_EXTENSION:")
                    if hasCommandTag {
                        await handleL2AIResponse(msg)
                    } else {
                        await MainActor.run {
                            let assistantMessage = AIChatMessage(role: .assistant, content: msg)
                            l2ChatMessages.append(assistantMessage)
                            if let output = result.output, !output.isEmpty {
                                updateL2Results(buildL2OutputResults(title: result.title, output: output))
                            } else {
                                updateL2Results([])
                            }
                        }
                    }
                }
                await MainActor.run {
                    l2IsLoading = false
                    l2CurrentTask = nil
                }
            }
            return
        }

        // Detect if this is a tab query that should be answered directly (not with extensions)
        let isTabQuery = frontmostName?.lowercased().contains("safari") == true &&
            queryLower.contains("tab") &&
            (queryLower.contains("list") || queryLower.contains("show") ||
             queryLower.contains("how many") || queryLower.contains("which") ||
             queryLower.contains("what") || queryLower.contains("find") ||
             queryLower.contains("about") || queryLower.contains("opened") ||
             queryLower.contains("open") || queryLower.contains("count"))

        // Skip extension discovery for tab queries - AI should answer directly with tab data
        if !isTabQuery {
            let matches = LayeredExtensionManager.shared.discoverExtensions(
                for: query,
                selectedFiles: selectedFiles,
                frontmostApp: frontmostName,
                layer: .l2_context
            ).filter { result in
                result.ilExtension.triggers.contains { trigger in
                    if case .appContext = trigger {
                        return true
                    }
                    return false
                }
            }

            if (queryLower.contains("summarize") || queryLower.contains("summary") || queryLower.contains("tldr")),
               case .filesSelected(let urls) = currentContext,
               let pdf = ContextDetector.shared.analyzeFiles(urls).first(where: { $0.type == "pdf" }),
               let pdfContent = pdf.content, !pdfContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                l2ChatMessages.append(AIChatMessage(role: .user, content: query))
                l2IsLoading = true
                l2CurrentTask = Task {
                    do {
                        let prompt = "Summarize this PDF content for the user request:\n\n\(pdfContent)\n\nUser request:\n\(query)"
                        let response = try await sendToAIProviderWithContext(query: prompt, messageHistory: l2ChatMessages)
                        if Task.isCancelled { return }
                        await MainActor.run {
                            let assistantMessage = AIChatMessage(role: .assistant, content: response)
                            l2ChatMessages.append(assistantMessage)
                            l2IsLoading = false
                            l2CurrentTask = nil
                        }
                    } catch {
                        await MainActor.run {
                            let errorMessage = AIChatMessage(role: .assistant, content: "Sorry, I encountered an error: \(error.localizedDescription)", isError: true)
                            l2ChatMessages.append(errorMessage)
                            l2IsLoading = false
                            l2CurrentTask = nil
                        }
                    }
                }
                return
            }

            if let top = matches.first, shouldAutoRunL2Extension(query: query, ext: top.ilExtension) {
                l2CurrentTask = Task {
                    await executeL2Extension(top.ilExtension, context: currentContext)
                    await MainActor.run {
                        l2CurrentTask = nil
                    }
                }
                return
            }

            if matches.isEmpty {
                updateL2Results([])
            }
        } else {
            // For tab queries, clear extension results so AI can answer directly
            updateL2Results([])
            print("🚫 [L2 Query] Skipping extension discovery for tab query - AI will answer directly")
        }

        // Build intelligent context prompt
        print("🔍 [L2 Query] Current context when building prompt: \(currentContext.description)")
        print("🔍 [L2 Query] Frontmost app: \(frontmostName ?? "none")")
        let intelligentPrompt = buildIntelligentL2Prompt(query: query, context: currentContext, frontmostApp: frontmostName)
        print("📝 [L2 Query] Prompt length: \(intelligentPrompt.count) characters")
        if case .textSelected(let text) = currentContext {
            print("✅ [L2 Query] Including selected text in prompt: \(text.prefix(100))...")
        } else {
            print("⚠️ [L2 Query] NO selected text in context!")
        }

        // Display only the user's actual query in the chat UI (not the full context prompt)
        let userMessage = AIChatMessage(role: .user, content: query)
        l2ChatMessages.append(userMessage)
        l2IsLoading = true

        // Use the user's selected AI provider in L2 context dock (respects Settings → AI Provider).
        let provider: AIProvider = settings.selectedAIProvider
        let rawKey = AppSettings.shared.getAPIKey(for: provider)
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey

        // Build conversation history (clean messages only — no tool chips)
        let chatHistory: [ChatMessage] = l2ChatMessages.dropLast()
            .filter { $0.role != .tool }
            .map { ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.content) }

        l2CurrentTask = Task {
            do {
                print("🧠 [L2 AI] Provider: \(provider.shortName), sendWithTools path")

                // Cloud providers: use real tool_use loop so AI can chain cross-app commands
                // (e.g. get Safari URL → save to Notes in two connected steps)
                if provider != .onDevice && provider != .shortcuts {
                    let (finalResponse, executedCmds) = try await AIProviderService.shared.sendWithTools(
                        intelligentPrompt,
                        context: currentContext,
                        provider: provider,
                        apiKey: apiKey,
                        conversationHistory: chatHistory,
                        commandExecutor: { [self] cmd, purpose in
                            await MainActor.run {
                                self.l2ChatMessages.append(AIChatMessage(role: .tool, content: "$ \(cmd)"))
                            }
                            return await TerminalAIBridge.shared.processAICommand(cmd, purpose: purpose)
                        }
                    )
                    if Task.isCancelled { return }
                    await MainActor.run {
                        l2ChatMessages.append(AIChatMessage(role: .assistant, content: finalResponse))
                        l2IsLoading = false
                        l2CurrentTask = nil
                    }
                } else if provider == .onDevice {
                    // On-device Apple Intelligence: full file/PDF/image/translation context via streaming
                    let placeholder = AIChatMessage(role: .assistant, content: "")
                    await MainActor.run { l2ChatMessages.append(placeholder) }
                    let msgId = placeholder.id

                    var finalResponse = ""
                    await withCheckedContinuation { cont in
                        AIProviderService.shared.streamOnDeviceResponse(
                            message: query,
                            context: currentContext,
                            history: chatHistory,
                            onPartial: { token in
                                DispatchQueue.main.async {
                                    if let idx = self.l2ChatMessages.firstIndex(where: { $0.id == msgId }) {
                                        self.l2ChatMessages[idx] = AIChatMessage(
                                            id: msgId, role: .assistant,
                                            content: self.l2ChatMessages[idx].content + token
                                        )
                                    }
                                }
                            },
                            onComplete: { response in
                                finalResponse = response
                                cont.resume()
                            },
                            onError: { errText in
                                DispatchQueue.main.async {
                                    if let idx = self.l2ChatMessages.firstIndex(where: { $0.id == msgId }) {
                                        self.l2ChatMessages[idx] = AIChatMessage(id: msgId, role: .assistant, content: errText, isError: true)
                                    }
                                }
                                cont.resume()
                            }
                        )
                    }
                    if Task.isCancelled { return }
                    await MainActor.run {
                        l2CurrentTask = nil
                        l2IsLoading = false
                    }
                } else {
                    // Shortcuts: text-tag approach
                    let messageHistory = l2ChatMessages.dropLast()
                    let contextualizedHistory = Array(messageHistory).map { msg in
                        ["role": msg.role == .user ? "user" : "assistant", "content": msg.content]
                    }
                    var fullContext = contextualizedHistory
                    fullContext.append(["role": "user", "content": intelligentPrompt])
                    let response = try await sendToAIProviderDirect(context: fullContext)
                    if Task.isCancelled { return }
                    await handleL2AIResponse(response)
                    await MainActor.run {
                        l2CurrentTask = nil
                        l2IsLoading = false
                    }
                }

            } catch {
                await MainActor.run {
                    let errorMessage = AIChatMessage(role: .assistant, content: "Sorry, I encountered an error: \(error.localizedDescription)", isError: true)
                    l2ChatMessages.append(errorMessage)
                    l2IsLoading = false
                    l2CurrentTask = nil
                }
            }
        }
    }

    private func sendToAIProvider(query: String) async throws -> String {
        // Build context from previous messages (uses aiChatMessages for global AI mode)
        var context = aiChatMessages.map { msg in
            ["role": msg.role == .user ? "user" : "assistant", "content": msg.content]
        }

        // Build system message — always include live AX context if available
        var sysContent = """
            You are a helpful AI assistant for quick queries and information.
            Provide concise, accurate answers to user questions.
            Keep responses brief and to the point.
            """
        // Append live AX context so the AI is grounded in what the user is looking at
        let ax = axContext
        if !ax.isEmpty {
            sysContent += "\n\n## Live App Context\n" + ax.contextSummary
        }
        let systemMessage: [String: String] = ["role": "system", "content": sysContent]

        // Insert system message at the beginning
        context.insert(systemMessage, at: 0)

        return try await sendToProvider(query: query, context: context)
    }

    private func sendToAIProviderWithContext(query: String, messageHistory: [AIChatMessage]) async throws -> String {
        // Build context from provided message history (for L2, uses l2ChatMessages)
        var context = messageHistory.map { msg in
            ["role": msg.role == .user ? "user" : "assistant", "content": msg.content]
        }

        // Build system message with live AX context
        var sysL2 = """
            You are an intelligent macOS assistant integrated into ILauncher.
            You can use pre-built extensions, answer questions directly, and suggest creating new extensions for recurring tasks.

            When responding:
            - If an extension was mentioned and user confirms (yes/ok/sure), provide the extension code you suggested
            - Maintain conversation context across multiple messages
            - Be helpful and actionable
            - Remember what you suggested in previous messages
            - You can analyze images when they are provided
            """
        let axL2 = axContext
        if !axL2.isEmpty {
            sysL2 += "\n\n## Live App Context (use this to ground your answers)\n" + axL2.contextSummary
        }
        let systemMessage: [String: String] = ["role": "system", "content": sysL2]

        // Insert system message at the beginning
        context.insert(systemMessage, at: 0)

        // Check if we have image files selected (for vision support)
        var imageFiles: [URL] = []
        if case .filesSelected(let urls) = currentContext {
            imageFiles = urls.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"].contains(ext)
            }
        }

        return try await sendToProvider(query: query, context: context, imageFiles: imageFiles)
    }
    
    // Direct provider sender that accepts pre-built context (used by L2 for custom prompts)
    private func sendToAIProviderDirect(context: [[String: String]]) async throws -> String {
        // Check if we have image files selected (for vision support)
        var imageFiles: [URL] = []
        if case .filesSelected(let urls) = currentContext {
            imageFiles = urls.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"].contains(ext)
            }
        }

        // Send directly without adding another query
        return try await sendToProvider(query: "", context: context, imageFiles: imageFiles)
    }

    // Common provider router
    private func sendToProvider(query: String, context: [[String: String]]) async throws -> String {
        return try await sendToProvider(query: query, context: context, imageFiles: [])
    }

    // Common provider router with image support
    private func sendToProvider(query: String, context: [[String: String]], imageFiles: [URL]) async throws -> String {
        switch settings.selectedAIProvider {
        case .onDevice:
            // Use AIProviderService's proper session — reads files, PDFs, images, builds rich context
            return try await AIProviderService.shared.sendOnDevice(query, context: currentContext)
        case .openAI:
            return try await sendToOpenAI(query: query, context: context, imageFiles: imageFiles)
        case .googleGemini:
            return try await sendToGemini(query: query, context: context, imageFiles: imageFiles)
        case .anthropic:
            return try await sendToAnthropic(query: query, context: context, imageFiles: imageFiles)
        case .ollama:
            return try await sendToOllama(query: query, context: context)
        case .shortcuts:
            return try await sendToShortcuts(query: query, context: context)
        }
    }

    // MARK: - Process AI Response (Simplified for quick queries only)
    
    // MARK: - AI Provider Implementations
    
    private func sendToOnDeviceAI(query: String, context: [[String: String]]) async throws -> String {
        // On-device AI using Apple's Foundation Models framework
        // This requires macOS 26.0+ (macOS Tahoe) and Apple Silicon

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                print("🤖 On-Device AI: Starting request...")

                // Import at runtime to avoid compilation issues on older macOS
                let session = LanguageModelSession()

                // Build the prompt with context, using custom system prompt
                var fullPrompt = ""

                // Add custom system prompt if not empty, otherwise use context system message
                let useCustomPrompt = !settings.onDeviceSystemPrompt.isEmpty
                if useCustomPrompt {
                    print("🤖 Using custom system prompt (\(settings.onDeviceSystemPrompt.count) chars)")
                    fullPrompt += "system: \(settings.onDeviceSystemPrompt)\n"
                }

                // Add conversation history (skip system message from context if we used custom)
                for msg in context {
                    let role = msg["role"] ?? "user"
                    let content = msg["content"] ?? ""

                    // Skip system message if we already added custom prompt
                    if useCustomPrompt && role == "system" {
                        continue
                    }

                    fullPrompt += "\(role): \(content)\n"
                }

                fullPrompt += "user: \(query)\nassistant:"

                print("🤖 On-Device AI: Sending prompt (length: \(fullPrompt.count))")

                let response = try await session.respond(to: fullPrompt)
                print("🤖 On-Device AI: Response received successfully")
                return response.content
            } catch {
                print("❌ On-Device AI Error: \(error.localizedDescription)")
                print("❌ Full error: \(error)")
                // Return user-friendly error instead of throwing
                return "On-Device AI encountered an error: \(error.localizedDescription)\n\nPlease try:\n1. Checking your internet connection (may be needed for initial model download)\n2. Ensuring Apple Intelligence is enabled in System Settings\n3. Using a different AI provider in Settings"
            }
        } else {
            return "On-device AI requires macOS 26.0 (Tahoe) or later with Apple Silicon. Your current macOS version does not support this feature. Please select a different AI provider in Settings."
        }
        #else
        // Foundation Models framework not available
        return "On-device AI (Apple Intelligence) is not available on this version of macOS. This feature requires macOS 26.0 (Tahoe) or later with Apple Silicon. Please select a different AI provider in Settings, such as:\n\n• **Ollama** - Free, runs locally on your Mac\n• **Google Gemini** - Requires API key\n• **OpenAI ChatGPT** - Requires API key\n• **Anthropic Claude** - Requires API key"
        #endif
    }
    
    private func sendToOpenAI(query: String, context: [[String: String]]) async throws -> String {
        return try await sendToOpenAI(query: query, context: context, imageFiles: [])
    }

    private func sendToOpenAI(query: String, context: [[String: String]], imageFiles: [URL]) async throws -> String {
        guard !settings.openAIAPIKey.isEmpty else {
            throw AIError.noAPIKey
        }

        // TODO: Add vision support for OpenAI (gpt-4-vision-preview)
        // For now, just use text-only

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages = context
        messages.append(["role": "user", "content": query])

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": messages,
            "max_tokens": 1000
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AIError.requestFailed
        }

        struct OpenAIResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let result = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return result.choices.first?.message.content ?? "No response received."
    }

    private func sendToGemini(query: String, context: [[String: String]]) async throws -> String {
        return try await sendToGemini(query: query, context: context, imageFiles: [])
    }

    private func sendToGemini(query: String, context: [[String: String]], imageFiles: [URL]) async throws -> String {
        guard !settings.googleGeminiAPIKey.isEmpty else {
            throw AIError.noAPIKey
        }
        
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.googleGeminiAPIKey, forHTTPHeaderField: "x-goog-api-key")

        // Build conversation history
        var parts: [[String: Any]] = []
        for msg in context {
            parts.append(["text": msg["content"] ?? ""])
        }
        parts.append(["text": query])

        let body: [String: Any] = [
            "contents": [["parts": parts]]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.requestFailed
        }
        if httpResponse.statusCode == 429 {
            throw AIError.rateLimited
        } else if httpResponse.statusCode != 200 {
            let errBody = String(data: data, encoding: .utf8) ?? "no body"
            print("❌ Gemini error \(httpResponse.statusCode): \(errBody)")
            throw AIError.requestFailed
        }
        
        struct GeminiResponse: Codable {
            struct Candidate: Codable {
                struct Content: Codable {
                    struct Part: Codable {
                        let text: String
                    }
                    let parts: [Part]
                }
                let content: Content
            }
            let candidates: [Candidate]
        }
        
        let result = try JSONDecoder().decode(GeminiResponse.self, from: data)
        return result.candidates.first?.content.parts.first?.text ?? "No response received."
    }
    
    private func sendToAnthropic(query: String, context: [[String: String]], imageFiles: [URL] = []) async throws -> String {
        guard !settings.anthropicAPIKey.isEmpty else {
            throw AIError.noAPIKey
        }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(settings.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: Any]] = []
        for msg in context {
            messages.append(["role": msg["role"] ?? "user", "content": msg["content"] ?? ""])
        }

        // Build the final user message with images if provided
        var finalMessageContent: [[String: Any]] = []

        // Add images first
        for imageFile in imageFiles {
            if let imageData = try? Data(contentsOf: imageFile) {
                let base64Image = imageData.base64EncodedString()
                let ext = imageFile.pathExtension.lowercased()
                let mediaType: String
                switch ext {
                case "png": mediaType = "image/png"
                case "jpg", "jpeg": mediaType = "image/jpeg"
                case "gif": mediaType = "image/gif"
                case "webp": mediaType = "image/webp"
                default: mediaType = "image/jpeg"
                }

                finalMessageContent.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType,
                        "data": base64Image
                    ]
                ])
            }
        }

        // Add text query
        finalMessageContent.append([
            "type": "text",
            "text": query
        ])

        messages.append(["role": "user", "content": finalMessageContent])

        // Use a vision-capable model if images are present
        let model = imageFiles.isEmpty ? "claude-3-haiku-20240307" : "claude-3-5-sonnet-20241022"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": imageFiles.isEmpty ? 1000 : 2000,
            "messages": messages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let httpResponse = response as? HTTPURLResponse {
                print("❌ Anthropic API error: \(httpResponse.statusCode)")
                if let errorString = String(data: data, encoding: .utf8) {
                    print("Error response: \(errorString)")
                }
            }
            throw AIError.requestFailed
        }

        struct AnthropicResponse: Codable {
            struct Content: Codable {
                let text: String
            }
            let content: [Content]
        }

        let result = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return result.content.first?.text ?? "No response received."
    }
    
    private func sendToOllama(query: String, context: [[String: String]]) async throws -> String {
        guard !settings.ollamaEndpoint.isEmpty else {
            throw AIError.noEndpoint
        }
        guard !settings.selectedOllamaModel.isEmpty else {
            throw AIError.noModel
        }
        
        let endpoint = settings.ollamaEndpoint.trimmingCharacters(in: .whitespaces)
        let url = URL(string: "\(endpoint)/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var messages: [[String: String]] = []
        for msg in context {
            messages.append(["role": msg["role"] ?? "user", "content": msg["content"] ?? ""])
        }
        messages.append(["role": "user", "content": query])
        
        let body: [String: Any] = [
            "model": settings.selectedOllamaModel,
            "messages": messages,
            "stream": false
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await AIProviderService.directSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AIError.requestFailed
        }
        
        struct OllamaResponse: Codable {
            struct Message: Codable {
                let content: String
            }
            let message: Message
        }
        
        let result = try JSONDecoder().decode(OllamaResponse.self, from: data)
        return result.message.content
    }
    
    private func sendToShortcuts(query: String, context: [[String: String]]) async throws -> String {
        // Check if a shortcut is configured
        guard !settings.shortcutsProviderShortcut.isEmpty else {
            return "⚠️ No shortcut configured for Shortcuts provider.\n\nPlease select a shortcut in Settings → AI Provider to use this feature."
        }

        // Run the shortcut on a background thread to avoid blocking
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // First, ensure Shortcuts app is running and ready
                let workspace = NSWorkspace.shared
                let isRunning = workspace.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.shortcuts" })

                if !isRunning {
                    print("⚠️ Shortcuts app not running, launching and activating...")

                    // Use AppleScript to launch and activate the app, which ensures it's ready
                    let launchScript = """
                    tell application "Shortcuts"
                        launch
                        activate
                    end tell
                    """

                    var launchError: NSDictionary?
                    if let launchScriptObject = NSAppleScript(source: launchScript) {
                        launchScriptObject.executeAndReturnError(&launchError)

                        if launchError != nil {
                            print("⚠️ Failed to launch Shortcuts app via AppleScript")
                        } else {
                            print("✅ Shortcuts app launched and activated")
                            // Wait for app to be fully ready
                            Thread.sleep(forTimeInterval: 2.0)
                        }
                    }
                } else {
                    print("✅ Shortcuts app already running")
                }

                // Escape the query for AppleScript - more thorough escaping
                let escapedQuery = query
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")

                print("🔵 Running shortcut: '\(self.settings.shortcutsProviderShortcut)' with input: '\(query)'")

                // Try using the direct Shortcuts app scripting (not Shortcuts Events)
                let script = """
                tell application "Shortcuts"
                    set theResult to run shortcut "\(self.settings.shortcutsProviderShortcut)" with input "\(escapedQuery)"
                    return theResult as text
                end tell
                """

                var error: NSDictionary?
                guard let scriptObject = NSAppleScript(source: script) else {
                    continuation.resume(returning: "⚠️ Failed to create AppleScript object")
                    return
                }

                print("⏳ Executing AppleScript...")
                let output = scriptObject.executeAndReturnError(&error)

                if let error = error {
                    print("❌ AppleScript error: \(error)")
                    let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                    let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? 0

                    // If we get error -600, try one more time with a longer delay
                    if errorNumber == -600 {
                        print("⚠️ Got error -600, waiting longer and retrying...")
                        Thread.sleep(forTimeInterval: 2.0)

                        // Retry
                        var retryError: NSDictionary?
                        let retryOutput = scriptObject.executeAndReturnError(&retryError)
                        if let retryErr = retryError {
                            let retryErrorMsg = retryErr["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                            let result = """
                            ⚠️ Error running shortcut '\(self.settings.shortcutsProviderShortcut)' (Error \(errorNumber)):

                            \(retryErrorMsg)

                            Make sure:
                            • The shortcut exists in your Shortcuts app
                            • It accepts text input
                            • It returns a text result
                            • Automation permission is granted in System Settings → Privacy & Security → Automation
                            • ILauncher has permission to control Shortcuts
                            """
                            continuation.resume(returning: result)
                            return
                        } else if let result = retryOutput.stringValue, !result.isEmpty {
                            print("✅ Shortcut returned (after retry): \(result.prefix(100))...")
                            continuation.resume(returning: result)
                            return
                        }
                    }

                    let result = """
                    ⚠️ Error running shortcut '\(self.settings.shortcutsProviderShortcut)' (Error \(errorNumber)):

                    \(errorMessage)

                    Make sure:
                    • The shortcut exists in your Shortcuts app
                    • It accepts text input
                    • It returns a text result
                    • Automation permission is granted in System Settings → Privacy & Security → Automation
                    """
                    continuation.resume(returning: result)
                    return
                }

                // Get the result from the AppleScript output
                if let result = output.stringValue, !result.isEmpty {
                    print("✅ Shortcut returned: \(result.prefix(100))...")
                    continuation.resume(returning: result)
                } else {
                    print("⚠️ Shortcut returned empty or nil result")
                    print("⚠️ Output descriptor: \(output)")
                    let result = """
                    ⚠️ Shortcut '\(self.settings.shortcutsProviderShortcut)' ran but returned no output.

                    Make sure your shortcut:
                    • Returns a text result
                    • Uses 'Stop and Output' or 'Return' action with text
                    • Doesn't just show an alert or notification
                    """
                    continuation.resume(returning: result)
                }
            }
        }
    }

    // MARK: - Browser Content Section (L3 right side)
    @ViewBuilder
    private var browserContentSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Pinned Websites Section
                if !pinnedWebsites.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pinned Websites")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 100), spacing: 12)
                        ], spacing: 12) {
                            ForEach(pinnedWebsites) { item in
                                BrowserItemCard(item: item, onTap: {
                                    if let url = URL(string: item.url) {
                                        NSWorkspace.shared.open(url)
                                    }
                                })
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Quick Tabs Section
                if !quickTabs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quick Tabs")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(quickTabs) { item in
                                BrowserItemRow(item: item, onTap: {
                                    if let url = URL(string: item.url) {
                                        NSWorkspace.shared.open(url)
                                    }
                                })
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Bookmarks Section
                if !browserBookmarks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Bookmarks")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(browserBookmarks) { item in
                                BrowserItemRow(item: item, onTap: {
                                    if let url = URL(string: item.url) {
                                        NSWorkspace.shared.open(url)
                                    }
                                })
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Empty state when no browser content
                if pinnedWebsites.isEmpty && quickTabs.isEmpty && browserBookmarks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.5))

                        Text("Browser Content")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("Pinned websites, quick tabs, and bookmarks will appear here")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
            }
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: 400)
    }

    // Meta info for the active smart query app panel
    private var smartQueryMeta: (icon: String, label: String, appPath: String) {
        switch activeSmartQueryKey ?? "" {
        case "calendar":  return ("calendar",        "Calendar",  "/System/Applications/Calendar.app")
        case "reminders": return ("checkmark.circle","Reminders", "/System/Applications/Reminders.app")
        case "notes":     return ("note.text",       "Notes",     "/System/Applications/Notes.app")
        case "mail":      return ("envelope",        "Mail",      "/System/Applications/Mail.app")
        case "photos":    return ("photo.on.rectangle","Photos",  "/System/Applications/Photos.app")
        case "messages":  return ("message",         "Messages",  "/System/Applications/Messages.app")
        case "contacts":  return ("person.2",        "Contacts",  "/System/Applications/Contacts.app")
        case "safari":    return ("safari",          "Safari Tabs", "/Applications/Safari.app")
        default:
            // Check custom app entries
            if let key = activeSmartQueryKey,
               let entry = settings.customAppEntries.first(where: { $0.key == key }) {
                return (entry.iconName, entry.label, entry.appPath)
            }
            return ("apps.iphone", "App", "")
        }
    }

    // Items to show in the app panel — filtered by search text if any
    private var appPanelDisplayedItems: [SearchResult] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return appPanelAllItems }
        let filtered = appPanelAllItems.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
        return filtered.isEmpty ? appPanelAllItems : filtered
    }

    // MARK: - Contextual Quick Actions (type-based)

    struct PanelAction: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let action: () -> Void
    }

    /// Returns quick actions appropriate for the current context item.
    private func contextPanelActions() -> [PanelAction] {
        // Built-in key panels (no searchContextApp)
        let activeKey = activeSmartQueryKey ?? ""
        if searchContextApp == nil {
            func sendRemQuery(_ msg: String) {
                searchText = msg
                handleRemPanelQuery()
                searchText = ""
            }
            if activeKey == "finder" {
                // Pills are built entirely from ~/.config/ilauncher/finder-tools/*.sh — no tool names in Swift
                let dir = ContextDetector.shared.getCurrentFinderDirectory() ?? NSHomeDirectory()
                let specs = FinderToolkit.shared.pillSpecs()
                var pills: [PanelAction] = specs.map { spec in
                    let capturedDir = dir
                    let capturedAction = spec.action
                    return PanelAction(icon: spec.icon, label: spec.name) { capturedAction(capturedDir) }
                }
                // Static system pills that need no external CLI
                pills.append(PanelAction(icon: "folder.badge.plus", label: "New Folder") {
                    NSAppleScript(source: "tell application \"Finder\" to make new folder at (target of front window as alias)")?.executeAndReturnError(nil)
                })
                pills.append(PanelAction(icon: "terminal", label: "Open Terminal") {
                    let script = """
                    tell application "Finder"
                        set p to POSIX path of (target of front window as text)
                    end tell
                    tell application "Terminal"
                        do script "cd " & quoted form of p
                        activate
                    end tell
                    """
                    NSAppleScript(source: script)?.executeAndReturnError(nil)
                })
                pills.append(PanelAction(icon: "doc.on.clipboard", label: "Copy Path") {
                    let script = """
                    tell application "Finder"
                        set f to POSIX path of (first item of selection as text)
                    end tell
                    set the clipboard to f
                    """
                    NSAppleScript(source: script)?.executeAndReturnError(nil)
                })
                return pills
            }
            if activeKey == "safari" {
                return [
                    PanelAction(icon: "arrow.clockwise", label: "Refresh Tabs") {
                        Task { await loadSafariTabs() }
                    },
                    PanelAction(icon: "plus.square", label: "New Tab") {
                        SafariTabManager.shared.openURL("about:newtab")
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Safari.app"))
                    },
                    PanelAction(icon: "lock.rectangle", label: "New Private Tab") {
                        if let url = URL(string: "x-safari-https://www.google.com") {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    PanelAction(icon: "bookmark.fill", label: "Add Bookmark") {
                        let script = "tell application \"Safari\" to add reading list item (URL of current tab of front window)"
                        NSAppleScript(source: script)?.executeAndReturnError(nil)
                    },
                    PanelAction(icon: "square.and.arrow.up", label: "Copy URL") {
                        Task {
                            if let url = await SafariTabManager.shared.currentURL() {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            }
                        }
                    },
                    PanelAction(icon: "arrow.up.forward.app", label: "Open Safari") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Safari.app"))
                    },
                ]
            }
            if activeKey == "amphetamine" {
                return [
                    PanelAction(icon: "timer", label: "30 min") {
                        sendRemQuery("Keep awake for 30 minutes")
                    },
                    PanelAction(icon: "clock", label: "1 hour") {
                        sendRemQuery("Keep awake for 1 hour")
                    },
                    PanelAction(icon: "moon.zzz", label: "End Session") {
                        sendRemQuery("End the current Amphetamine session")
                    },
                    PanelAction(icon: "info.circle", label: "Status") {
                        sendRemQuery("Is Amphetamine session active right now?")
                    },
                    PanelAction(icon: "arrow.up.forward.app", label: "Open App") {
                        NSWorkspace.shared.launchApplication("Amphetamine")
                    },
                ]
            }
            if activeKey == "homebrew" {
                return [
                    PanelAction(icon: "arrow.down.circle", label: "Update") {
                        sendRemQuery("Run brew update")
                    },
                    PanelAction(icon: "arrow.up.circle", label: "Upgrade All") {
                        sendRemQuery("Upgrade all outdated Homebrew packages")
                    },
                    PanelAction(icon: "clock.badge.exclamationmark", label: "Outdated") {
                        sendRemQuery("What packages are outdated?")
                    },
                    PanelAction(icon: "trash", label: "Cleanup") {
                        sendRemQuery("Clean up old Homebrew versions and show how much disk space is freed")
                    },
                    PanelAction(icon: "stethoscope", label: "Doctor") {
                        sendRemQuery("Run brew doctor and fix any issues")
                    },
                    PanelAction(icon: "list.bullet", label: "List") {
                        sendRemQuery("List all installed Homebrew packages with versions")
                    },
                ]
            }

            // Adapter-backed panels: map the panel key to its app's bundle ID,
            // pull the adapter's actions and present them as one-tap pills.
            let panelKeyToBundleId: [String: String] = [
                "mail":      "com.apple.mail",
                "calendar":  "com.apple.iCal",
                "notes":     "com.apple.Notes",
                "reminders": "com.apple.reminders",
                "messages":  "com.apple.MobileSMS",
                "contacts":  "com.apple.AddressBook",
                "photos":    "com.apple.Photos",
                "safari":    "com.apple.Safari",
                "finder":    "com.apple.finder",
            ]
            if let bundleId = panelKeyToBundleId[activeKey],
               let adapter = AppAdapterManager.shared.adapter(for: bundleId),
               !adapter.actions.isEmpty {
                let ctx = AXContextReader.shared.current
                return adapter.actions.prefix(12).map { action in
                    PanelAction(icon: action.icon, label: action.name) {
                        Task { await AppAdapterManager.shared.execute(action, context: ctx) }
                    }
                }
            }

            // Custom app entries: check if the key has an associated adapter
            if let entry = settings.customAppEntries.first(where: { $0.key == activeKey }),
               !entry.appPath.isEmpty,
               let bundleId = Bundle(path: entry.appPath)?.bundleIdentifier,
               let adapter = AppAdapterManager.shared.adapter(for: bundleId),
               !adapter.actions.isEmpty {
                let ctx = AXContextReader.shared.current
                return adapter.actions.prefix(12).map { action in
                    PanelAction(icon: action.icon, label: action.name) {
                        Task { await AppAdapterManager.shared.execute(action, context: ctx) }
                    }
                }
            }

            // Fallback: user-defined AppShortcuts for this panel key (quick + context-dock placements)
            if !activeKey.isEmpty {
                var seen = Set<String>()
                let quick = settings.shortcuts(for: activeKey)
                let dock  = settings.contextDockShortcuts(for: activeKey)
                for s in quick { seen.insert(s.name) }
                let combined = quick + dock.filter { seen.insert($0.name).inserted }
                if !combined.isEmpty {
                    return combined.map { sc in
                        PanelAction(icon: sc.iconName, label: sc.name) { executeAppShortcut(sc) }
                    }
                }
            }

            return []
        }
        guard let ctx = searchContextApp else { return [] }

        switch ctx.resultType {
        case .application:
            // Custom shortcuts first (combine quick-actions + context-dock placements), then standard
            let key = ctx.key ?? activeSmartQueryKey ?? ""
            let mergedShortcuts: [AppShortcut] = {
                var seen = Set<String>()
                let quick = settings.shortcuts(for: key)
                let dock  = settings.contextDockShortcuts(for: key)
                for s in quick { seen.insert(s.name) }
                return quick + dock.filter { seen.insert($0.name).inserted }
            }()
            let userShortcuts: [PanelAction] = mergedShortcuts.map { sc in
                PanelAction(icon: sc.iconName, label: sc.name) { executeAppShortcut(sc) }
            }
            if !userShortcuts.isEmpty { return userShortcuts }
            var actions: [PanelAction] = []
            if !ctx.appPath.isEmpty {
                actions.append(PanelAction(icon: "arrow.up.forward.app", label: "Open") {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: ctx.appPath),
                                                      configuration: NSWorkspace.OpenConfiguration())
                })
                actions.append(PanelAction(icon: "magnifyingglass", label: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ctx.appPath)])
                })
            }
            return actions

        case .file, .document:
            guard let path = ctx.filePath else { return [] }
            return [
                PanelAction(icon: "doc", label: "Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                },
                PanelAction(icon: "folder", label: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                },
                PanelAction(icon: "doc.on.doc", label: "Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                },
                PanelAction(icon: "eye", label: "Quick Look") {
                    quickLookDataSource = QuickLookDataSource(urls: [URL(fileURLWithPath: path)])
                },
                PanelAction(icon: "trash", label: "Move to Trash") {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                }
            ]

        case .folder:
            let path = ctx.filePath ?? ctx.subtitle
            return [
                PanelAction(icon: "folder", label: "Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                },
                PanelAction(icon: "doc.on.doc", label: "Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                },
                PanelAction(icon: "terminal", label: "Open in Terminal") {
                    let script = "tell application \"Terminal\" to do script \"cd '\(path)'\" activate"
                    NSAppleScript(source: script)?.executeAndReturnError(nil)
                },
                PanelAction(icon: "eye", label: "Quick Look") {
                    quickLookDataSource = QuickLookDataSource(urls: [URL(fileURLWithPath: path)])
                }
            ]

        case .contact:
            var actions: [PanelAction] = []
            if let email = ctx.contactEmail, !email.isEmpty {
                actions.append(PanelAction(icon: "envelope", label: "Send Email") {
                    if let url = URL(string: "mailto:\(email)") { NSWorkspace.shared.open(url) }
                })
                actions.append(PanelAction(icon: "message", label: "Send Message") {
                    if let url = URL(string: "imessage:\(email)") { NSWorkspace.shared.open(url) }
                })
                actions.append(PanelAction(icon: "doc.on.doc", label: "Copy Email") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(email, forType: .string)
                })
            }
            if let phone = ctx.contactPhone, !phone.isEmpty {
                actions.append(PanelAction(icon: "phone", label: "Call") {
                    if let url = URL(string: "tel:\(phone)") { NSWorkspace.shared.open(url) }
                })
            }
            actions.append(PanelAction(icon: "person.crop.circle", label: "Open in Contacts") {
                NSWorkspace.shared.open(URL(string: "addressbook://")!)
            })
            return actions

        case .calendarEvent:
            return [
                PanelAction(icon: "calendar", label: "Open Calendar") {
                    NSWorkspace.shared.open(URL(string: "ical://")!)
                },
                PanelAction(icon: "doc.on.doc", label: "Copy Title") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ctx.name, forType: .string)
                }
            ]

        case .reminder:
            return [
                PanelAction(icon: "checkmark.circle", label: "Open Reminders") {
                    NSWorkspace.shared.open(URL(string: "x-apple-reminder://")!)
                },
                PanelAction(icon: "doc.on.doc", label: "Copy Title") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ctx.name, forType: .string)
                }
            ]

        case .note:
            return [
                PanelAction(icon: "note.text", label: "Open Notes") {
                    NSWorkspace.shared.open(URL(string: "notes://")!)
                },
                PanelAction(icon: "doc.on.doc", label: "Copy Title") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ctx.name, forType: .string)
                }
            ]

        case .cliTool:
            // Show subcommands as quick actions, plus a "Run in Terminal" button for TUI tools
            let toolCmd = ctx.name
            let pkg = TerminalPackageManager.shared.packages.first(where: {
                $0.name == ctx.name || $0.command == ctx.name
            })
            let isTUI = TerminalAIBridge.shared.isTUICommand(toolCmd)
            var actions: [PanelAction] = []

            func sendCLIQuery(_ msg: String) {
                searchText = msg
                handleRemPanelQuery()
                searchText = ""
            }

            if isTUI {
                actions.append(PanelAction(icon: "play.fill", label: "Launch") {
                    // Direct spawn — bypasses AI so TUI starts instantly
                    if panelTerminalHost == nil {
                        panelTerminalHost = TerminalHostController()
                    }
                    showLivePanel(.terminal)
                    // Small delay so SwiftTerm shell is ready before we send the command
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        panelTerminalHost?.sendCommand(toolCmd)
                        BackgroundWorkerPool.shared.registerPTYWorker(
                            command: toolCmd,
                            purpose: "Launched from panel",
                            intent: TerminalAIBridge.shared.detectWorkerIntent(for: toolCmd)
                        )
                    }
                })
            }
            // First few subcommands as quick actions
            if let subs = pkg?.subcommands {
                for sub in subs.prefix(isTUI ? 3 : 4) {
                    actions.append(PanelAction(icon: "arrow.right.circle", label: sub) {
                        sendCLIQuery("Run: \(toolCmd) \(sub)")
                    })
                }
            }
            actions.append(PanelAction(icon: "questionmark.circle", label: "Help") {
                sendCLIQuery("Show \(toolCmd) --help")
            })
            actions.append(PanelAction(icon: "info.circle", label: "Version") {
                sendCLIQuery("What version is \(toolCmd)?")
            })
            return actions

        default:
            return []
        }
    }

    // MARK: - Live Panel (slides in from right like Claude's artifact panel)

    /// The slide-in panel — only rendered when `livePanelVisible == true`.
    /// Shows context info, an embedded terminal, music player, or a file preview
    /// depending on what the AI or user triggered.
    @ViewBuilder
    private var livePanelView: some View {
        VStack(spacing: 0) {
            livePanelHeader
            Divider()
            livePanelContent
        }
        .frame(width: 310)
        .background(.ultraThinMaterial)
        // Auto-switches
        .onChange(of: miniPlayer.playerInfo != nil) { _, has in
            if has { showLivePanel(.nowPlaying) }
        }
        .onChange(of: workerPool.workers.count) { old, new in
            guard new > old else { return }
            let hasPTY = workerPool.workers.values.contains { $0.isPTY && $0.status.isActive }
            if hasPTY { showLivePanel(.terminal) }
        }
        .onDisappear {
            nowPlayingTimer?.invalidate()
            nowPlayingTimer = nil
        }
    }

    /// Thin header: icon + title + optional subtitle + X dismiss button
    @ViewBuilder
    private var livePanelHeader: some View {
        let (icon, title, subtitle, tint) = livePanelHeaderMeta
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    livePanelVisible = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var livePanelHeaderMeta: (icon: String, title: String, subtitle: String, tint: SwiftUI.Color) {
        switch livePanelMode {
        case .results(let items):
            let count = items.count
            return ("list.bullet", count > 0 ? "\(count) Result\(count == 1 ? "" : "s")" : "Results", "", .accentColor)
        case .terminal:
            let count = workerPool.workers.values.filter { $0.status.isActive }.count
            return ("terminal.fill", "Terminal", count > 0 ? "\(count) process running" : "Shell ready", .green)
        case .nowPlaying:
            let track = nowPlayingTitle.isEmpty ? "Now Playing" : nowPlayingTitle
            return ("music.note", track, nowPlayingArtist, Color(red: 0.2, green: 0.8, blue: 0.4))
        case .filePreview(let url):
            return ("doc.fill", url.lastPathComponent, url.deletingLastPathComponent().path, .accentColor)
        case .youtubeResults(let items):
            return ("play.rectangle.fill", "YouTube", "\(items.count) results", .red)
        }
    }

    /// Switches mode content based on current `livePanelMode`
    @ViewBuilder
    private var livePanelContent: some View {
        switch livePanelMode {
        case .results(let items):
            livePanelResultsView(items: items)
        case .terminal:
            livePanelTerminalView
        case .nowPlaying:
            livePanelNowPlayingView
        case .filePreview(let url):
            livePanelFilePreviewView(url: url)
        case .youtubeResults(let results):
            YouTubePanelResultsView(
                results: results,
                selected: $selectedYouTubeResult,
                onDownloadMP3: { result in
                    remPanelChatMessages.append(AIChatMessage(role: .user,
                        content: "Download \"\(result.title)\" as mp3"))
                    selectedYouTubeResult = result
                    remPanelIsProcessing = true
                    handleYouTubeDownloadWithAI(query: "Download \"\(result.title)\" as mp3")
                },
                onDownloadMP4: { result in
                    remPanelChatMessages.append(AIChatMessage(role: .user,
                        content: "Download \"\(result.title)\" as mp4 video"))
                    selectedYouTubeResult = result
                    remPanelIsProcessing = true
                    handleYouTubeDownloadWithAI(query: "Download \"\(result.title)\" as mp4 video")
                },
                onOpenBrowser: { result in
                    if let url = URL(string: result.url) {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        }
    }

    /// Helper — show panel with a specific mode + slide-in animation
    private func showLivePanel(_ mode: LivePanelMode) {
        livePanelMode = mode
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            livePanelVisible = true
        }
    }

    @ViewBuilder
    private func livePanelResultsView(items: [LivePanelMode.ResultEntry]) -> some View {
        if items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(.secondary.opacity(0.4))
                Text("Ask the AI to show results")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("e.g. \"list all PDFs here\" or \"find large files\"")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            if !item.path.isEmpty {
                                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if !item.path.isEmpty {
                                    Menu {
                                        Button("Open") {
                                            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                                        }
                                        Button("Reveal in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                                        }
                                        Button("Copy Path") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(item.path, forType: .string)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .padding(4)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .frame(width: 20)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.0))
                        Divider().padding(.leading, 42).opacity(0.4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func livePanelFileCard(ctx: SearchContextApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Icon + name
            HStack(spacing: 12) {
                if let icon = ctx.icon {
                    Image(nsImage: icon)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(ctx.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if let path = ctx.filePath {
                        Text(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 14)

            // File metadata
            if let path = ctx.filePath {
                let url = URL(fileURLWithPath: path)
                let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                let size = attrs[.size] as? Int ?? 0
                let modified = attrs[.modificationDate] as? Date
                let ext = url.pathExtension.uppercased()

                VStack(spacing: 0) {
                    livePanelMetaRow(label: "Kind", value: ext.isEmpty ? "File" : "\(ext) file")
                    Divider().padding(.horizontal, 14).opacity(0.4)
                    livePanelMetaRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    if let mod = modified {
                        Divider().padding(.horizontal, 14).opacity(0.4)
                        livePanelMetaRow(label: "Modified", value: RelativeDateTimeFormatter().localizedString(for: mod, relativeTo: Date()))
                    }
                }
                .padding(.vertical, 6)
            }

            Divider().padding(.horizontal, 14)

            // Actions
            livePanelActionGrid(ctx: ctx)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func livePanelFolderCard(ctx: SearchContextApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let icon = ctx.icon {
                    Image(nsImage: icon)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.yellow)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(ctx.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let path = ctx.filePath {
                        Text(path)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 14)

            // Contents summary
            if let path = ctx.filePath,
               let contents = try? FileManager.default.contentsOfDirectory(atPath: path) {
                let count = contents.count
                let hidden = contents.filter { $0.hasPrefix(".") }.count
                VStack(spacing: 0) {
                    livePanelMetaRow(label: "Items", value: "\(count - hidden) visible, \(hidden) hidden")
                    Divider().padding(.horizontal, 14).opacity(0.4)
                    // Recent items
                    let recent = contents.prefix(6).filter { !$0.hasPrefix(".") }
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, name in
                        HStack(spacing: 8) {
                            Image(systemName: name.contains(".") ? "doc" : "folder")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .frame(width: 14)
                            Text(name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().padding(.horizontal, 14)
            livePanelActionGrid(ctx: ctx).padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func livePanelContactCard(ctx: SearchContextApp) -> some View {
        VStack(spacing: 0) {
            // Avatar
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.4)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 60, height: 60)
                    Text(String(ctx.name.prefix(2)).uppercased())
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Text(ctx.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(ctx.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

            Divider().padding(.horizontal, 14)

            VStack(spacing: 0) {
                if let email = ctx.contactEmail {
                    livePanelMetaRow(label: "Email", value: email)
                    Divider().padding(.horizontal, 14).opacity(0.4)
                }
                if let phone = ctx.contactPhone {
                    livePanelMetaRow(label: "Phone", value: phone)
                    Divider().padding(.horizontal, 14).opacity(0.4)
                }
            }
            .padding(.vertical, 4)

            livePanelActionGrid(ctx: ctx).padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func livePanelAppCard(ctx: SearchContextApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let icon = ctx.icon {
                    Image(nsImage: icon)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 52, height: 52)
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(ctx.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if !ctx.appPath.isEmpty {
                        let bundleID = Bundle(path: ctx.appPath)?.bundleIdentifier ?? ""
                        if !bundleID.isEmpty {
                            Text(bundleID)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        let version = Bundle(path: ctx.appPath)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                        if !version.isEmpty {
                            Text("Version \(version)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 14)
            livePanelActionGrid(ctx: ctx).padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func livePanelGenericCard(ctx: SearchContextApp) -> some View {
        VStack(spacing: 12) {
            if let icon = ctx.icon {
                Image(nsImage: icon)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
            }
            Text(ctx.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if !ctx.subtitle.isEmpty {
                Text(ctx.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    @ViewBuilder
    private func livePanelMetaRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func livePanelActionGrid(ctx: SearchContextApp) -> some View {
        let actions = contextPanelActions()
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Actions")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                VStack(spacing: 1) {
                    ForEach(actions) { action in
                        Button { action.action() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 16)
                                Text(action.label)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.quaternary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0))
                        if action.id != actions.last?.id {
                            Divider().padding(.horizontal, 14).opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    /// Compact quick-action chips floating above the panel input field
    @ViewBuilder
    private var floatingQuickActionsStrip: some View {
        let actions = contextPanelActions()
        if !actions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(actions) { action in
                        Button { action.action() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 10, weight: .medium))
                                Text(action.label)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var livePanelTerminalView: some View {
        VStack(spacing: 0) {
            // Terminal header
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Active workers indicator
                let active = workerPool.workers.values.filter { $0.status.isActive }
                if !active.isEmpty {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                            .opacity(0.8)
                        Text("\(active.count) running")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    panelTerminalHost?.sendCommand("clear")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.4))

            // SwiftTerm embedded view
            if let host = panelTerminalHost {
                TerminalNSViewRepresentable(terminalController: host)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Starting terminal…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    panelTerminalHost = TerminalHostController()
                }
            }
        }
        .background(Color.black.opacity(0.55))
        .onAppear {
            if panelTerminalHost == nil {
                panelTerminalHost = TerminalHostController()
            }
        }
    }

    @ViewBuilder
    private var livePanelNowPlayingView: some View {
        VStack(spacing: 0) {
            // Album art placeholder + info
            VStack(spacing: 0) {
                // Large album art area
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.3), Color.purple.opacity(0.2)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "music.note")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // Track info
                VStack(spacing: 4) {
                    Text(nowPlayingTitle.isEmpty ? "Nothing Playing" : nowPlayingTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(nowPlayingArtist.isEmpty ? "—" : nowPlayingArtist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !nowPlayingAlbum.isEmpty {
                        Text(nowPlayingAlbum)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Now playing source badge
                if let info = miniPlayer.playerInfo {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("via \(info.toolName)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                }

                Divider().padding(.horizontal, 16).padding(.vertical, 6)

                // Playback controls
                HStack(spacing: 0) {
                    Spacer()
                    Button { MiniPlayerController.shared.previous() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { MiniPlayerController.shared.togglePlayPause() } label: {
                        Image(systemName: nowPlayingIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { MiniPlayerController.shared.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Button { MiniPlayerController.shared.stop() } label: {
                    Label("Stop Playback", systemImage: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .onAppear {
            refreshNowPlaying()
            nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                Task { @MainActor in refreshNowPlaying() }
            }
        }
        .onDisappear {
            nowPlayingTimer?.invalidate()
            nowPlayingTimer = nil
        }
    }

    private func refreshNowPlaying() {
        let info = MediaInfoProvider.shared.getNowPlayingInfo()
        nowPlayingTitle = info.title ?? miniPlayer.playerInfo?.currentSong ?? ""
        nowPlayingArtist = info.artist ?? ""
        nowPlayingAlbum = info.album ?? ""
        nowPlayingIsPlaying = info.playbackRate > 0 || (miniPlayer.playerInfo?.isPlaying ?? false)
    }

    // MARK: - Live Panel: File Preview (inline QL preview for AI-created files)
    @ViewBuilder
    private func livePanelFilePreviewView(url: URL) -> some View {
        VStack(spacing: 0) {
            InlineQLPreview(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom action bar
            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered).controlSize(.small)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy path")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    /// Strips raw tool-call syntax that the AI accidentally echoes as plain text.
    static func stripLeakedToolCalls(_ text: String) -> String {
        var result = text
        let patterns = [
            // Function-call style: run_command(...) or spawn_worker(...)
            #"run_command\s*\([\s\S]*?\)"#,
            #"spawn_worker\s*\([\s\S]*?\)"#,
            // Any JSON object with a "name" key — catches invented tool names like {"name":"remind",...}
            #"\{[\s\S]*?"name"\s*:\s*"[^"]*"[\s\S]*?"parameters"[\s\S]*?\}"#,
            #"\{[\s\S]*?"name"\s*:\s*"[^"]*"[\s\S]*?"input"[\s\S]*?\}"#,
            // Also catch preamble lines like "I will call the X tool with..."
            #"(?m)^.*?I will (call|use|invoke).*?(tool|function|script).*\n?"#,
            #"(?m)^.*?(function call|tool call|following call).*\n?"#,
            // Fenced code blocks that are just tool calls
            #"```json[\s\S]*?```"#,
            #"```[\s\S]*?```"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect if a shell command created/wrote an output file.
    /// Returns the URL if found and the file exists.
    private func detectCreatedFile(command: String, output: String) -> URL? {
        let expandPath: (String) -> URL? = { raw in
            guard !raw.isEmpty else { return nil }
            let path = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        // -o flag: pandoc -o out.pdf, ffmpeg -o out.mp4, etc.
        if let range = command.range(of: #"-o\s+(\S+)"#, options: .regularExpression) {
            let full = String(command[range])
            let parts = full.components(separatedBy: .whitespaces)
            if parts.count >= 2, let url = expandPath(parts[1]) { return url }
        }

        // Shell redirect: cmd > file.txt
        if let range = command.range(of: #">\s*(\S+)"#, options: .regularExpression) {
            let full = String(command[range])
            let parts = full.components(separatedBy: .whitespaces)
            if parts.count >= 2, let url = expandPath(parts[1]) { return url }
        }

        // Common "saved to PATH" / "written to PATH" phrases in output
        for marker in ["saved to ", "created: ", "written to ", "output: ", "→ ", "=> ", "exported to "] {
            if let idx = output.range(of: marker, options: .caseInsensitive)?.upperBound {
                let after = String(output[idx...])
                let candidate = after.components(separatedBy: .whitespacesAndNewlines).first ?? ""
                if let url = expandPath(candidate) { return url }
            }
        }

        // Any absolute path in the output that is a file (not a directory)
        let pathPattern = #"(/[^\s\"']+\.[a-zA-Z0-9]{1,8})"#
        if let matches = output.range(of: pathPattern, options: .regularExpression) {
            let candidate = String(output[matches])
            if let url = expandPath(candidate),
               !url.hasDirectoryPath { return url }
        }

        return nil
    }

    /// Master dispatcher: routes command output to the right panel parser based on panel type.
    private func parseCommandOutputForPanel(command: String, output: String, panelKey: String) -> [LivePanelMode.ResultEntry] {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let cmd = command.trimmingCharacters(in: .whitespaces).lowercased()

        // ── Reminders (rem CLI) ─────────────────────────────────────────
        if panelKey == "reminders" || cmd.hasPrefix("rem ") {
            return parseRemOutput(output)
        }

        // ── Process list (ps, pgrep, top -l 1 | grep) ──────────────────
        if cmd.hasPrefix("ps ") || cmd.hasPrefix("ps\n") || cmd == "ps"
            || cmd.hasPrefix("pgrep") || cmd.contains("| ps") {
            return parseProcessOutput(output)
        }

        // ── Network (netstat, lsof -i, nmap) ───────────────────────────
        if cmd.hasPrefix("netstat") || cmd.hasPrefix("lsof -i") || cmd.hasPrefix("nmap") {
            return parseNetworkOutput(command: command, output: output)
        }

        // ── Brew (brew list, brew outdated, brew search) ────────────────
        if cmd.hasPrefix("brew ") {
            return parseBrewOutput(command: command, output: output)
        }

        // ── Git (git log, git status, git branch, git diff --stat) ─────
        if cmd.hasPrefix("git ") {
            return parseGitOutput(command: command, output: output)
        }

        // ── Generic line list (any output with ≥3 lines that isn't JSON) ─
        // Falls through to file parser first, then generic
        let fileEntries = parseOutputForFileResults(command: command, output: output)
        if !fileEntries.isEmpty { return fileEntries }

        return parseGenericListOutput(command: command, output: output, panelKey: panelKey)
    }

    // ── Reminders parser ───────────────────────────────────────────────

    private func parseRemOutput(_ output: String) -> [LivePanelMode.ResultEntry] {
        // rem list output: "[ ] Buy milk   due: tomorrow" or "[x] Call mom"
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("No reminders") && !$0.hasPrefix("---") }
        guard !lines.isEmpty else { return [] }

        return lines.compactMap { line -> LivePanelMode.ResultEntry? in
            let isDone = line.hasPrefix("[x]") || line.hasPrefix("[X]") || line.hasPrefix("✓") || line.hasPrefix("✅")
            let isPending = line.hasPrefix("[ ]") || line.hasPrefix("○") || line.hasPrefix("•")

            guard isDone || isPending else {
                // Still treat plain lines as reminder entries if they look like tasks
                if line.count < 3 || line.hasPrefix("{") { return nil }
                return LivePanelMode.ResultEntry(name: line, path: "", subtitle: "", icon: "checkmark.circle")
            }

            var text = line
            // Strip leading marker
            for prefix in ["[x] ", "[X] ", "[ ] ", "✓ ", "✅ ", "○ ", "• "] {
                if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)); break }
            }

            // Extract "due: ..." from end
            var subtitle = ""
            if let dueRange = text.range(of: #"\s+due:\s*.+"#, options: .regularExpression) {
                subtitle = String(text[dueRange]).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "due: ", with: "Due: ")
                text = String(text[..<dueRange.lowerBound])
            }

            let icon = isDone ? "checkmark.circle.fill" : "circle"
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return LivePanelMode.ResultEntry(name: name, path: "", subtitle: subtitle, icon: icon)
        }
    }

    // ── Process parser ─────────────────────────────────────────────────

    private func parseProcessOutput(_ output: String) -> [LivePanelMode.ResultEntry] {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return [] }

        var entries: [LivePanelMode.ResultEntry] = []
        // Detect header line (PID USER %CPU %MEM COMMAND etc.)
        let hasHeader = lines.first?.uppercased().contains("PID") == true
            || lines.first?.uppercased().contains("COMMAND") == true

        for (i, line) in lines.enumerated() {
            if i == 0 && hasHeader { continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            // Standard ps -ef format: UID PID PPID C STIME TTY TIME CMD
            // ps aux format: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
            let pid: String
            let cmdName: String
            var subtitle = ""

            if let pidInt = Int(parts[1]) {
                // ps aux: USER PID %CPU %MEM ... COMMAND
                pid = "\(pidInt)"
                let cpu = parts.count > 2 ? parts[2] : ""
                let mem = parts.count > 3 ? parts[3] : ""
                cmdName = parts.count > 10 ? (parts[10...].joined(separator: " ") as NSString).lastPathComponent : parts[1]
                if !cpu.isEmpty { subtitle = "CPU: \(cpu)%  MEM: \(mem)%" }
            } else if let pidInt = Int(parts[0]) {
                // simple format: PID NAME
                pid = "\(pidInt)"
                cmdName = parts.count > 1 ? (parts[1...].joined(separator: " ") as NSString).lastPathComponent : line
            } else {
                // last column is command
                let rawCmd = parts.last ?? line
                cmdName = (rawCmd as NSString).lastPathComponent
                pid = parts.count > 1 ? parts[1] : ""
                subtitle = pid.isEmpty ? "" : "PID \(pid)"
            }

            let name = (cmdName as NSString).lastPathComponent
            guard !name.isEmpty, name != "0", name.count > 1 else { continue }
            if subtitle.isEmpty && !pid.isEmpty { subtitle = "PID \(pid)" }

            entries.append(LivePanelMode.ResultEntry(name: name, path: "", subtitle: subtitle,
                                                     icon: "cpu"))
        }
        return entries
    }

    // ── Network parser ─────────────────────────────────────────────────

    private func parseNetworkOutput(command: String, output: String) -> [LivePanelMode.ResultEntry] {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Proto") && !$0.hasPrefix("Active") }

        return lines.prefix(30).compactMap { line -> LivePanelMode.ResultEntry? in
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 4 else { return nil }
            // netstat: Proto RecvQ SendQ LocalAddr ForeignAddr State
            let local = parts.count > 3 ? parts[3] : parts[1]
            let state = parts.last ?? ""
            return LivePanelMode.ResultEntry(name: local, path: "", subtitle: state,
                                             icon: "network")
        }
    }

    // ── Brew parser ────────────────────────────────────────────────────

    private func parseBrewOutput(command: String, output: String) -> [LivePanelMode.ResultEntry] {
        let cmd = command.lowercased()
        let isOutdated = cmd.contains("outdated")
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.hasPrefix("Warning") }
        guard !lines.isEmpty else { return [] }

        return lines.compactMap { line -> LivePanelMode.ResultEntry? in
            let parts = line.components(separatedBy: .whitespaces)
            let name = parts.first ?? line
            guard !name.isEmpty, name.count > 1 else { return nil }
            let subtitle: String
            if isOutdated && parts.count >= 3 {
                subtitle = "\(parts[1]) → \(parts[2])"  // current → latest
            } else if parts.count > 1 {
                subtitle = parts.dropFirst().joined(separator: " ")
            } else {
                subtitle = ""
            }
            return LivePanelMode.ResultEntry(name: name, path: "",
                                             subtitle: subtitle,
                                             icon: isOutdated ? "arrow.up.circle" : "shippingbox")
        }
    }

    // ── Git parser ─────────────────────────────────────────────────────

    private func parseGitOutput(command: String, output: String) -> [LivePanelMode.ResultEntry] {
        let cmd = command.lowercased()
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        if cmd.contains("git log") {
            // "abc1234 Fix bug in login" or "commit abc1234\n Author: ...\n    message"
            return lines.prefix(20).compactMap { line -> LivePanelMode.ResultEntry? in
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { return nil }
                let hash = String(parts[0].prefix(7))
                let msg = parts.dropFirst().joined(separator: " ")
                return LivePanelMode.ResultEntry(name: msg, path: "", subtitle: hash, icon: "arrow.triangle.branch")
            }
        } else if cmd.contains("git branch") {
            return lines.compactMap { line -> LivePanelMode.ResultEntry? in
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                guard !name.isEmpty else { return nil }
                let isCurrent = line.hasPrefix("*")
                return LivePanelMode.ResultEntry(name: name, path: "",
                                                 subtitle: isCurrent ? "current" : "",
                                                 icon: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
            }
        } else if cmd.contains("git diff --stat") || cmd.contains("git status") {
            return lines.compactMap { line -> LivePanelMode.ResultEntry? in
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard let name = parts.first, name.contains(".") || name.contains("/") else { return nil }
                let stat = parts.dropFirst().joined(separator: " ")
                return LivePanelMode.ResultEntry(name: name, path: "", subtitle: stat,
                                                 icon: "doc.badge.ellipsis")
            }
        }
        return parseGenericListOutput(command: command, output: output, panelKey: "git")
    }

    // ── Generic list parser ────────────────────────────────────────────

    private func parseGenericListOutput(command: String, output: String, panelKey: String) -> [LivePanelMode.ResultEntry] {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Don't show generic results for conversational / single-line outputs
        guard lines.count >= 3 else { return [] }
        // Skip JSON blobs
        if output.trimmingCharacters(in: .whitespaces).hasPrefix("{") { return [] }
        if output.trimmingCharacters(in: .whitespaces).hasPrefix("[") { return [] }

        // Pick icon based on panel key
        let icon: String = {
            switch panelKey {
            case "calendar":   return "calendar"
            case "notes":      return "note.text"
            case "mail":       return "envelope"
            case "contacts":   return "person.crop.circle"
            case "music":      return "music.note"
            default:           return "list.bullet"
            }
        }()

        return lines.prefix(50).compactMap { line -> LivePanelMode.ResultEntry? in
            // Skip separator lines and very short lines
            guard line.count > 2,
                  !line.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "─" }),
                  !line.hasPrefix("---"), !line.hasPrefix("===")
            else { return nil }

            // Split "name: detail" or "name — detail" into name + subtitle
            let separators = ["\t", " — ", " - ", ": "]
            for sep in separators {
                if let range = line.range(of: sep) {
                    let name = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let sub  = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        return LivePanelMode.ResultEntry(name: name, path: "", subtitle: sub, icon: icon)
                    }
                }
            }
            return LivePanelMode.ResultEntry(name: line, path: "", subtitle: "", icon: icon)
        }
    }

    /// Parses shell command output for file/path lists to display in the live panel.
    private func parseOutputForFileResults(command: String, output: String) -> [LivePanelMode.ResultEntry] {
        let cmd = command.trimmingCharacters(in: .whitespaces).lowercased()

        // du is a size-query command, not a file lister — keep result in chat only
        if cmd.hasPrefix("du ") || cmd == "du" { return [] }
        // stat, wc, grep -c, etc. — single-line summaries, not file lists
        if cmd.hasPrefix("stat ") || cmd.hasPrefix("wc ") { return [] }

        let isListCommand = cmd.hasPrefix("find ") || cmd.hasPrefix("ls") || cmd.hasPrefix("locate ")
            || cmd.contains(" find ") || cmd.contains("| find") || cmd.contains("| ls")
            || cmd.contains("-name ") || cmd.contains("-type f")

        let rawLines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Detect `ls -l` / `ls -lt` format: lines like "-rw-r--r-- 1 user staff 123456 Mar 10 file.jpg"
        let isLsLongFormat = rawLines.first?.range(of: #"^[-dlrwxst]{10}\s"#, options: .regularExpression) != nil
            || rawLines.first?.lowercased().hasPrefix("total") == true

        // Extract context folder path for resolving relative names
        let contextFolder: String? = {
            // From the command itself: find /path ... → /path
            if cmd.hasPrefix("find /") || cmd.hasPrefix("find ~/") {
                let parts = command.components(separatedBy: " ")
                if parts.count > 1 {
                    let p = parts[1].hasPrefix("~") ? NSHomeDirectory() + parts[1].dropFirst() : parts[1]
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return p }
                }
            }
            // From ls command: ls /path or ls -lt /path
            if cmd.hasPrefix("ls") {
                let parts = command.components(separatedBy: " ").filter { !$0.hasPrefix("-") && !$0.isEmpty }
                let pathPart = parts.dropFirst().first ?? ""
                let p = pathPart.hasPrefix("~") ? NSHomeDirectory() + pathPart.dropFirst() : pathPart
                if !p.isEmpty {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return p }
                }
            }
            return nil
        }()

        // Also activate if output lines are mostly file paths
        let pathLikeLines = rawLines.filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }.count
        let looksLikePaths = rawLines.count > 1 && pathLikeLines >= rawLines.count / 2

        guard isListCommand || looksLikePaths, !rawLines.isEmpty, rawLines.count <= 500 else { return [] }

        let fm = FileManager.default
        var entries: [LivePanelMode.ResultEntry] = []
        var seen = Set<String>()

        func makeEntry(path: String) {
            guard !seen.contains(path) else { return }
            seen.insert(path)
            guard fm.fileExists(atPath: path) else { return }

            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)

            let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            let size = attrs[.size] as? Int ?? 0
            let modified = attrs[.modificationDate] as? Date
            let ext = url.pathExtension.lowercased()

            let icon: String = {
                if isDir.boolValue { return "folder.fill" }
                switch ext {
                case "pdf":                              return "doc.richtext"
                case "png","jpg","jpeg","gif","heic",
                     "webp","tiff","raw","arw","cr2":   return "photo"
                case "mp4","mov","mkv","avi","m4v":      return "film"
                case "mp3","aac","flac","wav","m4a",
                     "ogg","opus":                       return "waveform"
                case "zip","gz","tar","7z","rar","bz2":  return "archivebox"
                case "swift","py","js","ts","sh","rb",
                     "go","rs","cpp","c","java":         return "chevron.left.forwardslash.chevron.right"
                case "md","txt","rtf":                   return "doc.text"
                case "json","yaml","yml","toml","xml":   return "curlybraces"
                default:                                 return "doc"
                }
            }()

            // Subtitle: file size + relative time if available
            var subtitle = ""
            if size > 0 { subtitle = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
            if let mod = modified {
                let rel = RelativeDateTimeFormatter().localizedString(for: mod, relativeTo: Date())
                subtitle = subtitle.isEmpty ? rel : "\(subtitle) · \(rel)"
            }
            if subtitle.isEmpty { subtitle = isDir.boolValue ? "Folder" : ext.uppercased() }

            entries.append(LivePanelMode.ResultEntry(name: url.lastPathComponent, path: path,
                                                     subtitle: subtitle, icon: icon))
        }

        for line in rawLines {
            // Skip ls -l header and permission strings
            if line.lowercased().hasPrefix("total") { continue }
            if line.range(of: #"^[-dlrwxst]{10}\s"#, options: .regularExpression) != nil {
                // ls -l line: last whitespace-separated token is the filename
                if isLsLongFormat, let folder = contextFolder {
                    // Handle ls -l output: extract filename (last column, may contain spaces after arrow)
                    // Format: perms links user group size mon day time/year name
                    // Split on 2+ spaces or use fixed column approach
                    let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 9 {
                        // name starts at index 8, join remaining (handles spaces in names via -> symlink)
                        let namePart = parts[8...].joined(separator: " ").components(separatedBy: " -> ").first ?? parts[8]
                        let fullPath = folder + "/" + namePart
                        makeEntry(path: fullPath)
                    }
                }
                continue
            }

            // du output: "size\tpath"
            var candidate = line
            if let tab = line.range(of: "\t") {
                candidate = String(line[tab.upperBound...])
            }
            // Expand ~
            if candidate.hasPrefix("~") {
                candidate = NSHomeDirectory() + String(candidate.dropFirst())
            }

            if candidate.hasPrefix("/") {
                makeEntry(path: candidate)
            } else if let folder = contextFolder, !candidate.isEmpty,
                      !candidate.hasPrefix("-") && !candidate.hasPrefix("#") {
                // Relative name — resolve against context folder
                makeEntry(path: folder + "/" + candidate)
            }
        }

        return entries
    }

    // MARK: - Terminal Drawer
    @ViewBuilder
    private var terminalDrawer: some View {
        let hasLines = !panelConsoleLines.isEmpty
        // Only show the terminal drawer when there's something to show
        let hasActivity = !remPanelChatMessages.isEmpty || remPanelIsProcessing || hasLines
        let isOpen   = showPanelConsole && hasActivity
        Group {
            if hasActivity {
                VStack(spacing: 0) {
                    terminalDrawerHandle(isOpen: isOpen, hasLines: hasLines)
                    if isOpen {
                        terminalDrawerBody
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .background(Color.black.opacity(isOpen ? 0.55 : 0))
                .clipShape(RoundedRectangle(cornerRadius: isOpen ? 10 : 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: isOpen ? 10 : 22, style: .continuous)
                        .strokeBorder(Color.green.opacity(isOpen ? 0.18 : 0), lineWidth: 0.75)
                )
                .padding(.horizontal, isOpen ? 10 : 50)
                .padding(.bottom, isOpen ? 8 : 4)
                .padding(.top, 2)
                .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isOpen)
            }
        }
    }

    @ViewBuilder
    private func terminalDrawerHandle(isOpen: Bool, hasLines: Bool) -> some View {
        let ck = activeConsoleKey
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                let opening = !showPanelConsole
                panelShowConsoleMap[ck] = opening
                let term = panelTerminal(for: ck)   // always create
                if opening {
                    // Give the embedded terminal focus so keyboard works
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        term.terminalView.window?.makeFirstResponder(term.terminalView)
                    }
                } else {
                    // Return focus to search field when drawer closes
                    isSearchFieldFocused = true
                }
            }
        } label: {
            ZStack(alignment: .center) {
                Rectangle().fill(Color.black.opacity(isOpen ? 0.65 : 0.32))
                HStack(spacing: 8) {
                    Capsule()
                        .fill(Color.white.opacity(isOpen ? 0.3 : 0.18))
                        .frame(width: 36, height: 4)
                    if remPanelIsProcessing {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                    }
                    Text(remPanelIsProcessing
                         ? (isOpen ? "running…" : "Terminal • running…")
                         : "Terminal")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(remPanelIsProcessing ? 0.7 : 0.45))
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.5))
                }
                .padding(.horizontal, 14)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 26)
    }

    @ViewBuilder
    private var terminalDrawerBody: some View {
        let ck = activeConsoleKey
        VStack(spacing: 0) {
            // ── Header bar ──────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.7))
                Text("Live Terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.7))
                    .textCase(.uppercase).tracking(0.5)
                if remPanelIsProcessing {
                    ProgressView().scaleEffect(0.45).tint(.green)
                    Text("running").font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.5))
                }
                Spacer()
                // Clear terminal screen button
                Button {
                    panelTerminalControllers[ck]?.sendCommand("clear")
                } label: {
                    Label("Clear", systemImage: "clear").font(.system(size: 9))
                        .foregroundStyle(Color.green.opacity(0.5))
                }.buttonStyle(.plain)
                // Close drawer button
                Button {
                    withAnimation { panelShowConsoleMap[ck] = false }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.5))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.black.opacity(0.55))

            Divider().overlay(Color.green.opacity(0.15))

            // ── Real SwiftTerm PTY ───────────────────────────────────────────
            PanelTerminalView(controller: panelTerminal(for: ck))
                .frame(height: panelConsoleHeight)
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
    }

    // MARK: - Quick Actions Column
    @ViewBuilder
    private func panelQuickActionsColumn(_ actions: [PanelAction]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quick Actions")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            if actions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20)).foregroundStyle(.tertiary)
                    Text("Add shortcuts\nin Settings")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(actions) { action in
                            Button { action.action() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: action.icon)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 18)
                                    Text(action.label)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(width: 148)
        .background(.primary.opacity(0.03))
    }

    // MARK: - App Panel Split View (2-column: 80% AI chat / 20% quick actions)
    @ViewBuilder
    private var appPanelView: some View {
        let ctx = searchContextApp
        let meta = smartQueryMeta
        let key = activeSmartQueryKey ?? ""
        let isReminders = key == "reminders"
        let hasChatHistory = !remPanelChatMessages.isEmpty

        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            HStack(spacing: 8) {
                if let icon = ctx?.icon {
                    Image(nsImage: icon)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: meta.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(ctx?.name ?? meta.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = ctx?.subtitle, !subtitle.isEmpty, ctx?.resultType != .application {
                    Text("·")
                        .font(.caption).foregroundStyle(.tertiary)
                    Text(subtitle)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if hasChatHistory {
                    Button {
                        let k = activeSmartQueryKey ?? ""
                        remPanelChatMessages = []
                        AppPanelChatStore.shared.clear(for: k)
                    } label: {
                        Label("Clear chat", systemImage: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text("esc to exit")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                let openPath = ctx?.appPath ?? ""
                if !openPath.isEmpty {
                    Button("Open \(ctx?.name ?? meta.label)") {
                        NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: openPath),
                            configuration: NSWorkspace.OpenConfiguration())
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)

            Divider()

            // ── Tool-removal cleanup banner ──────────────────────────
            if let removedTool = removedToolBannerName {
                HStack(spacing: 8) {
                    Image(systemName: "trash.circle")
                        .foregroundStyle(.orange)
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\"\(removedTool)\" was removed from this panel")
                            .font(.system(size: 11, weight: .medium))
                        Text("Clear old chat history related to this tool?")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Chat") {
                        let k = activeSmartQueryKey ?? ""
                        remPanelChatMessages = []
                        AppPanelChatStore.shared.clear(for: k)
                        removedToolBannerName = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    Button {
                        removedToolBannerName = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            // ── Body: 2 columns + terminal drawer ────────────
            VStack(spacing: 0) {

            // ── Inner: height-constrained chat area ──────────
            VStack(spacing: 0) {
                HStack(spacing: 0) {

                    // ── Column 1: AI Chat or Safari Tab List ─────────
                    VStack(spacing: 0) {
                        if key == "safari" {
                            // ── Safari Tab List header ───────────────────
                            HStack(spacing: 6) {
                                Image(systemName: "safari")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                Text("Open Tabs")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.4)
                                Spacer()
                                Text("\(appPanelDisplayedItems.count) tabs")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.06))

                            Divider()

                            safariTabListView

                        } else {
                            // ── Normal AI Chat column ────────────────────
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                Text("AI Assistant")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.4)
                                Spacer()
                                if remPanelIsProcessing {
                                    ProgressView().scaleEffect(0.55)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.06))

                            Divider()

                            // Chat messages or empty state
                            if hasChatHistory {
                                ScrollViewReader { proxy in
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(remPanelChatMessages) { msg in
                                                remChatBubble(msg).id(msg.id)
                                            }
                                            if remPanelIsProcessing {
                                                HStack(spacing: 6) {
                                                    ProgressView().scaleEffect(0.6)
                                                    Text("Thinking…")
                                                        .font(.system(size: 11))
                                                        .foregroundStyle(.secondary)
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 4)
                                                .id("typing")
                                            }
                                        }
                                        .padding(10)
                                    }
                                    .onChange(of: remPanelChatMessages.count) { _, _ in
                                        if let last = remPanelChatMessages.last {
                                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                                        }
                                    }
                                    .onChange(of: remPanelIsProcessing) { _, _ in
                                        withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                                    }
                                }
                            } else {
                                panelWelcomeView(ctx: ctx, meta: meta, key: key)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.02))

                    // ── Live Panel: slides in from right (hidden by default) ──
                    if livePanelVisible {
                        Divider()
                        livePanelView
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal:   .move(edge: .trailing).combined(with: .opacity)
                            ))
                    }
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: livePanelVisible)

            } // end inner height-constrained VStack
            .frame(maxHeight: 500)

            // ── Terminal Drawer (outside height constraint — always visible) ──
            terminalDrawer

            } // end outer VStack
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isSearchFieldFocused = true }
        )
        .transition(.opacity)
        .task(id: key) {
            guard appPanelAllItems.isEmpty else { return }
            reloadAppPanelData(for: key)
            if isReminders { checkRemInstalled() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBinaryDiscovered)) { note in
            if isReminders, let name = note.userInfo?["toolName"] as? String, name == "rem" {
                remIsInstalled = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appPanelToolRemoved)) { note in
            if let toolName = note.userInfo?["toolName"] as? String {
                // Show the cleanup banner for the currently open panel
                removedToolBannerName = toolName
            }
        }
    }

    // MARK: - Panel Welcome / Onboarding View

    /// Context-aware welcome card shown when no chat history exists yet.
    @ViewBuilder
    private func panelWelcomeView(
        ctx: SearchContextApp?,
        meta: (icon: String, label: String, appPath: String),
        key: String
    ) -> some View {
        let (greeting, subtext) = panelWelcomeText(ctx: ctx, key: key)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // ── Greeting card ──────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        // Context icon
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(width: 36, height: 36)
                            if let icon = ctx?.icon {
                                Image(nsImage: icon)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(width: 22, height: 22)
                            } else {
                                Image(systemName: meta.icon)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(greeting)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(subtext)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 12)


                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Contextual greeting + subtext for the welcome card.
    private func panelWelcomeText(ctx: SearchContextApp?, key: String) -> (String, String) {
        if let ctx = ctx {
            switch ctx.resultType {
            case .folder:
                return (
                    "Ready to help with \(ctx.name)",
                    "I can list, search, organize, and convert files here. Results appear on the right automatically."
                )
            case .file, .document:
                let ext = (ctx.filePath ?? "").components(separatedBy: ".").last?.uppercased() ?? "file"
                return (
                    "Working on \(ctx.name)",
                    "I can inspect, convert, extract info, or transform this \(ext) file using installed CLI tools."
                )
            case .contact:
                return (
                    "Contact: \(ctx.name)",
                    "I can send an email, compose a message, look up info, or copy contact details."
                )
            case .application:
                return (
                    "\(ctx.name) Assistant",
                    "Ask me anything about \(ctx.name). I can run commands, check status, and take actions on your behalf."
                )
            case .cliTool:
                let isTUI = TerminalAIBridge.shared.isTUICommand(ctx.name)
                if isTUI {
                    return (
                        "\(ctx.name)",
                        "This is a TUI app. Say \"launch \(ctx.name)\" to open it in the terminal, or ask me what it does."
                    )
                }
                return (
                    "\(ctx.name) Assistant",
                    "I know this tool's commands and flags. Ask me to run it, explain options, or chain operations."
                )
            default:
                return ("AI Assistant", "Ask me anything about \(ctx.name).")
            }
        }
        switch key {
        case "reminders":
            return ("Reminders Assistant", "I manage your macOS Reminders. Add tasks, set due dates, list and complete reminders — just ask.")
        case "calendar":
            return ("Calendar Assistant", "I can show today's events, add appointments, and help you manage your schedule.")
        case "notes":
            return ("Notes Assistant", "I can search, create, and edit your Notes. Just describe what you need.")
        case "mail":
            return ("Mail Assistant", "I can search emails, check unread count, and help you draft or manage messages.")
        case "photos":
            return ("Photos Assistant", "I can search your photo library, show recent imports, and help organize albums.")
        case "messages":
            return ("Messages Assistant", "I can show recent conversations and help you draft replies.")
        case "amphetamine":
            return ("Amphetamine", "Keep your Mac awake. Start a timed session, check status, or end a session — just ask.")
        case "homebrew":
            return ("Homebrew", "Install, update, and manage CLI tools and Mac apps. Search packages, check for updates, clean up disk space — just ask.")
        default:
            let label = settings.customAppEntries.first(where: { $0.key == key })?.label ?? key.capitalized
            return ("\(label) Assistant", "I'm ready to help with \(label). Ask me anything or run actions directly.")
        }
    }

    /// Contextual suggested prompts for each panel type.
    private func panelSuggestedPrompts(ctx: SearchContextApp?, key: String) -> [String] {
        if let ctx = ctx {
            switch ctx.resultType {
            case .cliTool:
                let toolCmd = ctx.name
                let pkg = TerminalPackageManager.shared.packages.first(where: {
                    $0.name == ctx.name || $0.command == ctx.name
                })
                let isTUI = TerminalAIBridge.shared.isTUICommand(toolCmd)
                if isTUI {
                    return [
                        "Launch \(toolCmd)",
                        "What does \(toolCmd) do?",
                        "Show \(toolCmd) help",
                        "How do I use \(toolCmd)?",
                    ]
                }
                // Use first few subcommands as prompt starters
                if let subs = pkg?.subcommands, !subs.isEmpty {
                    let subPrompts = subs.prefix(3).map { "Run: \(toolCmd) \($0)" }
                    return Array(subPrompts) + ["What does \(toolCmd) do?"]
                }
                return [
                    "What can \(toolCmd) do?",
                    "Show \(toolCmd) --help",
                    "Run \(toolCmd) with common options",
                    "What version is \(toolCmd)?",
                ]
            case .folder:
                let name = ctx.name
                return [
                    "List all PDFs in \(name)",
                    "Show the largest files here",
                    "Find files modified today",
                    "How much space is \(name) using?",
                ]
            case .file, .document:
                let ext = (ctx.filePath ?? "").components(separatedBy: ".").last?.lowercased() ?? ""
                switch ext {
                case "pdf":
                    return ["Extract text from this PDF", "How many pages does this have?", "Compress this PDF"]
                case "mp4", "mov", "mkv", "avi":
                    return ["Show video info", "Extract audio as MP3", "Compress to smaller size"]
                case "mp3", "flac", "wav", "m4a":
                    return ["Show audio metadata", "Convert to MP3", "Get duration and bitrate"]
                case "jpg", "jpeg", "png", "heic", "webp":
                    return ["Show image dimensions and size", "Convert to JPEG", "Strip EXIF metadata"]
                case "zip", "tar", "gz":
                    return ["List contents", "Extract here", "Show total compressed size"]
                case "json":
                    return ["Pretty-print this file", "Show top-level keys", "Validate JSON"]
                case "csv":
                    return ["Show first 10 rows", "Count rows", "Show column names"]
                default:
                    return ["Show file info", "Open in default app", "Copy path to clipboard"]
                }
            case .contact:
                return [
                    "Send \(ctx.name) an email",
                    "Copy \(ctx.name)'s email address",
                    "Show all contact details",
                ]
            case .application:
                let name = ctx.name
                return [
                    "Is \(name) running?",
                    "Show \(name) memory usage",
                    "What version is \(name)?",
                ]
            default:
                return ["Tell me about this", "Show related info", "What can you do here?"]
            }
        }
        switch key {
        case "reminders":
            return [
                "Show today's tasks",
                "Add: buy groceries — due tomorrow",
                "List all overdue reminders",
                "Mark my next task as done",
            ]
        case "calendar":
            return ["What's on my calendar today?", "Add meeting tomorrow at 3pm", "Show this week's events"]
        case "notes":
            return ["Search my notes for 'project'", "Create a new note called 'Ideas'", "List recent notes"]
        case "mail":
            return ["How many unread emails?", "Show emails from today", "Search for 'invoice'"]
        case "photos":
            return ["Show photos from this week", "Find screenshots", "How many photos do I have?"]
        case "amphetamine":
            return [
                "Keep awake for 1 hour",
                "Keep awake for 30 minutes",
                "Is a session active?",
                "End the current session",
                "Keep awake until I say stop",
            ]
        case "homebrew":
            return [
                "What packages are outdated?",
                "Update and upgrade everything",
                "Install a package",
                "Clean up old versions and free disk space",
                "List all installed packages",
                "Show running services",
            ]
        default:
            let label = settings.customAppEntries.first(where: { $0.key == key })?.label ?? key.capitalized
            return ["What can you do in \(label)?", "Show status", "Run a quick action"]
        }
    }

    // Small chat bubble for the rem assistant column
    @ViewBuilder
    private func remChatBubble(_ msg: AIChatMessage) -> some View {
        switch msg.role {
        case .tool:
            // Terminal command chip — shown inline while command runs
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green.opacity(0.8))
                Text(msg.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.9))
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5)
            )
            .frame(maxWidth: .infinity, alignment: .leading)

        case .approval:
            // Inline approval card — like Claude Code's "run this command?" prompt
            let parts = (msg.structuredData ?? "").components(separatedBy: "|||/")
            let purpose = parts.first ?? ""
            let risk = parts.count > 1 ? parts[1] : "Unknown"
            let isHighRisk = risk.lowercased().contains("high") || risk.lowercased().contains("critical")
            let isPending = terminalBridge.pendingApproval != nil

            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHighRisk ? Color.orange : Color.accentColor)
                    Text("Run command?")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if isHighRisk {
                        Text(risk)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                // Purpose
                if !purpose.isEmpty {
                    Text(purpose)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // Command
                Text(msg.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Buttons
                HStack(spacing: 8) {
                    Button("Deny") {
                        TerminalAIBridge.shared.denyCommand()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(!isPending)

                    Button {
                        TerminalAIBridge.shared.approveCommand(msg.content)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 9))
                            Text("Approve & Run")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(isHighRisk ? Color.orange : Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                    .disabled(!isPending)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHighRisk ? Color.orange.opacity(0.35) : Color.accentColor.opacity(0.25), lineWidth: 0.75)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isPending ? 1 : 0.5)

        case .user:
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 24)
                Text(msg.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: 180, alignment: .trailing)
            }
        case .assistant:
            let brewTools = extractBrewInstalls(from: msg.content)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 0) {
                    Text(msg.content)
                        .font(.system(size: 12))
                        .foregroundStyle(msg.isError ? .red : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            msg.isError ? AnyShapeStyle(Color.red.opacity(0.1)) : AnyShapeStyle(Color.primary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .frame(maxWidth: 180, alignment: .leading)
                    Spacer(minLength: 24)
                }
                // Inline install buttons — appear whenever AI says "brew install X"
                if !brewTools.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(brewTools, id: \.self) { tool in
                            BrewInstallButton(toolName: tool) {
                                // Auto-retry the last user query now that the tool is installed
                                if let lastQuery = remPanelChatMessages.last(where: { $0.role == .user })?.content {
                                    searchText = lastQuery
                                    handleRemPanelQuery()
                                }
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }

    /// Extracts all tool names from "brew install <tool>" patterns in a string.
    private func extractBrewInstalls(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"brew install ([a-zA-Z0-9][a-zA-Z0-9_\-\.]*)"#,
            options: .caseInsensitive)
        else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> String? in
                guard match.numberOfRanges > 1 else { return nil }
                let r = match.range(at: 1)
                return r.location != NSNotFound ? ns.substring(with: r) : nil
            }
    }

    @ViewBuilder
    private func remHintRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "return")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text("\"\(text)\"")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    /// Directly triggers the data load for a given app panel key.
    // MARK: - Selected Result Preview

    /// Returns the action label shown next to a selected result (like Spotlight's "— Open")
    private func selectedResultAction(_ result: SearchResult) -> String {
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
        case .cliTool: return "Open Panel"
        }
    }

    // MARK: - Spotlight-style App Context (Tab/→ on app result)

    /// Activates context panel for ANY result type (Spotlight-style Tab/→).
    /// Always opens the 2-column AI panel — chat + quick actions.
    private func activateSearchContext(for result: SearchResult) {
        let appPath = result.type == .application ? result.subtitle : ""

        // CLI/TUI tool panels: use the command name as the panel key directly
        if result.type == .cliTool {
            let toolCmd = result.title   // binary name (e.g. "pomodoro", "btop")
            let panelKey = "cli_\(toolCmd)"
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                searchContextApp = SearchContextApp(
                    name: toolCmd,
                    icon: result.icon,
                    key: panelKey,
                    appPath: result.filePath ?? "",
                    resultType: .cliTool,
                    filePath: result.filePath,
                    subtitle: result.subtitle,
                    contactEmail: nil,
                    contactPhone: nil
                )
                searchText = ""
                searchResults = []
                selectedResultIndex = nil
                isSearchBarExpanded = true
                remPanelChatMessages = AppPanelChatStore.shared.load(for: panelKey)
                activeSmartQueryKey = panelKey
                isInSmartMode = true
                appPanelAllItems = []

                // TUI panels: always show the embedded terminal on the right.
                // Pre-initialise panelTerminalHost NOW (before any command is sent)
                // so TerminalAIBridge.terminalController is wired up and ready.
                if panelTerminalHost == nil {
                    panelTerminalHost = TerminalHostController()
                }
                showLivePanel(.terminal)
            }
            isSearchFieldFocused = true
            return
        }

        // Find matching customAppEntries key for apps (gives AI access to assigned CLI tools)
        let customEntry = result.type == .application ? settings.customAppEntries.first(where: {
            $0.label.lowercased() == result.title.lowercased() ||
            $0.appPath == appPath ||
            $0.key == result.title.lowercased().replacingOccurrences(of: " ", with: "_")
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
            if let appPath = result.filePath ?? (result.subtitle.hasSuffix(".app") ? result.subtitle : nil),
               let bundle = Bundle(path: appPath), let bid = bundle.bundleIdentifier {
                return AppSettings.shared.appKey(forBundleID: bid, appName: result.title)
            }
            return nil
        }()
        let contextKey = customEntry?.key ?? builtInKey

        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            searchContextApp = SearchContextApp(
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
            searchText = ""
            searchResults = []
            selectedResultIndex = nil
            isSearchBarExpanded = true
            // Load persisted chat for this panel (panelKey computed just below)
            let panelKeyForLoad = contextKey ?? result.title.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
                .joined()
            remPanelChatMessages = AppPanelChatStore.shared.load(for: panelKeyForLoad)

            // Set activeSmartQueryKey — used by handleRemPanelQuery and panel header
            let panelKey = contextKey ?? result.title.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
                .joined()
            activeSmartQueryKey = panelKey
            isInSmartMode = true
            appPanelAllItems = []
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

    /// Clears the app context and returns to normal search.
    private func clearSearchContext() {
        if let key = activeSmartQueryKey {
            AppPanelChatStore.shared.save(remPanelChatMessages, for: key)
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            searchContextApp = nil
            activeSmartQueryKey = nil
            isInSmartMode = false
            appPanelAllItems = []
            remPanelChatMessages = []
            clearPinnedResults()
            searchResults = []
            selectedResultIndex = nil
            livePanelVisible = false
        }
    }

    private func reloadAppPanelData(for key: String) {
        switch key {
        case "reminders":
            loadSystemDataAsPinnedResults(query: "", types: [.reminder], title: "Reminders",
                                          perTypeLimit: 500, allowEmptyQuery: true, excludeTypes: [.reminder])
        case "calendar":
            loadSystemDataAsPinnedResults(query: "", types: [.calendarEvent], title: "Calendar",
                                          perTypeLimit: 500, allowEmptyQuery: true, excludeTypes: [.calendarEvent])
        case "notes":
            loadSystemDataAsPinnedResults(query: "", types: [.note], title: "Notes",
                                          perTypeLimit: 500, allowEmptyQuery: true, excludeTypes: [.note])
        case "mail":
            loadSystemDataAsPinnedResults(query: "", types: [.mail], title: "Mail",
                                          perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.mail])
        case "photos":
            loadSystemDataAsPinnedResults(query: "", types: [.photo], title: "Photos",
                                          perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.photo])
        case "messages":
            loadSystemDataAsPinnedResults(query: "", types: [.message], title: "Messages",
                                          perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.message])
        case "contacts":
            loadAllContactsAsResults()
        case "safari":
            Task { await loadSafariTabs() }
        default: break
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        // Show folder preview inline if active
        if showFolderPreview, let folderPath = folderPreviewPath {
            FolderPreviewView(folderPath: folderPath, isPresented: $showFolderPreview, selectedFilePath: $folderPreviewSelectedFile)
                .frame(minHeight: 400, maxHeight: 600)
                .transition(.opacity.combined(with: .move(edge: settings.effectiveDockAtBottom ? .bottom : .top)))
        }
        // L3: Show web search prompt (homepage or search results)
        else if showBrowserLayer {
            webSearchPromptView
        }
        // App panel: full-screen split view — hides normal search results entirely
        else if activeSmartQueryKey != nil {
            appPanelView
        } else if !searchResults.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // In dock mode, reverse order so first result is at bottom (closest to dock)
                        let sectionsToRender = settings.effectiveDockAtBottom ?
                            Array(groupedResults.sections.reversed()) :
                            groupedResults.sections

                        // Render grouped sections with headers
                        ForEach(Array(sectionsToRender.enumerated()), id: \.offset) { sectionIndex, section in
                            let (sectionName, sectionResults) = section

                            // In dock mode, also reverse items within each section
                            let itemsToRender = settings.effectiveDockAtBottom ?
                                Array(sectionResults.reversed()) :
                                sectionResults

                            // Section header
                            if groupedResults.sections.count > 1 {
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

                            // Section items
                            ForEach(Array(itemsToRender.enumerated()), id: \.element.id) { itemIndex, result in
                                let globalIndex = getGlobalIndex(for: result)

                                resultRowView(for: result, at: globalIndex)
                                    .id(result.id) // Add ID for scroll targeting

                                // Divider between items (but not after last item in section)
                                if itemIndex < itemsToRender.count - 1 {
                                    Divider()
                                        .padding(.leading, 60)
                                }
                            }

                            // Add space between sections (but not after last section)
                            if sectionIndex < sectionsToRender.count - 1 {
                                Divider()
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding(.top, settings.effectiveDockAtBottom ? 0 : 8)
                    .padding(.bottom, settings.effectiveDockAtBottom ? 4 : 8)
                }
                .frame(maxHeight: 400)
                .onChange(of: searchResultsRevision) { _, _ in
                    // When docked at bottom, keep the best match in view even if selection didn't change.
                    guard settings.effectiveDockAtBottom else { return }
                    guard let index = selectedResultIndex,
                          index >= 0,
                          index < searchResults.count else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(searchResults[index].id, anchor: .bottom)
                    }
                }
                .onChange(of: selectedResultIndex) { _, newIndex in
                    // Auto-scroll to selected result ONLY when navigating with arrow keys
                    if (isKeyboardNavigation || shouldAutoScrollToSelection),
                       let index = newIndex,
                       index >= 0 && index < searchResults.count {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let anchor: UnitPoint = settings.effectiveDockAtBottom ? .bottom : .center
                            proxy.scrollTo(searchResults[index].id, anchor: anchor)
                        }
                    }
                    if shouldAutoScrollToSelection { shouldAutoScrollToSelection = false }
                    // Update context extensions for the newly selected result
                    // so context-based dock pills reflect file type / app context immediately
                    updateL2ContextExtensions()
                }
            }
        } else if isLoadingApps {
            loadingView
        }
    }

    // MARK: - Web Search Prompt View (L3)
    @ViewBuilder
    private var webSearchPromptView: some View {
        if showInlineBrowser {
            // Show inline browser with search results in dock
            VStack(spacing: 0) {
                // Browser header with back button
                HStack {
                    Button(action: {
                        showInlineBrowser = false
                        inlineBrowserQuery = ""
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("Web Search: \(inlineBrowserQuery)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isInlineBrowserLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)

                Divider()

                // Compact mini web preview panel
                WebView(
                    url: getSearchURL(for: inlineBrowserQuery),
                    userScripts: settings.webExtensions.filter { $0.enabled }.map { $0.script },
                    isLoading: $isInlineBrowserLoading
                )
                .frame(height: 320) // Fixed height for web preview

                // Open in full browser button at bottom
                Divider()

                Button(action: {
                    // Open in separate browser window
                    if let url = URL(string: inlineBrowserQuery.hasPrefix("http") ? inlineBrowserQuery : "https://\(inlineBrowserQuery)") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12))
                        Text("Open in Browser")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial)
            }
        } else if !searchText.isEmpty {
            // Show filtered recent searches and bookmarks in result panel
            VStack(spacing: 0) {
                // Filter recent searches that match current input
                let matchingSearches = settings.recentWebSearches.filter { search in
                    search.lowercased().contains(searchText.lowercased())
                }

                // Filter bookmarks that match current input
                let matchingBookmarks = settings.importedBookmarks.filter { bookmark in
                    bookmark.title.lowercased().contains(searchText.lowercased()) ||
                    bookmark.url.lowercased().contains(searchText.lowercased())
                }

                ScrollView {
                    VStack(spacing: 0) {
                        // Show matching recent searches
                        if !matchingSearches.isEmpty {
                            // Section header
                            HStack {
                                Text("Recent Searches")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.5)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                            // Recent search results
                            ForEach(Array(matchingSearches.prefix(3).enumerated()), id: \.element) { index, search in
                                Button(action: {
                                    searchText = search
                                    openInDockBrowser()
                                }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.gray)
                                            .font(.system(size: 16))
                                            .frame(width: 40)

                                        Text(search)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Spacer()

                                        Image(systemName: "arrow.up.left")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())

                                if index < matchingSearches.prefix(3).count - 1 {
                                    Divider()
                                        .padding(.leading, 60)
                                }
                            }
                        }

                        // Show matching bookmarks
                        if !matchingBookmarks.isEmpty {
                            // Section header
                            HStack {
                                Text("Bookmarks")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.5)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, matchingSearches.isEmpty ? 12 : 16)
                            .padding(.bottom, 4)

                            // Bookmark results
                            ForEach(Array(matchingBookmarks.prefix(3).enumerated()), id: \.element.id) { index, bookmark in
                                Button(action: {
                                    searchText = bookmark.url
                                    openInDockBrowser()
                                }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.yellow)
                                            .font(.system(size: 16))
                                            .frame(width: 40)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(bookmark.title)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(bookmark.url)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())

                                if index < matchingBookmarks.prefix(3).count - 1 {
                                    Divider()
                                        .padding(.leading, 60)
                                }
                            }
                        }

                        // Always show "Search web for" option at bottom
                        Divider()
                            .padding(.vertical, 8)

                        // Web search button
                        Button(action: {
                            openInDockBrowser()
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "globe")
                                    .foregroundStyle(.blue)
                                    .font(.system(size: 16))
                                    .frame(width: 40)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Search web for \"\(searchText)\"")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("Press ⏎ to open in browser")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            // Small browser icon in corner
                            Image(systemName: "safari")
                                .font(.system(size: 14))
                                .foregroundStyle(.blue.opacity(0.7))
                                .padding(6)
                                .background(Circle().fill(.blue.opacity(0.1)))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.05))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    Spacer() // Push content to top, fill remaining space
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 350) // Scrollable content area
            }
            .frame(minHeight: 200, maxHeight: 350) // Ensure consistent panel size
        } else {
            // Show homepage with bookmarks and recent searches when search field is empty
            browserHomepageView
        }
    }

    @ViewBuilder
    private var browserHomepageView: some View {
        // Don't show anything when search is empty (like L1)
        EmptyView()
    }

    // MARK: - L3 Browser Layer Full Screen View
    @ViewBuilder
    private var browserLayerFullScreenView: some View {
        VStack(spacing: 0) {
            // Main content area - shows browser or suggestions
            if showInlineBrowser {
                // Inline browser view
                VStack(spacing: 0) {
                    // Browser header
                    HStack {
                        Button(action: {
                            showInlineBrowser = false
                            inlineBrowserQuery = ""
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Back")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 16)

                        Spacer()

                        Text("Web Search: \(inlineBrowserQuery)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if isInlineBrowserLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.trailing, 16)
                        } else {
                            Spacer()
                                .frame(width: 60)
                        }
                    }
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)

                    Divider()

                    // WebView
                    WebView(
                        url: getSearchURL(for: inlineBrowserQuery),
                        userScripts: settings.webExtensions.filter { $0.enabled }.map { $0.script },
                        isLoading: $isInlineBrowserLoading
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !searchText.isEmpty {
                // Search suggestions
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Image(systemName: "globe")
                            .font(.system(size: 40))
                            .foregroundStyle(.blue)

                        Spacer()
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 60)

                    Text("Search the web for \"\(searchText)\"")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.top, 20)

                    Text("Press Enter to open in browser")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)

                    // Recent searches matching query
                    let matchingSearches = settings.recentWebSearches.filter { search in
                        search.lowercased().contains(searchText.lowercased())
                    }

                    if !matchingSearches.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent Searches")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.top, 40)
                                .padding(.leading, 40)

                            VStack(spacing: 0) {
                                ForEach(matchingSearches.prefix(5), id: \.self) { search in
                                    Button(action: {
                                        searchText = search
                                        openInDockBrowser()
                                    }) {
                                        HStack(spacing: 16) {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.system(size: 16))
                                                .foregroundStyle(.gray)
                                                .frame(width: 24)
                                            Text(search)
                                                .font(.system(size: 15))
                                                .foregroundStyle(.primary)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 40)
                                        .padding(.vertical, 14)
                                        .background(Color.primary.opacity(0.0))
                                    }
                                    .buttonStyle(.plain)

                                    if search != matchingSearches.prefix(5).last {
                                        Divider()
                                            .padding(.leading, 80)
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                            .padding(.horizontal, 40)
                        }
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Homepage with bookmarks and recent searches
                ScrollView {
                    VStack(spacing: 32) {
                        // Bookmarks
                        if !settings.importedBookmarks.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Image(systemName: "bookmark.fill")
                                        .foregroundStyle(.blue)
                                        .font(.system(size: 18))
                                    Text("Bookmarks")
                                        .font(.system(size: 20, weight: .semibold))
                                    Spacer()
                                    Text("\(settings.importedBookmarks.count)")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 40)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(settings.importedBookmarks.prefix(20)) { bookmark in
                                            BookmarkCard(bookmark: bookmark) {
                                                openBookmark(bookmark)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 40)
                                }
                            }
                        }

                        // Recent Searches
                        if !settings.recentWebSearches.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Image(systemName: "clock")
                                        .foregroundStyle(.purple)
                                        .font(.system(size: 18))
                                    Text("Recent Searches")
                                        .font(.system(size: 20, weight: .semibold))
                                    Spacer()
                                }
                                .padding(.horizontal, 40)

                                VStack(spacing: 0) {
                                    ForEach(settings.recentWebSearches.prefix(10), id: \.self) { search in
                                        Button(action: {
                                            searchText = search
                                            openInDockBrowser()
                                        }) {
                                            HStack(spacing: 16) {
                                                Image(systemName: "magnifyingglass")
                                                    .font(.system(size: 16))
                                                    .foregroundStyle(.gray)
                                                    .frame(width: 24)
                                                Text(search)
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(.primary)
                                                Spacer()
                                                Image(systemName: "arrow.up.left")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(.horizontal, 40)
                                            .padding(.vertical, 14)
                                        }
                                        .buttonStyle(.plain)

                                        if search != settings.recentWebSearches.prefix(10).last {
                                            Divider()
                                                .padding(.leading, 80)
                                        }
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                                .padding(.horizontal, 40)
                            }
                        }
                    }
                    .padding(.top, 60)
                    .padding(.bottom, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Search bar at bottom
            HStack(spacing: 12) {
                // Globe icon
                Image(systemName: "globe")
                    .font(.system(size: 20))
                    .foregroundStyle(.blue)
                    .frame(width: 28)

                // Search field
                TextField("", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isSearchFieldFocused)

                // Clear button
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // User profile icon
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            .padding(.horizontal, 120)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.3))
    }

    @ViewBuilder
    private var browserContentView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Imported Bookmarks Section
                if !settings.importedBookmarks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.blue)
                            Text("Bookmarks")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text("\(settings.importedBookmarks.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(settings.importedBookmarks.prefix(20)) { bookmark in
                                    BookmarkCard(bookmark: bookmark) {
                                        openBookmark(bookmark)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .frame(height: 120)
                    }
                }

                // Recent Web Searches Section
                if !settings.recentWebSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.gray)
                            Text("Recent Searches")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        VStack(spacing: 0) {
                            ForEach(Array(settings.recentWebSearches.prefix(8).enumerated()), id: \.element) { index, search in
                                Button(action: {
                                    performWebSearch(search)
                                }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundStyle(.gray)
                                            .font(.system(size: 14))
                                            .frame(width: 40)

                                        Text(search)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Spacer()

                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())

                                if index < min(7, settings.recentWebSearches.count - 1) {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }
                    }
                }

                // Empty state
                if settings.importedBookmarks.isEmpty && settings.recentWebSearches.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "globe")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue.opacity(0.6))
                            .padding(.top, 40)

                        Text("Browser Layer")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)

                        Text("Import bookmarks in Settings or start searching the web")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 400)
    }

    private func openBookmark(_ bookmark: BrowserItem) {
        guard let url = URL(string: bookmark.url) else { return }
        NSWorkspace.shared.open(url)

        // Clear search text (which will auto-collapse the dock)
        searchText = ""
    }

    private func performWebSearch(_ query: String) {
        searchText = query
        performBrowserSearch()
    }

    // Helper to find global index for a result (for selection tracking)
    private func getGlobalIndex(for result: SearchResult) -> Int {
        searchResults.firstIndex(where: { $0.id == result.id }) ?? 0
    }
    
    private func resultRowView(for result: SearchResult, at index: Int) -> some View {
        ResultRow(
            result: result,
            isSelected: selectedResultIndex == index
        )
        .contentShape(Rectangle())
        .onTapGesture {
            executeResult(result)
        }
        .onHover { hovering in
            if hovering {
                if isSearchFieldFocused {
                    return
                }
                if isKeyboardNavigation {
                    // Switch back to mouse mode but don't steal selection immediately
                    isKeyboardNavigation = false
                    return
                }
                selectedResultIndex = index
            }
        }
        .contextMenu {
            resultContextMenu(for: result)
        }
    }
    
    @ViewBuilder
    private func resultContextMenu(for result: SearchResult) -> some View {
        Group {
            if result.type == .contact {
                Button("Open in Contacts") {
                    result.action()
                }

                Button("Copy Email") {
                    let email = result.subtitle
                    guard !email.isEmpty else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(email, forType: .string)
                }

                Button("Send Email") {
                    let email = result.subtitle
                    guard !email.isEmpty, let url = URL(string: "mailto:\(email)") else { return }
                    NSWorkspace.shared.open(url)
                }

                Button("Send Message") {
                    let email = result.subtitle
                    guard !email.isEmpty, let url = URL(string: "imessage:\(email)") else { return }
                    NSWorkspace.shared.open(url)
                }
            }
            else if result.type == .application {
                if settings.isPinned(path: result.subtitle) {
                    Button("Unpin from Launcher") {
                        if let pinnedApp = settings.pinnedApps.first(where: { $0.path == result.subtitle }) {
                            settings.unpinApp(pinnedApp)
                        }
                    }
                } else {
                    Button("Pin to Launcher") {
                        settings.pinApp(name: result.title, path: result.subtitle)
                    }
                }
            }
            else if result.type == .shortcut {
                // Pin/Unpin shortcut
                let shortcutPath = result.subtitle.isEmpty ? result.title : result.subtitle
                if settings.pinnedApps.contains(where: { $0.path == shortcutPath }) {
                    Button("Unpin from Launcher") {
                        if let pinnedItem = settings.pinnedApps.first(where: { $0.path == shortcutPath }) {
                            settings.unpinApp(pinnedItem)
                        }
                    }
                } else {
                    Button("Pin to Launcher") {
                        settings.pinItem(name: result.title, path: shortcutPath, type: .shortcut)
                    }
                }
            }
            else if let filePath = result.filePath, (result.type == .file || result.type == .folder || result.type == .document) {
                // Pin/Unpin option
                if settings.pinnedApps.contains(where: { $0.path == filePath }) {
                    Button("Unpin from Launcher") {
                        if let pinnedItem = settings.pinnedApps.first(where: { $0.path == filePath }) {
                            settings.unpinApp(pinnedItem)
                        }
                    }
                } else {
                    Button("Pin to Launcher") {
                        // Determine the type
                        let itemType: PinnedApp.PinnedItemType = result.type == .folder ? .folder : .file
                        settings.pinItem(name: result.title, path: filePath, type: itemType)
                    }
                }

                Divider()

                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
                }

                Button("Get Info") {
                    if let url = URL(string: "file://\(filePath)") {
                        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: NSWorkspace.OpenConfiguration())
                    }
                }

                Divider()

                Button("Copy Path") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(filePath, forType: .string)
                }
            }
        }
    }
    
    private var loadingView: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading applications and shortcuts...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding()
    }
    
    private var backgroundView: some View {
        Group {
            // Dark glassy blur is handled by NSVisualEffectView at window level
            // SwiftUI background should be clear to let the blur show through
            Color.clear
        }
    }

    // Determine if background should be shown
    private var shouldShowBackground: Bool {
        // Results and chat now show inside expanding dock, so no separate background needed
        return false
    }
    
    private func activateSearchField() {
        // Clear any existing text and results first
        searchText = ""
        searchResults = []
        selectedResultIndex = nil

        // Detect context when launcher opens (check clipboard, frontmost app)
        detectAndUpdateContext()

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

    private func loadUserProfilePicture() {
        // Get the user's profile picture from Contacts
        Task { @MainActor in
            // Try to get user icon from system
            let userPictureURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/com.apple.iconservices.store/")
                .appendingPathComponent("user.icns")

            if let image = NSImage(contentsOf: userPictureURL) {
                userProfileImage = image
                return
            }

            // Fallback: Use default person icon if we can't find user picture
            userProfileImage = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
        }
    }

    // MARK: - Swipe Gesture Monitor Functions

    private func setupSwipeGestureMonitor() {
        removeSwipeGestureMonitor()

        swipeGestureMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let deltaX = abs(event.scrollingDeltaX)
            let deltaY = abs(event.scrollingDeltaY)

            // Track both vertical and horizontal movement during the gesture
            if event.phase == .began {
                self.accumulatedSwipeDeltaY = 0
                self.accumulatedSwipeDeltaX = 0
            }

            if event.phase == .changed || event.phase == .began {
                // Accumulate both deltas
                self.accumulatedSwipeDeltaY += event.scrollingDeltaY
                self.accumulatedSwipeDeltaX += event.scrollingDeltaX
            }

            // When gesture ends, check if we have significant movement
            if event.phase == .ended {
                let totalVertical = abs(self.accumulatedSwipeDeltaY)
                let totalHorizontal = abs(self.accumulatedSwipeDeltaX)

                // Check for HORIZONTAL swipe (AI mode toggle) - ONLY when hovering over input field
                // BLOCKED on dock area (all three layers) - only vertical swipes allowed there
                // Horizontal swipe → toggle chat layer (right = open, left = close)
                // ONLY on input field — dock area is for pill scrolling, never for chat toggle
                if totalHorizontal > 40 && totalHorizontal > totalVertical * 1.8 && self.isHoveringInputField && !self.isHoveringDockArea {
                    if self.accumulatedSwipeDeltaX < 0 {
                        // Swipe RIGHT — open chat
                        if !self.isAIMode { self.toggleAIModeViaSwipe() }
                    } else {
                        // Swipe LEFT — close chat
                        if self.isAIMode { self.toggleAIModeViaSwipe() }
                    }
                    print("↔️ Horizontal swipe: \(self.accumulatedSwipeDeltaX < 0 ? "open" : "close") chat")
                }
                // Vertical swipe — L1↔L2↔L3 layer cycling
                // Disabled in l2OnlyMode (context dock is the only layer)
                else if totalVertical > 30 && totalVertical > totalHorizontal * 0.8
                        && !self.isAIMode
                        && !self.settings.l2OnlyMode
                        && (self.isHoveringDockArea || self.isHoveringInputField) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        // Swipe UP (negative deltaY) = show next layer
                        if self.accumulatedSwipeDeltaY < 0 {
                            if !self.showContextInDock {
                                // Layer 1 -> Layer 2 (only if Layer 2 is enabled)
                                if self.settings.enableLayer2 {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        self.showContextInDock = true
                                    }
                                    print("🔼 Swipe up: L1→L2")
                                    if self.searchText.isEmpty && !self.isSearchFieldFocused {
                                        self.startCollapseTimer()
                                    }
                                } else if !self.settings.enableLayer2 && self.settings.enableLayer3 {
                                    // Layer 2 disabled — skip straight to Layer 3
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        self.showBrowserLayer = true
                                    }
                                    print("🔼 Swipe up: L1→L3 (L2 disabled)")
                                    if self.searchText.isEmpty && !self.isSearchFieldFocused {
                                        self.startCollapseTimer()
                                    }
                                }
                            } else if !self.showBrowserLayer {
                                // Layer 2 -> Layer 3 (only if Layer 3 is enabled)
                                if self.settings.enableLayer3 {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        self.showBrowserLayer = true
                                    }
                                    print("🔼 Swipe up: L2→L3 (accumulated: \(self.accumulatedSwipeDeltaY))")
                                    if self.searchText.isEmpty && !self.isSearchFieldFocused {
                                        self.startCollapseTimer()
                                    }
                                }
                            }
                        }
                        // Swipe DOWN (positive deltaY) = show previous layer
                        else {
                            if self.showBrowserLayer {
                                // Layer 3 -> Layer 2 (or skip to L1 if L2 disabled)
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    self.showBrowserLayer = false
                                    if !self.settings.enableLayer2 {
                                        self.showContextInDock = false
                                    }
                                }
                                let dest = self.settings.enableLayer2 ? "L2" : "L1"
                                print("🔽 Swipe down: L3→\(dest) (accumulated: \(self.accumulatedSwipeDeltaY))")

                                // Start collapse timer if no input
                                if self.searchText.isEmpty && !self.isSearchFieldFocused {
                                    self.startCollapseTimer()
                                }
                            } else if self.showContextInDock {
                                // Layer 2 -> Layer 1
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    self.showContextInDock = false
                                }
                                print("🔽 Swipe down: L2→L1 (accumulated: \(self.accumulatedSwipeDeltaY))")

                                // Start collapse timer if no input
                                if self.searchText.isEmpty && !self.isSearchFieldFocused {
                                    self.startCollapseTimer()
                                }
                            }
                        }
                    }
                }
            }

            return event
        }
    }

    private func removeSwipeGestureMonitor() {
        if let monitor = swipeGestureMonitor {
            NSEvent.removeMonitor(monitor)
            swipeGestureMonitor = nil
        }
    }

    private func toggleAIModeViaSwipe() {
        // Only allow toggling if enabled in settings
        guard settings.enableAIMode else {
            return
        }

        // Clear results when switching modes (outside animation to prevent jumping)
        searchResults = []
        selectedResultIndex = nil
        searchText = ""
        currentAITask?.cancel()
        isAILoading = false
        hasUserSentMessageInCurrentSession = false

        if !isAIMode {
            // Opening chat — remember current layer so we can return to it
            chatReturnContextInDock = showContextInDock
            chatReturnBrowserLayer = showBrowserLayer
        }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            isAIMode.toggle()
            if isAIMode {
                // Chat is standalone — clear L2/L3
                showContextInDock = false
                showBrowserLayer = false
            } else {
                // Restore the layer we came from
                showContextInDock = chatReturnContextInDock
                showBrowserLayer = chatReturnBrowserLayer
            }
        }

        if isAIMode {
            print("🔍 [Swipe] Entering AI mode from L\(chatReturnBrowserLayer ? "3" : chatReturnContextInDock ? "2" : "1")")
            loadAIExtensionSuggestions()
            collapseTimer?.cancel()
        } else {
            if searchText.isEmpty { startCollapseTimer() }
        }
    }

    // MARK: - Search Bar Collapse/Expand Functions

    private func expandSearchBar() {
        // Blocked during layer transitions to prevent phantom expand on icon change
        guard !suppressHoverExpand else { return }

        collapseTimer?.cancel()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            isSearchBarExpanded = true
        }
        updateWindowSize()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isSearchFieldFocused = true
        }

        startCollapseTimer()
    }

    private func startCollapseTimer() {
        // Auto-collapse disabled — bar only collapses when user clicks the search icon
        collapseTimer?.cancel()
    }

    private func resetCollapseTimer() {
        // Cancel existing timer
        collapseTimer?.cancel()

        // Collapse timer is an L1 concept — skip entirely in L2 and AI mode
        if isAIMode || isL2ContextActive {
            return
        }

        if !searchText.isEmpty {
            // Keep expanded while there's text
            return
        }

        // Restart timer if search is empty
        startCollapseTimer()
    }

    private func updateL2ContextExtensions() {
        guard settings.enableContextAIExtensions else {
            l2ContextExtensions = []
            return
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Frontmost app — from context or stored name
        let frontmostName: String? = {
            switch currentContext {
            case .appFocused(let name, _): return name
            default: return frontmostAppName.isEmpty ? nil : frontmostAppName
            }
        }()

        // Selected files — from context + Finder
        var contextFiles: [URL] = {
            switch currentContext {
            case .filesSelected(let urls): return urls
            default: return []
            }
        }()
        // Also pull live Finder selection
        let finderFiles = ContextDetector.shared.getFinderSelectedFiles()
        if !finderFiles.isEmpty { contextFiles = finderFiles }

        // Selected text
        let selectedText: String? = {
            switch currentContext {
            case .textSelected(let t): return t.isEmpty ? nil : t
            default: return nil
            }
        }()

        // Show extensions whenever there's any meaningful context
        let hasAnyContext = frontmostName != nil
            || !contextFiles.isEmpty
            || selectedText != nil

        if !hasAnyContext {
            l2ContextExtensions = []
            return
        }

        // Discover with full context
        let results = LayeredExtensionManager.shared.discoverExtensions(
            for: query,
            selectedFiles: contextFiles,
            selectedText: selectedText,
            frontmostApp: frontmostName,
            layer: .l2_context
        )

        l2ContextExtensions = Array(results.prefix(6))
    }

    private func updateContextSuggestions() {
        updateL2ContextExtensions()
    }

    // MARK: - App Switch Observer

    @State private var appSwitchObserver: NSObjectProtocol?

    private func startObservingAppSwitches() {
        // Observe when other apps become active (user switches windows)
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Only update if frontmost detection is enabled
            guard settings.enableFrontmostDetection else { return }

            // Get the activated app
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let bundleID = app.bundleIdentifier ?? ""
                let appName = app.localizedName ?? "Unknown"

                // Skip if it's ILauncher itself or ChatGPT desktop app
                if bundleID == Bundle.main.bundleIdentifier ||
                   bundleID == "com.openai.chat" {
                    return
                }

                // Update frontmost app info
                frontmostAppName = appName
                frontmostAppBundleID = bundleID
                frontmostAppIcon = app.icon

                // Auto-map to an appKey so the AI knows context without manual panel selection
                settings.autoDetectedAppKey = settings.appKey(forBundleID: bundleID, appName: appName)

                print("🔄 App switched to: \(appName) (\(bundleID)) → key: \(settings.autoDetectedAppKey ?? "none")")

                // Re-detect context (selected text/files/browser tab/clipboard) and then refresh suggestions.
                // This ensures suggestions update based on actual user selection, not just the app name.
                detectAndUpdateContext()

                if showContextInDock {
                    updateL2Results([])
                }
            }
        }
    }

    private func stopObservingAppSwitches() {
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    // MARK: - Context Detection & Metadata

    private func loadShortcutMetadata() {
        // Load shortcuts metadata from JSON file
        guard let metadataURL = Bundle.main.url(forResource: "shortcuts-metadata", withExtension: "json", subdirectory: ".claude") else {
            print("⚠️ Shortcuts metadata file not found")
            return
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            let metadata = try decoder.decode([String: ShortcutMetadataJSON].self, from: data)

            // Convert to our internal format
            for (name, meta) in metadata {
                shortcutMetadataCache[name] = ShortcutMetadata(
                    acceptsFiles: meta.acceptsFiles,
                    acceptsText: meta.acceptsText,
                    acceptsImages: meta.acceptsImages,
                    acceptsContacts: meta.acceptsContacts,
                    acceptsPDFs: meta.acceptsPDFs,
                    fileExtensions: meta.fileExtensions
                )
            }

            print("✅ Loaded metadata for \(shortcutMetadataCache.count) shortcuts")
        } catch {
            print("❌ Failed to load shortcuts metadata: \(error)")
        }
    }

    private func detectAndUpdateContext() {
        // Skip context detection if context awareness is disabled
        guard settings.enableContextAIExtensions else {
            currentContext = .none
            print("⚠️ [Context Detection] Context awareness is DISABLED in settings")
            return
        }

        print("🔍 [Context Detection] Starting automatic context detection...")

        // Priority 0: File selected in folder preview (highest priority!)
        if showFolderPreview, let selectedFile = folderPreviewSelectedFile, !selectedFile.isEmpty {
            let fileURL = URL(fileURLWithPath: selectedFile)
            currentContext = .filesSelected([fileURL])
            print("📁 Context: File selected in folder preview - \(fileURL.lastPathComponent)")
            updateContextSuggestions()
            return
        }

        // Priority 1: Files selected in search results (internal selection)
        if !selectedFiles.isEmpty {
            let selectedURLs = searchResults
                .filter { selectedFiles.contains($0.id) }
                .compactMap { $0.filePath }
                .map { URL(fileURLWithPath: $0) }

            if !selectedURLs.isEmpty {
                currentContext = .filesSelected(selectedURLs)
                print("📁 Context: \(selectedURLs.count) files selected in search results")
                updateContextSuggestions()
                return
            }
        }

        // Priority 2: Automatic context detection from frontmost app
        // This detects: Finder selections, browser tabs, selected text, etc.
        if let frontmostApp = contextTargetApp() {
            let bundleID = frontmostApp.bundleIdentifier ?? ""
            let appName = frontmostApp.localizedName ?? "Unknown"

            print("🔍 [Context Detection] Frontmost app: \(appName) (\(bundleID))")

            // CRITICAL: Skip ILauncher itself - we never want to detect our own app
            if bundleID.contains("ILauncher") {
                print("⚠️ [Context Detection] Skipping ILauncher itself")
            } else {
                frontmostAppName = appName
                frontmostAppBundleID = bundleID
                frontmostAppIcon = frontmostApp.icon

                print("🔍 [Context Detection] Calling ContextDetector.detectContext()...")
                if let detected = ContextDetector.shared.detectContext(frontmostApp: frontmostApp) {
                    print("✅ [Context Detection] Detected context type: \(detected.description)")

                    switch detected {
                    case .files(let urls):
                        currentContext = .filesSelected(urls)
                        print("📁 Context: \(urls.count) file(s) selected in Finder - \(urls.map { $0.lastPathComponent }.joined(separator: ", "))")

                    case .text(let text):
                        currentContext = .textSelected(text)
                        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                        print("📝 ✅ Context: Selected text (\(words.count) words) - \"\(String(text.prefix(100)))...\"")

                    case .browserTab(let url, let title):
                        // Store browser URL context
                        currentContext = .textSelected(url) // Treat URL as text for now
                        print("🌐 Context: Browser tab - \(title)")

                    case .browserTabs(let tabs):
                        // Store first tab URL or summary
                        if let firstTab = tabs.first {
                            currentContext = .textSelected(firstTab.url)
                        }
                        print("🌐 Context: \(tabs.count) browser tabs")

                    case .clipboard(let content):
                        currentContext = .textSelected(content)
                        print("📋 Context: Clipboard content")

                    case .music(let title, let artist, _):
                        currentContext = .textSelected("\(title) by \(artist)")
                        print("🎵 Context: Playing \(title) by \(artist)")

                    case .podcast(let title, let show):
                        currentContext = .textSelected("\(title) - \(show)")
                        print("🎙️ Context: Podcast \(title)")

                    case .note(let content):
                        currentContext = .textSelected(content)
                        print("📝 Context: Note content detected")

                    case .email(let subject, _, _):
                        currentContext = .textSelected(subject)
                        print("📧 Context: Email - \(subject)")

                    case .app(_, let name):
                        currentContext = .appFocused(name: name, bundleID: bundleID)
                        print("🖥️ Context: Frontmost app = \(name)")
                    }

                    updateContextSuggestions()
                    return
                } else {
                    print("⚠️ [Context Detection] ContextDetector returned nil for \(appName)")
                }
            }
        } else {
            print("⚠️ [Context Detection] No target application found for context!")
        }

        // Priority 3: Fallback to clipboard
        // Check clipboard for files
        if let fileURLs = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let validFileURLs = fileURLs.filter { $0.isFileURL }
            if !validFileURLs.isEmpty {
                currentContext = .filesSelected(validFileURLs)
                print("📁 Context: \(validFileURLs.count) file(s) in clipboard")
                updateContextSuggestions()
                return
            }
        }

        // Check clipboard for text
        if let clipboardText = NSPasteboard.general.string(forType: .string) {
            let trimmed = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

            if words.count >= 2 || (words.count == 1 && trimmed.count >= 10) {
                currentContext = .textSelected(clipboardText)
                print("📝 Context: Text in clipboard (\(words.count) words)")
                updateContextSuggestions()
                return
            }
        }

        // Priority 4: No context
        currentContext = .none
        print("❌ No context detected")
        updateContextSuggestions()
    }

    private func contextTargetApp() -> NSRunningApplication? {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           !(frontmostApp.bundleIdentifier ?? "").contains("ILauncher") {
            return frontmostApp
        }

        if !frontmostAppBundleID.isEmpty,
           !frontmostAppBundleID.contains("ILauncher"),
           let fallbackApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == frontmostAppBundleID }) {
            return fallbackApp
        }

        return nil
    }

    private func setupQuickLookEventMonitor() {
        // Remove any existing monitor first
        removeQuickLookEventMonitor()
        
        // Add a local event monitor to intercept Space key for Quick Look
        // This works even when the text field has focus
        quickLookEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // Only handle Space key (keyCode 49)
            guard event.keyCode == 49 else { return event }
            
            // Don't intercept if in folder preview mode (folder preview has its own handler)
            guard !showFolderPreview else { return event }
            
            // Don't intercept if in AI mode (allow typing spaces in AI queries)
            guard !isAIMode else { return event }
            
            // Only intercept if we have a selected result
            guard let index = selectedResultIndex, index < searchResults.count else { return event }

            let result = searchResults[index]

            // Check if the result supports preview (file, folder, or contact)
            let supportsPreview = result.filePath != nil || result.type == .contact
            guard supportsPreview else { return event }

            // If search text is empty OR ends with space (user likely not mid-typing), trigger Quick Look
            // Also trigger if Shift is held (Shift+Space is unlikely to be intentional typing)
            let isShiftHeld = event.modifierFlags.contains(.shift)
            let searchIsEmpty = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            let endsWithSpace = searchText.hasSuffix(" ")
            
            if isShiftHeld || searchIsEmpty || endsWithSpace {
                DispatchQueue.main.async {
                    self.quickLookSelectedItem()
                }
                return nil // Consume the event
            }
            
            return event
        }
    }
    
    private func removeQuickLookEventMonitor() {
        if let monitor = quickLookEventMonitor {
            NSEvent.removeMonitor(monitor)
            quickLookEventMonitor = nil
        }
    }

    // MARK: - Dock pill arrow-key navigation

    /// Set up a key monitor that handles Left/Right arrow navigation and
    /// Enter-to-execute for dock pills when the L2 Context Dock is active.
    private func setupDockPillKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // Only intercept when the context dock is showing and we're not in AI chat
            // Don't intercept while a system sheet (share, etc.) is in front
            guard self.showContextInDock, !self.isAIMode, !self.isSharingSheetActive else { return event }

            let q = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let pills = self.buildDockPills(query: q)
            guard !pills.isEmpty else { return event }

            switch event.keyCode {
            case 123: // Left arrow — move focus left (skip separators)
                // Route to shortcut sheet when open
                if self.showShortcutSheet {
                    let count = self.liveMenuItems.filter(\.isEnabled).count
                    self.shortcutSheetFocusedIdx = max(0, (self.shortcutSheetFocusedIdx ?? 0) - 1)
                    _ = count; return nil
                }
                self.pillNavViaKeyboard = true
                var idx = max(0, (self.focusedPillIndex ?? 0) - 1)
                while idx > 0 && pills[idx].isSeparator { idx -= 1 }
                self.focusedPillIndex = idx
                return nil

            case 124: // Right arrow — move focus right (skip separators)
                if self.showShortcutSheet {
                    let count = self.liveMenuItems.filter(\.isEnabled).count
                    self.shortcutSheetFocusedIdx = min(count - 1, (self.shortcutSheetFocusedIdx ?? -1) + 1)
                    return nil
                }
                self.pillNavViaKeyboard = true
                var idx = min(pills.count - 1, (self.focusedPillIndex ?? -1) + 1)
                while idx < pills.count - 1 && pills[idx].isSeparator { idx += 1 }
                self.focusedPillIndex = idx
                return nil

            case 125: // Down arrow
                if self.showShortcutSheet {
                    let count = self.liveMenuItems.filter(\.isEnabled).count
                    self.shortcutSheetFocusedIdx = min(count - 1, (self.shortcutSheetFocusedIdx ?? -1) + 1)
                    return nil
                }
                return event

            case 126: // Up arrow
                if self.showShortcutSheet {
                    self.shortcutSheetFocusedIdx = max(0, (self.shortcutSheetFocusedIdx ?? 0) - 1)
                    return nil
                }
                return event

            case 36: // Return / Enter
                // Shortcut sheet: execute the focused item if any
                if self.showShortcutSheet, let idx = self.shortcutSheetFocusedIdx {
                    let enabled = self.liveMenuItems.filter(\.isEnabled)
                    if idx < enabled.count {
                        let item = enabled[idx]
                        self.showShortcutSheet = false
                        self.shortcutSheetFocusedIdx = nil
                        let pid = item.sourcePID != 0
                            ? item.sourcePID
                            : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
                        let sourceApp = NSWorkspace.shared.runningApplications
                            .first { $0.processIdentifier == pid && !$0.isTerminated }
                        guard pid != 0 else { return nil }
                        let path = item.path; let sc = item.shortcutChar; let mod = item.shortcutModifiers
                        Task {
                            sourceApp?.activate(options: [.activateIgnoringOtherApps])
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            await Task.detached(priority: .userInitiated) {
                                if let ch = sc, !ch.isEmpty {
                                    AXMenuReader.shared.executeShortcut(char: ch, modifiers: mod, in: pid)
                                } else {
                                    AXMenuReader.shared.clickMenuItem(path: path, in: pid)
                                }
                            }.value
                        }
                    }
                    return nil
                }
                // Only intercept Enter when dock is active AND search text is non-empty
                // (empty search text + Enter = submit AI query, handled elsewhere)
                guard !q.isEmpty || self.focusedPillIndex != nil else { return event }
                self.executeFirstOrFocusedPill()
                return nil

            case 53: // Escape — clear pill focus
                if self.focusedPillIndex != nil {
                    self.focusedPillIndex = nil
                    return nil
                }
                return event

            default:
                return event
            }
        }
    }

    // MARK: - Cmd long-press → shortcut sheet

    /// Holds Cmd ≥ 1.5 s without pressing any other key → shows the shortcut sheet.
    private func setupCmdHoldMonitor() {
        if let m = cmdHoldMonitor { NSEvent.removeMonitor(m); cmdHoldMonitor = nil }

        cmdHoldMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [self] event in
            if event.type == .keyDown {
                // Any keyDown while Cmd held → cancel the timer (user is doing a shortcut, not long-press)
                cmdHoldTask?.cancel()
                cmdHoldTask = nil
                return event
            }

            // flagsChanged
            let cmdDown = event.modifierFlags.contains(.command)
                       && !event.modifierFlags.contains(.shift)
                       && !event.modifierFlags.contains(.option)
                       && !event.modifierFlags.contains(.control)

            if cmdDown {
                guard cmdHoldTask == nil else { return event }   // already counting
                cmdHoldTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)   // 0.8 s
                    guard !Task.isCancelled else { return }
                    // Only show when dock is visible and not in AI mode
                    guard self.showContextInDock && !self.isAIMode && !self.liveMenuItems.isEmpty else { return }
                    self.showShortcutSheet = true
                    self.cmdHoldTask = nil
                }
            } else {
                // Cmd released — cancel countdown
                cmdHoldTask?.cancel()
                cmdHoldTask = nil
            }
            return event
        }
    }

    // MARK: - Browser shortcut passthrough (L3)

    /// Intercepts Cmd+T/W/R/L/[/] when L3 is active and forwards them to
    /// the background browser via AppleScript — ILauncher stays visible.
    private func setupBrowserShortcutPassthrough() {
        if let existing = browserShortcutMonitor {
            NSEvent.removeMonitor(existing)
            browserShortcutMonitor = nil
        }
        browserShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard self.showBrowserLayer else { return event }
            guard event.modifierFlags.contains(.command) else { return event }
            // Ignore if option/control also held (system shortcuts)
            guard event.modifierFlags.intersection([.option, .control]).isEmpty else { return event }

            let shift    = event.modifierFlags.contains(.shift)
            let bundleId = AppDelegate.shared?.previousFrontmostApp?.bundleIdentifier ?? ""
            let appName  = AppDelegate.shared?.previousFrontmostApp?.localizedName ?? ""

            let isSafari  = bundleId == "com.apple.Safari" || bundleId.hasPrefix("com.apple.Safari")
            let isChrome  = ["com.google.Chrome","com.microsoft.edgemac","com.brave.Browser",
                             "org.chromium.Chromium"].contains(bundleId)
                         || bundleId.lowercased().contains("chrome")
            let isArc     = bundleId == "company.thebrowser.Browser"
            let isFirefox = bundleId == "org.mozilla.firefox"
            guard isSafari || isChrome || isArc || isFirefox else { return event }

            // (menu, item) tuples per key code
            typealias MA = (String, String)
            var action: MA? = nil

            if isSafari {
                switch event.keyCode {
                case 17: action = shift ? ("History","Reopen Last Closed Tab") : ("File","New Tab")
                case 13: action = ("File",    "Close Tab")
                case 15: action = ("View",    "Reload Page")
                case 37: action = ("File",    "Open Location…")
                case 33: action = ("History", "Back")
                case 30: action = ("History", "Forward")
                default: break
                }
            } else if isChrome {
                switch event.keyCode {
                case 17: action = shift ? ("History","Reopen Closed Tab") : ("File","New Tab")
                case 13: action = ("File",    "Close Tab")
                case 15: action = ("View",    "Reload This Page")
                case 37: action = ("File",    "Open Location…")
                case 33: action = ("History", "Back")
                case 30: action = ("History", "Forward")
                default: break
                }
            } else {                              // Arc / Firefox
                switch event.keyCode {
                case 17: action = ("File", "New Tab")
                case 13: action = ("File", "Close Tab")
                case 15: action = ("View", "Reload Page")
                default: break
                }
            }

            guard let (menu, item) = action else { return event }
            let script = """
            tell application "\(appName)"
                do menu item "\(item)" of menu "\(menu)" of menu bar 1
            end tell
            """
            Task.detached(priority: .userInitiated) {
                if let s = NSAppleScript(source: script) { var e: NSDictionary?; s.executeAndReturnError(&e) }
            }
            return nil  // consume — don't pass to ILauncher
        }
    }

    private func updateWindowSize() {
        // Use asyncAfter to break out of the current layout pass
        // This prevents the "Update Constraints in Window pass" crash
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            // Don't interrupt the opening animation
            guard !self.suppressOpenResize else { return }

            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
                print("⚠️ Could not find window to resize")
                return
            }
            
            let currentFrame = window.frame
            let newHeight = self.calculatedHeight
            let newWidth = self.calculatedWidth
            
            // Only update if the height actually changed significantly
            guard abs(currentFrame.height - newHeight) > 1 || abs(currentFrame.width - newWidth) > 1 else {
                return
            }
            
            // Adjust the y position to keep the window anchored at the top
            let newY = currentFrame.maxY - newHeight
            let newX = currentFrame.midX - (newWidth / 2)
            let newFrame = NSRect(
                x: newX,
                y: newY,
                width: newWidth,
                height: newHeight
            )
            
            print("📐 Resizing window to \(newWidth)x\(newHeight)")

            window.setFrame(newFrame, display: true, animate: true)
        }
    }
    
    private func loadApplicationsInBackground() {
        isLoadingApps = true
        print("🔄 Starting to load applications, shortcuts, and folders...")
        Task.detached(priority: .userInitiated) {
            let apps = findAllApplications()
            let shortcuts = findAllShortcuts()
            let systemFolders = findSystemFolders()
            let contacts = await findAllContacts()
            await MainActor.run {
                print("🔄 Before assignment - Apps: \(apps.count), Shortcuts: \(shortcuts.count), Folders: \(systemFolders.count)")
                withAnimation(.easeInOut(duration: 0.2)) {
                    allApplications = apps + systemFolders // Add system folders to searchable items
                    allShortcuts = shortcuts
                    allContacts = contacts
                    isLoadingApps = false
                }
                print("✅ Loaded: \(allApplications.count) apps+folders, \(allShortcuts.count) shortcuts, \(allContacts.count) contacts")
                print("✅ Total items in allItems: \(allItems.count)")
                if !shortcuts.isEmpty {
                    print("📝 Shortcuts loaded: \(shortcuts.map { $0.title }.joined(separator: ", "))")
                }
                // Re-run search on next run loop to avoid state changes during view updates
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    DispatchQueue.main.async {
                        performSearch()
                    }
                }
            }
        }
    }
    
    private func findAllApplications() -> [SearchResult] {
        let fileManager = FileManager.default
        let appDirectories = [
            "/Applications",
            "/System/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "\(NSHomeDirectory())/Applications"
        ]

        var apps: [SearchResult] = []
        var foundPaths = Set<String>() // Track to avoid duplicates

        print("📂 Searching for applications in directories:")
        for directory in appDirectories {
            print("  - \(directory)")

            // Check if directory exists
            guard fileManager.fileExists(atPath: directory) else {
                print("    ⚠️ Directory does not exist")
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                print("    ⚠️ Could not enumerate directory")
                continue
            }

            var dirCount = 0
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "app" {
                    // Resolve symlinks to get the real path
                    let resolvedURL = fileURL.resolvingSymlinksInPath()

                    // Use the original path for display but resolved for deduplication
                    let displayPath = fileURL.path
                    let realPath = resolvedURL.path

                    // Skip if we've already found this app (by real path)
                    guard !foundPaths.contains(realPath) else {
                        continue
                    }
                    foundPaths.insert(realPath)

                    let appName = fileURL.deletingPathExtension().lastPathComponent
                    let icon = NSWorkspace.shared.icon(forFile: fileURL.path)

                    apps.append(SearchResult(
                        title: appName,
                        subtitle: displayPath,
                        icon: icon,
                        action: {
                            NSWorkspace.shared.open(fileURL)
                        },
                        type: .application,
                        filePath: nil,
                        contactData: nil
                    ))
                    dirCount += 1

                    if appName == "Safari" {
                        print("    ✅ Found Safari: display=\(displayPath), real=\(realPath)")
                    }

                    // Skip descending into .app bundles to avoid finding nested apps
                    enumerator.skipDescendants()
                }
            }
            print("    ✓ Found \(dirCount) apps")
        }

        // Fallback: Ensure Safari is found using NSWorkspace
        if !foundPaths.contains(where: { $0.contains("Safari.app") }) {
            print("🔍 Safari not found in directories, trying NSWorkspace...")
            if let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                print("  ✅ Found Safari at: \(safariURL.path)")
                foundPaths.insert(safariURL.path)

                let appName = safariURL.deletingPathExtension().lastPathComponent
                let icon = NSWorkspace.shared.icon(forFile: safariURL.path)

                apps.append(SearchResult(
                    title: appName,
                    subtitle: safariURL.path,
                    icon: icon,
                    action: {
                        NSWorkspace.shared.open(safariURL)
                    },
                    type: .application,
                    filePath: nil,
                    contactData: nil
                ))
            }
        }

        print("🎯 Total applications found: \(apps.count)")
        let sorted = apps.sorted { $0.title.lowercased() < $1.title.lowercased() }
        if sorted.count > 0 {
            print("📝 First few apps: \(sorted.prefix(5).map { $0.title }.joined(separator: ", "))")
        }
        return sorted
    }
    
    private func findAllShortcuts() -> [SearchResult] {
        var shortcuts: [SearchResult] = []
        
        print("🔗 Searching for shortcuts using AppIntents framework...")
        
        // Get the Shortcuts app icon once
        let shortcutsAppIcon: NSImage = {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                print("    ✅ Found Shortcuts app icon")
                return icon
            } else {
                print("    ⚠️ Shortcuts app not found, using fallback icon")
                return NSWorkspace.shared.icon(forFileType: "shortcut")
            }
        }()
        
        // Use ShortcutsLink to query available shortcuts
        // Note: This requires macOS 13+ and proper entitlements
        do {
            // Query all available shortcuts
            let query = ShortcutsLinkQuery()
            
            // This is a synchronous call that fetches shortcuts
            let results = try query.shortcuts()
            
            print("    ✅ Found \(results.count) shortcuts via AppIntents")
            
            for shortcut in results {
                let shortcutName = shortcut.name
                print("    📝 Shortcut: \(shortcutName)")
                
                shortcuts.append(SearchResult(
                    title: shortcutName,
                    subtitle: "Shortcut",
                    icon: shortcutsAppIcon,
                    action: {
                        // Run the shortcut using the shortcuts:// URL scheme
                        if let encodedName = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                           let url = URL(string: "shortcuts://run-shortcut?name=\(encodedName)") {
                            print("🚀 Running shortcut: \(shortcutName)")
                            NSWorkspace.shared.open(url)
                        }
                    },
                    type: .shortcut,
                    filePath: nil,
                    contactData: nil
                ))
            }
        } catch {
            print("    ⚠️ Error querying shortcuts: \(error)")
            print("    💡 Make sure com.apple.security.automation.apple-events entitlement is enabled")
        }
        
        print("🎯 Total shortcuts found: \(shortcuts.count)")
        
        let sorted = shortcuts.sorted { $0.title.lowercased() < $1.title.lowercased() }
        if sorted.count > 0 {
            print("📝 Shortcuts: \(sorted.map { $0.title }.joined(separator: ", "))")
        } else {
            print("⚠️ No shortcuts found")
        }
        return sorted
    }

    private func findSystemFolders() -> [SearchResult] {
        var folders: [SearchResult] = []
        let fileManager = FileManager.default

        // Get user's home directory
        let homeURL = fileManager.homeDirectoryForCurrentUser

        // Common system folders with their names and icons
        let systemFolders: [(name: String, path: String, icon: String)] = [
            ("Desktop", "\(homeURL.path)/Desktop", "desktop"),
            ("Documents", "\(homeURL.path)/Documents", "doc.text.fill"),
            ("Downloads", "\(homeURL.path)/Downloads", "arrow.down.circle.fill"),
            ("Pictures", "\(homeURL.path)/Pictures", "photo.fill"),
            ("Music", "\(homeURL.path)/Music", "music.note"),
            ("Movies", "\(homeURL.path)/Movies", "film.fill"),
            ("Applications", "/Applications", "app.fill"),
            ("Library", "\(homeURL.path)/Library", "books.vertical.fill"),
            ("Public", "\(homeURL.path)/Public", "person.2.fill"),
            ("iCloud Drive", "\(homeURL.path)/Library/Mobile Documents/com~apple~CloudDocs", "icloud.fill")
        ]
        
        // Scan home directory for user-created folders (like MEGA, Projects, etc.)
        do {
            let homeContents = try fileManager.contentsOfDirectory(
                at: homeURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            
            // Get list of system folder names to exclude duplicates
            let systemFolderNames = Set(systemFolders.map { $0.name.lowercased() })
            
            for url in homeContents {
                // Check if it's a directory
                guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                      resourceValues.isDirectory == true else {
                    continue
                }
                
                let folderName = url.lastPathComponent
                
                // Skip if it's already in system folders
                guard !systemFolderNames.contains(folderName.lowercased()) else {
                    continue
                }
                
                // Skip hidden folders (like .ssh, .config, etc.)
                guard !folderName.hasPrefix(".") else {
                    continue
                }
                
                // Skip known non-interesting folders
                let skipFolders = ["Applications (Parallels)", "Parallels", "VirtualBox VMs"]
                guard !skipFolders.contains(folderName) else {
                    continue
                }
                
                // Add user folder with inline preview
                let folderPath = url.path
                folders.append(SearchResult(
                    title: folderName,
                    subtitle: url.path,
                    icon: NSWorkspace.shared.icon(forFile: url.path),
                    action: {
                        self.showFolderPreviewInline(path: folderPath)
                    },
                    type: .folder,
                    filePath: url.path,
                    contactData: nil
                ))
                
                print("📁 Added user folder: \(folderName)")
            }
        } catch {
            print("⚠️ Error scanning home directory for user folders: \(error)")
        }

        // Add predefined system folders
        for folder in systemFolders {
            let folderURL = URL(fileURLWithPath: folder.path)

            // Check if folder exists
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                folders.append(SearchResult(
                    title: folder.name,
                    subtitle: folder.path,
                    icon: NSImage(systemSymbolName: folder.icon, accessibilityDescription: folder.name),
                    action: {
                        // Folder opening is handled in executeResult
                    },
                    type: .folder,
                    filePath: folder.path,
                    contactData: nil
                ))
            }
        }

        print("📁 Found \(folders.count) system + user folders")
        return folders
    }

    private func findAllContacts() async -> [SearchResult] {
        var contacts: [SearchResult] = []

        // Check if contacts search is enabled in settings
        if !settings.allowContacts {
            print("ℹ️ Contacts search is disabled in settings")
            return []
        }

        // Check permission first
        if !contactManager.hasContactsPermission {
            let granted = await contactManager.requestPermission()
            if !granted {
                print("⚠️ Contacts permission denied")
                return []
            }
        }
        
        // Get all contacts for searching
        let contactResults = await contactManager.getAllContacts()
        
        for contactResult in contactResults {
            contacts.append(SearchResult(
                title: contactResult.fullName,
                subtitle: contactResult.subtitle,
                icon: contactResult.image,
                action: { [contactResult] in
                    // Default action: open in Contacts app
                    contactResult.openInContacts()
                },
                type: .contact,
                filePath: nil,
                contactData: SearchResult.ContactData(
                    primaryEmail: contactResult.primaryEmail,
                    allEmails: contactResult.allEmails,
                    primaryPhone: contactResult.primaryPhone,
                    allPhones: contactResult.allPhones,
                    identifier: contactResult.identifier
                )
            ))
        }
        
        print("📇 Loaded \(contacts.count) contacts")
        return contacts
    }
    
    private func initializeFileIndex() {
        Task {
            await fileIndexManager.initialize()
        }
    }
    
    private func searchIndexedFiles(for query: String) {
        guard settings.enableSpotlightSearch else {
            indexedFileResults = []
            return
        }
        
        guard !query.isEmpty else {
            indexedFileResults = []
            return
        }
        
        guard fileIndexManager.isReady else {
            print("⚠️ File index not ready yet")
            indexedFileResults = []
            return
        }
        
        
        // Use the pre-built index for instant search
        let results = fileIndexManager.search(query: query, limit: 20)
        
        indexedFileResults = results
    }

    private func searchSystemData(for query: String) async {
        // System data (calendar, reminders, notes, mail) only appears in the
        // dedicated app panel (activeSmartQueryKey), never in normal search results.
        // This prevents clutter like "call mom" showing under CALENDAR & NOTES when
        // the user types "cal" looking for Calendar.app.
        guard !query.isEmpty else {
            await MainActor.run {
                systemDataResults = []
            }
            return
        }
        // Skip entirely when not in app panel mode
        guard await MainActor.run(resultType: Bool.self, body: { activeSmartQueryKey != nil }) else {
            return
        }

        print("🔍 [SystemSearch] Starting search for: '\(query)'")

        // Search all system data types
        let systemResults = await systemDataManager.searchAll(
            query: query,
            types: [.calendarEvent, .reminder, .note, .mail, .photo, .message, .voiceRecording],
            perTypeLimit: 5
        )

        print("✅ [SystemSearch] Found \(systemResults.count) system data results")
        if systemResults.isEmpty {
            print("⚠️ [SystemSearch] No results found - this might indicate permission issues or no matching data")
        } else {
            print("📊 [SystemSearch] Result types: \(systemResults.map { "\($0.type)" }.joined(separator: ", "))")
        }

        // Convert SystemSearchResult to SearchResult
        let searchResults = systemResults.map { systemResult -> SearchResult in
            // Map SystemDataType to ResultType
            let resultType: SearchResult.ResultType
            switch systemResult.type {
            case .calendarEvent:
                resultType = .calendarEvent
            case .reminder:
                resultType = .reminder
            case .note:
                resultType = .note
            case .mail:
                resultType = .mail
            case .photo:
                resultType = .photo
            case .message:
                resultType = .message
            case .voiceRecording, .contact:
                // Map voiceRecording to file type and contact is already handled separately
                resultType = .file
            }

            return SearchResult(
                title: systemResult.title,
                subtitle: systemResult.subtitle,
                icon: systemResult.icon,
                action: { systemResult.open() },
                score: 0.0,
                type: resultType,
                filePath: nil,
                contactData: nil
            )
        }

        print("✅ [SystemSearch] Converted to \(searchResults.count) SearchResults")

        await MainActor.run {
            print("📝 [SystemSearch] Updating systemDataResults on main thread")
            systemDataResults = searchResults
            print("📝 [SystemSearch] Current systemDataResults count: \(systemDataResults.count)")
            print("📝 [SystemSearch] Current allItems count: \(allItems.count)")
            // Trigger re-search on next run loop to avoid state changes during view updates
            DispatchQueue.main.async {
                performSearchWithoutSpotlight()
            }
        }
    }

    func navigateResults(direction: Int) {
        let results = searchResults // Capture current snapshot
        guard !results.isEmpty else {
            selectedResultIndex = nil
            return
        }

        // Mark as keyboard navigation for auto-scroll
        isKeyboardNavigation = true

        let movementDirection = direction

        if let currentIndex = selectedResultIndex {
            // Validate current index is still valid
            guard currentIndex >= 0 && currentIndex < results.count else {
                selectedResultIndex = 0
                return
            }

            let newIndex = currentIndex + movementDirection
            if newIndex >= 0 && newIndex < results.count {
                selectedResultIndex = newIndex
            } else if movementDirection < 0 {
                // At the top, stay at top
                selectedResultIndex = 0
            } else {
                // At the bottom, stay at bottom
                selectedResultIndex = results.count - 1
            }
        } else {
            selectedResultIndex = direction > 0 ? 0 : max(results.count - 1, 0)
        }
    }
    
    func executeSelectedResult() {
        // In AI mode, submit to AI provider instead
        if isAIMode {
            submitAIQuery()
            return
        }
        
        // Validate index bounds before accessing
        if let index = selectedResultIndex, index >= 0 && index < searchResults.count {
            executeResult(searchResults[index])
        } else if !searchResults.isEmpty {
            executeResult(searchResults[0])
        } else {
            // Try to open as URL or perform web search
            handleDirectInput()
        }
    }
    
    func executeResult(_ result: SearchResult) {
        // Track usage for frecency ranking
        UsageTracker.shared.recordAccess(for: result.trackingIdentifier)

        // Contacts → open context panel (contact card)
        if result.type == .contact {
            activateSearchContext(for: result)
            return
        }

        // Files, documents, and folders → Enter always opens them directly
        // (Use Tab or → to open the context panel instead)
        if result.type == .file || result.type == .document || result.type == .folder {
            result.action()
            searchText = ""
            searchResults = []
            selectedResultIndex = nil
            onClose()
            return
        }

        // Special handling for shortcuts with context
        if result.type == .shortcut {
            executeShortcutWithContext(result)
        } else {
            result.action()
        }

        searchText = ""
        searchResults = []
        selectedResultIndex = nil
        onClose()
    }

    private func executeL2Extension(_ ext: ILExtension, context: UserContext) async {
        await MainActor.run {
            l2IsLoading = true
            updateWindowSize()
        }

        defer {
            Task { @MainActor in
                l2IsLoading = false
                updateWindowSize()
            }
        }

        let inputFiles: [URL]
        if case .filesSelected(let urls) = context {
            inputFiles = urls
        } else {
            inputFiles = []
        }

        do {
            if ext.name == "Summarize Webpage",
               frontmostAppName.lowercased().contains("safari"),
               let pageText = fetchSafariPageText(),
               !pageText.isEmpty {
                let prompt = "Summarize this webpage:\n\n\(pageText)"
                let response = try await sendToAIProvider(query: prompt)
                await MainActor.run {
                    updateL2Results(buildL2OutputResults(title: ext.name, output: response))
                }
                return
            }

            let output = try await LayeredExtensionManager.shared.execute(extension: ext, with: inputFiles)
            await MainActor.run {
                updateL2Results(buildL2OutputResults(title: ext.name, output: output))
            }
        } catch {
            print("❌ [L2 Extension] Failed to run \(ext.name): \(error.localizedDescription)")
        }
    }

    private func fetchSafariPageText() -> String? {
        let script = """
        tell application "Safari"
            if (count of windows) = 0 then return ""
            set currentTab to current tab of front window
            set js to "document.body ? document.body.innerText : ''"
            return do JavaScript js in currentTab
        end tell
        """

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return nil
        }

        let output = scriptObject.executeAndReturnError(&error)
        if error != nil {
            return nil
        }

        let text = output.stringValue ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return String(trimmed.prefix(6000))
    }

    private func fetchSafariPageLinks() -> [String] {
        let script = """
        tell application "Safari"
            if (count of windows) = 0 then return ""
            set currentTab to current tab of front window
            set js to "Array.from(document.links).map(a => a.href).filter(Boolean).join('\\\\n')"
            return do JavaScript js in currentTab
        end tell
        """

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return []
        }

        let output = scriptObject.executeAndReturnError(&error)
        if error != nil {
            return []
        }

        let text = output.stringValue ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let links = trimmed
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(NSOrderedSet(array: links)) as? [String] ?? links
    }

    private func fetchSafariPageImages() -> [String] {
        let script = """
        tell application "Safari"
            if (count of windows) = 0 then return ""
            set currentTab to current tab of front window
            set js to "Array.from(document.images).map(i => i.src).filter(Boolean).join('\\\\n')"
            return do JavaScript js in currentTab
        end tell
        """

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return []
        }

        let output = scriptObject.executeAndReturnError(&error)
        if error != nil {
            return []
        }

        let text = output.stringValue ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let images = trimmed
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(NSOrderedSet(array: images)) as? [String] ?? images
    }

    private func handleSafariDirectQuery(query: String) -> Bool {
        let normalized = query.lowercased()

        let isPDFSaveQuery = (normalized.contains("save") || normalized.contains("export")) &&
            (normalized.contains("pdf") || normalized.contains("page"))

        if isPDFSaveQuery {
            let userMessage = AIChatMessage(role: .user, content: query)
            l2ChatMessages.append(userMessage)
            l2IsLoading = true

            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            let outputPath = "\(NSHomeDirectory())/Downloads/SafariPage-\(timestamp).pdf"
            let command = "ilauncher-api safari save-pdf \"\(outputPath)\""

            l2CurrentTask = Task {
                let result = await executeShellCommandSafely(command)
                await MainActor.run {
                    let response = """
                    Saved current page as PDF:
                    \(outputPath)

                    Result:
                    \(result)
                    """
                    l2ChatMessages.append(AIChatMessage(role: .assistant, content: response))
                    l2IsLoading = false
                    l2CurrentTask = nil
                }
            }
            return true
        }

        if normalized.contains("airdrop") || normalized.contains("share") {
            let userMessage = AIChatMessage(role: .user, content: query)
            l2ChatMessages.append(userMessage)
            l2IsLoading = true

            let suggestion = """
            [SUGGEST_EXTENSION]
            {
                "name": "Safari Page → PDF (Ready for AirDrop)",
                "description": "Save the current Safari page as a PDF to Downloads and reveal it so you can AirDrop it.",
                "app": "Safari",
                "code": "#!/bin/bash\\nset -e\\nTS=$(date +%Y%m%d-%H%M%S)\\nOUT=\\\"$HOME/Downloads/SafariPage-$TS.pdf\\\"\\nilauncher-api safari save-pdf \\\"$OUT\\\"\\nopen -R \\\"$OUT\\\"\\necho \\\"Saved: $OUT\\\""
            }
            [/SUGGEST_EXTENSION]
            """

            l2CurrentTask = Task {
                await handleL2AIResponse(suggestion)
                await MainActor.run {
                    l2IsLoading = false
                    l2CurrentTask = nil
                }
            }
            return true
        }


        let isSearchQuery = normalized.contains("search") ||
            normalized.contains("youtube") ||
            normalized.contains("google") ||
            normalized.contains("open") ||
            normalized.contains("go to") ||
            normalized.contains("navigate")

        if isSearchQuery, let url = buildSafariSearchURL(from: normalized) {
            let userMessage = AIChatMessage(role: .user, content: query)
            l2ChatMessages.append(userMessage)
            l2IsLoading = true

            let command = "open -a Safari \"\(url.absoluteString)\""
            l2CurrentTask = Task {
                let result = await executeShellCommandSafely(command)
                await MainActor.run {
                    let response = """
                    Opened in Safari:
                    \(url.absoluteString)

                    Result:
                    \(result)
                    """
                    l2ChatMessages.append(AIChatMessage(role: .assistant, content: response))
                    l2IsLoading = false
                    l2CurrentTask = nil
                }
            }
            return true
        }

        return false
    }

    // MARK: - YouTube Panel Handlers

    func handleYouTubePanelQuery(query: String) {
        let normalized = query.lowercased()
        let isDownload = normalized.contains("download") || normalized.contains("mp3") ||
            normalized.contains("mp4") || normalized.contains("save audio") ||
            normalized.contains("save video") || normalized.contains("extract audio")
        if isDownload {
            handleYouTubeDownloadWithAI(query: query)
        } else {
            handleYouTubeSearch(query: query)
        }
    }

    private func handleYouTubeSearch(query: String) {
        guard let ytdlp = ytdlpBinaryPath() else {
            remPanelChatMessages.append(AIChatMessage(role: .assistant,
                content: "yt-dlp not installed. Run: brew install yt-dlp", isError: true))
            remPanelIsProcessing = false
            return
        }
        remPanelIsProcessing = true
        remPanelAITask = Task {
            let safeQuery = query.replacingOccurrences(of: "'", with: "'\\''")
            let cmd = "\(ytdlp) 'ytsearch10:\(safeQuery)' --flat-playlist -j --no-warnings 2>/dev/null"
            let output = await executeShellCommandSafely(cmd)
            let results = parseYouTubeSearchJSON(output)
            await MainActor.run {
                if results.isEmpty {
                    remPanelChatMessages.append(AIChatMessage(role: .assistant,
                        content: "No results for \"\(query)\". Check your internet connection."))
                } else {
                    remPanelChatMessages.append(AIChatMessage(role: .assistant,
                        content: "Found \(results.count) results for \"\(query)\" — click to select, right-click to download."))
                    selectedYouTubeResult = nil
                    showLivePanel(.youtubeResults(results))
                }
                remPanelIsProcessing = false
            }
        }
    }

    private func handleYouTubeDownloadWithAI(query: String) {
        let provider = settings.selectedAIProvider
        let rawKey = AppSettings.shared.getAPIKey(for: provider)
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey
        guard let ytdlp = ytdlpBinaryPath() else {
            remPanelChatMessages.append(AIChatMessage(role: .assistant,
                content: "yt-dlp not installed. Run: brew install yt-dlp", isError: true))
            remPanelIsProcessing = false
            return
        }

        var selectedContext = ""
        if let sel = selectedYouTubeResult {
            selectedContext = """

            SELECTED VIDEO: \(sel.title)
            URL: \(sel.url)
            Channel: \(sel.channel ?? "unknown")
            Duration: \(sel.durationString)
            Use this URL directly — no need to search again.
            """
        }

        let systemPrompt = """
        You are a YouTube download assistant. yt-dlp is at \(ytdlp).
        \(selectedContext)

        DOWNLOAD COMMANDS:
        - MP3: \(ytdlp) -x --audio-format mp3 "URL" -o "\(NSHomeDirectory())/Music/%(title)s.%(ext)s" --no-warnings
        - MP4: \(ytdlp) -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" "URL" -o "\(NSHomeDirectory())/Movies/%(title)s.%(ext)s" --no-warnings
        - Find URL: \(ytdlp) "ytsearch1:QUERY" --flat-playlist -j --no-warnings | python3 -c "import sys,json;d=json.loads(sys.stdin.readline());print(d.get('url',''))"

        RULES:
        - If selected URL provided above, use it directly — skip search.
        - If no URL, search with ytsearch1 first, get the URL, then download.
        - For MP3 always use -x --audio-format mp3.
        - After download, confirm: "Downloaded: [title] → ~/Music/[file]"
        """

        let history: [ChatMessage] = remPanelChatMessages.dropLast()
            .filter { $0.role != .tool }
            .map { ChatMessage(role: $0.role == .user ? .user : .assistant, content: $0.content) }

        remPanelIsProcessing = true
        remPanelAITask = Task {
            do {
                let (finalResponse, executedCmds) = try await AIProviderService.shared.sendWithTools(
                    query,
                    context: .none,
                    provider: provider,
                    apiKey: apiKey,
                    conversationHistory: history,
                    commandExecutor: { cmd, _ in
                        let ck = self.activeConsoleKey
                        await MainActor.run {
                            self.panelConsoleLinesMap[ck, default: []].append((line: "$ \(cmd)", isCommand: true))
                            self.panelShowConsoleMap[ck] = true
                        }
                        let result = await executeShellCommandSafely(cmd)
                        await MainActor.run {
                            for line in result.split(separator: "\n", omittingEmptySubsequences: false) {
                                self.panelConsoleLinesMap[ck, default: []].append((line: String(line), isCommand: false))
                            }
                        }
                        return (!result.lowercased().contains("error:"), result)
                    },
                    systemPromptOverride: systemPrompt
                )
                await MainActor.run {
                    for cmd in executedCmds {
                        remPanelChatMessages.append(AIChatMessage(role: .tool,
                            content: "$ \(cmd.command)\n\(String(cmd.output.suffix(200)))"))
                    }
                    remPanelChatMessages.append(AIChatMessage(role: .assistant, content: finalResponse))
                    remPanelIsProcessing = false
                }
            } catch {
                await MainActor.run {
                    remPanelChatMessages.append(AIChatMessage(role: .assistant,
                        content: "Download failed: \(error.localizedDescription)", isError: true))
                    remPanelIsProcessing = false
                }
            }
        }
    }

    private func ytdlpBinaryPath() -> String? {
        ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp",
         "\(NSHomeDirectory())/.local/bin/yt-dlp"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private func parseYouTubeSearchJSON(_ raw: String) -> [YouTubeSearchResult] {
        var results: [YouTubeSearchResult] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let id = json["id"] as? String ?? UUID().uuidString
            let title = json["title"] as? String ?? "Untitled"
            let rawURL = json["url"] as? String ?? ""
            let url: String
            if rawURL.hasPrefix("http") {
                url = rawURL
            } else {
                url = "https://www.youtube.com/watch?v=\(id)"
            }
            results.append(YouTubeSearchResult(
                id: id, title: title, url: url,
                duration: json["duration"] as? Int,
                channel: json["channel"] as? String ?? json["uploader"] as? String,
                thumbnail: json["thumbnail"] as? String,
                viewCount: json["view_count"] as? Int
            ))
        }
        return results
    }

    private func buildSafariSearchURL(from normalizedQuery: String) -> URL? {
        let isYouTube = normalizedQuery.contains("youtube")
        var term = normalizedQuery

        let tokens = [
            "search", "on youtube", "in youtube", "youtube",
            "google", "open", "go to", "navigate", "in safari", "on safari"
        ]

        for token in tokens {
            term = term.replacingOccurrences(of: token, with: "")
        }

        term = term
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !term.isEmpty else {
            return nil
        }

        let queryTerm = term
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: "+")

        let base = isYouTube
            ? "https://youtube.com/results?search_query="
            : "https://google.com/search?q="

        return URL(string: base + queryTerm)
    }

    private func shouldAutoRunL2Extension(query: String, ext: ILExtension) -> Bool {
        let normalized = query.lowercased()
        let name = ext.name.lowercased()

        if normalized.contains(name) {
            return true
        }

        if ext.matchesKeyword(query) {
            return true
        }

        for intent in ext.intents {
            if normalized.contains(intent.action.lowercased()) {
                return true
            }
            if let target = intent.target?.lowercased(), normalized.contains(target) {
                return true
            }
        }

        return false
    }

    private func buildL2OutputResults(title: String, output: String) -> [SearchResult] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lines = trimmed
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let maxItems = 20
        let items = lines.isEmpty ? [trimmed] : Array(lines.prefix(maxItems))

        return items.map { line in
            let url = URL(string: line)
            return SearchResult(
                title: line,
                subtitle: title,
                icon: NSImage(systemSymbolName: "doc.text", accessibilityDescription: title),
                action: {
                    if let url, url.scheme != nil {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line, forType: .string)
                    }
                },
                score: 0.0,
                type: .extensionCommand,
                filePath: nil,
                contactData: nil
            )
        }
    }

    /// Returns a stable string identifying WHAT the context is about (file path, text hash, URL, app bundle).
    /// Used to detect when the user switches to a different subject so stale chat can be cleared.
    private func contextIdentityKey(_ context: UserContext) -> String {
        switch context {
        case .filesSelected(let urls):
            // Use all paths so selecting a different file in same folder is caught
            return "files:" + urls.map(\.path).sorted().joined(separator: "|")
        case .textSelected(let text):
            return "text:" + String(text.prefix(200))
        case .url(let urlString):
            return "url:" + urlString
        case .appFocused(_, let bundleID):
            return "app:" + bundleID
        case .contactSelected(let name):
            return "contact:" + name
        case .none:
            return "none"
        }
    }

    private func updateL2Results(_ results: [SearchResult]) {
        l2ExtensionResults = results
        if showContextInDock && !showBrowserLayer {
            if !isSearchBarExpanded && !results.isEmpty {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isSearchBarExpanded = true
                }
            }
            searchResults = results
            groupedResults = {
                var grouped = GroupedResults()
                results.forEach { grouped.add($0) }
                return grouped
            }()
            selectedResultIndex = results.isEmpty ? nil : 0
        }
    }

    // MARK: - Intelligent L2 Query Handling

    // Compact prompt for on-device AI (4096 token limit)
    private func buildCompactL2Prompt(query: String, context: UserContext, frontmostApp: String?) -> String {
        var prompt = "You are a macOS assistant. Answer the user's question based on the context provided.\n\n"
        let queryLower = query.lowercased()
        let isExtensionRequest = queryLower.contains("extension") || queryLower.contains("automation") || queryLower.contains("script")

        // Add only essential context based on what's selected
        switch context {
        case .filesSelected(let urls):
            let fileAnalysis = ContextDetector.shared.analyzeFiles(urls)
            prompt += "SELECTED FILES (\(fileAnalysis.count)):\n"
            for (index, file) in fileAnalysis.prefix(3).enumerated() {
                prompt += "\n\(index + 1). \(file.url.lastPathComponent)\n"
                prompt += "Type: \(file.type), Size: \(file.size)\n"

                if let content = file.content {
                    // For PDFs and text, limit to 1500 chars
                    let preview = String(content.prefix(1500))
                    prompt += "Content:\n```\n\(preview)\n```\n"
                    if content.count > 1500 {
                        prompt += "(truncated)\n"
                    }
                }
            }
            if fileAnalysis.count > 3 {
                prompt += "\n... and \(fileAnalysis.count - 3) more files\n"
            }
            if frontmostApp?.lowercased() == "finder",
               let currentDir = ContextDetector.shared.getCurrentFinderDirectory() {
                prompt += "\nCURRENT DIRECTORY:\n\(currentDir)\n"
            }

        case .textSelected(let text):
            let preview = String(text.prefix(2000))
            prompt += "SELECTED TEXT:\n```\n\(preview)\n```\n"
            if text.count > 2000 {
                prompt += "(truncated)\n"
            }

        case .appFocused(let appName, _):
            if appName.lowercased() == "finder" {
                if let currentDir = ContextDetector.shared.getCurrentFinderDirectory() {
                    prompt += "CURRENT DIRECTORY:\n\(currentDir)\n"
                }
                let selectedFiles = ContextDetector.shared.getFinderSelectedFiles()
                if !selectedFiles.isEmpty {
                    let fileAnalysis = ContextDetector.shared.analyzeFiles(selectedFiles)
                    prompt += "FINDER - SELECTED FILES (\(fileAnalysis.count)):\n"
                    for (index, file) in fileAnalysis.prefix(3).enumerated() {
                        prompt += "\n\(index + 1). \(file.url.lastPathComponent)\n"
                        prompt += "Type: \(file.type), Size: \(file.size)\n"

                        if let content = file.content {
                            let preview = String(content.prefix(1500))
                            prompt += "Content:\n```\n\(preview)\n```\n"
                            if content.count > 1500 {
                                prompt += "(truncated)\n"
                            }
                        }
                    }
                }
            } else {
                prompt += "User is in: \(appName)\n"
            }

        default:
            break
        }

        if frontmostApp?.lowercased().contains("safari") == true {
            if let safariContext = ContextDetector.shared.getSafariContext() {
                prompt += "\nCURRENT SAFARI TAB:\n"
                prompt += "Title: \(safariContext.title)\n"
                prompt += "URL: \(safariContext.url)\n"
            }

            if let pageText = fetchSafariPageText(), !pageText.isEmpty {
                let preview = pageText.prefix(1200)
                prompt += "\nPAGE CONTENT (excerpt):\n```\n\(preview)\n```\n"
                if pageText.count > 1200 {
                    prompt += "(truncated)\n"
                }
            }

            if queryLower.contains("link") || queryLower.contains("social") || queryLower.contains("url") {
                let links = fetchSafariPageLinks()
                if !links.isEmpty {
                    prompt += "\nPAGE LINKS:\n"
                    for link in links.prefix(30) {
                        prompt += "- \(link)\n"
                    }

                    if queryLower.contains("social") {
                        let socialDomains = [
                            "twitter.com", "x.com", "facebook.com", "instagram.com",
                            "linkedin.com", "youtube.com", "tiktok.com", "github.com", "reddit.com"
                        ]
                        let socialLinks = links.filter { link in
                            socialDomains.contains { link.lowercased().contains($0) }
                        }
                        if !socialLinks.isEmpty {
                            prompt += "\nSOCIAL LINKS:\n"
                            for link in socialLinks.prefix(20) {
                                prompt += "- \(link)\n"
                            }
                        }
                    }
                }
            }
        }

        if isExtensionRequest {
            prompt += "\nUser explicitly requested an extension. You MUST respond with [SUGGEST_EXTENSION] and include working code.\n"
        }

        // Inject tools for every app mentioned in the query (cross-app task support)
        let crossAppSnippet = buildCrossAppToolsSnippet(query: query, frontmostApp: frontmostApp)
        if !crossAppSnippet.isEmpty {
            prompt += crossAppSnippet
        }

        // Proactively suggest missing tools based on query intent
        // e.g. user asks "compress this video" but has no video tool → suggest ffmpeg
        let missingTools = FileTypeToolRegistry.shared.suggestMissingTools(for: query, maxCount: 2)
        if !missingTools.isEmpty {
            let suggestions = missingTools.map { "  - \($0.toolName): \($0.description) (brew install \($0.toolName))" }.joined(separator: "\n")
            prompt += """

            TOOL SUGGESTION: No installed tool matches this request. Tell the user:
            \(suggestions)
            Provide the exact brew install command so they can tap the install button.

            """
        }

        prompt += "\nUser question: \(query)\n"
        return prompt
    }

    /// Detects which apps are mentioned in the query (beyond the frontmost app),
    /// pulls the user's installed CLI tools for each, and returns a prompt snippet
    /// so the AI can chain tools across apps without any hardcoded AppleScript.
    private func buildCrossAppToolsSnippet(query: String, frontmostApp: String?) -> String {
        let q = query.lowercased()
        let frontmostKey = activeSmartQueryKey ?? settings.autoDetectedAppKey
            ?? frontmostApp.flatMap { settings.appKey(forBundleID: frontmostAppBundleID, appName: $0) }

        // Build app mention map from two sources:
        // 1. Built-in well-known app keys with common aliases
        // 2. All user-registered custom apps and tool extensions (dynamic — no hardcoded limit)
        var appMentionMap: [(words: [String], key: String)] = [
            (["notes", "note"],                 "notes"),
            (["reminders", "reminder", "todo"], "reminders"),
            (["calendar", "event", "meeting"],  "calendar"),
            (["mail", "email"],                 "mail"),
            (["messages", "imessage", "sms"],   "messages"),
            (["safari", "browser", "webpage",
              "page", "link", "url", "tab"],    "safari"),
            (["finder", "files", "folder"],     "finder"),
            (["spotify", "music", "song",
              "playlist", "track"],             "spotify"),
            (["xcode", "project", "build"],     "xcode"),
            (["vscode", "code", "editor"],      "vscode"),
        ]
        // Append every user-registered custom app (e.g. "obsidian", "notion", "slack")
        // Words = [key, label.lowercased()] so both "obsidian" and "Obsidian" match
        for entry in settings.customAppEntries {
            let key = entry.key.lowercased()
            guard !appMentionMap.contains(where: { $0.key == key }) else { continue }
            var words: [String] = [key]
            let labelLower = entry.label.lowercased()
            if labelLower != key { words.append(labelLower) }
            appMentionMap.append((words: words, key: key))
        }
        // Also add any appKey that has tool extensions but isn't a custom entry or built-in
        let knownKeys = Set(appMentionMap.map { $0.key })
        for ext in settings.appToolExtensions {
            let key = ext.appKey.lowercased()
            guard !knownKeys.contains(key) else { continue }
            appMentionMap.append((words: [key], key: key))
        }

        // Collect keys of all apps mentioned in the query (excluding frontmost — already injected)
        var mentionedKeys: [String] = []
        for entry in appMentionMap {
            guard entry.key != frontmostKey else { continue }
            if entry.words.contains(where: { q.contains($0) }) {
                mentionedKeys.append(entry.key)
            }
        }
        guard !mentionedKeys.isEmpty else { return "" }

        // For each mentioned app, pull its installed tools (scored against query)
        let pkgs = TerminalPackageManager.shared.packages
        var sections: [String] = []

        for key in mentionedKeys {
            let tools = settings.topExtensions(for: key, query: query, maxCount: 3)
            guard !tools.isEmpty else { continue }

            let appLabel = settings.customAppEntries.first(where: { $0.key == key })?.label
                ?? key.capitalized

            let toolLines = tools.map { ext -> String in
                let pkg = pkgs.first(where: { $0.command == ext.toolName })
                var line = "  - \(ext.toolName)"
                if let path = pkg?.installedPath ?? (ext.toolPath.isEmpty ? nil : ext.toolPath) {
                    line += " (\(path))"
                }
                let hint = ext.effectiveHint
                if !hint.isEmpty { line += ": \(String(hint.prefix(200)))" }
                else if let ht = pkg?.helpText, !ht.isEmpty { line += ": \(String(ht.prefix(200)))" }
                if !ext.profile.exampleCommands.isEmpty {
                    line += " | e.g. \(ext.profile.exampleCommands.prefix(2).joined(separator: " / "))"
                }
                return line
            }.joined(separator: "\n")

            sections.append("\(appLabel) tools:\n\(toolLines)")
        }

        guard !sections.isEmpty else { return "" }

        return """

        ADDITIONAL APP TOOLS FOR THIS TASK:
        \(sections.joined(separator: "\n\n"))

        RULES:
        - Use these tools (via run_command) to complete the cross-app task.
        - Chain run_command calls: first get data from the current app, then pass it to the target app's tool.
        - After completing, respond with a single clean confirmation line (e.g. "Saved." or "Done — note created in Notes.").
        - Do NOT use AppleScript unless no CLI tool is available for an app.

        """
    }

    private func buildIntelligentL2Prompt(query: String, context: UserContext, frontmostApp: String?) -> String {
        // Check if using on-device AI (has 4096 token limit) - need MUCH shorter prompt
        let isOnDeviceAI = settings.selectedAIProvider == .onDevice
        let queryLower = query.lowercased()
        let isExtensionRequest = queryLower.contains("extension") || queryLower.contains("automation") || queryLower.contains("script")

        if isOnDeviceAI {
            // COMPACT PROMPT for on-device AI (4096 token limit)
            return buildCompactL2Prompt(query: query, context: context, frontmostApp: frontmostApp)
        }

        // FULL PROMPT for cloud AI providers (larger context windows)
        // Get current date and time
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .medium
        let currentDateTime = dateFormatter.string(from: now)

        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now)
        let weekdayName = dateFormatter.weekdaySymbols[weekday - 1]

        var prompt = """
        You are an intelligent assistant integrated into macOS. You have access to system information and can help users with file operations, app context, and more.

        CURRENT DATE & TIME:
        📅 \(currentDateTime) (\(weekdayName))

        IMPORTANT: Use this current date/time to:
        - Filter calendar events correctly (today, tomorrow, this week, this month)
        - Understand relative time queries ("today", "tomorrow", "next Monday")
        - Provide accurate time-based responses

        """

        // Add system capabilities
        prompt += """

        CAPABILITIES:
        - Access to user's file system (read directories, find files, get file info)
        - Context awareness (knows which app is active and what's selected)
        - Can execute shell commands for file operations
        - Can use installed extensions/tools
        - macOS system knowledge
        - Can directly analyze and explain files (images, documents, code, etc.)
        - Access to REAL Calendar events, Reminders, Contacts (ALWAYS available regardless of frontmost app)
        - Full Safari control: search, navigate, bookmark, manage tabs
        - AI-powered intelligent understanding of user intent

        INSTALLED TERMINAL TOOLS:
        \(TerminalToolDiscovery.installedToolsSummary())

        SAFARI CONTROL & ANALYSIS:
        - Save page as PDF: `ilauncher-api safari save-pdf [filename]`
        - Print dialog: `ilauncher-api safari print`
        - Get current page: `ilauncher-api safari current-page`
        - Search/open URL: [EXECUTE_COMMAND: open -a Safari "https://youtube.com"]
        - Google search: [EXECUTE_COMMAND: open -a Safari "https://google.com/search?q=your+query"]
        - Access ALL open tabs and their URLs (provided in context when in Safari)
        - Analyze tab content by titles and URLs
        - Answer questions about tabs ("which tabs are about X?", "how many tabs?")
        - Summarize research across multiple tabs
        - Can execute AppleScript for Safari operations (bookmarks, navigation, tab management)

        IMPORTANT RULES:
        - For simple file questions, answer directly without extensions
        - For Calendar/Reminders/Contacts questions, use the ACTUAL data provided below
        - For Safari PDF save, ACTUALLY DO IT with ilauncher-api command
        - For Safari search/navigate, use [EXECUTE_COMMAND] with appropriate URLs
        - For Safari tab analysis, use the tab data provided in context to answer intelligently
        - Only suggest extensions for complex automation that can't be done with existing APIs
        - When suggesting extensions, provide COMPLETE, WORKING code ready to save and use
        - You are INTELLIGENT - understand user intent and provide the most helpful response

        EXTENSION SUGGESTION CRITERIA:
        - Task requires automation not available via existing APIs
        - Task would be reused frequently (not one-time)
        - Task involves file format conversion, image processing, or complex workflows
        - For PDF save in Safari: Use ilauncher-api, DON'T suggest extension
        - For tab management/analysis: Answer directly with provided data, DON'T suggest extension
        - For recurring workflows: SUGGEST extension with complete code

        """

        if isExtensionRequest {
            prompt += """

            USER EXPLICITLY REQUESTED AN EXTENSION.
            You MUST respond with [SUGGEST_EXTENSION] and include complete, working code.

            """
        }

        // Add available extensions catalog
        let availableExtensions = getAvailableExtensionsForContext(frontmostApp: frontmostApp, context: context)

        if !availableExtensions.isEmpty {
            prompt += """

            AVAILABLE EXTENSIONS/TOOLS:
            You have access to these pre-built extensions that can help complete tasks:

            """

            for (index, ext) in availableExtensions.prefix(10).enumerated() {
                let keywordsList = ext.keywords.isEmpty ? "N/A" : ext.keywords.prefix(5).joined(separator: ", ")
                prompt += """
                \(index + 1). \(ext.name)
                   - Description: \(ext.description)
                   - Keywords: \(keywordsList)
                   - Can do: \(ext.capabilities)
                   - Category: \(ext.category)

                """
            }

            if availableExtensions.count > 10 {
                prompt += "... and \(availableExtensions.count - 10) more extensions available\n"
            }

            prompt += """

            HOW TO USE EXTENSIONS:
            - If the user's request matches an extension, respond with:
              [USE_EXTENSION: extension_name]
            - Example: If user asks "compress these files" and you have an "Archive Tool" extension, respond with:
              "I'll compress your files using the Archive Tool.
              [USE_EXTENSION: Archive Tool]"
            - You can explain what you're doing AND trigger the extension in the same response

            """
        } else {
            // No extensions available, suggest creating one if applicable
            prompt += """

            NOTE: No extensions are currently available for this context.
            You can still help the user by:
            1. Answering their question directly
            2. Suggesting they create an extension if this is a recurring task

            """
        }

        // Add selected text context FIRST (most important for user queries)
        if case .textSelected(let text) = context, !text.isEmpty {
            let preview = text.prefix(2000) // Show more text for better context
            prompt += """

            📝 SELECTED TEXT (User has this text selected/visible):
            ```
            \(preview)
            ```
            """
            if text.count > 2000 {
                prompt += "\n... (truncated, total \(text.count) characters)\n"
            }
            prompt += "\n"
        }

        // UNIVERSAL APP CONTEXT - AI automatically understands any app
        if let appName = frontmostApp, !appName.isEmpty {
            // Get comprehensive context for current app
            // IMPORTANT: Use the app from the context, NOT the current frontmost app (which is ILauncher)
            var targetApp: NSRunningApplication?

            // Extract bundle ID from context
            switch context {
            case .appFocused(_, let bundleID):
                // Find the running app by bundle ID
                targetApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
            default:
                // Fallback: try to find by name
                targetApp = NSWorkspace.shared.runningApplications.first { $0.localizedName == appName }
            }

            // If we found the target app, get its context
            if let app = targetApp {
                let comprehensiveContext = ContextDetector.shared.getComprehensiveContext(frontmostApp: app)

                prompt += """

                ========================================
                FRONTMOST APP: \(appName)
                ========================================

                You are helping the user with \(appName).
                ALL user queries are in the context of \(appName) unless explicitly stated otherwise.

                AUTOMATICALLY AVAILABLE CONTEXT:
                """

                // Add all detected context
                for ctx in comprehensiveContext {
                    switch ctx {
                    case .browserTabs(let tabs):
                        prompt += "\n\n🌐 ALL BROWSER TABS (\(tabs.count) tabs):\n"
                        var currentWindow = 0
                        for (index, tab) in tabs.prefix(50).enumerated() {
                            if tab.windowIndex != currentWindow {
                                currentWindow = tab.windowIndex
                                prompt += "\n--- Window \(currentWindow) ---\n"
                            }
                            prompt += "\(tab.tabIndex). \(tab.title)\n   \(tab.url)\n"
                        }
                        if tabs.count > 50 {
                            prompt += "... and \(tabs.count - 50) more tabs\n"
                        }

                    case .clipboard(let content):
                        let preview = content.prefix(500)
                        prompt += "\n\n📋 CLIPBOARD:\n\(preview)"
                        if content.count > 500 {
                            prompt += "...\n(total: \(content.count) chars)"
                        }

                    case .music(let title, let artist, let album):
                        prompt += "\n\n🎵 CURRENTLY PLAYING:\n"
                        prompt += "Song: \(title)\n"
                        prompt += "Artist: \(artist)\n"
                        prompt += "Album: \(album)\n"

                    case .podcast(let title, let show):
                        prompt += "\n\n🎙️ CURRENTLY PLAYING PODCAST:\n"
                        prompt += "Episode: \(title)\n"
                        prompt += "Show: \(show)\n"

                    case .files(let urls):
                        prompt += "\n\n📁 SELECTED FILES (\(urls.count)):\n"
                        for url in urls.prefix(20) {
                            prompt += "- \(url.lastPathComponent)\n"
                        }

                    case .text(let text):
                        let preview = text.prefix(1000)
                        prompt += "\n\n📝 SELECTED TEXT:\n\(preview)"
                        if text.count > 1000 {
                            prompt += "...\n"
                        }

                    case .browserTab(let url, let title):
                        prompt += "\n\n🌐 CURRENT TAB:\n"
                        prompt += "Title: \(title)\n"
                        prompt += "URL: \(url)\n"

                        // Fetch actual page content for Safari
                        if appName.lowercased() == "safari" {
                            if let pageText = fetchSafariPageText(), !pageText.isEmpty {
                                let preview = pageText.prefix(3000)
                                prompt += "\n📄 PAGE CONTENT:\n```\n\(preview)\n```\n"
                                if pageText.count > 3000 {
                                    prompt += "... (total: \(pageText.count) characters)\n"
                                }
                                prompt += "\n✅ Use this ACTUAL page content to answer questions about what's on the page!\n"
                            }
                        }

                    case .note(let content):
                        let preview = content.prefix(1000)
                        prompt += "\n\n📝 CURRENT NOTE:\n\(preview)"
                        if content.count > 1000 {
                            prompt += "...\n"
                        }

                    case .email(let subject, let from, let content):
                        prompt += "\n\n📧 SELECTED EMAIL:\n"
                        prompt += "Subject: \(subject)\n"
                        prompt += "From: \(from)\n"

                        if !content.isEmpty {
                            let preview = content.prefix(2000)
                            prompt += "\nEmail Content:\n```\n\(preview)\n```\n"
                            if content.count > 2000 {
                                prompt += "... (total: \(content.count) characters)\n"
                            }
                            prompt += "\n✅ Use this ACTUAL email content to answer questions!\n"
                        }

                    case .app:
                        break // Already shown above
                    }
                }
            }

            prompt += "\n\n"

            // Add app-specific capabilities
            switch appName.lowercased() {
            case "finder":
                prompt += """
                - User is in Finder (file manager)
                - User has full access to their file system
                - Can perform: find files, check sizes, list directories, organize files
                - Downloads folder: ~/Downloads
                - Desktop folder: ~/Desktop
                - Documents folder: ~/Documents

                """

                // Get current Finder directory (ALWAYS include this for context)
                if let currentDir = ContextDetector.shared.getCurrentFinderDirectory() {
                    prompt += "\n📂 CURRENT DIRECTORY:\n"
                    prompt += "Path: \(currentDir)\n"
                    prompt += "Folder: \(URL(fileURLWithPath: currentDir).lastPathComponent)\n"
                }

                // Get selected files/folders and analyze them
                let selectedFiles = ContextDetector.shared.getFinderSelectedFiles()
                if !selectedFiles.isEmpty {
                    let fileAnalysis = ContextDetector.shared.analyzeFiles(selectedFiles)

                    prompt += "\n"
                    prompt += "========================================\n"
                    prompt += "📁 SELECTED FILES (\(fileAnalysis.count))\n"
                    prompt += "========================================\n"

                    for (index, file) in fileAnalysis.enumerated() {
                        let fileName = file.url.lastPathComponent
                        prompt += "\n\(index + 1). \(fileName)\n"
                        prompt += "   Type: \(file.type)\n"
                        prompt += "   Size: \(file.size)\n"
                        prompt += "   Path: \(file.url.path)\n"

                        // If it's a text/code file with content, include it
                        if let content = file.content {
                            prompt += "\n   📄 FILE CONTENT:\n"
                            prompt += "   ```\n"
                            let lines = content.components(separatedBy: "\n").prefix(50)
                            prompt += lines.joined(separator: "\n")
                            prompt += "\n   ```\n"

                            // Special note for PDFs
                            if file.type == "pdf" {
                                prompt += "\n   ✅ THIS IS THE ACTUAL PDF CONTENT ABOVE - Use it to answer user questions!\n"
                            }
                        } else {
                            // No content extracted
                            if file.type == "pdf" {
                                prompt += "\n   ⚠️ Could not extract text from this PDF (might be image-based/scanned)\n"
                            }
                        }

                        // Special handling for images
                        if file.isImage {
                            prompt += "\n   📷 This is an image file - you can analyze it visually\n"
                        }
                    }

                    prompt += "\n========================================\n"
                } else {
                    prompt += "\n(No files selected)\n"
                }

                // ALWAYS include instructions for file operations
                prompt += """

                IMPORTANT INSTRUCTIONS FOR FILE OPERATIONS:

                CONTEXT AVAILABLE:
                - Current directory path (where the user is in Finder)
                - Selected files/folders with full paths, types, sizes, and content (if any)
                - For PDFs: Text content has been automatically extracted from the PDF
                - For text/code files: Full content is provided
                - You can reference these paths in your responses and extension scripts

                1. ANALYSIS QUERIES: For questions like "what is this file?", "explain this code", "summarize this PDF", "what is this PDF about?" → Analyze and answer directly using the provided content
                2. ACTION QUERIES: For tasks like "move to Downloads", "copy to folder X", "send via iMessage", "add to Notes" → Suggest creating an extension
                3. DIRECTORY QUERIES: User can ask about current directory, list files, find files, organize files, etc.

                IMPORTANT: When user asks "what is this PDF about?" or similar questions about PDFs, you MUST use the PDF text content provided above to answer. DO NOT say you cannot read PDFs - the content is already extracted and provided!
                IMPORTANT: Do NOT suggest an extension if you can answer directly from this content.

                WHEN TO SUGGEST EXTENSIONS:
                - ONLY when the task cannot be completed directly with the provided context
                - Examples: batch processing, file format conversion, multi-step automation

                HOW TO SUGGEST EXTENSIONS:
                Use this format:
                [SUGGEST_EXTENSION]
                {
                    "name": "Task Name",
                    "description": "What it does",
                    "app": "Finder",
                    "code": "#!/bin/bash\\n# Your working script here\\n# You have access to: SELECTED_FILES (if any) and CURRENT_DIR"
                }
                [/SUGGEST_EXTENSION]

                The extension will be automatically:
                - Added to the Extensions directory
                - Grouped under "Finder" app
                - Immediately executed to complete the user's request

                """

            case "safari":
                prompt += """
                - User is browsing in Safari
                - You can answer questions about the current page and user intent
                - You can reference the current URL/title below

                """

                if let safariContext = ContextDetector.shared.getSafariContext() {
                    prompt += "\n🌐 CURRENT TAB:\n"
                    prompt += "Title: \(safariContext.title)\n"
                    prompt += "URL: \(safariContext.url)\n"
                }

                if let pageText = fetchSafariPageText(), !pageText.isEmpty {
                    let preview = pageText.prefix(2000)
                    prompt += "\n📄 PAGE CONTENT (excerpt):\n"
                    prompt += "```\n\(preview)\n```\n"
                    if pageText.count > 2000 {
                        prompt += "... (truncated, total \(pageText.count) characters)\n"
                    }
                }

                if queryLower.contains("link") || queryLower.contains("social") || queryLower.contains("url") {
                    let links = fetchSafariPageLinks()
                    if !links.isEmpty {
                        prompt += "\n🔗 PAGE LINKS:\n"
                        for link in links.prefix(50) {
                            prompt += "- \(link)\n"
                        }

                        if queryLower.contains("social") {
                            let socialDomains = [
                                "twitter.com", "x.com", "facebook.com", "instagram.com",
                                "linkedin.com", "youtube.com", "tiktok.com", "github.com", "reddit.com"
                            ]
                            let socialLinks = links.filter { link in
                                socialDomains.contains { link.lowercased().contains($0) }
                            }
                            if !socialLinks.isEmpty {
                                prompt += "\n🔗 SOCIAL LINKS:\n"
                                for link in socialLinks.prefix(30) {
                                    prompt += "- \(link)\n"
                                }
                            }
                        }
                    }
                }

            case "calendar":
                prompt += """
                - User is in Calendar app
                - Can help with: event analysis, scheduling, finding free time

                """

                // Detect if query is simple (viewing) or complex (needs extension)
                let isSimpleCalendarQuery = queryLower.contains("show") ||
                                           queryLower.contains("list") ||
                                           queryLower.contains("what") ||
                                           queryLower.contains("today") ||
                                           queryLower.contains("this week") ||
                                           queryLower.contains("this month")

                let isComplexCalendarQuery = queryLower.contains("create") ||
                                            queryLower.contains("add event") ||
                                            queryLower.contains("schedule") ||
                                            queryLower.contains("export") ||
                                            queryLower.contains("sync") ||
                                            queryLower.contains("free time") ||
                                            queryLower.contains("available")

                if isComplexCalendarQuery {
                    prompt += """

                    USER QUERY REQUIRES COMPLEX CALENDAR OPERATIONS.
                    Suggest creating a custom extension for this task.

                    Examples needing extensions:
                    - Creating/modifying events
                    - Finding free time slots
                    - Exporting calendar data
                    - Syncing calendars
                    - Complex filtering by date ranges

                    Use [SUGGEST_EXTENSION] tag with working code.

                    """
                } else if isSimpleCalendarQuery {
                    // Fetch REAL calendar events for viewing
                    let calendarEvents = AppleAppsAPI.shared.getCalendarEvents(limit: 50)
                    if !calendarEvents.isEmpty {
                        prompt += "\n📅 ACTUAL CALENDAR EVENTS (Current Month):\n"

                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "MMM d, yyyy h:mm a"

                        for event in calendarEvents {
                            if let title = event["title"] as? String,
                               let startDateStr = event["startDate"] as? String,
                               let startDate = ISO8601DateFormatter().date(from: startDateStr) {
                                let formattedDate = dateFormatter.string(from: startDate)
                                let isAllDay = event["isAllDay"] as? Bool ?? false
                                let location = event["location"] as? String ?? ""

                                prompt += "- \(title)"
                                prompt += " on \(formattedDate)"
                                if isAllDay { prompt += " (All Day)" }
                                if !location.isEmpty { prompt += " at \(location)" }
                                prompt += "\n"
                            }
                        }
                        prompt += "\nIMPORTANT: Use this ACTUAL calendar data to answer questions. Don't make up generic holidays.\n"
                    } else {
                        prompt += "\nNo upcoming calendar events found.\n"
                    }
                }

            case "notes":
                prompt += """
                - User is in Notes app
                - Can help with: note content, summarization, organization

                """

            case "mail":
                prompt += """
                - User is in Mail app
                - Can help with: email analysis, drafting replies, organizing

                """

                // Detect if query is simple (just viewing) or complex (filtering, searching, organizing)
                let queryLower = query.lowercased()
                let isSimpleQuery = queryLower.contains("today") ||
                                   queryLower.contains("unread") ||
                                   (queryLower.contains("show") && queryLower.contains("mail"))

                let isComplexQuery = queryLower.contains("from ") ||
                                     queryLower.contains("search") ||
                                     queryLower.contains("filter") ||
                                     queryLower.contains("find") ||
                                     queryLower.contains("attach") ||
                                     queryLower.contains("export") ||
                                     queryLower.contains("save") ||
                                     queryLower.contains("subject:") ||
                                     queryLower.contains("organize")

                if isComplexQuery {
                    // For complex queries, suggest creating an extension
                    prompt += """

                    USER QUERY REQUIRES COMPLEX MAIL OPERATIONS.
                    You should suggest creating a custom extension for this task.

                    Examples of complex mail tasks that need extensions:
                    - Search emails by sender, subject, or date range
                    - Filter emails with attachments
                    - Export emails to files
                    - Organize emails into folders
                    - Batch operations on multiple emails

                    When suggesting extension, use [SUGGEST_EXTENSION] tag and provide working AppleScript code.

                    """
                } else if isSimpleQuery {
                    // For simple viewing queries, provide actual data
                    let mailScript = """
                    tell application "Mail"
                        set todayStart to (current date) - (time of (current date))
                        set todayEnd to todayStart + (24 * 60 * 60)

                        set todayMessages to {}
                        set unreadMessages to {}

                        repeat with msg in (messages of inbox)
                            if date received of msg ≥ todayStart and date received of msg < todayEnd then
                                set msgInfo to {subject:(subject of msg), sender:(sender of msg), dateReceived:(date received of msg as text), isRead:(read status of msg)}
                                set end of todayMessages to msgInfo
                            end if

                            if read status of msg is false then
                                set msgInfo to {subject:(subject of msg), sender:(sender of msg), dateReceived:(date received of msg as text)}
                                set end of unreadMessages to msgInfo
                                if (count of unreadMessages) ≥ 20 then exit repeat
                            end if
                        end repeat

                        set AppleScript's text item delimiters to "SECTION_SEP"
                        set output to ""

                        -- Today's emails
                        set output to output & "TODAY:" & return
                        repeat with msg in todayMessages
                            set output to output & "- " & (subject of msg) & " | From: " & (sender of msg) & " | " & (dateReceived of msg) & " | Read: " & (isRead of msg) & return
                        end repeat

                        set output to output & "SECTION_SEP"

                        -- Unread emails
                        set output to output & "UNREAD:" & return
                        repeat with msg in unreadMessages
                            set output to output & "- " & (subject of msg) & " | From: " & (sender of msg) & " | " & (dateReceived of msg) & return
                        end repeat

                        return output
                    end tell
                    """

                    if let result = runAppleScript(mailScript), !result.isEmpty {
                        let sections = result.components(separatedBy: "SECTION_SEP")

                        if sections.count >= 2 {
                            let todaySection = sections[0]
                            let unreadSection = sections[1]

                            prompt += "\n📧 ACTUAL MAIL DATA:\n"
                            prompt += todaySection
                            prompt += "\n"
                            prompt += unreadSection
                            prompt += "\nIMPORTANT: Use this ACTUAL mail data to answer. Don't provide generic explanations.\n"
                        }
                    }
                }

            case "safari", "chrome", "arc":
                prompt += """
                - User is in \(appName) browser
                - FULL BROWSER CONTROL available

                """

                // Detect user intent for Safari operations
                let queryLower = query.lowercased()

                // Check if user wants to search/navigate
                let isSearchQuery = queryLower.contains("search") ||
                                   queryLower.contains("youtube") ||
                                   queryLower.contains("google") ||
                                   queryLower.contains("open") ||
                                   queryLower.contains("go to") ||
                                   queryLower.contains("navigate")

                let isBookmarkQuery = queryLower.contains("bookmark")

                // Detect PDF save requests (should use API, not extension)
                let isPDFSaveQuery = (queryLower.contains("save") || queryLower.contains("export")) &&
                                     (queryLower.contains("pdf") || queryLower.contains("page"))

                // Detect tab queries (should answer with data, not extension)
                let isTabQuery = queryLower.contains("tab") &&
                                (queryLower.contains("list") || queryLower.contains("show") ||
                                 queryLower.contains("how many") || queryLower.contains("which") ||
                                 queryLower.contains("what") || queryLower.contains("find") ||
                                 queryLower.contains("about") || queryLower.contains("opened") ||
                                 queryLower.contains("open") || queryLower.contains("count"))

                let isComplexBrowserQuery = !isPDFSaveQuery &&
                                           !isTabQuery &&
                                           (queryLower.contains("save") ||
                                           queryLower.contains("export") ||
                                           queryLower.contains("close") ||
                                           queryLower.contains("organize") ||
                                           queryLower.contains("group") ||
                                           queryLower.contains("screenshot"))

                if isTabQuery {
                    prompt += """

                    TAB QUERY DETECTED:
                    The user is asking about Safari tabs. ALL tab data is provided below.
                    Analyze the tabs and answer intelligently:
                    - Count tabs if asked "how many tabs"
                    - List specific tabs if asked "show tabs about X"
                    - Summarize research if asked about topics across tabs
                    - Find tabs matching criteria

                    DO NOT suggest creating an extension - ANSWER WITH THE DATA PROVIDED!

                    """
                } else if isSearchQuery {
                    prompt += """

                    SAFARI SEARCH/NAVIGATION COMMANDS:
                    - To open YouTube: [EXECUTE_COMMAND: open -a Safari "https://youtube.com"]
                    - To search on Google: [EXECUTE_COMMAND: open -a Safari "https://google.com/search?q=SEARCH_TERM"]
                    - To search YouTube: [EXECUTE_COMMAND: open -a Safari "https://youtube.com/results?search_query=SEARCH_TERM"]
                    - To open any URL: [EXECUTE_COMMAND: open -a Safari "https://example.com"]

                    IMPORTANT: Understand user intent intelligently:
                    - "youtube" → open YouTube homepage
                    - "search for cats on youtube" → open YouTube search for cats
                    - "google python tutorial" → Google search for python tutorial
                    - Replace spaces in search terms with + symbols

                    """
                } else if isBookmarkQuery {
                    prompt += """

                    BOOKMARK OPERATIONS:
                    Create an extension using AppleScript to add current tab to bookmarks:
                    tell application "Safari"
                        add current tab of front window to bookmarks
                    end tell

                    Use [SUGGEST_EXTENSION] tag with complete code.

                    """
                } else if isComplexBrowserQuery {
                    prompt += """

                    COMPLEX BROWSER OPERATIONS - Suggest Extension:
                    - Save/export tabs to files
                    - Close tabs matching criteria
                    - Take screenshots of pages
                    - Organize tabs into groups

                    Use [SUGGEST_EXTENSION] tag with working AppleScript code.

                    """
                } else {
                    // For viewing tabs or general browser queries, provide actual URLs from ALL windows
                    if let frontmostApp = NSWorkspace.shared.frontmostApplication {
                        let comprehensiveContext = ContextDetector.shared.getComprehensiveContext(frontmostApp: frontmostApp)

                        // Look for browserTabs or clipboard in comprehensive context
                        for ctx in comprehensiveContext {
                            if case .browserTabs(let tabs) = ctx {
                                prompt += "\n🌐 ALL BROWSER TABS (All Windows):\n"
                                prompt += "Total: \(tabs.count) tabs across multiple windows\n\n"

                                var currentWindow = 0
                                for tab in tabs.prefix(50) { // Limit to 50 tabs to avoid huge prompts
                                    if tab.windowIndex != currentWindow {
                                        currentWindow = tab.windowIndex
                                        prompt += "\n--- Window \(currentWindow) ---\n"
                                    }
                                    prompt += "\(tab.tabIndex). \(tab.title)\n   URL: \(tab.url)\n"
                                }

                                if tabs.count > 50 {
                                    prompt += "\n... and \(tabs.count - 50) more tabs\n"
                                }

                                prompt += "\nYou can:\n"
                                prompt += "- List specific tabs\n"
                                prompt += "- Search for tabs by title or URL\n"
                                prompt += "- Answer questions about tab content\n"
                                prompt += "- Summarize research across tabs\n"
                                break
                            }
                        }

                        // Also include clipboard if available
                        for ctx in comprehensiveContext {
                            if case .clipboard(let content) = ctx {
                                prompt += "\n\n📋 CLIPBOARD CONTENT:\n"
                                let preview = content.prefix(500)
                                prompt += "\(preview)\n"
                                if content.count > 500 {
                                    prompt += "... (clipboard has \(content.count) total characters)\n"
                                }
                                prompt += "\nYou can reference clipboard content in your response.\n"
                                break
                            }
                        }
                    }
                }

            default:
                prompt += "- User is currently in: \(appName)\n"
            }
        }

        // ALWAYS include clipboard if available (for ALL apps, not just browsers)
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            if let clipboard = ContextDetector.shared.getClipboardContent() {
                prompt += "\n📋 CLIPBOARD CONTENT (Always Available):\n"
                let preview = clipboard.prefix(1000)
                prompt += "\(preview)\n"
                if clipboard.count > 1000 {
                    prompt += "... (clipboard has \(clipboard.count) total characters)\n"
                }
                prompt += "\nYou can reference or use clipboard content in your response.\n"
            }

            // Include currently playing music/podcast if available
            if let musicInfo = ContextDetector.shared.getMusicInfo() {
                prompt += "\n🎵 CURRENTLY PLAYING:\n"
                prompt += "Track: \(musicInfo.title)\n"
                prompt += "Artist: \(musicInfo.artist)\n"
                prompt += "Album: \(musicInfo.album)\n"
                prompt += "\nYou can reference this music in your response or help with music-related queries.\n"
            } else if let podcastInfo = ContextDetector.shared.getPodcastInfo() {
                prompt += "\n🎙️ CURRENTLY PLAYING PODCAST:\n"
                prompt += "Episode: \(podcastInfo.title)\n"
                prompt += "Show: \(podcastInfo.show)\n"
                prompt += "\nYou can reference this podcast in your response.\n"
            }
        }

        // ALWAYS provide system data (Calendar, Reminders, Contacts) - AI can use when relevant
        prompt += "\n=== SYSTEM DATA (Always Available) ===\n"

        // Calendar Events - always fetch
        let calendarEvents = AppleAppsAPI.shared.getCalendarEvents(limit: 30)
        if !calendarEvents.isEmpty {
            prompt += "\n📅 CALENDAR EVENTS (Next 30 days from NOW):\n"
            let eventDateFormatter = DateFormatter()
            eventDateFormatter.dateFormat = "MMM d, yyyy h:mm a"

            let relativeDateFormatter = RelativeDateTimeFormatter()
            relativeDateFormatter.unitsStyle = .full

            for event in calendarEvents.prefix(15) {
                if let title = event["title"] as? String,
                   let startDateStr = event["startDate"] as? String,
                   let startDate = ISO8601DateFormatter().date(from: startDateStr) {
                    let formattedDate = eventDateFormatter.string(from: startDate)
                    let isAllDay = event["isAllDay"] as? Bool ?? false

                    // Calculate relative time
                    let timeInterval = startDate.timeIntervalSince(now)
                    let relativeTime = relativeDateFormatter.localizedString(for: startDate, relativeTo: now)

                    prompt += "- \(title)\n"
                    prompt += "  Date: \(formattedDate)"
                    if isAllDay { prompt += " (All Day)" }
                    prompt += "\n  Time from now: \(relativeTime)\n"
                }
            }
        } else {
            prompt += "\n📅 CALENDAR: No upcoming events\n"
        }

        // Reminders - always fetch
        let reminders = AppleAppsAPI.shared.getReminders(limit: 15)
        if !reminders.isEmpty {
            prompt += "\n📝 REMINDERS:\n"
            let reminderDateFormatter = DateFormatter()
            reminderDateFormatter.dateStyle = .medium
            reminderDateFormatter.timeStyle = .short

            let relativeDateFormatter = RelativeDateTimeFormatter()
            relativeDateFormatter.unitsStyle = .full

            for reminder in reminders.prefix(10) {
                if let title = reminder["title"] as? String {
                    prompt += "- \(title)"
                    if let dueDateStr = reminder["dueDate"] as? String,
                       let dueDate = ISO8601DateFormatter().date(from: dueDateStr) {
                        let formattedDate = reminderDateFormatter.string(from: dueDate)
                        let relativeTime = relativeDateFormatter.localizedString(for: dueDate, relativeTo: now)

                        // Check if overdue
                        let isOverdue = dueDate < now
                        if isOverdue {
                            prompt += " ⚠️ OVERDUE"
                        }
                        prompt += "\n  Due: \(formattedDate) (\(relativeTime))"
                    }
                    prompt += "\n"
                }
            }
        } else {
            prompt += "\n📝 REMINDERS: No active reminders\n"
        }

        // Contacts - provide count, AI can ask for specific searches
        prompt += "\n👥 CONTACTS: Available (you can search by name if user asks)\n"

        prompt += "\nIMPORTANT: This system data is ALWAYS available. Use it intelligently when relevant to user's query.\n"
        prompt += "========================================\n"

        // Add selected files context
        if case .filesSelected(let urls) = context, !urls.isEmpty {
            prompt += "\nSELECTED FILES:\n"
            for url in urls.prefix(10) {
                prompt += "- \(url.lastPathComponent) (\(url.pathExtension))\n"
            }
            if urls.count > 10 {
                prompt += "... and \(urls.count - 10) more files\n"
            }

            let fileAnalysis = ContextDetector.shared.analyzeFiles(urls)
            if !fileAnalysis.isEmpty {
                prompt += "\nSELECTED FILE DETAILS:\n"
                for (index, file) in fileAnalysis.prefix(3).enumerated() {
                    prompt += "\n\(index + 1). \(file.url.lastPathComponent)\n"
                    prompt += "Type: \(file.type)\n"
                    prompt += "Size: \(file.size)\n"
                    if let content = file.content, !content.isEmpty {
                        let preview = content.prefix(3000)
                        prompt += "Content:\n```\n\(preview)\n```\n"
                        if content.count > 3000 {
                            prompt += "... (truncated)\n"
                        }
                        if file.type == "pdf" {
                            prompt += "✅ PDF text extracted above. Use it to summarize.\n"
                        }
                    } else if file.type == "pdf" {
                        prompt += "⚠️ PDF text could not be extracted (image-based PDF).\n"
                    }
                }
            }
        }

        prompt += """

        USER REQUEST:
        \(query)

        ========================================
        INTELLIGENCE RULES - READ CAREFULLY
        ========================================

        YOU ARE CONTEXT-AWARE:
        - The user is in \(frontmostApp ?? "an app")
        - ALL their questions relate to this app unless explicitly stated
        - ALL context provided above is AUTOMATICALLY AVAILABLE to you
        - You DON'T need to ask for context - it's already provided

        AUTOMATIC UNDERSTANDING:
        - SELECTED TEXT (ANY APP): If user has text selected → Use SELECTED TEXT provided above
        - Safari/Browser: Questions about page content → Use PAGE CONTENT provided above
        - Safari/Browser: Questions about tabs → Use tab data provided above
        - Finder: Questions about files → Use the file/directory data provided
        - Mail: Questions about emails → Use email context if provided
        - Calendar: Questions about events → Use calendar data provided
        - ANY APP: Answer based on automatically detected context

        FOR SELECTED TEXT QUESTIONS (HIGHEST PRIORITY):
        - If SELECTED TEXT is provided, user's questions are about THAT TEXT
        - "summarize this" → Summarize the SELECTED TEXT
        - "explain this" → Explain the SELECTED TEXT
        - "translate this" → Translate the SELECTED TEXT
        - "what does this mean" → Explain the SELECTED TEXT meaning
        - The SELECTED TEXT section is shown at the TOP - it's the most important context!
        - Works in Safari, TextEdit, Notes, Mail, or ANY app where text is selected

        FOR MAIL APP QUESTIONS:
        - "summarize this email" → Summarize the EMAIL CONTENT provided
        - "what is this about" → Explain based on EMAIL CONTENT
        - "reply to this" → Draft reply based on EMAIL CONTENT
        - "who sent this" → Use the From field provided
        - The EMAIL CONTENT section contains the ACTUAL email text
        - DON'T say "I can't see the email" - the content is RIGHT THERE!

        FOR SAFARI PAGE CONTENT QUESTIONS:
        - "explain about X on this page" → Read and analyze the PAGE CONTENT provided
        - "what apps are shown" → Look in PAGE CONTENT for app names
        - "summarize this page" → Summarize the PAGE CONTENT provided
        - The PAGE CONTENT section contains the ACTUAL text from the webpage
        - DON'T say "I can't see the page" - the content is RIGHT THERE in the context!

        FOR PDF SAVE IN SAFARI:
        - Immediately execute: ilauncher-api safari save-pdf
        - DON'T suggest creating extension
        - DON'T explain how to do it manually
        - JUST DO IT!

        FOR TAB QUESTIONS IN SAFARI:
        - Answer using the tab data already provided above
        - Count tabs, filter tabs, summarize tabs
        - DON'T suggest creating extension
        - JUST ANSWER with the data!

        FOR FILE QUESTIONS IN FINDER:
        - Answer using the file/directory data provided above
        - List files, find files, analyze files
        - DON'T suggest extension for simple queries
        - JUST ANSWER with the data!

        RESPONSE GUIDELINES:
        1. If you can answer with the provided context → Answer directly (no extension)
        2. If an extension is required to complete the task → Use it with [USE_EXTENSION: name]
        3. If the task cannot be completed by AI or existing APIs → Suggest a custom extension

        WHEN TO SUGGEST EXTENSIONS:
        - ONLY when the task cannot be completed with the provided context or built-in APIs
        - Examples: batch automation, file transformations, app automation not already supported

        HOW TO SUGGEST EXTENSIONS:
        - Add [SUGGEST_EXTENSION] tag in your response
        - Provide complete, working extension code
        - Use this format:

        ```bash
        #!/bin/bash
        # Extension: [Name]
        # Description: [What it does]
        # Trigger: keyword
        # Layer: l2_context

        [Your working code here]
        ```

        - Make code simple, well-commented, and copy-paste ready
        - Include example usage
        - Explain where to save the file

        IMPORTANT:
        - For file operations: Provide ACTUAL RESULTS (run commands if needed)
        - For simple questions (like "what is X?"): Give direct, comprehensive answers
        - Do NOT suggest extensions when you can answer directly
        - Only include code blocks when using [SUGGEST_EXTENSION]
        - Always be actionable and helpful
        """

        // For Finder queries, actually execute and add results to prompt
        if let appName = frontmostApp, appName.lowercased() == "finder" {
            if let fileResults = executeFinderQuery(query) {
                prompt += """

                ACTUAL FILE SYSTEM RESULTS:
                \(fileResults)

                Now provide a helpful summary of these results to the user.
                """
            }
        }

        // Inject user-configured app-specific tool extensions into L2 prompt
        let l2AppKey = activeSmartQueryKey ?? settings.autoDetectedAppKey
            ?? frontmostApp.flatMap { settings.appKey(forBundleID: frontmostAppBundleID, appName: $0) }
        if let key = l2AppKey {
            let relevantTools = settings.topExtensions(for: key, query: query, maxCount: 4)
            if !relevantTools.isEmpty {
                let pkgs = TerminalPackageManager.shared.packages
                let toolSnippet = relevantTools.map { ext -> String in
                    let pkg = pkgs.first(where: { $0.command == ext.toolName })
                    var line = "- \(ext.toolName)"
                    if let path = pkg?.installedPath ?? (ext.toolPath.isEmpty ? nil : ext.toolPath) { line += " (\(path))" }
                    let hint = ext.effectiveHint
                    if !hint.isEmpty { line += ": " + String(hint.prefix(300)) }
                    else if let ht = pkg?.helpText, !ht.isEmpty { line += ": " + String(ht.prefix(300)) }
                    return line
                }.joined(separator: "\n")
                prompt += """

                APP CONTEXT [\(key)] — USER-CONFIGURED TOOLS:
                \(toolSnippet)
                Use these tools via run_command when they match the user's request.
                """
            }
        }

        // ── Cross-app shortcut catalog ──────────────────────────────────────────
        // Inject ALL user-defined scriptable shortcuts across ALL app panels so the
        // AI can chain tools from different apps (e.g. Safari URL → Notes → Mail).
        let crossAppSection = buildCrossAppShortcutsSection()
        if !crossAppSection.isEmpty {
            prompt += crossAppSection
        }

        return prompt
    }

    /// Builds a cross-app tool catalog from all user-defined scriptable shortcuts.
    /// Writes multi-line JXA/AppleScript scripts to /tmp/ilauncher_tools/ so the AI
    /// can call them via run_command. Single-line scripts are inlined.
    private func buildCrossAppShortcutsSection() -> String {
        // Gather all scriptable shortcuts grouped by appKey
        let scriptable = settings.appShortcuts.filter {
            $0.actionType == .jxa || $0.actionType == .appleScript || $0.actionType == .shellCommand
        }
        guard !scriptable.isEmpty else { return "" }

        // Create temp tools directory
        let toolsDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ilauncher_tools")
        try? FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)

        // Group by appKey
        var byApp: [String: [AppShortcut]] = [:]
        for sc in scriptable {
            byApp[sc.appKey, default: []].append(sc)
        }

        var section = "\n=== CROSS-APP TOOLS (User-Defined) ===\n"
        section += "You can chain these tools across apps to complete multi-step tasks.\n"
        section += "Use run_command to execute them. See instructions per tool below.\n\n"

        for (appKey, shortcuts) in byApp.sorted(by: { $0.key < $1.key }) {
            let appDisplay = appKey.capitalized
            section += "── \(appDisplay) ──\n"

            for sc in shortcuts {
                let safeName = sc.name.lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                    .filter { $0.isLetter || $0.isNumber || $0 == "_" }
                let toolID = "\(appKey)_\(safeName)"

                switch sc.actionType {
                case .jxa:
                    let code = sc.actionValue
                    let isMultiLine = code.contains("\n") || code.count > 120
                    if isMultiLine {
                        let filePath = toolsDir.appendingPathComponent("\(toolID).js").path
                        try? code.write(toFile: filePath, atomically: true, encoding: .utf8)
                        section += "  • \(sc.name) → run_command: osascript -l JavaScript \"\(filePath)\"\n"
                    } else {
                        let escaped = code.replacingOccurrences(of: "\"", with: "\\\"")
                        section += "  • \(sc.name) → run_command: osascript -l JavaScript -e \"\(escaped)\"\n"
                    }

                case .appleScript:
                    let code = sc.actionValue
                    let isMultiLine = code.contains("\n") || code.count > 120
                    if isMultiLine {
                        let filePath = toolsDir.appendingPathComponent("\(toolID).scpt").path
                        try? code.write(toFile: filePath, atomically: true, encoding: .utf8)
                        section += "  • \(sc.name) → run_command: osascript \"\(filePath)\"\n"
                    } else {
                        let escaped = code.replacingOccurrences(of: "\"", with: "\\\"")
                        section += "  • \(sc.name) → run_command: osascript -e \"\(escaped)\"\n"
                    }

                case .shellCommand:
                    // Pass $CURRENT_FILE and $SELECTED_TEXT as env vars if needed
                    let cmd = sc.actionValue
                    section += "  • \(sc.name) → run_command: \(cmd)\n"

                default:
                    break
                }
            }
            section += "\n"
        }

        section += """
        CROSS-APP CHAINING RULES:
        - To do multi-step tasks (e.g. "save Safari URL to Notes"), chain run_command calls:
          1. First run_command to get data from app A (e.g. Safari URL via osascript)
          2. Use the output in the next run_command to write to app B (e.g. Notes)
        - Variables: capture stdout from step N, pass as arg to step N+1
        - For AppleScript output: wrap with 'result=$(osascript -e ...)' then use $result
        ===================================\n
        """

        return section
    }

    private func executeFinderQuery(_ query: String) -> String? {
        let lowerQuery = query.lowercased()

        // Detect what user wants to find
        let targetPath: String
        if lowerQuery.contains("downloads") {
            targetPath = NSHomeDirectory() + "/Downloads"
        } else if lowerQuery.contains("desktop") {
            targetPath = NSHomeDirectory() + "/Desktop"
        } else if lowerQuery.contains("documents") {
            targetPath = NSHomeDirectory() + "/Documents"
        } else {
            return nil
        }

        // Detect file size criteria
        let sizeCriteria: String
        if lowerQuery.contains("large") || lowerQuery.contains("big") {
            sizeCriteria = "+10M" // Files larger than 10MB
        } else if lowerQuery.contains("huge") || lowerQuery.contains("largest") {
            sizeCriteria = "+100M" // Files larger than 100MB
        } else {
            return nil
        }

        // Execute find command
        let findCommand = "find \"\(targetPath)\" -type f -size \(sizeCriteria) -exec ls -lh {} \\; 2>/dev/null | head -20"
        print("🔍 [L2] Executing: \(findCommand)")

        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", findCommand]

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                // Parse ls output to extract file names and sizes
                let lines = output.components(separatedBy: "\n")
                    .filter { !$0.isEmpty }
                    .prefix(20)

                var results = "Found \(lines.count) large files in \(targetPath):\n\n"
                for line in lines {
                    // Parse ls -lh output: extract size and filename
                    let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if components.count >= 9 {
                        let size = components[4]
                        let filename = components[8...].joined(separator: " ")
                        results += "• \(filename) (\(size))\n"
                    }
                }
                return results
            }
        } catch {
            print("❌ [L2] Failed to execute find command: \(error)")
        }

        return nil
    }

    // MARK: - AI Response Parsing & Execution

    enum L2Action {
        case useExtension(String)
        case executeCommand(String)
        case terminalCommand(command: String, purpose: String)  // AI terminal automation
        case suggestExtension(code: String, explanation: String)
        case createAndExecuteExtension(name: String, description: String, app: String, code: String)
        case directAnswer(String)
    }

    private func parseL2AIResponse(_ response: String) -> L2Action {
        print("🔍 [L2] Parsing AI response...")

        // Check if AI wants to use an extension
        if let range = response.range(of: #"\[USE_EXTENSION:\s*([^\]]+)\]"#, options: .regularExpression) {
            let matched = String(response[range])
            // Extract extension name between brackets
            let extensionName = matched
                .replacingOccurrences(of: "[USE_EXTENSION:", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            print("✅ [L2] AI wants to use extension: \(extensionName)")
            return .useExtension(extensionName)
        }

        // Check if AI is suggesting extension creation (explicit tag)
        if response.contains("[SUGGEST_EXTENSION]") {
            print("💡 [L2] AI is suggesting an extension (explicit tag)")

            // Try to parse JSON format first
            if let jsonStart = response.range(of: "\\{[\\s\\S]*?\\}", options: .regularExpression) {
                let jsonString = String(response[jsonStart])
                if let jsonData = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String],
                   let name = json["name"],
                   let description = json["description"],
                   let app = json["app"],
                   let code = json["code"] {
                    print("✅ [L2] Parsed JSON extension suggestion")
                    return .createAndExecuteExtension(name: name, description: description, app: app, code: code)
                }
            }

            // Fallback to old code block parsing
            let codePattern = "```(?:bash|python|javascript|applescript)?\\n([\\s\\S]*?)```"
            if let codeRange = response.range(of: codePattern, options: .regularExpression) {
                let codeBlock = String(response[codeRange])
                // Remove markdown code fence
                let code = codeBlock
                    .replacingOccurrences(of: "```bash\n", with: "")
                    .replacingOccurrences(of: "```python\n", with: "")
                    .replacingOccurrences(of: "```javascript\n", with: "")
                    .replacingOccurrences(of: "```applescript\n", with: "")
                    .replacingOccurrences(of: "```sh\n", with: "")
                    .replacingOccurrences(of: "```\n", with: "")
                    .replacingOccurrences(of: "\n```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Extract explanation (everything before code block)
                let explanation = response.components(separatedBy: "```").first ?? response

                return .suggestExtension(code: code, explanation: explanation)
            }
        }

        // Check if AI wants to run a terminal command (new format with purpose)
        if let commandRange = response.range(of: #"\[TERMINAL_COMMAND:\s*([^\]]+)\]"#, options: .regularExpression) {
            let commandMatched = String(response[commandRange])
            let command = commandMatched
                .replacingOccurrences(of: "[TERMINAL_COMMAND:", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract purpose if available
            var purpose = "Execute terminal command"
            if let purposeRange = response.range(of: #"\[COMMAND_PURPOSE:\s*([^\]]+)\]"#, options: .regularExpression) {
                let purposeMatched = String(response[purposeRange])
                purpose = purposeMatched
                    .replacingOccurrences(of: "[COMMAND_PURPOSE:", with: "")
                    .replacingOccurrences(of: "]", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            print("✅ [L2] AI wants to run terminal command: \(command)")
            print("   Purpose: \(purpose)")
            return .terminalCommand(command: command, purpose: purpose)
        }

        // Check if AI wants to execute a command (legacy format)
        if let range = response.range(of: #"\[EXECUTE_COMMAND:\s*([^\]]+)\]"#, options: .regularExpression) {
            let matched = String(response[range])
            let command = matched
                .replacingOccurrences(of: "[EXECUTE_COMMAND:", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            print("✅ [L2] AI wants to execute command: \(command)")
            return .executeCommand(command)
        }

        // Otherwise, it's a direct answer
        print("💬 [L2] Direct answer from AI")
        return .directAnswer(response)
    }

    private func handleL2AIResponse(_ response: String) async {
        let action = parseL2AIResponse(response)

        switch action {
        case .useExtension(let extensionName):
            print("🔧 [L2] Executing extension: \(extensionName)")

            // Find the extension
            if let ext = findExtension(named: extensionName) {
                if let query = originalUserQuery, !shouldAutoRunL2Extension(query: query, ext: ext) {
                    await MainActor.run {
                        var cleanedResponse = response
                        if let range = response.range(of: #"\[USE_EXTENSION:[^\]]+\]"#, options: .regularExpression) {
                            cleanedResponse.removeSubrange(range)
                        }

                        let message = AIChatMessage(
                            role: .assistant,
                            content: cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        l2ChatMessages.append(message)
                        l2IsLoading = false
                    }
                    return
                }
                print("✅ [L2] Found extension: \(ext.name)")

                // Show initial message
                await MainActor.run {
                    // Remove the [USE_EXTENSION: ...] tag from display
                    var cleanedResponse = response
                    if let range = response.range(of: #"\[USE_EXTENSION:[^\]]+\]"#, options: .regularExpression) {
                        cleanedResponse.removeSubrange(range)
                    }

                    let message = AIChatMessage(
                        role: .assistant,
                        content: cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    if l2ChatMessages.last?.role != .assistant {
                        l2ChatMessages.append(message)
                    } else {
                        // Update last message if it's already there
                        l2ChatMessages[l2ChatMessages.count - 1] = message
                    }
                }

                // Execute the extension and get results
                let inputFiles: [URL]
                if case .filesSelected(let urls) = currentContext {
                    inputFiles = urls
                } else {
                    inputFiles = []
                }

                do {
                    let output = try await LayeredExtensionManager.shared.execute(extension: ext, with: inputFiles)

                    await MainActor.run {
                        // Update L2 results panel
                        updateL2Results(buildL2OutputResults(title: ext.name, output: output))

                        // Also add results to chat
                        let resultMessage = AIChatMessage(
                            role: .assistant,
                            content: "📋 Results:\n\(output)"
                        )
                        l2ChatMessages.append(resultMessage)
                        l2IsLoading = false
                    }
                } catch {
                    await MainActor.run {
                        let errorMessage = AIChatMessage(
                            role: .assistant,
                            content: "❌ Failed to execute extension: \(error.localizedDescription)",
                            isError: true
                        )
                        l2ChatMessages.append(errorMessage)
                        l2IsLoading = false
                    }
                }
            } else {
                print("❌ [L2] Extension '\(extensionName)' not found")
                await MainActor.run {
                    let errorMessage = AIChatMessage(
                        role: .assistant,
                        content: "Sorry, I couldn't find the '\(extensionName)' extension.",
                        isError: true
                    )
                    l2ChatMessages.append(errorMessage)
                    l2IsLoading = false
                }
            }

        case .executeCommand(let command):
            print("⚙️ [L2] Executing shell command: \(command)")

            // Execute command safely
            let result = await executeShellCommandSafely(command)

            await MainActor.run {
                // Remove the [EXECUTE_COMMAND: ...] tag from display
                var cleanedResponse = response
                if let range = response.range(of: #"\[EXECUTE_COMMAND:[^\]]+\]"#, options: .regularExpression) {
                    cleanedResponse.removeSubrange(range)
                }

                let finalMessage = """
                \(cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines))

                Result:
                \(result)
                """

                let message = AIChatMessage(role: .assistant, content: finalMessage)
                l2ChatMessages.append(message)
                l2IsLoading = false
            }

        case .terminalCommand(let command, let purpose):
            print("🖥️ [L2] Processing terminal command: \(command)")
            print("   Purpose: \(purpose)")

            // Classify the command
            let classification = TerminalCommandClassifier.shared.classify(command)

            // Clean response for display
            var cleanedResponse = response
            if let range = response.range(of: #"\[TERMINAL_COMMAND:[^\]]+\]"#, options: .regularExpression) {
                cleanedResponse.removeSubrange(range)
            }
            if let range = cleanedResponse.range(of: #"\[COMMAND_PURPOSE:[^\]]+\]"#, options: .regularExpression) {
                cleanedResponse.removeSubrange(range)
            }
            if let range = cleanedResponse.range(of: #"\[COMMAND_CATEGORY:[^\]]+\]"#, options: .regularExpression) {
                cleanedResponse.removeSubrange(range)
            }

            // Show AI explanation in chat
            await MainActor.run {
                let explanationMessage = AIChatMessage(
                    role: .assistant,
                    content: cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                l2ChatMessages.append(explanationMessage)
            }

            // Check if command is blocked
            if classification.riskLevel == .critical {
                await MainActor.run {
                    var blockedMessage = "⛔ Command blocked for safety: \(classification.blockedReason ?? "Security risk")"
                    if let alternative = classification.suggestedAlternative {
                        blockedMessage += "\n\n💡 Alternative: \(alternative)"
                    }
                    let message = AIChatMessage(role: .assistant, content: blockedMessage, isError: true)
                    l2ChatMessages.append(message)
                    l2IsLoading = false
                }
                return
            }

            let lowerExplanation = cleanedResponse.lowercased()
            let needsConfirmation = lowerExplanation.contains("would you like") ||
                lowerExplanation.contains("should i") ||
                lowerExplanation.contains("do you want") ||
                command.contains("<") ||
                command.contains("{")

            if needsConfirmation {
                await MainActor.run {
                    pendingTerminalCommand = PendingTerminalCommand(command: command, purpose: purpose)
                    let promptMessage = AIChatMessage(
                        role: .assistant,
                        content: "Reply \"yes\" to run that command, or \"no\" to cancel."
                    )
                    l2ChatMessages.append(promptMessage)
                    l2IsLoading = false
                }
                return
            }

            // Process through terminal AI bridge
            let (success, output) = await TerminalAIBridge.shared.processAICommand(command, purpose: purpose)

            await MainActor.run {
                let resultIcon = success ? "✅" : "❌"
                let resultMessage = AIChatMessage(
                    role: .assistant,
                    content: "\(resultIcon) Command Result:\n```\n\(output)\n```"
                )
                l2ChatMessages.append(resultMessage)
                l2IsLoading = false
            }

        case .suggestExtension(let code, let explanation):
            print("💡 [L2] Showing extension suggestion")
            await MainActor.run {
                // Show explanation and code with action button
                let suggestedExtensionMessage = """
                \(explanation.trimmingCharacters(in: .whitespacesAndNewlines))

                📦 Extension Code:
                ```
                \(code)
                ```

                💾 Click "Add to Extensions" below to install and use it immediately!
                """

                let message = AIChatMessage(role: .assistant, content: suggestedExtensionMessage, hasInstallButton: true)
                l2ChatMessages.append(message)

                // Store the code for installation
                suggestedExtensionCode = code

                l2IsLoading = false
            }

        case .createAndExecuteExtension(let name, let description, let app, let code):
            print("🚀 [L2] Creating and executing extension: \(name)")
            await MainActor.run {
                // Show creation message
                let creatingMessage = AIChatMessage(
                    role: .assistant,
                    content: "Creating extension '\(name)' for \(app)..."
                )
                l2ChatMessages.append(creatingMessage)
            }

            // Create the extension
            let newExtension = ILExtension(
                name: name,
                description: description,
                layer: .l2_context,
                category: app,
                triggers: [.appContext(app)],
                scriptPath: "", // Will be set by manager
                isBuiltIn: false
            )

            // Save the script content
            let extensionsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ILauncher/Extensions")
            let appGroupDir = extensionsDir.appendingPathComponent(app)

            do {
                // Create app group directory if needed
                try FileManager.default.createDirectory(at: appGroupDir, withIntermediateDirectories: true)

                // Create script file
                let scriptFileName = "\(name.lowercased().replacingOccurrences(of: " ", with: "_")).sh"
                let scriptPath = appGroupDir.appendingPathComponent(scriptFileName)
                try code.write(to: scriptPath, atomically: true, encoding: .utf8)

                // Make executable
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

                // Update extension with actual path
                var ext = newExtension
                ext.scriptPath = scriptPath.path

                // Add to manager
                await MainActor.run {
                    LayeredExtensionManager.shared.addExtension(ext)
                }

                print("✅ [L2] Extension created at: \(scriptPath.path)")

                // Execute the extension immediately
                let inputFiles: [URL]
                if case .filesSelected(let urls) = currentContext {
                    inputFiles = urls
                } else {
                    inputFiles = []
                }

                let output = try await LayeredExtensionManager.shared.execute(extension: ext, with: inputFiles)

                await MainActor.run {
                    // Update message with success
                    let successMessage = AIChatMessage(
                        role: .assistant,
                        content: """
                        ✅ Extension '\(name)' created and executed!

                        📋 Results:
                        \(output)

                        The extension has been saved to your Extensions directory and can be used again anytime.
                        """
                    )
                    l2ChatMessages.append(successMessage)
                    l2IsLoading = false
                }

            } catch {
                print("❌ [L2] Failed to create extension: \(error)")
                await MainActor.run {
                    let errorMessage = AIChatMessage(
                        role: .assistant,
                        content: "❌ Failed to create extension: \(error.localizedDescription)",
                        isError: true
                    )
                    l2ChatMessages.append(errorMessage)
                    l2IsLoading = false
                }
            }

        case .directAnswer(let answer):
            print("💬 [L2] Showing direct answer")
            await MainActor.run {
                let message = AIChatMessage(role: .assistant, content: answer)
                // Only append if not already added
                if l2ChatMessages.last?.content != answer {
                    l2ChatMessages.append(message)
                }
                l2IsLoading = false
            }
        }
    }

    // Store suggested extension code for easy copying
    @State private var suggestedExtensionCode: String? = nil
    @State private var originalUserQuery: String? = nil // Store original query to re-execute

    private func copySuggestedExtension() {
        guard let code = suggestedExtensionCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        // Show confirmation
        let confirmMessage = AIChatMessage(role: .assistant, content: "✅ Extension code copied to clipboard! Save it to ExtensionLibrary/ and make it executable.")
        l2ChatMessages.append(confirmMessage)
    }

    private func installSuggestedExtension() {
        guard let code = suggestedExtensionCode else { return }

        Task {
            do {
                // Extract extension metadata from code comments
                let extensionName = extractExtensionName(from: code)
                let description = extractExtensionDescription(from: code)
                let layer = extractExtensionLayer(from: code)
                await MainActor.run {
                    let scriptType = determineExtensionScriptType(from: code)
                    let category = inferExtensionCategory(layer: layer, appName: frontmostAppName)
                    let triggers = buildExtensionTriggers(layer: layer, appName: frontmostAppName)
                    let ext = ILExtension(
                        name: extensionName,
                        description: description,
                        icon: "sparkles",
                        layer: layer.contains("l1") ? .l1_search : (layer.contains("l3") ? .l3_browser : .l2_context),
                        tags: [.automation],
                        category: category,
                        triggers: triggers,
                        scriptPath: "",
                        scriptContent: code,
                        scriptType: scriptType,
                        isBuiltIn: false
                    )

                    LayeredExtensionManager.shared.addExtension(ext)
                    updateL2ContextExtensions()

                    let successMessage = """
                    ✅ Extension installed successfully!

                    📦 **\(extensionName)**
                    📝 \(description)
                    📂 Saved to: Documents/ILauncher/Extensions

                    The extension has been added and is now available in your Extensions library!
                    """

                    let confirmMessage = AIChatMessage(role: .assistant, content: successMessage)
                    l2ChatMessages.append(confirmMessage)
                }

            } catch {
                await MainActor.run {
                    let errorMessage = AIChatMessage(
                        role: .assistant,
                        content: "❌ Failed to install extension: \(error.localizedDescription)",
                        isError: true
                    )
                    l2ChatMessages.append(errorMessage)
                }
            }
        }
    }

    private func extractExtensionName(from code: String) -> String {
        // Look for "# Extension: Name" in comments
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Extension:") {
                return line.replacingOccurrences(of: "# Extension:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "Custom Extension"
    }

    private func extractExtensionDescription(from code: String) -> String {
        // Look for "# Description: ..." in comments
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Description:") {
                return line.replacingOccurrences(of: "# Description:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "No description provided"
    }

    private func extractExtensionLayer(from code: String) -> String {
        // Look for "# Layer: ..." in comments
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Layer:") {
                return line.replacingOccurrences(of: "# Layer:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "l2_context" // Default to L2
    }

    private func determineExtensionScriptType(from code: String, language: String? = nil) -> ILExtension.ScriptType {
        if code.hasPrefix("#!/bin/bash") || code.hasPrefix("#!/usr/bin/env bash") || code.hasPrefix("#!/bin/sh") || language == "bash" || language == "sh" {
            return .bash
        }
        if code.hasPrefix("#!/usr/bin/env python") || code.hasPrefix("#!/usr/bin/python") || language == "python" {
            return .python
        }
        if code.hasPrefix("#!/usr/bin/osascript") || language == "applescript" {
            return .applescript
        }
        return .bash
    }

    private func inferExtensionCategory(layer: String, appName: String) -> String {
        let normalized = appName.lowercased()
        if layer.contains("l2") {
            if normalized.contains("safari") || normalized.contains("chrome") || normalized.contains("arc") {
                return "browser"
            }
            if normalized.contains("finder") {
                return "finder"
            }
            if normalized.contains("mail") {
                return "mail"
            }
            if normalized.contains("notes") || normalized.contains("textedit") {
                return "text-editor"
            }
            if normalized.contains("xcode") || normalized.contains("vscode") {
                return "code-editor"
            }
        }
        if layer.contains("l3") {
            return "page-enhancers"
        }
        return "custom"
    }

    private func buildExtensionTriggers(layer: String, appName: String) -> [ExtensionTrigger] {
        if layer.contains("l2"), !appName.isEmpty {
            return [.appContext(appName)]
        }
        return [.always]
    }

    private func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            print("❌ Failed to create AppleScript")
            return nil
        }

        let output = scriptObject.executeAndReturnError(&error)

        if let error = error {
            print("❌ AppleScript error: \(error)")
            return nil
        }

        return output.stringValue
    }

    private func executeShellCommandSafely(_ command: String) async -> String {
        // Check if this is an ilauncher-api command - handle it directly
        if command.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ilauncher-api ") {
            print("🔧 [Shell] Detected ilauncher-api command, routing to APICommandHandler")

            // Extract args from command
            let cleanCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let components = cleanCommand.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

            // Remove "ilauncher-api" prefix
            let args = Array(components.dropFirst())

            print("🔧 [Shell] API args: \(args)")

            // Route to API handler
            let result = APICommandHandler.shared.handleCommand(args)
            print("✅ [Shell] API result: \(result)")

            return result
        }

        // Otherwise execute as normal shell command
        let task = Process()
        let pipe = Pipe()

        task.standardOutput = pipe
        task.standardError = pipe
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return "✅ Command executed successfully"
            }
        } catch {
            return "❌ Error: \(error.localizedDescription)"
        }
    }

    private func parseAIAction(_ response: String) -> AIAction? {
        // Legacy - keeping for compatibility
        return nil
    }

    private func executeAIAction(_ action: AIAction) async {
        // Legacy - keeping for compatibility
    }

    enum AIAction {
        case findFiles(path: String, criteria: String)
        case listDirectory(path: String)
        case getFileInfo(path: String)
        case openFile(path: String)
    }

    // MARK: - Extension Catalog for AI

    struct ExtensionInfo {
        let name: String
        let description: String
        let keywords: [String]
        let capabilities: String
        let category: String
    }

    private func getAvailableExtensionsForContext(frontmostApp: String?, context: UserContext) -> [ExtensionInfo] {
        print("📚 [L2] Building extension catalog for AI")

        // Get all context-relevant extensions
        let selectedFiles: [URL] = {
            if case .filesSelected(let urls) = context {
                return urls
            }
            return []
        }()

        let allExtensions = LayeredExtensionManager.shared.discoverExtensions(
            for: "",
            selectedFiles: selectedFiles,
            frontmostApp: frontmostApp,
            layer: .l2_context
        )

        print("📚 [L2] Found \(allExtensions.count) total extensions")

        // Filter context-relevant extensions
        let relevantExtensions = allExtensions.filter { ext in
            ext.ilExtension.triggers.contains { trigger in
                switch trigger {
                case .appContext:
                    return true
                case .fileType:
                    if case .filesSelected = context {
                        return true
                    }
                    return false
                case .keyword:
                    return true
                default:
                    return false
                }
            }
        }

        print("📚 [L2] Filtered to \(relevantExtensions.count) relevant extensions")

        // Convert to simplified info for AI
        let catalog = relevantExtensions.map { ext -> ExtensionInfo in
            let keywords = extractKeywordsFromExtension(ext.ilExtension)
            let capabilities = ext.ilExtension.intents.map { $0.action }.joined(separator: ", ")

            return ExtensionInfo(
                name: ext.ilExtension.name,
                description: ext.ilExtension.description,
                keywords: keywords,
                capabilities: capabilities.isEmpty ? "General actions" : capabilities,
                category: ext.ilExtension.category
            )
        }

        // Log catalog
        for ext in catalog.prefix(5) {
            print("  📦 \(ext.name): \(ext.description)")
        }
        if catalog.count > 5 {
            print("  ... and \(catalog.count - 5) more")
        }

        return catalog
    }

    private func extractKeywordsFromExtension(_ ext: ILExtension) -> [String] {
        var keywords: [String] = []

        for trigger in ext.triggers {
            if case .keyword(let kws) = trigger {
                keywords.append(contentsOf: kws)
            }
        }

        // Also extract from intents
        keywords.append(contentsOf: ext.intents.map { $0.action })
        if let target = ext.intents.first?.target {
            keywords.append(target)
        }

        return Array(Set(keywords)) // Remove duplicates
    }

    private func findExtension(named name: String) -> ILExtension? {
        let allExtensions = LayeredExtensionManager.shared.discoverExtensions(
            for: "",
            selectedFiles: [],
            frontmostApp: frontmostAppName,
            layer: .l2_context
        )

        return allExtensions.first { ext in
            ext.ilExtension.name.lowercased() == name.lowercased() ||
            ext.ilExtension.name.lowercased().contains(name.lowercased())
        }?.ilExtension
    }

    private func executeShortcutWithContext(_ result: SearchResult) {
        let shortcutName = result.title

        print("🎯 [Shortcut Execution] Executing '\(shortcutName)' with context: \(currentContext)")

        // Use Universal Runner v2 system
        Task {
            do {
                let frontmostApp = NSWorkspace.shared.frontmostApplication

                var files: [URL] = []
                var text: String? = nil
                var url: String? = nil

                // Extract context data
                switch currentContext {
                case .filesSelected(let urls):
                    files = urls
                    print("📁 Context: \(urls.count) file(s)")
                    for fileURL in urls {
                        print("   📄 \(fileURL.lastPathComponent)")
                    }

                case .textSelected(let textContent):
                    text = textContent
                    let preview = textContent.prefix(100)
                    print("📝 Context: Text - \"\(preview)\(textContent.count > 100 ? "..." : "")\"")

                    // Check if it's a URL
                    if let urlFromText = URL(string: textContent), urlFromText.scheme != nil {
                        url = textContent
                        print("🌐 Detected as URL: \(textContent)")
                    }

                case .url(let urlString):
                    url = urlString
                    text = urlString
                    print("🌐 Context: URL - \(urlString)")

                case .appFocused(let appName, _):
                    print("🖥️ Context: App focused - \(appName)")

                case .contactSelected:
                    print("👤 Context: Contact selected")

                case .none:
                    print("❌ No context")
                }

                // Execute DIRECTLY with input (no Runner v2 needed!)
                let output: String

                if !files.isEmpty {
                    // Files context - send files directly
                    print("🎯 [Direct Execution] Sending \(files.count) file(s) directly to '\(shortcutName)'")
                    output = try await ShortcutRunner.shared.runDirectly(
                        shortcutName,
                        with: .files(files)
                    )
                } else if let text = text {
                    // Text context - send text directly
                    print("🎯 [Direct Execution] Sending text directly to '\(shortcutName)'")
                    output = try await ShortcutRunner.shared.runDirectly(
                        shortcutName,
                        with: .text(text)
                    )
                } else if let url = url {
                    // URL context - send URL as text directly
                    print("🎯 [Direct Execution] Sending URL directly to '\(shortcutName)'")
                    output = try await ShortcutRunner.shared.runDirectly(
                        shortcutName,
                        with: .url(url)
                    )
                } else {
                    // No context - run shortcut without input
                    print("🎯 [Direct Execution] Running '\(shortcutName)' without input")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                    process.arguments = ["run", shortcutName]

                    let outputPipe = Pipe()
                    process.standardOutput = outputPipe

                    try process.run()
                    process.waitUntilExit()

                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }

                await MainActor.run {
                    print("✅ [ShortcutRunner] Output: \(output)")

                    // Handle output (could be file path, text, or status)
                    if output.starts(with: "/") {
                        // It's a file path - reveal in Finder
                        let fileURL = URL(fileURLWithPath: output)
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } else if !output.isEmpty && output != "OK" {
                        // Show as notification or toast
                        print("📋 Result: \(output)")
                    }

                    // Close launcher
                    onClose()
                }

            } catch ShortcutRunner.RunnerError.runnerNotInstalled {
                await MainActor.run {
                    print("⚠️ ILauncher Runner v2 not installed - falling back to direct execution")
                    // Fallback to old method
                    executeShortcutLegacy(result)
                }

            } catch {
                await MainActor.run {
                    print("❌ Shortcut execution failed: \(error)")
                    onClose()
                }
            }
        }
    }

    // Legacy execution method (fallback)
    private func executeShortcutLegacy(_ result: SearchResult) {
        switch currentContext {
        case .filesSelected(let urls):
            let filePaths = urls.map { $0.path }
            runShortcutWithInputLegacy(name: result.title, input: filePaths)

        case .textSelected(let text):
            runShortcutWithInputLegacy(name: result.title, input: text)

        case .url(let urlString):
            runShortcutWithInputLegacy(name: result.title, input: urlString)

        case .none, .appFocused, .contactSelected:
            result.action()
        }
    }

    private func runShortcutWithInputLegacy(name: String, input: Any) {
        Task {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")

            // Convert input to JSON string
            let inputString: String
            if let textInput = input as? String {
                inputString = textInput
            } else if let arrayInput = input as? [String] {
                // For file arrays, pass as newline-separated list
                inputString = arrayInput.joined(separator: "\n")
            } else {
                print("⚠️ Unsupported input type")
                return
            }

            // Run shortcut with input via stdin
            process.arguments = ["run", name, "--input-path", "-"]

            let inputPipe = Pipe()
            let outputPipe = Pipe()

            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()

                // Write input to stdin
                if let inputData = inputString.data(using: .utf8) {
                    inputPipe.fileHandleForWriting.write(inputData)
                }
                inputPipe.fileHandleForWriting.closeFile()

                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    print("✅ Shortcut '\(name)' completed successfully")
                } else {
                    let errorData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if let errorOutput = String(data: errorData, encoding: .utf8) {
                        print("❌ Shortcut '\(name)' failed: \(errorOutput)")
                    }
                }
            } catch {
                print("❌ Failed to run shortcut '\(name)': \(error)")
            }
        }
    }
    
    func handleDirectInput() {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)

        // Check if it's a URL
        if let url = URL(string: trimmed), url.scheme != nil {
            NSWorkspace.shared.open(url)
            searchText = ""
            onClose()
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            // Try as a URL with https://
            if let url = URL(string: "https://\(trimmed)") {
                NSWorkspace.shared.open(url)
                searchText = ""
                onClose()
            } else {
                // Not a valid URL, perform web search
                performWebSearch(query: trimmed)
            }
        } else {
            // Perform inline web search
            performWebSearch(query: trimmed)
        }
    }

    func performWebSearch(query: String) {
        print("🌐 Starting web search for: \(query)")

        // Show web search in a separate NSWindow with WebKit and user scripts
        WebSearchWindowManager.shared.showWebSearch(
            query: query,
            userScripts: settings.webExtensions.filter { $0.enabled }.map { $0.script }
        )

        searchText = ""
        onClose()
    }

    func fetchWebSearchResults(query: String) async throws -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            print("❌ Failed to encode query")
            return []
        }

        // Use DuckDuckGo Instant Answer API (no API key required)
        let urlString = "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1"
        print("🌐 Fetching from: \(urlString)")
        guard let url = URL(string: urlString) else {
            print("❌ Invalid URL")
            return []
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        print("🌐 Received \(data.count) bytes of data")

        struct DDGResponse: Codable {
            let Abstract: String?
            let AbstractText: String?
            let AbstractSource: String?
            let AbstractURL: String?
            let Heading: String?
            let RelatedTopics: [RelatedTopic]?

            struct RelatedTopic: Codable {
                let Text: String?
                let FirstURL: String?
                let Icon: IconInfo?

                struct IconInfo: Codable {
                    let URL: String?
                }
            }
        }

        let response = try JSONDecoder().decode(DDGResponse.self, from: data)
        var results: [SearchResult] = []

        print("🌐 DDG Response - Abstract: \(response.AbstractText ?? "none"), Topics: \(response.RelatedTopics?.count ?? 0)")

        // Add main abstract result if available
        if let abstractText = response.AbstractText, !abstractText.isEmpty,
           let abstractURL = response.AbstractURL, let url = URL(string: abstractURL) {
            let heading = response.Heading ?? query
            print("🌐 Adding abstract result: \(heading)")
            results.append(SearchResult(
                title: heading,
                subtitle: abstractText,
                icon: NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: nil),
                action: { NSWorkspace.shared.open(url) },
                score: 100.0,
                type: .webSearch,
                filePath: nil,
                contactData: nil
            ))
        }

        // Add related topics as results
        if let topics = response.RelatedTopics {
            for topic in topics.prefix(5) {
                guard let text = topic.Text, !text.isEmpty,
                      let urlString = topic.FirstURL,
                      let url = URL(string: urlString) else {
                    continue
                }

                // Split text into title and description
                let parts = text.components(separatedBy: " - ")
                let title = parts.first ?? text
                let subtitle = parts.count > 1 ? parts[1...].joined(separator: " - ") : urlString

                results.append(SearchResult(
                    title: title,
                    subtitle: subtitle,
                    icon: NSImage(systemSymbolName: "globe", accessibilityDescription: nil),
                    action: { NSWorkspace.shared.open(url) },
                    score: 90.0,
                    type: .webSearch,
                    filePath: nil,
                    contactData: nil
                ))
            }
        }

        // Always add "Search on Google" as fallback
        let googleQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let googleURL = URL(string: "https://www.google.com/search?q=\(googleQuery)") {
            print("🌐 Adding Google search fallback")
            results.append(SearchResult(
                title: "Search \"\(query)\" on Google",
                subtitle: "Open Google search in browser",
                icon: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil),
                action: {
                    NSWorkspace.shared.open(googleURL)
                },
                score: 50.0,
                type: .webSearch,
                filePath: nil,
                contactData: nil
            ))
        }

        print("🌐 Returning \(results.count) total results")
        return results
    }

    func performSearch() {
        // NOTE: detectAndUpdateContext() deliberately NOT called here.
        // It uses synchronous Accessibility API calls that block the main thread
        // 100-500ms per call — calling it on every keystroke kills input responsiveness.
        // Context is detected once when the launcher shows (showLauncher / onAppear).

        let query = searchText.trimmingCharacters(in: .whitespaces)

        if isL2ContextActive {
            enforceL2ContextMode()
        }

        // L3: browser layer handles its own suggestions via webSearchPromptView.
        // Don't put history into searchResults — that causes the selected-result overlay
        // to replace the user's typed text with a history item title.
        if showBrowserLayer {
            searchResults = []
            selectedResultIndex = nil
            return
        }

        if showContextInDock && !showBrowserLayer {
            // In L2 context dock: pills filter in the dock row — don't touch the result sheet.
            // Results only appear when the user submits via Enter (handleL2Query).
            return
        }


        // If an app panel is active (calendar/notes/etc.), the panel view handles display
        // via appPanelDisplayedItems (reactive to searchText). Just clear regular results
        // so the normal APPLICATIONS/SHORTCUTS sections don't appear behind the panel.
        if activeSmartQueryKey != nil {
            if query.isEmpty {
                // Stay in panel mode — show all items (appPanelDisplayedItems returns all when query empty)
                searchResults = []
                searchDebounceTask?.cancel()
            } else {
                // Filter is handled by appPanelDisplayedItems computed property
                searchResults = []
            }
            return
        }

        guard !query.isEmpty else {
            // Folder preview stays open until ESC — don't reset it on empty query
            if showFolderPreview {
                searchResults = []
                searchDebounceTask?.cancel()
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                searchResults = []
                selectedResultIndex = nil
                indexedFileResults = []
                isInSmartMode = false
                lastSmartQuery = ""
                activeSmartQueryKey = nil
                searchContextApp = nil
                clearPinnedResults()
                systemDataResults = []
            }
            searchDebounceTask?.cancel()
            return
        }

        // Check if we need to exit smart mode (user deleted characters)
        if isInSmartMode && query != lastSmartQuery {
            // User is editing the query - check if we should stay in smart mode
            let currentSmartResult = detectSmartQuery(query: query)
            if currentSmartResult == nil {
                // No longer a smart query - exit smart mode and do normal search
                print("🔄 Exiting smart mode, switching to normal search")
                isInSmartMode = false
                lastSmartQuery = ""
                // Close folder preview if open
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFolderPreview = false
                }
                // Continue with normal search below
            }
        }

        // Smart exact match detection for folders, contacts, and photos
        if let smartResult = detectSmartQuery(query: query) {
            print("🎯 Smart query detected: \(smartResult)")
            isInSmartMode = true
            lastSmartQuery = query
            let shouldReturn = handleSmartQueryResult(smartResult)
            if shouldReturn {
                return
            }
        } else {
            // Not a smart query anymore
            if isInSmartMode {
                isInSmartMode = false
                lastSmartQuery = ""
                clearPinnedResults()
            }
        }

        // L3 (Browser layer): Show browser search results (recent searches + bookmarks)
        if showBrowserLayer {
            var browserResults: [SearchResult] = []

            // Filter recent searches that match current input
            let matchingSearches = settings.recentWebSearches.filter { search in
                search.lowercased().contains(query.lowercased())
            }

            // Filter bookmarks that match current input
            let matchingBookmarks = settings.importedBookmarks.filter { bookmark in
                bookmark.title.lowercased().contains(query.lowercased()) ||
                bookmark.url.lowercased().contains(query.lowercased())
            }

            // Convert recent searches to SearchResult
            for search in matchingSearches.prefix(10) {
                browserResults.append(SearchResult(
                    title: search,
                    subtitle: "Recent Search",
                    icon: NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil),
                    action: {
                        searchText = search
                        openInDockBrowser()
                    },
                    type: .webSearch,
                    filePath: nil,
                    contactData: nil
                ))
            }

            // Convert bookmarks to SearchResult
            for bookmark in matchingBookmarks.prefix(10) {
                browserResults.append(SearchResult(
                    title: bookmark.title,
                    subtitle: bookmark.url,
                    icon: NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil),
                    action: {
                        searchText = bookmark.url
                        openInDockBrowser()
                    },
                    type: .webSearch,
                    filePath: nil,
                    contactData: nil
                ))
            }

            // Update search results for keyboard navigation
            withAnimation(.easeInOut(duration: 0.2)) {
                searchResults = browserResults
                selectedResultIndex = browserResults.isEmpty ? nil : 0
                indexedFileResults = []
            }

            print("🌐 L3 Browser layer: Showing \(browserResults.count) browser results")
            return
        }

        // Indexed file search is in-memory — run immediately for instant results
        if settings.enableSpotlightSearch {
            searchIndexedFiles(for: query)
        } else {
            indexedFileResults = []
        }

        // Debounce scoring onto background thread so keystrokes never block the UI
        searchDebounceTask?.cancel()
        searchDebounceTask = Task(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 60_000_000) // 60ms debounce
            guard !Task.isCancelled else { return }
            await MainActor.run { performSearchWithoutSpotlight() }
        }
    }

    // MARK: - Smart Query Detection
    enum SmartQueryType {
        case folder(String)      // Folder path
        case contacts            // Show all contacts
        case photos              // Show all photos
        case notes               // Show all notes
        case reminders           // Show all reminders
        case calendarEvents      // Show all calendar events
        case mail                // Show all mail
        case messages            // Show all messages
        case application(String) // Specific app (show app-related content)
        case customApp(String)   // User-added app by key (show generic AI panel)
    }

    private func detectSmartQuery(query: String) -> SmartQueryType? {
        let lowercased = query.lowercased().trimmingCharacters(in: .whitespaces)

        // Skip detection if query is too short (let normal search work)
        guard !lowercased.isEmpty else { return nil }

        // Detect "contacts" query
        if lowercased == "contacts" || lowercased == "contact" {
            return .contacts
        }

        // Detect "notes" query
        if lowercased == "notes" || lowercased == "note" {
            return .notes
        }

        // Detect "reminders" query
        if lowercased == "reminders" || lowercased == "reminder" || lowercased == "remainders" || lowercased == "remmainder" {
            return .reminders
        }

        // Detect "calendar" query
        if lowercased == "calendar" || lowercased == "calender" || lowercased == "events" || lowercased == "event" {
            return .calendarEvents
        }

        // Detect "mail" query
        if lowercased == "mail" || lowercased == "email" || lowercased == "emails" {
            return .mail
        }

        // Detect "messages" query
        if lowercased == "messages" || lowercased == "message" || lowercased == "imessage" || lowercased == "sms" {
            return .messages
        }

        // Detect "photos" query
        if lowercased == "photos" || lowercased == "photo" || lowercased == "pictures" || lowercased == "picture" {
            return .photos
        }


        // Detect common folder names (exact match)
        let commonFolders = [
            "downloads": "Downloads",
            "documents": "Documents",
            "desktop": "Desktop",
            "pictures": "Pictures",
            "music": "Music",
            "movies": "Movies",
            "applications": "Applications"
        ]

        if let folderName = commonFolders[lowercased] {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let folderPath = "\(homeDir)/\(folderName)"

            // Check if folder exists
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory), isDirectory.boolValue {
                return .folder(folderPath)
            }
        }

        // Check for /Applications
        if lowercased == "applications" {
            return .folder("/Applications")
        }

        // Check if query matches a user-added custom app entry
        if let entry = AppSettings.shared.customAppEntries.first(where: {
            $0.key == lowercased || $0.label.lowercased() == lowercased
        }) {
            return .customApp(entry.key)
        }

        // Check if query exactly matches an application name
        // This allows showing app-specific content when user types full app name
        if let matchedApp = findExactApplicationMatch(query: query) {
            return .application(matchedApp)
        }

        return nil
    }

    private func findExactApplicationMatch(query: String) -> String? {
        let lowercased = query.lowercased().trimmingCharacters(in: .whitespaces)

        // Search through all applications
        for app in allApplications {
            guard let appPath = app.filePath else { continue }
            let appName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent.lowercased()
            if appName == lowercased {
                return appPath // Return full path
            }
        }

        return nil
    }

    @discardableResult
    private func handleSmartQueryResult(_ smartQuery: SmartQueryType) -> Bool {
        switch smartQuery {
        case .folder(let path):
            folderPreviewPath = path
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showFolderPreview = true
            }
            return true

        case .contacts:
            activeSmartQueryKey = "contacts"
            loadAllContactsAsResults()
            return false

        case .photos:
            activeSmartQueryKey = "photos"
            loadPhotosAsResults()
            return false

        case .notes:
            activeSmartQueryKey = "notes"
            loadSystemDataAsPinnedResults(query: "", types: [.note], title: "Notes", perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.note])
            return false

        case .reminders:
            activeSmartQueryKey = "reminders"
            loadSystemDataAsPinnedResults(query: "", types: [.reminder], title: "Reminders", perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.reminder])
            return false

        case .calendarEvents:
            activeSmartQueryKey = "calendar"
            loadSystemDataAsPinnedResults(query: "", types: [.calendarEvent], title: "Calendar", perTypeLimit: 200, allowEmptyQuery: true, excludeTypes: [.calendarEvent])
            return false

        case .mail:
            activeSmartQueryKey = "mail"
            loadSystemDataAsPinnedResults(query: "", types: [.mail], title: "Mail", perTypeLimit: 100, allowEmptyQuery: true, excludeTypes: [.mail])
            return false

        case .messages:
            activeSmartQueryKey = "messages"
            loadSystemDataAsPinnedResults(query: "", types: [.message], title: "Messages", perTypeLimit: 100, allowEmptyQuery: true, excludeTypes: [.message])
            return false

        case .customApp(let key):
            activeSmartQueryKey = key
            let entry = settings.customAppEntries.first(where: { $0.key == key })
            // Only put the "Open App" entry in appPanelAllItems — injectAppShortcuts adds quick actions
            var items: [SearchResult] = []
            if let path = entry?.appPath, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                items.append(SearchResult(
                    title: "Open \(entry?.label ?? key.capitalized)",
                    subtitle: path,
                    icon: NSWorkspace.shared.icon(forFile: path),
                    action: { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) },
                    type: .application,
                    filePath: path,
                    contactData: nil
                ))
            }
            appPanelAllItems = items
            injectAppShortcuts(for: key)
            return false

        case .application(let appPath):
            loadApplicationSpecificContent(appPath: appPath)
            return false

        }
    }

    /// Converts user-defined AppShortcuts into SearchResult rows and prepends them
    /// to the pinned results so they appear at the top of the smart-query view.
    private func injectAppShortcuts(for appKey: String) {
        let shortcuts = settings.shortcuts(for: appKey)
        guard !shortcuts.isEmpty else { return }

        let shortcutResults: [SearchResult] = shortcuts.map { sc in
            SearchResult(
                title: sc.name,
                subtitle: sc.actionValue,
                icon: NSImage(systemSymbolName: sc.iconName, accessibilityDescription: sc.name),
                action: { [sc] in
                    switch sc.actionType {
                    case .openURL:
                        if let url = URL(string: sc.actionValue) { NSWorkspace.shared.open(url) }
                    case .openFile:
                        NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: sc.actionValue),
                            configuration: NSWorkspace.OpenConfiguration())
                    case .shellCommand:
                        let proc = Process()
                        proc.launchPath = "/bin/zsh"
                        proc.arguments  = ["-c", sc.actionValue]
                        try? proc.run()
                    case .appleScript:
                        if let script = NSAppleScript(source: sc.actionValue) { script.executeAndReturnError(nil) }
                    case .jxa:
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent("ilauncher_jxa_\(UUID().uuidString).js")
                        try? sc.actionValue.write(to: tmp, atomically: true, encoding: .utf8)
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        p.arguments = ["-l", "JavaScript", tmp.path]
                        try? p.run()
                    }
                },
                type: .shortcut,
                filePath: nil,
                contactData: nil
            )
        }
        // Prepend as pinned "Quick Actions" section; content follows below
        setPinnedResults(shortcutResults, title: "Quick Actions", excludeTypes: [])
    }

    private func loadApplicationSpecificContent(appPath: String) {
        let expectedQuery = searchText.trimmingCharacters(in: .whitespaces)
        Task {
            await MainActor.run {
                let currentQuery = searchText.trimmingCharacters(in: .whitespaces)
                guard currentQuery == expectedQuery else { return }
                var appResults: [SearchResult] = []

                // Add the app itself as first result
                let appName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
                let appIcon = NSWorkspace.shared.icon(forFile: appPath)

                appResults.append(SearchResult(
                    title: appName,
                    subtitle: appPath,
                    icon: appIcon,
                    action: {
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: NSWorkspace.OpenConfiguration())
                    },
                    type: .application,
                    filePath: appPath,
                    contactData: nil
                ))

                // TODO: Add recent documents opened by this app
                // TODO: Add app settings/preferences
                // For now, just show the app itself

                setPinnedResults(appResults, title: "Application", excludeTypes: [])
                print("✅ Loaded app-specific content for \(appName)")
            }
        }
    }

    // MARK: - Safari Tab Switcher

    @MainActor
    private func loadSafariTabs() async {
        // Check Safari is running first
        guard NSWorkspace.shared.runningApplications
                .contains(where: { $0.bundleIdentifier == "com.apple.Safari" }) else {
            setPinnedResults([], title: "Safari Tabs", excludeTypes: [])
            return
        }

        let tabs = await SafariTabManager.shared.fetchTabs()

        let results: [SearchResult] = tabs.map { tab in
            SearchResult(
                title: tab.title.isEmpty ? tab.domain : tab.title,
                subtitle: tab.domain,
                icon: nil,
                action: {
                    SafariTabManager.shared.switchTo(tab)
                    AppDelegate.shared?.hideLauncher()
                },
                type: .webSearch,
                filePath: nil,
                contactData: nil
            )
        }

        setPinnedResults(
            results,
            title: "Safari Tabs — \(tabs.count) open",
            excludeTypes: [.webSearch]
        )
    }

    // MARK: - Safari Tab List View

    @ViewBuilder
    private var safariTabListView: some View {
        let items = appPanelDisplayedItems
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "safari")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(NSWorkspace.shared.runningApplications
                        .contains(where: { $0.bundleIdentifier == "com.apple.Safari" })
                     ? "No tabs found"
                     : "Safari is not running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        Button {
                            item.action()
                        } label: {
                            HStack(spacing: 10) {
                                // favicon placeholder with site-aware icon
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.10))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: safariTabIcon(for: item.subtitle))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(idx % 2 == 0
                                ? Color.clear
                                : Color.primary.opacity(0.02))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < items.count - 1 { Divider().padding(.leading, 50) }
                    }
                }
            }
        }
    }

    private func safariTabIcon(for domain: String) -> String {
        let d = domain.lowercased()
        if d.contains("github")       { return "chevron.left.forwardslash.chevron.right" }
        if d.contains("youtube")      { return "play.rectangle.fill" }
        if d.contains("mail.google")  { return "envelope.fill" }
        if d.contains("docs.google")  { return "doc.text.fill" }
        if d.contains("notion")       { return "square.grid.2x2" }
        if d.contains("figma")        { return "paintbrush.fill" }
        if d.contains("stackoverflow"){ return "questionmark.circle.fill" }
        if d.contains("twitter") || d.contains("x.com") { return "bird.fill" }
        if d.contains("reddit")       { return "bubble.left.and.bubble.right.fill" }
        if d.contains("apple")        { return "applelogo" }
        if d.contains("localhost") || d.contains("127.0.0.1") { return "server.rack" }
        return "safari"
    }

    private func loadAllContactsAsResults() {
        let expectedQuery = searchText.trimmingCharacters(in: .whitespaces)
        Task {
            let allContacts = await contactManager.getAllContacts()

            await MainActor.run {
                let currentQuery = searchText.trimmingCharacters(in: .whitespaces)
                guard currentQuery == expectedQuery else { return }
                var contactResults: [SearchResult] = []

                for contact in allContacts.prefix(100) { // Limit to 100 for performance
                    let fullName = contact.fullName.isEmpty ? "Unnamed Contact" : contact.fullName

                    let contactData = SearchResult.ContactData(
                        primaryEmail: contact.primaryEmail,
                        allEmails: contact.allEmails,
                        primaryPhone: contact.primaryPhone,
                        allPhones: contact.allPhones,
                        identifier: contact.identifier
                    )

                    contactResults.append(SearchResult(
                        title: fullName,
                        subtitle: contact.subtitle,
                        icon: contact.image ?? NSImage(systemSymbolName: "person.circle.fill", accessibilityDescription: nil),
                        action: {
                            // Open Contacts app
                            contact.openInContacts()
                        },
                        type: .contact,
                        filePath: nil,
                        contactData: contactData
                    ))
                }

                setPinnedResults(contactResults, title: "Contacts", excludeTypes: [.contact])
                print("✅ Loaded \(contactResults.count) contacts")
            }
        }
    }

    private func loadPhotosAsResults() {
        loadSystemDataAsPinnedResults(query: "", types: [.photo], title: "Photos", perTypeLimit: 100, allowEmptyQuery: true, excludeTypes: [.photo])
    }

    private func setPinnedResults(_ results: [SearchResult], title: String, excludeTypes: Set<SearchResult.ResultType>) {
        // Defer ALL state mutations so they never fire during a SwiftUI body pass
        DispatchQueue.main.async {
            self.pinnedResults = results
            self.pinnedResultsTitle = title
            self.pinnedResultTypesToExclude = excludeTypes
            if self.activeSmartQueryKey != nil {
                self.appPanelAllItems = results
            }
            self.performSearchWithoutSpotlight()
        }
    }

    private func clearPinnedResults() {
        pinnedResults = []
        pinnedResultsTitle = nil
        pinnedResultTypesToExclude = []
        appPanelAllItems = []
    }

    private func loadSystemDataAsPinnedResults(
        query: String,
        types: Set<SystemDataType>,
        title: String,
        perTypeLimit: Int = 100,
        allowEmptyQuery: Bool = false,
        excludeTypes: Set<SearchResult.ResultType> = []
    ) {
        let expectedQuery = searchText.trimmingCharacters(in: .whitespaces)
        Task {
            let systemResults = await systemDataManager.searchAll(
                query: query,
                types: types,
                perTypeLimit: perTypeLimit,
                allowEmptyQuery: allowEmptyQuery
            )

            await MainActor.run {
                let currentQuery = searchText.trimmingCharacters(in: .whitespaces)
                // In app panel mode load always (text is used as in-panel filter, not a query guard)
                guard currentQuery == expectedQuery || activeSmartQueryKey != nil else { return }

                let results: [SearchResult] = systemResults.map { systemResult in
                    let resultType: SearchResult.ResultType
                    switch systemResult.type {
                    case .calendarEvent:
                        resultType = .calendarEvent
                    case .reminder:
                        resultType = .reminder
                    case .note:
                        resultType = .note
                    case .mail:
                        resultType = .mail
                    case .photo:
                        resultType = .photo
                    case .message:
                        resultType = .message
                    case .voiceRecording, .contact:
                        resultType = .file
                    }

                    return SearchResult(
                        title: systemResult.title,
                        subtitle: systemResult.subtitle,
                        icon: systemResult.icon,
                        action: { systemResult.open() },
                        score: 0.0,
                        type: resultType,
                        filePath: nil,
                        contactData: nil
                    )
                }

                setPinnedResults(results, title: title, excludeTypes: excludeTypes)
            }
        }
    }


    // MARK: - Instant Calculator
    private func evaluateMathExpression(_ expression: String) -> String? {
        // Check if the expression looks like a math expression
        let mathPattern = #"^[\d\s\+\-\*\/\(\)\.\^]+$"#
        guard let regex = try? NSRegularExpression(pattern: mathPattern),
              regex.firstMatch(in: expression, range: NSRange(expression.startIndex..., in: expression)) != nil else {
            return nil
        }

        // Use bc command for calculation
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bc")
        process.arguments = ["-l"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()

            // Write the expression to bc
            let bcExpression = "scale=4; \(expression)\n"
            inputPipe.fileHandleForWriting.write(bcExpression.data(using: .utf8)!)
            inputPipe.fileHandleForWriting.closeFile()

            process.waitUntilExit()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            if let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !result.isEmpty,
               process.terminationStatus == 0 {
                // Clean up trailing zeros
                let cleanResult = result.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
                return cleanResult
            }
        } catch {
            return nil
        }

        return nil
    }


    private func performSearchWithoutSpotlight() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let isNewQuery = query != lastSearchQuery
        if isNewQuery {
            // Defer so these don't fire during an in-progress body pass
            DispatchQueue.main.async {
                self.lastSearchQuery = query
                self.isKeyboardNavigation = false
            }
        }

        // Show results even if still loading (with whatever we have so far)
        guard !allApplications.isEmpty || !allShortcuts.isEmpty || !indexedFileResults.isEmpty || !pinnedResults.isEmpty else {
            // If no items loaded yet, just clear results
            searchResults = []
            selectedResultIndex = nil
                return
        }

        // Fuzzy match and score all items (apps + shortcuts + indexed file results + extension commands)
        var scoredItems: [(item: SearchResult, score: Double)] = []

        if showContextInDock && !showBrowserLayer {
            updateL2Results(l2ExtensionResults)
            return
        }

        // Search regular items
        // L1: Include shortcuts + apps/files (full Spotlight list)
        // L2: Context-only extensions (no standard search results)
        // L3: Exclude shortcuts (web/browser search)
        let searchableItems: [SearchResult]
        if showContextInDock && !showBrowserLayer {
            searchableItems = []
        } else {
            searchableItems = showBrowserLayer ? allItems.filter { $0.type != .shortcut } : allItems
        }

        // Calendar events, reminders, and messages are only surfaced in app panels (L2 smart query)
        // and never in Layer 1 search results.
        let l1ExcludedTypes: Set<SearchResult.ResultType> = [.calendarEvent, .reminder, .message]
        let filteredItems = searchableItems.filter {
            !pinnedResultTypesToExclude.contains($0.type) && !l1ExcludedTypes.contains($0.type)
        }

        // Quick pre-filter: skip items that don't even contain the first character
        // This eliminates ~90% of the list before the expensive fuzzy match
        let queryLower = query.lowercased()
        let preFiltered = filteredItems.filter {
            $0.title.lowercased().contains(queryLower.prefix(1))
        }

        for item in preFiltered {
            if let score = FuzzyMatcher.score(query, against: item.title) {
                var scoredItem = item
                scoredItem.score = score

                // Get usage (frecency) score for this item
                let usageScore = UsageTracker.shared.getScore(for: item.trackingIdentifier)

                // Enhanced type priority system
                let typePriority: Double
                switch item.type {
                case .extensionCommand:
                    typePriority = 20.0 // Highest - instant commands
                case .application:
                    typePriority = 15.0 // Very high - apps are primary
                case .folder:
                    typePriority = 14.0 // Just below apps
                case .shortcut:
                    typePriority = 12.0
                case .calendarEvent, .reminder:
                    typePriority = 10.0 // High - calendar/reminders
                case .mail, .message:
                    typePriority = 9.0 // High - communications
                case .document:
                    typePriority = 7.0 // Medium - documents
                case .note:
                    typePriority = 6.0
                case .contact:
                    typePriority = 5.0
                case .file:
                    typePriority = 3.0
                case .photo:
                    typePriority = 2.0
                case .cliTool:
                    typePriority = 13.0 // Just below apps — CLI tools are surfaced prominently
                case .webSearch:
                    typePriority = 1.0 // Lowest - only show when no other matches
                }

                // Combine scores with weighted frecency
                // Fuzzy match score (0-1000) + type priority (0-20) + usage score * multiplier
                // Usage score is heavily weighted to create learning behavior
                var finalScore = score + typePriority + (usageScore * 8.0)

                // CONTEXT BOOST: Huge boost for shortcuts that match current context
                if item.type == .shortcut,
                   let metadata = shortcutMetadataCache[item.title],
                   metadata.matches(context: currentContext) {
                    finalScore += 500.0  // Massive boost for context-matching shortcuts
                }

                scoredItems.append((item: scoredItem, score: finalScore))
            }
        }

        // L2 extensions show only as chips next to the input field.


        // Sort by score and limit to top results
        let sortedResults = scoredItems
            .sorted { $0.score > $1.score }
            .prefix(20) // Increased limit to accommodate grouping
            .map { $0.item }

        // Group results by type, marking context-matching shortcuts as suggested
        var grouped = GroupedResults()
        for result in sortedResults {
            let isSuggested = result.type == .shortcut &&
                             shortcutMetadataCache[result.title]?.matches(context: currentContext) == true
            grouped.add(result, isSuggested: isSuggested)
        }

        grouped.pinnedResults = pinnedResults
        grouped.pinnedSectionTitle = pinnedResultsTitle

        // Get flat list for navigation (match visual order in dock mode)
        let newResults = settings.effectiveDockAtBottom ?
            Array(grouped.allResults.reversed()) :
            grouped.allResults


        let oldSelectedResultID: UUID? = {
            if let oldIndex = selectedResultIndex,
               oldIndex >= 0,
               oldIndex < searchResults.count {
                return searchResults[oldIndex].id
            }
            return nil
        }()

        // Defer the result write so it never fires during a body pass
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.15)) {
                self.searchResults = newResults
                self.groupedResults = grouped

                if self.isKeyboardNavigation && !isNewQuery,
                   let oldID = oldSelectedResultID,
                   let newIndex = self.searchResults.firstIndex(where: { $0.id == oldID }) {
                    self.selectedResultIndex = newIndex
                } else if !self.searchResults.isEmpty {
                    let defaultIndex = self.settings.effectiveDockAtBottom ? max(self.searchResults.count - 1, 0) : 0
                    self.selectedResultIndex = defaultIndex
                    if self.settings.effectiveDockAtBottom {
                        self.shouldAutoScrollToSelection = true
                    }
                } else {
                    self.selectedResultIndex = nil
                }
            }
        }
        if settings.effectiveDockAtBottom {
            searchResultsRevision += 1
        }

        print("✅ Updated to \(searchResults.count) items across \(grouped.sections.count) sections")
    }
    
    func findApplications(matching query: String) -> [SearchResult] {
        // This method is now deprecated - we use the cached allItems instead
        return allItems.filter { item in
            item.title.lowercased().contains(query)
        }
    }
    
    // MARK: - Browser Search Function
    // MARK: - Smart Positioning Function
    private func updateResultsPosition() {
        // Removed: Smart positioning logic - results always show below dock now
        // This function is kept for compatibility but does nothing
    }

    private func performBrowserSearch() {
        // Default: Open in default browser (same as pressing Enter)
        openInDefaultBrowser()
    }

    private func openInDefaultBrowser() {
        guard !searchText.isEmpty else { return }

        let query = searchText.trimmingCharacters(in: .whitespaces)

        // Determine if it's a URL or search query
        var urlString: String

        if query.contains(".") && !query.contains(" ") {
            // Looks like a URL
            if query.hasPrefix("http://") || query.hasPrefix("https://") {
                urlString = query
            } else {
                urlString = "https://\(query)"
            }
        } else {
            // Search query - use Google
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            urlString = "https://www.google.com/search?q=\(encodedQuery)"
        }

        guard let url = URL(string: urlString) else {
            print("❌ Invalid URL: \(urlString)")
            return
        }

        // Add to recent searches using AppSettings
        settings.addRecentWebSearch(query)

        // Open directly in default browser
        NSWorkspace.shared.open(url)

        // Clear search text
        searchText = ""

        print("🌐 Opening in default browser: \(urlString)")
    }

    private func openInCustomBrowser() {
        guard !searchText.isEmpty else { return }

        let query = searchText.trimmingCharacters(in: .whitespaces)

        // Add to recent searches using AppSettings
        settings.addRecentWebSearch(query)

        // Open in ILauncher's custom browser window
        WebSearchWindowManager.shared.showWebSearch(
            query: query,
            userScripts: settings.webExtensions.filter { $0.enabled }.map { $0.script }
        )

        // Clear search text
        searchText = ""

        print("🌐 Opening in ILauncher browser: \(query)")
    }

    /// Open search in inline dock browser (L3)
    private func openInDockBrowser() {
        guard !searchText.isEmpty else { return }

        let query = searchText.trimmingCharacters(in: .whitespaces)

        // Add to recent searches using AppSettings
        settings.addRecentWebSearch(query)

        // Show inline browser in L3
        inlineBrowserQuery = query
        showInlineBrowser = true
        isInlineBrowserLoading = true

        print("🌐 Opening in dock browser: \(query)")
    }

    /// Get search URL for a query
    private func getSearchURL(for query: String) -> URL {
        // Determine if it's a URL or search query
        var urlString: String

        if query.contains(".") && !query.contains(" ") {
            // Looks like a URL
            if query.hasPrefix("http://") || query.hasPrefix("https://") {
                urlString = query
            } else {
                urlString = "https://\(query)"
            }
        } else {
            // Search query - use Google
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            urlString = "https://www.google.com/search?q=\(encodedQuery)"
        }

        return URL(string: urlString) ?? URL(string: "https://www.google.com")!
    }

    private func updateBrowserSearchSuggestions() {
        let query = browserSearchText.trimmingCharacters(in: .whitespaces).lowercased()

        // Clear results if search text is empty
        if query.isEmpty {
            browserSearchResults = []
            currentBrowserQuery = ""
            return
        }

        // Filter recent searches that match the query
        let matchingSearches = settings.recentWebSearches.filter { search in
            search.lowercased().contains(query)
        }

        // If we have matching recent searches, show them
        if !matchingSearches.isEmpty {
            var results: [SearchResult] = []

            for search in matchingSearches.prefix(5) {
                results.append(SearchResult(
                    title: search,
                    subtitle: "Recent search",
                    icon: NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil),
                    action: {
                        self.browserSearchText = search
                        self.performBrowserSearch()
                    },
                    score: 100.0,
                    type: .webSearch,
                    filePath: nil,
                    contactData: nil
                ))
            }

            withAnimation(.easeInOut(duration: 0.2)) {
                browserSearchResults = results
                currentBrowserQuery = ""  // No query header for suggestions
            }
        } else {
            // No matching recent searches - clear results
            // User will need to press Enter to perform actual search
            browserSearchResults = []
            currentBrowserQuery = ""
        }
    }

    private func openBrowserSearch() {
        guard !browserSearchText.isEmpty else { return }

        // Add to recent searches using AppSettings
        settings.addRecentWebSearch(browserSearchText)

        // Determine if it's a URL or search query
        let searchQuery = browserSearchText
        var urlString: String

        if searchQuery.contains(".") && !searchQuery.contains(" ") {
            // Looks like a URL
            if searchQuery.hasPrefix("http://") || searchQuery.hasPrefix("https://") {
                urlString = searchQuery
            } else {
                urlString = "https://\(searchQuery)"
            }
        } else {
            // Search query - use Google
            let encodedQuery = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
            urlString = "https://www.google.com/search?q=\(encodedQuery)"
        }

        // Open in WebSearchWindow using WebSearchWindowManager
        WebSearchWindowManager.shared.showWebSearch(
            query: urlString,
            userScripts: settings.webExtensions.filter { $0.enabled }.map { $0.script }
        )

        // Clear the input field after opening
        browserSearchText = ""

        print("🌐 Opening browser: \(urlString)")
    }

    private func launchPinnedApp(_ app: PinnedApp) {
        // Check if it's a folder - show folder preview instead of opening
        if app.type == .folder {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue {
                print("👁️ Showing custom folder preview for pinned folder: \(app.path)")
                folderPreviewPath = app.path
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showFolderPreview = true
                }
                return
            }
        }

        // For apps, files, and shortcuts - open normally
        let url = URL(fileURLWithPath: app.path)
        NSWorkspace.shared.open(url)
        onClose()
    }
    
    // MARK: - Folder Preview Helper
    private func showFolderPreviewInline(path: String) {
        print("📂 Opening folder preview inline: \(path)")
        folderPreviewPath = path
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showFolderPreview = true
        }
    }

    private func quickLookSelectedItem() {
        guard let index = selectedResultIndex, index < searchResults.count else { return }
        let result = searchResults[index]

        // Handle contacts separately - show contact preview
        if result.type == .contact {
            contactPreviewData = result
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showContactPreview = true
            }
            return
        }

        // Only Quick Look files and folders
        guard let filePath = result.filePath else {
            print("⚠️ Cannot Quick Look: No file path")
            return
        }

        let url = URL(fileURLWithPath: filePath)

        // Verify the file/folder exists
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("⚠️ File does not exist: \(filePath)")
            return
        }

        // For folders, show custom preview
        if result.type == .folder {
            print("👁️ Showing custom folder preview for: \(filePath)")
            showFolderPreviewInline(path: filePath)
            return
        }
        
        // For files, use Quick Look
        print("👁️ Quick Look preview for file: \(filePath)")
        
        // Create a shared Quick Look panel
        guard let panel = QLPreviewPanel.shared() else {
            print("⚠️ Could not get Quick Look panel")
            return
        }

        // Check if we're previewing the same file - if so, toggle (close it)
        if panel.isVisible,
           let currentDataSource = quickLookDataSource,
           currentDataSource.urls.first == url {
            // Same file - close the preview
            panel.orderOut(nil)
            quickLookDataSource = nil
        } else {
            // Different file or panel not visible - show the preview
            let dataSource = QuickLookDataSource(urls: [url])
            quickLookDataSource = dataSource
            panel.dataSource = dataSource
            panel.delegate = dataSource
            panel.reloadData() // Force reload with new data

            if !panel.isVisible {
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Browser Helper Functions
    private func openBrowserURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func loadSampleBrowserContent() {
        // Sample pinned websites
        self.pinnedWebsites = [
            BrowserItem(title: "YouTube", url: "https://youtube.com", favicon: "play.rectangle.fill", type: .pinnedSite),
            BrowserItem(title: "GitHub", url: "https://github.com", favicon: "chevron.left.forwardslash.chevron.right", type: .pinnedSite),
            BrowserItem(title: "ChatGPT", url: "https://chat.openai.com", favicon: "bubble.left.and.bubble.right.fill", type: .pinnedSite),
            BrowserItem(title: "Gmail", url: "https://mail.google.com", favicon: "envelope.fill", type: .pinnedSite)
        ]

        // Sample quick tabs
        self.quickTabs = [
            BrowserItem(title: "Google Drive", url: "https://drive.google.com", favicon: "folder.fill", type: .quickTab),
            BrowserItem(title: "Figma", url: "https://figma.com", favicon: "square.on.square", type: .quickTab),
            BrowserItem(title: "Linear", url: "https://linear.app", favicon: "checkmark.circle.fill", type: .quickTab)
        ]

        // Sample bookmarks
        self.browserBookmarks = [
            BrowserItem(title: "Apple Developer", url: "https://developer.apple.com", favicon: "apple.logo", type: .bookmark),
            BrowserItem(title: "Stack Overflow", url: "https://stackoverflow.com", favicon: "text.bubble.fill", type: .bookmark),
            BrowserItem(title: "MDN Web Docs", url: "https://developer.mozilla.org", favicon: "doc.text.fill", type: .bookmark)
        ]
    }
}

// MARK: - Command Approval Window Host
/// Manages the standalone NSWindow used for command approval dialogs.
class CommandApprovalWindowHost: NSObject, NSWindowDelegate {
    static let shared = CommandApprovalWindowHost()
    static var window: NSWindow?

    static func close() {
        window?.close()
        window = nil
    }

    // Called when user clicks the red X button — treat as deny
    func windowWillClose(_ notification: Notification) {
        if TerminalAIBridge.shared.pendingApproval != nil {
            TerminalAIBridge.shared.denyCommand()
        }
        CommandApprovalWindowHost.window = nil
    }
}

// MARK: - Quick Look Support
class QuickLookDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let urls: [URL]
    
    init(urls: [URL]) {
        self.urls = urls
        super.init()
    }
    
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return urls.count
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return urls[index] as NSURL
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown {
            if event.keyCode == 53 { // Escape key
                panel.orderOut(nil)
                return true
            }
        }
        return false
    }
}

struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    @ObservedObject private var settings = AppSettings.shared
    
    private var isPinned: Bool {
        result.type == .application && settings.isPinned(path: result.subtitle)
    }
    
    private var typeLabel: String? {
        switch result.type {
        case .shortcut:
            return "SHORTCUT"
        case .folder:
            return "FOLDER"
        case .document:
            return "DOCUMENT"
        case .file:
            return "FILE"
        case .contact:
            return "CONTACT"
        case .calendarEvent:
            return "EVENT"
        case .reminder:
            return "REMINDER"
        case .note:
            return "NOTE"
        case .mail:
            return "MAIL"
        case .photo:
            return "PHOTO"
        case .message:
            return "MESSAGE"
        case .extensionCommand:
            return "EXTENSION"
        case .webSearch:
            return "WEB"
        case .application:
            return nil
        case .cliTool:
            return "CLI"
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Group {
                if let icon = result.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    // Default icons based on type
                    switch result.type {
                    case .application:
                        Image(systemName: "app")
                            .foregroundColor(.blue)
                        case .shortcut:
                            Image(systemName: "shortcut")
                                .foregroundColor(.orange)
                        case .file, .document:
                            Image(systemName: "doc")
                                .foregroundColor(.gray)
                        case .folder:
                            Image(systemName: "folder")
                                .foregroundColor(.blue)
                        case .contact:
                            Image(systemName: "person.crop.circle")
                                .foregroundColor(.purple)
                        case .calendarEvent:
                        Image(systemName: "calendar")
                            .foregroundColor(.red)
                    case .reminder:
                        Image(systemName: "checklist")
                            .foregroundColor(.orange)
                    case .note:
                        Image(systemName: "note.text")
                            .foregroundColor(.yellow)
                    case .mail:
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.blue)
                    case .photo:
                        Image(systemName: "photo")
                            .foregroundColor(.pink)
                    case .message:
                        Image(systemName: "message.fill")
                            .foregroundColor(.green)
                    case .extensionCommand:
                        Image(systemName: "puzzlepiece.extension.fill")
                            .foregroundColor(.indigo)
                    case .webSearch:
                        Image(systemName: "globe")
                            .foregroundColor(.blue)
                    case .cliTool:
                        Image(systemName: "terminal.fill")
                            .foregroundColor(.green)
                    }
                }
            }
            .frame(width: 32, height: 32)
            
            // Text
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    if let label = typeLabel {
                        Text(label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(badgeColor)
                            )
                    }
                    
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()

            // Spotlight-style Tab hint for any result when selected
            if isSelected {
                HStack(spacing: 4) {
                    Text(result.type == .application ? "Open panel" :
                         result.type == .cliTool ? "Open panel" :
                         result.type == .folder ? "Browse" :
                         result.type == .contact ? "Contact" : "More")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text("tab")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .tertiaryLabelColor).opacity(0.2))
                        .cornerRadius(4)
                }
                .padding(.trailing, 4)
            }

            // Quick Actions for Contacts
            if result.type == .contact, let contactData = result.contactData {
                HStack(spacing: 8) {
                    // Email button
                    if !contactData.primaryEmail.isEmpty {
                        ContactQuickActionButton(
                            icon: "envelope.fill",
                            color: .blue,
                            tooltip: "Email"
                        ) {
                            if let url = URL(string: "mailto:\(contactData.primaryEmail)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }

                    // Message button
                    if !contactData.primaryEmail.isEmpty {
                        ContactQuickActionButton(
                            icon: "message.fill",
                            color: .green,
                            tooltip: "Message"
                        ) {
                            if let url = URL(string: "imessage:\(contactData.primaryEmail)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }

                    // Call button
                    if !contactData.primaryPhone.isEmpty {
                        ContactQuickActionButton(
                            icon: "phone.fill",
                            color: .orange,
                            tooltip: "Call"
                        ) {
                            if let url = URL(string: "tel:\(contactData.primaryPhone)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }

                    // Spacebar hint
                    if isSelected {
                        Text("Space")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: .tertiaryLabelColor).opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
    
    private var iconName: String {
        switch result.type {
        case .application:
            return "app.fill"
        case .shortcut:
            return "bolt.fill"
        case .folder:
            return "folder.fill"
        case .document:
            return "doc.fill"
        case .file:
            return "doc.fill"
        case .contact:
            return "person.crop.circle.fill"
        case .calendarEvent:
            return "calendar"
        case .reminder:
            return "checklist"
        case .note:
            return "note.text"
        case .mail:
            return "envelope.fill"
        case .photo:
            return "photo"
        case .message:
            return "message.fill"
        case .extensionCommand:
            return "puzzlepiece.extension.fill"
        case .webSearch:
            return "globe"
        case .cliTool:
            return "terminal.fill"
        }
    }

    private var badgeColor: SwiftUI.Color {
        switch result.type {
        case .shortcut:
            return SwiftUI.Color.secondary.opacity(0.15)
        case .folder:
            return SwiftUI.Color.blue.opacity(0.15)
        case .document, .file:
            return SwiftUI.Color.green.opacity(0.15)
        case .contact:
            return SwiftUI.Color.purple.opacity(0.15)
        case .calendarEvent:
            return SwiftUI.Color.red.opacity(0.15)
        case .reminder:
            return SwiftUI.Color.orange.opacity(0.15)
        case .note:
            return SwiftUI.Color.yellow.opacity(0.15)
        case .mail:
            return SwiftUI.Color.blue.opacity(0.15)
        case .photo:
            return SwiftUI.Color.pink.opacity(0.15)
        case .message:
            return SwiftUI.Color.green.opacity(0.15)
        case .extensionCommand:
            return SwiftUI.Color.indigo.opacity(0.15)
        case .webSearch:
            return SwiftUI.Color.blue.opacity(0.15)
        case .application:
            return SwiftUI.Color.clear
        case .cliTool:
            return SwiftUI.Color.green.opacity(0.15)
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let launcherWindowOpened = Notification.Name("launcherWindowOpened")
    static let folderPreviewShouldClose = Notification.Name("folderPreviewShouldClose")
    static let frontmostAppDetected = Notification.Name("frontmostAppDetected")
    static let userContextDetected = Notification.Name("userContextDetected")
}

// MARK: - Folder Preview View
struct FolderPreviewView: View {
    let folderPath: String
    @Binding var isPresented: Bool
    @Binding var selectedFilePath: String? // Expose selected file to parent
    @State private var currentFolderPath: String = ""
    @State private var folderHistory: [String] = [] // Stack of parent folders for back navigation
    @State private var folderItems: [FolderItem] = []
    @State private var isLoading = true
    @State private var folderName: String = ""
    @State private var folderIcon: NSImage?
    @State private var selectedItemIndex: Int? = nil
    @State private var quickLookDataSource: FolderQuickLookDataSource? = nil
    @StateObject private var keyboardHandler = FolderPreviewKeyboardHandler()
    @ObservedObject private var settings = AppSettings.shared

    // Window resize state
    @State private var windowWidth: CGFloat = 0 // Will be loaded from settings or default to screen size
    @State private var windowHeight: CGFloat = 0 // Will be loaded from settings or default to screen size
    @State private var isDraggingResize: Bool = false
    @State private var dragStartWidth: CGFloat = 0
    @State private var dragStartHeight: CGFloat = 0

    // Track selection source to prevent auto-scroll on mouse hover
    @State private var selectionByKeyboard: Bool = false

    // View options (will be loaded from settings in onAppear)
    @State private var viewMode: ViewMode = .list
    @State private var sortBy: SortOption = .name
    @State private var iconSize: IconSize = .medium

    enum ViewMode {
        case list, grid
    }

    enum SortOption {
        case name, date, size, kind
    }

    enum IconSize: CGFloat {
        case small = 24
        case medium = 32
        case large = 48
    }

    struct FolderItem: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let icon: NSImage
        let isDirectory: Bool
        let size: String
        let modifiedDate: String
        let sizeBytes: Int64  // Raw size for sorting
        let modifiedDateRaw: Date?  // Raw date for sorting
        let fileExtension: String  // For "Kind" sorting
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Content (header removed)
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading folder contents...")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else if folderItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("This folder is empty")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    
                    if !folderHistory.isEmpty {
                        Button("Go Back") {
                            navigateBack()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        if viewMode == .grid {
                            // Grid View
                            LazyVGrid(columns: [
                                GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 16)
                            ], spacing: 16) {
                                ForEach(Array(folderItems.enumerated()), id: \.element.id) { index, item in
                                    VStack(spacing: 8) {
                                        Image(nsImage: item.icon)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: iconSize.rawValue, height: iconSize.rawValue)

                                        Text(item.name)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .padding(8)
                                    .background(selectedItemIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .cornerRadius(8)
                                    .id(index)
                                    .onTapGesture(count: 2) {
                                        openItem(item)
                                    }
                                    .onTapGesture(count: 1) {
                                        selectedItemIndex = index
                                        selectionByKeyboard = false
                                        // Update parent's selected file context
                                        selectedFilePath = item.path
                                    }
                                    .contextMenu {
                                        Button("Open") { openItem(item) }
                                        if item.isDirectory {
                                            Button("Enter Folder") { navigateIntoFolder(item) }
                                        }
                                        Button("Quick Look") { quickLookItem(item) }
                                        Button("Show in Finder") {
                                            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                                        }
                                        Divider()
                                        Button("Copy Path") {
                                            let pasteboard = NSPasteboard.general
                                            pasteboard.clearContents()
                                            pasteboard.setString(item.path, forType: .string)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        } else {
                            // List View
                            LazyVStack(spacing: 0) {
                                ForEach(Array(folderItems.enumerated()), id: \.element.id) { index, item in
                                    FolderItemRow(item: item, isSelected: selectedItemIndex == index, iconSize: iconSize.rawValue)
                                        .id(index)
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) {
                                            openItem(item)
                                        }
                                        .onTapGesture(count: 1) {
                                            selectedItemIndex = index
                                            selectionByKeyboard = false
                                            // Update parent's selected file context
                                            selectedFilePath = item.path
                                        }
                                        .contextMenu {
                                            Button("Open") { openItem(item) }
                                            if item.isDirectory {
                                                Button("Enter Folder") { navigateIntoFolder(item) }
                                            }
                                            Button("Quick Look") { quickLookItem(item) }
                                            Button("Show in Finder") {
                                                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                                            }
                                            Divider()
                                            Button("Copy Path") {
                                                let pasteboard = NSPasteboard.general
                                                pasteboard.clearContents()
                                                pasteboard.setString(item.path, forType: .string)
                                            }
                                        }

                                    if index < folderItems.count - 1 {
                                        Divider()
                                            .padding(.leading, 60)
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: selectedItemIndex) { _, newIndex in
                        if selectionByKeyboard, let index = newIndex {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                    }
                }
            }
            
            // Footer - Liquid Glass Effect
            HStack(spacing: 12) {
                // Item count
                Text("\(folderItems.count) \(folderItems.count == 1 ? "item" : "items")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))

                Divider()
                    .frame(height: 16)
                    .overlay(Color.white.opacity(0.1))

                // View mode toggle (Grid/List)
                HStack(spacing: 4) {
                    Button(action: { viewMode = .list }) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(viewMode == .list ? .white : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("List View")

                    Button(action: { viewMode = .grid }) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(viewMode == .grid ? .white : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Grid View")
                }

                Divider()
                    .frame(height: 16)
                    .overlay(Color.white.opacity(0.1))

                // Sort options
                Menu {
                    Button(action: { sortBy = .name }) {
                        Label("Name", systemImage: sortBy == .name ? "checkmark" : "")
                    }
                    Button(action: { sortBy = .date }) {
                        Label("Date Modified", systemImage: sortBy == .date ? "checkmark" : "")
                    }
                    Button(action: { sortBy = .size }) {
                        Label("Size", systemImage: sortBy == .size ? "checkmark" : "")
                    }
                    Button(action: { sortBy = .kind }) {
                        Label("Kind", systemImage: sortBy == .kind ? "checkmark" : "")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                        Text("Sort")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
                .menuStyle(.borderlessButton)
                .help("Sort By")

                Divider()
                    .frame(height: 16)
                    .overlay(Color.white.opacity(0.1))

                // Icon size
                Menu {
                    Button(action: { iconSize = .small }) {
                        Label("Small", systemImage: iconSize == .small ? "checkmark" : "")
                    }
                    Button(action: { iconSize = .medium }) {
                        Label("Medium", systemImage: iconSize == .medium ? "checkmark" : "")
                    }
                    Button(action: { iconSize = .large }) {
                        Label("Large", systemImage: iconSize == .large ? "checkmark" : "")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.system(size: 12, weight: .medium))
                        Text("Icon")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
                .menuStyle(.borderlessButton)
                .help("Icon Size")

                Spacer()

                // Open in Finder button - Glassy style
                Button("Open in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: currentFolderPath))
                    closePreview()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.white.opacity(0.2))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    // Liquid glass base
                    Rectangle()
                        .fill(.thickMaterial)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Glassmorphism border
                    Rectangle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )

                    // Top highlight (liquid glass shine)
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.15),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 1)
                        Spacer()
                    }
                }
            )
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: -2)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Handle dropped files
            handleDroppedFiles(providers: providers)
            return true
        }
        .onAppear {
            // Load saved preferences
            viewMode = settings.folderViewMode == "grid" ? .grid : .list
            switch settings.folderSortBy {
            case "date": sortBy = .date
            case "size": sortBy = .size
            case "kind": sortBy = .kind
            default: sortBy = .name
            }
            iconSize = IconSize(rawValue: settings.folderIconSize) ?? .medium

            currentFolderPath = folderPath
            loadFolderContents()
            setupKeyboardHandler()
        }
        .onChange(of: viewMode) { _, newValue in
            settings.folderViewMode = newValue == .grid ? "grid" : "list"
        }
        .onChange(of: sortBy) { _, newValue in
            let sortByString: String
            switch newValue {
            case .name: sortByString = "name"
            case .date: sortByString = "date"
            case .size: sortByString = "size"
            case .kind: sortByString = "kind"
            }
            settings.folderSortBy = sortByString
            // Reload contents with new sort
            loadFolderContents()
        }
        .onChange(of: iconSize) { _, newValue in
            settings.folderIconSize = newValue.rawValue
        }
        .onDisappear {
            keyboardHandler.stopMonitoring()
            // Dismiss Quick Look panel if it's open
            if let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.orderOut(nil)
            }
            quickLookDataSource = nil
        }
        .onChange(of: keyboardHandler.lastAction) { _, action in
            handleKeyboardAction(action)
        }
        .onReceive(NotificationCenter.default.publisher(for: .folderPreviewShouldClose)) { _ in
            // Handle escape key close via notification to break the synchronous call chain
            isPresented = false
        }
    }
    
    private func setupKeyboardHandler() {
        // Set up the close handler to bypass @Published timing issues
        // We'll use a notification instead of direct binding manipulation
        keyboardHandler.onCloseRequested = {
            // First dismiss Quick Look if open
            if let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.orderOut(nil)
            }
            
            // Post notification to close - this breaks the synchronous call chain
            NotificationCenter.default.post(name: .folderPreviewShouldClose, object: nil)
        }
        keyboardHandler.startMonitoring()
    }
    
    private func handleKeyboardAction(_ action: FolderPreviewKeyboardHandler.KeyAction?) {
        guard let action = action else { return }

        // Reset the action immediately to prevent re-triggering
        keyboardHandler.lastAction = nil

        switch action {
        case .navigateUp:
            navigateItems(direction: -1, horizontal: false)
        case .navigateDown:
            navigateItems(direction: 1, horizontal: false)
        case .navigateInto:
            // Right arrow behavior depends on view mode
            if viewMode == .grid {
                // In grid view: Right arrow navigates horizontally (next item to the right)
                navigateItems(direction: 1, horizontal: true)
            } else {
                // In list view: Right arrow enters subfolder
                if let index = selectedItemIndex, index < folderItems.count {
                    let item = folderItems[index]
                    if item.isDirectory {
                        navigateIntoFolder(item)
                    }
                }
            }
        case .navigateBack:
            // Left arrow behavior depends on view mode
            if viewMode == .grid {
                // In grid view: Left arrow navigates horizontally (previous item to the left)
                if let index = selectedItemIndex, index > 0 {
                    // Only navigate left if not at start, otherwise go back to parent
                    navigateItems(direction: -1, horizontal: true)
                } else if !folderHistory.isEmpty {
                    // At start of grid, go back to parent folder
                    navigateBack()
                }
            } else {
                // In list view: Left arrow always goes back to parent folder
                navigateBack()
            }
        case .open:
            // Enter key - behavior depends on view mode
            if let index = selectedItemIndex, index < folderItems.count {
                let item = folderItems[index]
                if viewMode == .grid && item.isDirectory {
                    // In grid view: Enter opens folders (navigates into them)
                    navigateIntoFolder(item)
                } else {
                    // In list view or for files: Enter opens the item
                    openItem(item)
                }
            }
        case .quickLook:
            print("🔍 Quick Look action received (viewMode: \(viewMode), selectedIndex: \(String(describing: selectedItemIndex)))")
            if let index = selectedItemIndex, index < folderItems.count {
                print("🔍 Calling quickLookItem for: \(folderItems[index].name)")
                quickLookItem(folderItems[index])
            } else {
                print("⚠️ Quick Look failed: no valid selection (selectedItemIndex: \(String(describing: selectedItemIndex)), items count: \(folderItems.count))")
            }
        case .quickLookPrevious:
            // Navigate up and update Quick Look preview
            navigateItems(direction: -1)
            updateQuickLookPreview()
        case .quickLookNext:
            // Navigate down and update Quick Look preview
            navigateItems(direction: 1)
            updateQuickLookPreview()
        case .close:
            // This case is now handled by onCloseRequested closure
            closePreview()
        }
    }
    
    private func updateQuickLookPreview() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        guard let index = selectedItemIndex, index < folderItems.count else { return }
        
        let item = folderItems[index]
        let url = URL(fileURLWithPath: item.path)
        
        // Get the current window for restoring focus later
        let currentWindow = NSApp.windows.first(where: { $0.isVisible && $0 != panel })
        
        // Update the data source with the new file
        let dataSource = FolderQuickLookDataSource(urls: [url], folderPreviewWindow: currentWindow)
        quickLookDataSource = dataSource
        panel.dataSource = dataSource
        panel.delegate = dataSource
        
        // Reload to show the new file
        panel.reloadData()
        
        // Keep our window visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            currentWindow?.orderFront(nil)
        }
    }
    
    private func navigateIntoFolder(_ item: FolderItem) {
        guard item.isDirectory else { return }
        
        // Use asyncAfter to prevent constraint update crashes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            // Save current path to history
            self.folderHistory.append(self.currentFolderPath)
            
            // Update to new path
            self.currentFolderPath = item.path
            self.selectedItemIndex = nil
            
            // Reload contents
            self.loadFolderContents()
        }
    }
    
    private func navigateBack() {
        guard let previousPath = folderHistory.popLast() else { return }
        
        // Use asyncAfter to prevent constraint update crashes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.currentFolderPath = previousPath
            self.selectedItemIndex = nil
            
            // Reload contents
            self.loadFolderContents()
        }
    }
    
    private func handleDroppedFiles(providers: [NSItemProvider]) {
        print("📥 Files dropped into folder preview")

        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let sourceURL = url, error == nil else {
                    print("⚠️ Failed to load dropped file: \(error?.localizedDescription ?? "unknown error")")
                    return
                }

                // Move/copy file to current folder
                let fileName = sourceURL.lastPathComponent
                let destinationURL = URL(fileURLWithPath: self.currentFolderPath).appendingPathComponent(fileName)

                DispatchQueue.main.async {
                    do {
                        // Check if file already exists
                        if FileManager.default.fileExists(atPath: destinationURL.path) {
                            print("⚠️ File already exists: \(fileName)")
                            // Could show an alert here asking to replace
                            return
                        }

                        // Copy the file
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        print("✅ File copied: \(fileName) → \(self.currentFolderPath)")

                        // Reload folder contents to show the new file
                        self.loadFolderContents()
                    } catch {
                        print("❌ Failed to copy file: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func closePreview() {
        // Stop monitoring keyboard events first to prevent re-entry
        keyboardHandler.stopMonitoring()
        
        // Dismiss Quick Look panel first if it's open
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            quickLookDataSource = nil
        }
        
        // Use asyncAfter to ensure we're out of any layout pass
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                self.isPresented = false
            }
        }
    }
    
    private func quickLookItem(_ item: FolderItem) {
        let url = URL(fileURLWithPath: item.path)
        
        // Verify the file exists
        guard FileManager.default.fileExists(atPath: item.path) else {
            print("⚠️ File does not exist: \(item.path)")
            return
        }
        
        print("👁️ Quick Look preview for: \(item.path)")
        
        // Use asyncAfter to prevent constraint update crashes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            // Get or create the Quick Look panel
            guard let panel = QLPreviewPanel.shared() else {
                print("⚠️ Could not get Quick Look panel")
                return
            }
            
            // Get the current window for restoring focus later
            let currentWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
            
            // Toggle Quick Look panel - if showing same file, close it
            if panel.isVisible {
                if let currentDataSource = self.quickLookDataSource,
                   currentDataSource.urls.first == url {
                    panel.orderOut(nil)
                    self.quickLookDataSource = nil
                    // Restore focus to our window
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        currentWindow?.makeKeyAndOrderFront(nil)
                    }
                    return
                }
            }
            
            // Create a new data source with window reference
            let dataSource = FolderQuickLookDataSource(urls: [url], folderPreviewWindow: currentWindow)
            self.quickLookDataSource = dataSource
            panel.dataSource = dataSource
            panel.delegate = dataSource
            
            // Configure panel to work better with our app
            panel.level = .floating // Keep it above other windows
            
            // Reload and show
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
            
            // Keep our window visible (don't let it hide behind)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                currentWindow?.orderFront(nil)
            }
        }
    }
    
    private func loadFolderContents() {
        isLoading = true

        // Capture the path and sort option to avoid race conditions
        let pathToLoad = currentFolderPath
        let currentSortBy = sortBy

        Task.detached(priority: .userInitiated) {
            // Get folder info - do this on background thread
            let url = URL(fileURLWithPath: pathToLoad)
            let name = url.lastPathComponent
            
            // Load folder contents
            let fileManager = FileManager.default
            
            // Check if path exists and is accessible (important for iCloud)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: pathToLoad, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                await MainActor.run {
                    // Use asyncAfter to break out of any constraint update cycle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.folderName = name
                        self.folderIcon = nil
                        self.folderItems = []
                        self.isLoading = false
                    }
                }
                return
            }
            
            // For iCloud folders, we need to handle potential delays
            // Try to get contents with a timeout approach
            let contents: [String]
            do {
                contents = try fileManager.contentsOfDirectory(atPath: pathToLoad)
            } catch {
                print("⚠️ Error reading folder contents: \(error)")
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.folderName = name
                        self.folderIcon = NSWorkspace.shared.icon(forFile: pathToLoad)
                        self.folderItems = []
                        self.isLoading = false
                    }
                }
                return
            }
            
            var items: [FolderItem] = []
            
            for item in contents.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                // Skip hidden files
                guard !item.hasPrefix(".") else { continue }
                
                let itemPath = (pathToLoad as NSString).appendingPathComponent(item)
                
                var itemIsDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: itemPath, isDirectory: &itemIsDirectory)
                
                // Skip items that don't exist (might be iCloud placeholders that aren't downloaded)
                guard exists else { continue }
                
                // Get file attributes for sorting
                let attributes = try? fileManager.attributesOfItem(atPath: itemPath)

                // Get file size - be defensive about iCloud files
                let size: String
                let sizeBytes: Int64
                if itemIsDirectory.boolValue {
                    size = "Folder"
                    sizeBytes = 0
                } else {
                    if let fileSize = attributes?[.size] as? Int64 {
                        size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
                        sizeBytes = fileSize
                    } else {
                        size = "--"
                        sizeBytes = 0
                    }
                }

                // Get modification date - be defensive
                let modDate: String
                let modDateRaw: Date?
                if let date = attributes?[.modificationDate] as? Date {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .abbreviated
                    modDate = formatter.localizedString(for: date, relativeTo: Date())
                    modDateRaw = date
                } else {
                    modDate = "--"
                    modDateRaw = nil
                }

                // Get file extension for "Kind" sorting
                let fileExt = (itemPath as NSString).pathExtension.lowercased()

                // Get icon on main thread to avoid potential threading issues
                let itemIcon = NSWorkspace.shared.icon(forFile: itemPath)
                itemIcon.size = NSSize(width: 32, height: 32)

                items.append(FolderItem(
                    name: item,
                    path: itemPath,
                    icon: itemIcon,
                    isDirectory: itemIsDirectory.boolValue,
                    size: size,
                    modifiedDate: modDate,
                    sizeBytes: sizeBytes,
                    modifiedDateRaw: modDateRaw,
                    fileExtension: fileExt
                ))
            }
            
            // Sort: folders first, then by selected option
            let sortedItems = items.sorted { item1, item2 in
                // Always put folders before files
                if item1.isDirectory != item2.isDirectory {
                    return item1.isDirectory && !item2.isDirectory
                }

                // Within same type (folder or file), sort by selected option
                switch currentSortBy {
                case .name:
                    return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending

                case .date:
                    // Sort by date (most recent first)
                    guard let date1 = item1.modifiedDateRaw, let date2 = item2.modifiedDateRaw else {
                        return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
                    }
                    return date1 > date2  // Most recent first

                case .size:
                    // Sort by size (largest first)
                    if item1.sizeBytes != item2.sizeBytes {
                        return item1.sizeBytes > item2.sizeBytes
                    }
                    return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending

                case .kind:
                    // Sort by file extension/kind
                    if item1.fileExtension != item2.fileExtension {
                        return item1.fileExtension.localizedCaseInsensitiveCompare(item2.fileExtension) == .orderedAscending
                    }
                    return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
                }
            }
            
            // Get the icon on main thread
            let folderIconResult = NSWorkspace.shared.icon(forFile: pathToLoad)
            
            await MainActor.run {
                // Use asyncAfter to ensure we're not in the middle of a constraint update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // Verify we're still looking at the same folder (user might have navigated away)
                    guard self.currentFolderPath == pathToLoad else { return }
                    
                    self.folderName = name
                    self.folderIcon = folderIconResult
                    self.folderItems = sortedItems
                    self.isLoading = false
                    if !sortedItems.isEmpty {
                        self.selectedItemIndex = 0
                        // Update parent's selected file context
                        self.selectedFilePath = sortedItems[0].path
                    }
                }
            }
        }
    }
    
    private func openItem(_ item: FolderItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        closePreview()
    }
    
    private func navigateItems(direction: Int, horizontal: Bool = false) {
        guard !folderItems.isEmpty else { return }

        // Mark as keyboard navigation to enable auto-scroll
        selectionByKeyboard = true

        if let currentIndex = selectedItemIndex {
            var newIndex: Int

            if viewMode == .grid && horizontal {
                // In grid view with horizontal navigation
                // Estimate columns based on grid width (100-150px per item + spacing)
                // For 700px width: ~4-5 columns
                let estimatedColumns = 5 // Average column count in grid

                if direction > 0 {
                    // Right arrow - move right
                    newIndex = currentIndex + 1
                } else {
                    // Left arrow - move left
                    newIndex = currentIndex - 1
                }
            } else if viewMode == .grid && !horizontal {
                // In grid view with vertical navigation (up/down)
                let estimatedColumns = 5

                if direction > 0 {
                    // Down arrow - move down one row
                    newIndex = currentIndex + estimatedColumns
                } else {
                    // Up arrow - move up one row
                    newIndex = currentIndex - estimatedColumns
                }
            } else {
                // List view - simple linear navigation
                newIndex = currentIndex + direction
            }

            // Clamp to valid range
            if newIndex >= 0 && newIndex < folderItems.count {
                selectedItemIndex = newIndex
                // Update parent's selected file context
                selectedFilePath = folderItems[newIndex].path
            }
        } else {
            let newIndex = direction > 0 ? 0 : folderItems.count - 1
            selectedItemIndex = newIndex
            // Update parent's selected file context
            selectedFilePath = folderItems[newIndex].path
        }
    }
}

// MARK: - Folder Quick Look Data Source
class FolderQuickLookDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let urls: [URL]
    weak var folderPreviewWindow: NSWindow?
    
    init(urls: [URL], folderPreviewWindow: NSWindow? = nil) {
        self.urls = urls
        self.folderPreviewWindow = folderPreviewWindow
        super.init()
    }
    
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return urls.count
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0 && index < urls.count else { return nil }
        return urls[index] as NSURL
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown {
            switch event.keyCode {
            case 53: // Escape key - close Quick Look only
                panel.orderOut(nil)
                // Restore focus to the main window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let window = self.folderPreviewWindow ?? NSApp.windows.first(where: { $0.isVisible && $0 != panel }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                return true
            case 49: // Space - also close Quick Look (toggle behavior)
                panel.orderOut(nil)
                // Restore focus to the main window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let window = self.folderPreviewWindow ?? NSApp.windows.first(where: { $0.isVisible && $0 != panel }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                return true
            default:
                break
            }
        }
        return false
    }
    
    // Keep the folder preview window visible when Quick Look opens
    func previewPanelDidBecomeKey(_ panel: QLPreviewPanel!) {
        // Don't let Quick Look hide our window
    }
}

// MARK: - Folder Preview Keyboard Handler
class FolderPreviewKeyboardHandler: ObservableObject {
    enum KeyAction {
        case navigateUp
        case navigateDown
        case navigateInto      // Right arrow - enter subfolder
        case navigateBack      // Left arrow - go to parent folder
        case open
        case close
        case quickLook
        case quickLookNext     // Navigate to next item while Quick Look is open
        case quickLookPrevious // Navigate to previous item while Quick Look is open
    }
    
    @Published var lastAction: KeyAction? = nil
    @Published var isQuickLookActive: Bool = false
    private var monitor: Any? = nil
    private var isClosing: Bool = false // Prevent multiple close attempts
    
    // Closure to call directly for close action (avoids @Published timing issues)
    var onCloseRequested: (() -> Void)?
    
    func startMonitoring() {
        // Remove any existing monitor first
        stopMonitoring()
        isClosing = false
        
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, !self.isClosing else { return event }
            
            let quickLookVisible = QLPreviewPanel.shared()?.isVisible ?? false
            
            // When Quick Look is visible, handle navigation differently
            if quickLookVisible {
                switch event.keyCode {
                case 126: // Up arrow - navigate to previous item and update Quick Look
                    DispatchQueue.main.async {
                        self.lastAction = .quickLookPrevious
                    }
                    return nil
                case 125: // Down arrow - navigate to next item and update Quick Look
                    DispatchQueue.main.async {
                        self.lastAction = .quickLookNext
                    }
                    return nil
                case 49: // Space - close Quick Look
                    QLPreviewPanel.shared()?.orderOut(nil)
                    // Restore focus to main window
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if let window = NSApp.windows.first(where: { $0.isVisible && $0 != QLPreviewPanel.shared() }) {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                    return nil
                case 53: // Escape - close Quick Look only
                    QLPreviewPanel.shared()?.orderOut(nil)
                    // Restore focus to main window
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if let window = NSApp.windows.first(where: { $0.isVisible && $0 != QLPreviewPanel.shared() }) {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                    return nil
                case 36: // Return - open the file and close everything
                    DispatchQueue.main.async {
                        self.lastAction = .open
                    }
                    return nil
                default:
                    return event
                }
            }
            
            // Normal handling when Quick Look is not visible
            switch event.keyCode {
            case 126: // Up arrow
                DispatchQueue.main.async {
                    self.lastAction = .navigateUp
                }
                return nil
            case 125: // Down arrow
                DispatchQueue.main.async {
                    self.lastAction = .navigateDown
                }
                return nil
            case 124: // Right arrow - navigate into subfolder
                DispatchQueue.main.async {
                    self.lastAction = .navigateInto
                }
                return nil
            case 123: // Left arrow - go back to parent
                DispatchQueue.main.async {
                    self.lastAction = .navigateBack
                }
                return nil
            case 36: // Return
                DispatchQueue.main.async {
                    self.lastAction = .open
                }
                return nil
            case 49: // Space - Quick Look the selected item
                print("⌨️ Space key detected in folder preview")
                DispatchQueue.main.async {
                    print("⌨️ Setting lastAction to .quickLook")
                    self.lastAction = .quickLook
                }
                return nil
            case 53: // Escape - Close the preview
                // Mark as closing to prevent re-entry
                self.isClosing = true
                // Stop monitoring immediately
                self.stopMonitoring()
                // Call the close handler directly with a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.onCloseRequested?()
                }
                return nil
            default:
                return event
            }
        }
    }
    
    func stopMonitoring() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
    
    deinit {
        stopMonitoring()
    }
}

// MARK: - Keyboard Hint Badge
struct KeyboardHintBadge: View {
    let keys: String
    let action: String
    
    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: .tertiaryLabelColor).opacity(0.2))
                .cornerRadius(4)
            
            Text(action)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Contact Preview Card
struct ContactPreviewCard: View {
    let contact: SearchResult
    @Binding var isPresented: Bool
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        isPresented = false
                    }
                }

            // Contact card
            VStack(spacing: 0) {
                // Header with close button
                HStack {
                    Text(contact.title)
                        .font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Button(action: {
                        withAnimation {
                            isPresented = false
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // Contact details
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Profile section
                        VStack(spacing: 12) {
                            if let icon = contact.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 80)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.gray.opacity(0.2), lineWidth: 2))
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(
                                            colors: [Color.purple.opacity(0.6), Color.blue.opacity(0.6)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ))
                                        .frame(width: 80, height: 80)

                                    Text(getInitials())
                                        .font(.system(size: 32, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                            }

                            Text(contact.title)
                                .font(.system(size: 20, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                        Divider()

                        // All Emails
                        if let contactData = contact.contactData, !contactData.allEmails.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Email")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(contactData.allEmails, id: \.self) { email in
                                    ContactDetailRow(
                                        icon: "envelope.fill",
                                        label: "",
                                        value: email,
                                        action: {
                                            if let url = URL(string: "mailto:\(email)") {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                    )
                                }
                            }
                        }

                        // All Phones
                        if let contactData = contact.contactData, !contactData.allPhones.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Phone")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(contactData.allPhones, id: \.self) { phone in
                                    ContactDetailRow(
                                        icon: "phone.fill",
                                        label: "",
                                        value: phone,
                                        action: {
                                            if let url = URL(string: "tel:\(phone)") {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                    )
                                }
                            }
                        }

                        Divider()

                        // Action buttons
                        HStack(spacing: 12) {
                            if let contactData = contact.contactData {
                                if !contactData.primaryEmail.isEmpty {
                                    Button(action: {
                                        if let url = URL(string: "mailto:\(contactData.primaryEmail)") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }) {
                                        Label("Email", systemImage: "envelope.fill")
                                    }
                                    .buttonStyle(.bordered)

                                    Button(action: {
                                        if let url = URL(string: "imessage:\(contactData.primaryEmail)") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }) {
                                        Label("Message", systemImage: "message.fill")
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if !contactData.primaryPhone.isEmpty {
                                    Button(action: {
                                        if let url = URL(string: "tel:\(contactData.primaryPhone)") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }) {
                                        Label("Call", systemImage: "phone.fill")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }

                            Spacer()

                            Button(action: {
                                contact.action() // Opens in Contacts.app
                            }) {
                                Label("Open", systemImage: "person.crop.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 8)
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(width: 450, height: 500)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 15)
            .opacity(settings.folderPreviewOpacity)
        }
        .onKeyPress(.escape) {
            withAnimation {
                isPresented = false
            }
            return .handled
        }
    }

    private func getInitials() -> String {
        let components = contact.title.components(separatedBy: " ")
        if components.count >= 2 {
            let first = components[0].prefix(1)
            let last = components[components.count - 1].prefix(1)
            return "\(first)\(last)".uppercased()
        } else if let first = components.first?.prefix(1) {
            return first.uppercased()
        }
        return "?"
    }
}

struct ContactDetailRow: View {
    let icon: String
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.lowercase)

            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Text(value)
                    .font(.system(size: 14))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .contentShape(Rectangle())
            .onTapGesture {
                action()
            }
        }
    }
}

// MARK: - Contact Quick Action Button
struct ContactQuickActionButton: View {
    let icon: String
    let color: SwiftUI.Color
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.12))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

// MARK: - Resize Handle Component
struct ResizeHandle: View {
    @Binding var isDragging: Bool
    @State private var isHovering: Bool = false

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(isHovering || isDragging ? 0.2 : 0.1), radius: 4)

            // Resize icon (diagonal arrows)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering || isDragging ? .primary : .secondary)
                .rotationEffect(.degrees(90))
        }
        .padding(12)
        .opacity(isDragging ? 1.0 : (isHovering ? 0.9 : 0.6))
        .scaleEffect(isDragging ? 1.15 : (isHovering ? 1.05 : 1.0))
        .animation(.easeInOut(duration: 0.15), value: isDragging)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else if !isDragging {
                NSCursor.pop()
            }
        }
        .help("Drag to resize • 75% of screen by default")
    }
}

// MARK: - Folder Item Row
struct FolderItemRow: View {
    let item: FolderPreviewView.FolderItem
    let isSelected: Bool
    var iconSize: CGFloat = 32

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: iconSize, height: iconSize)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(item.size)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    
                    Text("•")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    
                    Text(item.modifiedDate)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

// MARK: - AI Chat Models
/// Spotlight-style context: set when user presses Tab/→ on any search result
struct SearchContextApp {
    let name: String
    let icon: NSImage?
    let key: String?                           // customAppEntries key (apps with assigned tools)
    let appPath: String                        // .app path (empty for non-apps)
    let resultType: SearchResult.ResultType    // type of item (app, file, folder, contact, etc.)
    let filePath: String?                      // full path for files/folders
    let subtitle: String                       // subtitle from result row (path, email, etc.)
    let contactEmail: String?                  // for contacts
    let contactPhone: String?                  // for contacts

    /// Human-readable description for the AI system prompt
    var aiContextDescription: String {
        switch resultType {
        case .application: return "the app \(name) (\(appPath))"
        case .file, .document: return "the file \(name) at \(filePath ?? subtitle)"
        case .folder: return "the folder \(name) at \(filePath ?? subtitle)"
        case .contact: return "the contact \(name)\(contactEmail.map { " (\($0))" } ?? "")"
        case .calendarEvent: return "the calendar event \(name)"
        case .reminder: return "the reminder \(name)"
        case .note: return "the note \(name)"
        case .mail: return "the email \(name)"
        case .shortcut: return "the shortcut \(name)"
        case .cliTool: return "the CLI tool '\(name)' installed at \(filePath ?? appPath)"
        default: return "\(name)"
        }
    }
}

struct AIChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    let content: String
    let timestamp: Date
    var isError: Bool
    var structuredData: String? // JSON data from extensions
    var hasInstallButton: Bool // Show "Add to Extensions" button

    enum ChatRole {
        case user
        case assistant
        case tool     // terminal command chip (shown while running)
        case approval // inline approve/deny card (replaces popup window)
    }

    init(role: ChatRole, content: String, isError: Bool = false, structuredData: String? = nil, hasInstallButton: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isError = isError
        self.structuredData = structuredData
        self.hasInstallButton = hasInstallButton
    }

    /// Streaming update — preserves the original UUID so the message can be updated in-place.
    init(id: UUID, role: ChatRole, content: String, isError: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isError = isError
        self.structuredData = nil
        self.hasInstallButton = false
    }

    static func == (lhs: AIChatMessage, rhs: AIChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

enum AIError: LocalizedError {
    case noAPIKey
    case noEndpoint
    case noModel
    case requestFailed
    case invalidResponse
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured. Please add your API key in Settings."
        case .noEndpoint: return "No endpoint configured. Please configure the endpoint in Settings."
        case .noModel: return "No model selected. Please select a model in Settings."
        case .requestFailed: return "Request failed. Please check your connection and try again."
        case .invalidResponse: return "Invalid response from AI provider."
        case .rateLimited: return "Gemini free tier quota exceeded. Wait 1–2 minutes and try again, or switch to a different AI provider in Settings."
        }
    }
}

// MARK: - AI Chat Message View
struct AIChatMessageView: View {
    let message: AIChatMessage
    var isStreaming: Bool = false
    var onInstallExtension: (() -> Void)? = nil
    @ObservedObject private var settings = AppSettings.shared

    private var providerColor: SwiftUI.Color {
        switch settings.selectedAIProvider {
        case .onDevice: return .purple
        case .googleGemini: return .blue
        case .openAI: return .green
        case .anthropic: return .orange
        case .ollama: return .cyan
        case .shortcuts: return .indigo
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            // Avatar - uses provider icon for assistant messages
            if message.role == .assistant {
                Image(systemName: settings.selectedAIProvider.iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(providerColor)
                    .frame(width: 28, height: 28)
                    .background(providerColor.opacity(0.1))
                    .clipShape(Circle())
            }

            // Message bubble
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                // Show structured data if available
                if let structuredData = message.structuredData, message.role == .assistant {
                    VStack(alignment: .leading, spacing: 8) {
                        if !message.content.isEmpty {
                            MarkdownMessageView(
                                content: message.content,
                                isError: message.isError
                            )
                        }

                        AIResultViewer(jsonString: structuredData)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    HStack(alignment: .bottom, spacing: 4) {
                        MarkdownMessageView(
                            content: message.content.isEmpty && isStreaming ? "" : message.content,
                            isError: message.isError
                        )
                        if isStreaming {
                            // Blinking cursor while Apple Intelligence streams
                            Rectangle()
                                .fill(providerColor)
                                .frame(width: 2, height: 14)
                                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isStreaming)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(message.role == .user ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.1))
                    )
                }

                // Add to Extensions button for AI-suggested extensions
                if message.hasInstallButton, let onInstall = onInstallExtension {
                    Button(action: onInstall) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add to Extensions")
                                .fontWeight(.medium)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color.cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                Text(message.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // User avatar
            if message.role == .user {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Circle())
            }

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - Tool Selection Inline View
struct ToolSelectionInlineView: View {
    let pending: L2AITaskExecutor.PendingToolChoice
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a tool")
                .font(.headline)
            Text(pending.stepDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(pending.tools, id: \.self) { tool in
                Button {
                    onSelect(tool)
                } label: {
                    HStack {
                        Text(tool)
                            .font(.body)
                        Spacer()
                        if !L2AITaskExecutor.TerminalTool.isInstalled(tool) {
                            Text("Install")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.08))
                )
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - AI Loading View
struct AILoadingView: View {
    @State private var animationOffset: CGFloat = 0
    @ObservedObject private var settings = AppSettings.shared
    
    private var providerColor: SwiftUI.Color {
        switch settings.selectedAIProvider {
        case .onDevice: return .purple
        case .googleGemini: return .blue
        case .openAI: return .green
        case .anthropic: return .orange
        case .ollama: return .cyan
        case .shortcuts: return .indigo
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // AI Avatar - uses provider icon
            Image(systemName: settings.selectedAIProvider.iconName)
                .font(.system(size: 16))
                .foregroundStyle(providerColor)
                .frame(width: 28, height: 28)
                .background(providerColor.opacity(0.1))
                .clipShape(Circle())
            
            // Loading indicator
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(providerColor.opacity(0.6))
                        .frame(width: 8, height: 8)
                        .offset(y: animationOffset)
                        .animation(
                            Animation.easeInOut(duration: 0.5)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                            value: animationOffset
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
            .onAppear {
                animationOffset = -5
            }
            
            Spacer(minLength: 40)
        }
    }
}

/// MARK: - Adapter Action Approval Overlay

struct AdapterApprovalOverlay: View {
    let request: AdapterActionRequest
    @State private var isHoveringAllow = false
    @State private var isHoveringDeny  = false

    private var typeLabel: String {
        switch request.action.type {
        case .menubar:     return "Menu Bar: \(request.action.menuPath?.joined(separator: " › ") ?? "")"
        case .applescript: return "AppleScript"
        case .jxa:         return "JXA Script"
        case .shell:       return "Shell Command"
        case .urlScheme:   return "Open URL: \(request.action.urlScheme ?? "")"
        case .shortcut:    return "Shortcut: \(request.action.shortcutName ?? "")"
        case .aiPrompt:    return "AI Prompt"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { request.onDeny() }

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: request.action.isDestructive ? "exclamationmark.triangle.fill" : "app.connected.to.app.below.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(request.action.isDestructive ? .red : .accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ILauncher wants to:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(request.action.name)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider().opacity(0.5)

                // Details
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "app.badge.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("App: \(request.adapter.appName)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(typeLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !request.action.description.isEmpty {
                        Text(request.action.description)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider().opacity(0.5)

                // Buttons
                HStack(spacing: 8) {
                    Button { request.onDeny() } label: {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                isHoveringDeny ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringDeny = $0 }

                    Button { request.onApprove() } label: {
                        Text("Allow")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                request.action.isDestructive
                                    ? (isHoveringAllow ? Color.red.opacity(0.85) : Color.red.opacity(0.7))
                                    : (isHoveringAllow ? Color.accentColor.opacity(0.9) : Color.accentColor.opacity(0.75)),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringAllow = $0 }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        request.action.isDestructive ? Color.red.opacity(0.35) : Color.primary.opacity(0.12),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
        }
    }
}

// MARK: - L2 Extension Chip Button
struct L2ExtensionChipButton: View {
    let extensionResult: ExtensionDiscoveryResult
    let currentContext: UserContext
    let onExecute: (ILExtension, UserContext) async -> Void

    @State private var isHovered = false
    @State private var isExecuting = false

    private var chipColor: SwiftUI.Color {
        switch extensionResult.relevanceScore {
        case 0.5...:
            return .blue
        case 0.3..<0.5:
            return .green
        default:
            return .gray
        }
    }

    var body: some View {
        Button(action: {
            Task {
                isExecuting = true
                await onExecute(extensionResult.ilExtension, currentContext)
                isExecuting = false
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: extensionResult.ilExtension.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(chipColor)

                Text(extensionResult.ilExtension.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? chipColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(chipColor.opacity(isHovered ? 0.8 : 0.3), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - AI Extension Chip Button
struct AIExtensionChipButton: View {
    let suggestion: SuggestedExtension
    let context: UserContext
    @Binding var aiChatMessages: [AIChatMessage]

    @State private var isHovered = false
    @State private var isExecuting = false

    private var chipColor: SwiftUI.Color {
        switch suggestion.relevanceScore {
        case 90...:
            return .green
        case 70..<90:
            return .blue
        default:
            return .orange
        }
    }

    var body: some View {
        Button(action: {
            executeExtension()
        }) {
            HStack(spacing: 6) {
                // Icon
                Image(systemName: suggestion.scriptExtension.type.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(chipColor)

                // Title
                Text(suggestion.scriptExtension.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Loading indicator
                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }

                // Star for high relevance
                if suggestion.relevanceScore >= 90 {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? chipColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(chipColor.opacity(isHovered ? 0.8 : 0.3), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(suggestion.reason)
    }

    private func executeExtension() {
        isExecuting = true

        // Add user action message to chat
        let actionMessage = AIChatMessage(
            role: .user,
            content: "Run \(suggestion.scriptExtension.displayName)"
        )
        aiChatMessages.append(actionMessage)

        Task {
            do {
                let input = getInputFromContext()
                print("🔧 [Extension] Executing: \(suggestion.scriptExtension.displayName)")
                print("🔧 [Extension] Input: \(input.prefix(100))...")

                let result = try await suggestion.scriptExtension.execute(with: input)

                print("✅ [Extension] Result: \(result.prefix(200))...")

                await MainActor.run {
                    isExecuting = false

                    // Add result to chat
                    let resultMessage = AIChatMessage(
                        role: .assistant,
                        content: result.isEmpty ? "✅ Completed successfully" : result,
                        isError: false
                    )
                    aiChatMessages.append(resultMessage)
                }
            } catch {
                print("❌ [Extension] Error: \(error.localizedDescription)")

                await MainActor.run {
                    isExecuting = false

                    // Add error to chat
                    let errorMessage = AIChatMessage(
                        role: .assistant,
                        content: "❌ Error: \(error.localizedDescription)",
                        isError: true
                    )
                    aiChatMessages.append(errorMessage)
                }
            }
        }
    }

    private func getInputFromContext() -> String {
        switch context {
        case .filesSelected(let urls):
            return urls.map { $0.path }.joined(separator: "\n")
        case .textSelected(let text):
            return text
        case .url(let urlString):
            return urlString
        case .appFocused(let name, _):
            return name
        case .contactSelected(let contact):
            return contact
        case .none:
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
    }
}

// MARK: - Markdown Message View
struct MarkdownMessageView: View {
    let content: String
    let isError: Bool

    @State private var parsedBlocks: [MessageBlock] = []

    enum MessageBlock: Identifiable {
        case text(String)
        case codeBlock(code: String, language: String?)

        var id: String {
            switch self {
            case .text(let s): return "text-\(s.hashValue)"
            case .codeBlock(let code, _): return "code-\(code.hashValue)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parsedBlocks) { block in
                switch block {
                case .text(let text):
                    if #available(macOS 12.0, *) {
                        Text(attributedMarkdown(text))
                            .font(.system(size: 13))
                            .foregroundStyle(isError ? .red : .primary)
                            .textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { url in
                                NSWorkspace.shared.open(url)
                                return .handled
                            })
                    } else {
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(isError ? .red : .primary)
                            .textSelection(.enabled)
                    }

                case .codeBlock(let code, let language):
                    CodeBlockView(code: code, language: language)
                }
            }
        }
        .onAppear {
            parseContent()
        }
    }

    private func parseContent() {
        var blocks: [MessageBlock] = []

        // Pattern to match ```language\ncode``` blocks
        let pattern = "```([a-zA-Z]*)\\n([\\s\\S]*?)```"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            blocks.append(.text(content))
            parsedBlocks = blocks
            return
        }

        let range = NSRange(content.startIndex..., in: content)
        var lastIndex = content.startIndex

        regex.enumerateMatches(in: content, range: range) { match, _, _ in
            guard let match = match else { return }

            // Text before code block
            guard let matchRange = Range(match.range, in: content) else { return }
            addTextBlockIfNotEmpty(from: lastIndex, to: matchRange.lowerBound, into: &blocks)

            // Code block
            if match.numberOfRanges >= 3,
               let langRange = Range(match.range(at: 1), in: content),
               let codeRange = Range(match.range(at: 2), in: content) {
                let language = String(content[langRange])
                let code = String(content[codeRange])
                blocks.append(.codeBlock(code: code, language: language.isEmpty ? nil : language))
            }

            lastIndex = matchRange.upperBound
        }

        // Remaining text
        addTextBlockIfNotEmpty(from: lastIndex, to: content.endIndex, into: &blocks)

        // If no blocks found, treat as single text block
        if blocks.isEmpty {
            blocks.append(.text(content))
        }

        parsedBlocks = blocks
    }
    
    private func addTextBlockIfNotEmpty(from start: String.Index, to end: String.Index, into blocks: inout [MessageBlock]) {
        guard start < end else { return }
        let text = String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.append(.text(text))
        }
    }

    @available(macOS 12.0, *)
    private func attributedMarkdown(_ text: String) -> AttributedString {
        do {
            var attributed = try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )

            return attributed
        } catch {
            return AttributedString(text)
        }
    }
}

// MARK: - Code Block View
struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var copied = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language, save, and copy buttons
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Save to Extensions button
                Button(action: saveToExtensions) {
                    HStack(spacing: 4) {
                        Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .font(.system(size: 11))
                        Text(saved ? "Saved" : "Save")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(saved ? .green : .blue)
                }
                .buttonStyle(.plain)
                .help("Save to Extensions folder")

                // Copy button
                Button(action: copyCode) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.05))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color.black.opacity(0.02))
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }

    private func saveToExtensions() {
        Task {
            do {
                // Extract extension metadata from code
                let extensionName = extractExtensionName(from: code)
                let layer = extractExtensionLayer(from: code)
                let activeAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
                await MainActor.run {
                    let scriptType = determineExtensionScriptType(from: code, language: language)
                    let category = inferExtensionCategory(layer: layer, appName: activeAppName)
                    let triggers = buildExtensionTriggers(layer: layer, appName: activeAppName)
                    let ext = ILExtension(
                        name: extensionName,
                        description: "Saved from AI",
                        icon: "sparkles",
                        layer: layer.contains("l1") ? .l1_search : (layer.contains("l3") ? .l3_browser : .l2_context),
                        tags: [.automation],
                        category: category,
                        triggers: triggers,
                        scriptPath: "",
                        scriptContent: code,
                        scriptType: scriptType,
                        isBuiltIn: false
                    )

                    LayeredExtensionManager.shared.addExtension(ext)
                    saved = true

                    // Reset after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saved = false
                    }
                }

                print("✅ Saved extension to Documents/ILauncher/Extensions")

            } catch {
                print("❌ Failed to save extension: \(error.localizedDescription)")
            }
        }
    }

    private func extractExtensionName(from code: String) -> String {
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Extension:") {
                return line.replacingOccurrences(of: "# Extension:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "extension_\(Int(Date().timeIntervalSince1970))"
    }

    private func extractExtensionLayer(from code: String) -> String {
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Layer:") {
                return line.replacingOccurrences(of: "# Layer:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "l2_context"
    }

    private func determineExtensionScriptType(from code: String, language: String? = nil) -> ILExtension.ScriptType {
        if code.hasPrefix("#!/bin/bash") || code.hasPrefix("#!/usr/bin/env bash") || code.hasPrefix("#!/bin/sh") || language == "bash" || language == "sh" {
            return .bash
        }
        if code.hasPrefix("#!/usr/bin/env python") || code.hasPrefix("#!/usr/bin/python") || language == "python" {
            return .python
        }
        if code.hasPrefix("#!/usr/bin/osascript") || language == "applescript" {
            return .applescript
        }
        return .bash
    }

    private func inferExtensionCategory(layer: String, appName: String) -> String {
        let normalized = appName.lowercased()
        if layer.contains("l2") {
            if normalized.contains("safari") || normalized.contains("chrome") || normalized.contains("arc") {
                return "browser"
            }
            if normalized.contains("finder") {
                return "finder"
            }
            if normalized.contains("mail") {
                return "mail"
            }
            if normalized.contains("notes") || normalized.contains("textedit") {
                return "text-editor"
            }
            if normalized.contains("xcode") || normalized.contains("vscode") {
                return "code-editor"
            }
        }
        if layer.contains("l3") {
            return "page-enhancers"
        }
        return "custom"
    }

    private func buildExtensionTriggers(layer: String, appName: String) -> [ExtensionTrigger] {
        if layer.contains("l2"), !appName.isEmpty {
            return [.appContext(appName)]
        }
        return [.always]
    }
}

// MARK: - Notification Panel

struct NotificationPanelView: View {
    @ObservedObject private var manager = ILauncherNotificationManager.shared

    private func color(for name: String) -> SwiftUI.Color {
        switch name {
        case "green":  return .green
        case "red":    return .red
        case "orange": return .orange
        case "purple": return .purple
        case "teal":   return .teal
        default:       return .blue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Notifications")
                    .font(.headline)
                if manager.unreadCount > 0 {
                    Text("\(manager.unreadCount)")
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                if !manager.notifications.isEmpty {
                    Button("Mark all read") { manager.markAllRead() }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    Button(action: { manager.clearAll() }) {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if manager.notifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No notifications")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.notifications) { n in
                            Button(action: { manager.tap(n.id) }) {
                                HStack(spacing: 10) {
                                    Image(systemName: n.icon)
                                        .font(.system(size: 16))
                                        .foregroundStyle(color(for: n.accentColor))
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(n.title)
                                            .font(.subheadline)
                                            .fontWeight(n.isRead ? .regular : .semibold)
                                            .lineLimit(1)
                                        Text(n.body)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        Text(n.date, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }

                                    Spacer()

                                    if !n.isRead {
                                        Circle()
                                            .fill(color(for: n.accentColor))
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(n.isRead ? Color.clear : Color.white.opacity(0.04))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Mark as Read") { manager.markRead(n.id) }
                                Button("Remove", role: .destructive) { manager.remove(n.id) }
                            }
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pinned App Drop Delegate for Reordering
struct PinnedAppDropDelegate: DropDelegate {
    let item: PinnedApp
    @Binding var pinnedApps: [PinnedApp]
    let settings: AppSettings
    
    func performDrop(info: DropInfo) -> Bool {
        return true
    }
    
    func dropEntered(info: DropInfo) {
        // Get the dragged item ID
        guard let itemProvider = info.itemProviders(for: [.text]).first else { return }
        
        itemProvider.loadItem(forTypeIdentifier: "public.text", options: nil) { (data, error) in
            guard let data = data as? Data,
                  let draggedIdString = String(data: data, encoding: .utf8),
                  let draggedId = UUID(uuidString: draggedIdString) else { return }
            
            DispatchQueue.main.async {
                // Find the indices
                guard let fromIndex = self.pinnedApps.firstIndex(where: { $0.id == draggedId }),
                      let toIndex = self.pinnedApps.firstIndex(where: { $0.id == self.item.id }),
                      fromIndex != toIndex else { return }
                
                // Perform the reorder with animation
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    let movedItem = self.pinnedApps.remove(at: fromIndex)
                    self.pinnedApps.insert(movedItem, at: toIndex)
                }
                
                print("📌 Reordered pinned items: moved '\(self.pinnedApps[toIndex].name)' from index \(fromIndex) to \(toIndex)")
            }
        }
    }
}

// MARK: - Two Finger Swipe Gesture Helper
struct TwoFingerSwipeGestureView: NSViewRepresentable {
    let onSwipeUp: () -> Void
    let onSwipeDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = SwipeDetectorView()
        view.onSwipeUp = onSwipeUp
        view.onSwipeDown = onSwipeDown
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? SwipeDetectorView {
            view.onSwipeUp = onSwipeUp
            view.onSwipeDown = onSwipeDown
        }
    }

    class SwipeDetectorView: NSView {
        var onSwipeUp: (() -> Void)?
        var onSwipeDown: (() -> Void)?

        private var accumulatedDeltaY: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // Make this view able to receive scroll events but NOT block clicks
            self.wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { false }

        // Don't block mouse clicks - pass them through
        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }

        override func scrollWheel(with event: NSEvent) {
            let deltaX = abs(event.scrollingDeltaX)
            let deltaY = abs(event.scrollingDeltaY)

            // ALWAYS pass through horizontal scroll immediately (for pinned apps scrolling)
            // Only intercept vertical swipes for switching modes
            if deltaX > deltaY {
                super.scrollWheel(with: event)
                return
            }

            // Only handle vertical swipes
            // Reset accumulator on new gesture
            if event.phase == .began {
                accumulatedDeltaY = 0
            }

            // Accumulate delta during gesture
            if event.phase == .changed || event.phase == .began {
                accumulatedDeltaY += event.scrollingDeltaY
            }

            // Check accumulated delta when gesture ends
            if event.phase == .ended {
                if abs(accumulatedDeltaY) > 30 {
                    if accumulatedDeltaY > 0 {
                        onSwipeDown?()
                    } else {
                        onSwipeUp?()
                    }
                    return
                }
            }

            // Pass through if not handled
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - Browser Item Components
struct BrowserItemCard: View {
    let item: BrowserItem
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                // Favicon/Icon
                Image(systemName: item.favicon ?? "globe")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue.opacity(0.8))
                    .frame(width: 60, height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue.opacity(0.1))
                    )

                // Title
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 100)
            .scaleEffect(isHovering ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct BrowserItemRow: View {
    let item: BrowserItem
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Favicon/Icon
                Image(systemName: item.favicon ?? "globe")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                    )

                // Title and URL
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(item.url)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Arrow indicator
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(isHovering ? 1.0 : 0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering ? Color.primary.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Bookmark Card Component
struct BookmarkCard: View {
    let bookmark: BrowserItem
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "safari")
                        .foregroundStyle(.blue)
                        .font(.title3)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(bookmark.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    Text(bookmark.url)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, height: 100)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Color.blue.opacity(0.1) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovering ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Recent Search Row Component
struct RecentSearchRow: View {
    let search: String
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.gray)
                    .font(.system(size: 14))
                    .frame(width: 20)

                Text(search)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "arrow.up.left")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Color.primary.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// Preview commented out due to init parameter changes
// #Preview {
//     LauncherView(onClose: {})
//         .frame(width: 600)
//         .padding()
// }

// MARK: - Glass Background

/// NSVisualEffectView wrapped in SwiftUI — provides true wallpaper-blur glass effect.
/// Rounded corners are applied at the AppKit layer so they clip the blur itself.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    @ObservedObject private var settings = AppSettings.shared

    func makeNSView(context: Context) -> NSVisualEffectView {
        let ve = NSVisualEffectView()
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        configure(ve)
        return ve
    }

    func updateNSView(_ ve: NSVisualEffectView, context: Context) {
        configure(ve)
    }

    private func configure(_ ve: NSVisualEffectView) {
        ve.layer?.cornerRadius = cornerRadius
        ve.layer?.masksToBounds = true

        let isLight = isLightMode
        switch settings.appearanceMode {
        case "light":
            ve.material = .popover
            ve.appearance = NSAppearance(named: .aqua)
        case "dark":
            ve.material = .popover
            ve.appearance = NSAppearance(named: .darkAqua)
        default:
            ve.material = .popover
            ve.appearance = nil
        }

        // Specular top-edge highlight (looks like light catching the glass edge)
        ve.layer?.sublayers?.filter { $0.name == "specularHighlight" }.forEach { $0.removeFromSuperlayer() }
        if ve.bounds.height > 0 {
            let highlight = CAGradientLayer()
            highlight.name = "specularHighlight"
            // Light mode: strong white highlight; dark mode: subtle
            let alpha: CGFloat = isLight ? 0.5 : 0.18
            highlight.colors = [
                CGColor(red: 1, green: 1, blue: 1, alpha: alpha),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
            ]
            highlight.startPoint = CGPoint(x: 0.5, y: 1)
            highlight.endPoint   = CGPoint(x: 0.5, y: 0)
            highlight.frame = CGRect(x: 0, y: ve.bounds.height - 2, width: ve.bounds.width, height: 2)
            highlight.cornerRadius = cornerRadius
            ve.layer?.addSublayer(highlight)
        }
    }

    private var isLightMode: Bool {
        if settings.appearanceMode == "light" { return true }
        if settings.appearanceMode == "dark"  { return false }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }
}

extension View {
    /// Wraps a view in the full glass-pill container: NSVisualEffectView blur + specular border stroke + shadow.
    func glassContainer(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(GlassBackground(cornerRadius: cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - View helpers

extension View {
    /// Applies a transform only when an optional value is non-nil.
    @ViewBuilder
    func ifLet<T, V: View>(_ value: T?, transform: (Self, T) -> V) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - NSSharingServicePicker dismiss coordinator

/// Lightweight Obj-C object that acts as NSSharingServicePickerDelegate.
/// Calls `onDismiss` after the user picks a service or cancels the picker.
final class SharePickerCoordinator: NSObject, NSSharingServicePickerDelegate {
    static var key = 0   // used as objc_setAssociatedObject key
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        DispatchQueue.main.async { self.onDismiss() }
    }
}
